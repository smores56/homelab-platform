// Builds a minimal restic repository for the reader tests. The real backup
// fixtures are tens of megabytes and were not ported; this writes one small
// repository with the same on-disk shapes: scrypt key file, sealed config,
// sealed snapshot files, one pack, and one index that maps every blob.
//
// The sealing here is the inverse of src/restic/crypto.ts (AES-CTR + AES-ECB
// Poly1305), so a change to the reader's format breaks these tests immediately.

import { ctr, ecb } from "@noble/ciphers/aes.js";
import { oneTimeAuth } from "@stablelib/poly1305";
import { scrypt } from "hash-wasm";

type MasterKey = { encrypt: Uint8Array; mac: { k: Uint8Array; r: Uint8Array } };

type Blob = { id: string; type: "data" | "tree"; sealed: Uint8Array };

const encoder = new TextEncoder();

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes as BufferSource));
  let out = "";
  for (const byte of digest) out += byte.toString(16).padStart(2, "0");
  return out;
}

function seal(plain: Uint8Array, master: MasterKey): Uint8Array {
  const nonce = crypto.getRandomValues(new Uint8Array(16));
  const ciphertext = ctr(master.encrypt, nonce).encrypt(plain);
  const s = ecb(master.mac.k).encrypt(nonce);
  const tag = oneTimeAuth(concat(master.mac.r, s), ciphertext);
  return concat(nonce, ciphertext, tag);
}

function sealJson(value: unknown, master: MasterKey): Uint8Array {
  return seal(encoder.encode(JSON.stringify(value)), master);
}

async function keyFile(password: string, master: MasterKey): Promise<string> {
  const salt = crypto.getRandomValues(new Uint8Array(16));
  const derived = await scrypt({
    password,
    salt,
    costFactor: 1024,
    blockSize: 8,
    parallelism: 1,
    hashLength: 64,
    outputType: "binary",
  });
  const encKey = derived.slice(0, 32);
  const keyMac = { k: derived.slice(32, 48), r: derived.slice(48, 64) };
  const masterJson = encoder.encode(
    JSON.stringify({
      encrypt: toBase64(master.encrypt),
      mac: { k: toBase64(master.mac.k), r: toBase64(master.mac.r) },
    }),
  );
  const sealed = seal(masterJson, { encrypt: encKey, mac: keyMac });
  return JSON.stringify({
    kdf: "scrypt",
    N: 1024,
    r: 8,
    p: 1,
    salt: toBase64(salt),
    data: toBase64(sealed),
  });
}

type FileSpec = { path: string; content: Uint8Array; blobs?: number };

function fileSpecs(): FileSpec[] {
  const longName = `${"x".repeat(210)}.txt`;
  const large = new Uint8Array(64 * 1024);
  for (let index = 0; index < large.length; index++) large[index] = index % 251;
  return [
    { path: "notes.txt", content: encoder.encode("fixture notes\n") },
    {
      path: "documents/nested/hello.txt",
      content: encoder.encode("hello from a nested document\n"),
    },
    { path: "empty.txt", content: new Uint8Array(0) },
    { path: "binary.bin", content: new Uint8Array([0, 1, 2, 255]) },
    { path: "compressible.txt", content: encoder.encode("compressible line of text\n".repeat(64)) },
    { path: longName, content: encoder.encode("long name\n") },
    { path: "large.bin", content: large, blobs: 2 },
  ];
}

export type ResticFixture = { root: string; password: string };

/**
 * Write a restic repository under `root`. The tree mirrors the platform layout:
 * `/srv/photos` holds the files, so the reader can open the same data_root the
 * manifest declares.
 */
export async function createResticFixture(
  root: string,
  password = "family-access-fixture",
): Promise<ResticFixture> {
  const master: MasterKey = {
    encrypt: crypto.getRandomValues(new Uint8Array(32)),
    mac: {
      k: crypto.getRandomValues(new Uint8Array(16)),
      r: crypto.getRandomValues(new Uint8Array(16)),
    },
  };

  await Deno.mkdir(`${root}/keys`, { recursive: true });
  await Deno.mkdir(`${root}/snapshots`, { recursive: true });
  await Deno.mkdir(`${root}/index`, { recursive: true });

  const blobs: Blob[] = [];
  const addBlob = async (type: Blob["type"], plain: Uint8Array): Promise<string> => {
    const id = await sha256Hex(plain);
    blobs.push({ id, type, sealed: seal(plain, master) });
    return id;
  };

  // Data blobs, split into the requested number of parts so the reader's
  // multi-blob path has a fixture.
  const photosNodes: Array<Record<string, unknown>> = [];
  let totalBytes = 0;
  for (const spec of fileSpecs()) {
    const parts = spec.blobs ?? (spec.content.length > 0 ? 1 : 0);
    const content: string[] = [];
    if (parts > 0) {
      const size = Math.ceil(spec.content.length / parts);
      for (let index = 0; index < parts; index++) {
        const part = spec.content.slice(index * size, (index + 1) * size);
        content.push(await addBlob("data", part));
      }
    }
    totalBytes += spec.content.length;
    const segments = spec.path.split("/");
    const name = segments.pop()!;
    let target = photosNodes;
    for (const segment of segments) {
      let node = target.find((candidate) => candidate.name === segment);
      if (!node) {
        node = { name: segment, type: "dir" };
        target.push(node);
      }
      node.children ??= [];
      target = node.children as Array<Record<string, unknown>>;
    }
    target.push({
      name,
      type: "file",
      size: spec.content.length,
      content,
    });
  }

  // Turn the nested spec into restic trees, deepest first.
  const treeIdFor = async (nodes: Array<Record<string, unknown>>): Promise<string> => {
    const out: Array<Record<string, unknown>> = [];
    for (const node of nodes) {
      if (node.type === "dir") {
        out.push({
          name: node.name,
          type: "dir",
          subtree: await treeIdFor(node.children as Array<Record<string, unknown>>),
        });
      } else {
        out.push(node);
      }
    }
    return addBlob("tree", encoder.encode(JSON.stringify({ nodes: out })));
  };

  const photosTree = await treeIdFor(photosNodes);
  const srvTree = await addBlob(
    "tree",
    encoder.encode(
      JSON.stringify({ nodes: [{ name: "photos", type: "dir", subtree: photosTree }] }),
    ),
  );
  const rootTree = await addBlob(
    "tree",
    encoder.encode(JSON.stringify({ nodes: [{ name: "srv", type: "dir", subtree: srvTree }] })),
  );

  // One pack holds every sealed blob; the index points at its offsets.
  const packBytes = concat(...blobs.map((blob) => blob.sealed));
  const packId = await sha256Hex(packBytes);
  await Deno.mkdir(`${root}/data/${packId.slice(0, 2)}`, { recursive: true });
  await Deno.writeFile(`${root}/data/${packId.slice(0, 2)}/${packId}`, packBytes);

  let offset = 0;
  const indexBlobs = blobs.map((blob) => {
    const entry = {
      id: blob.id,
      type: blob.type,
      offset,
      length: blob.sealed.length,
    };
    offset += blob.sealed.length;
    return entry;
  });
  const index = sealJson({ packs: [{ id: packId, blobs: indexBlobs }] }, master);
  await Deno.writeFile(`${root}/index/${await sha256Hex(index)}`, index);

  const config = sealJson(
    {
      version: 2,
      id: [...crypto.getRandomValues(new Uint8Array(32))]
        .map((byte) => byte.toString(16).padStart(2, "0"))
        .join(""),
      chunker_polynomial: "3da3358b4dc173",
    },
    master,
  );
  await Deno.writeFile(`${root}/config`, config);

  for (const time of ["2026-11-07T00:00:00Z", "2026-11-08T00:00:00Z"]) {
    const snapshot = sealJson(
      {
        time,
        tree: rootTree,
        paths: ["/srv/photos"],
        hostname: "fixture",
        summary: {
          total_bytes_processed: totalBytes,
          total_files_processed: fileSpecs().length,
        },
      },
      master,
    );
    await Deno.writeFile(`${root}/snapshots/${await sha256Hex(snapshot)}`, snapshot);
  }

  const key = await keyFile(password, master);
  await Deno.writeFile(`${root}/keys/${await sha256Hex(encoder.encode(key))}`, encoder.encode(key));

  return { root, password };
}
