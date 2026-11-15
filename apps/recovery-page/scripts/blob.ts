// Builds the encrypted data-keys blob that ships with the page.
//
// The blob holds one read-only R2 key pair over the shared backup bucket and one
// restic password shared by every group repository. Repository addresses come
// from the public manifest, so a new group never needs a new blob.
//
// Prompts for the recovery password (twice), encrypts the payload with
// Argon2id + AES-256-GCM, writes public/data-keys.enc, then decrypts it again
// and opens every group's newest snapshot to prove the declared data_root
// exists. There is no magic marker file: the check is the manifest itself.
//
//   deno task blob [--out public/data-keys.enc] [--manifest public/manifest.json]
//                  [--secrets ../../secrets/recovery.yaml]
//                  [--endpoint https://<account>.r2.cloudflarestorage.com]
//                  [--bucket <bucket>] [--no-check] [--check-only]
//
// `--check-only` re-runs the group check against an existing blob. It needs only
// the recovery password: the blob carries the restic and R2 credentials.
//
// Passwords are only read from the terminal: there is no password-file option.

import { type DataKeys, type DataKeysBlob, decryptBlob, encryptBlob } from "../src/blob.ts";
import { groupStore, resolveDataRoot } from "../src/groups.ts";
import {
  parseManifest,
  type RecoveryGroup,
  type RecoveryManifest,
  repositoryUrl,
} from "../src/manifest.ts";
import { normalizeDataRoot } from "../src/restore.ts";
import { R2Backend } from "../src/restic/r2.ts";
import {
  openRepository,
  type ResticRepository,
  type ResticSnapshot,
} from "../src/restic/repository.ts";
import { promptHidden, promptNewPassword, verifyBlobPassword } from "./prompt.ts";

type Args = {
  out: string;
  manifest: string;
  secrets: string;
  endpoint: string | null;
  bucket: string | null;
  check: boolean;
  checkOnly: boolean;
};

const USAGE = "usage: blob [--out public/data-keys.enc] [--manifest public/manifest.json] " +
  "[--secrets ../../secrets/recovery.yaml] [--endpoint <url>] [--bucket <name>] " +
  "[--no-check] [--check-only]";

function takeValue(argv: string[], index: number, flag: string): string {
  const value = argv[index + 1];
  if (value === undefined || value.startsWith("-")) throw new Error(`${flag} needs a value`);
  return value;
}

function parseArgs(argv: string[]): Args {
  const args: Args = {
    out: "public/data-keys.enc",
    manifest: "public/manifest.json",
    secrets: "../../secrets/recovery.yaml",
    endpoint: null,
    bucket: null,
    check: true,
    checkOnly: false,
  };
  for (let index = 0; index < argv.length; index++) {
    const value = argv[index];
    switch (value) {
      case "--out":
        args.out = takeValue(argv, index++, value);
        break;
      case "--manifest":
        args.manifest = takeValue(argv, index++, value);
        break;
      case "--secrets":
        args.secrets = takeValue(argv, index++, value);
        break;
      case "--endpoint":
        args.endpoint = takeValue(argv, index++, value);
        break;
      case "--bucket":
        args.bucket = takeValue(argv, index++, value);
        break;
      case "--no-check":
        args.check = false;
        break;
      case "--check-only":
        args.checkOnly = true;
        break;
      case "--help":
      case "-h":
        console.log(USAGE);
        Deno.exit(0);
        break;
      default:
        throw new Error(`unknown argument: ${value}`);
    }
  }
  return args;
}

async function readManifest(path: string): Promise<RecoveryManifest> {
  let text: string;
  try {
    text = await Deno.readTextFile(path);
  } catch {
    throw new Error(`${path} is missing; render it from the platform inventory first`);
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    throw new Error(`${path} is not valid JSON`);
  }
  return parseManifest(parsed);
}

/**
 * Every group repository must live on one store: the blob carries a single
 * endpoint, bucket, and read-only token. A manifest that names a second host is
 * refused rather than silently ignored.
 */
export function sharedStore(
  manifest: RecoveryManifest,
  endpoint: string | null,
  bucket: string | null,
): { endpoint: string; bucket: string } {
  const hosts = new Set<string>();
  const buckets = new Set<string>();
  for (const group of manifest.groups) {
    const url = repositoryUrl(group.repo);
    if (!url) {
      throw new Error(
        `group ${group.id} repo is not an R2 URL; the public manifest must name the R2 tier`,
      );
    }
    if (url.username || url.password || url.search || url.hash) {
      throw new Error(`group ${group.id} repo must be a bare s3 URL`);
    }
    const segments = url.pathname.split("/").filter(Boolean);
    const [groupBucket, ...prefix] = segments;
    if (!groupBucket) throw new Error(`group ${group.id} repo must name a bucket`);
    if (prefix.some((segment) => segment === "." || segment === "..")) {
      throw new Error(`group ${group.id} repo contains a traversal segment`);
    }
    hosts.add(url.host);
    buckets.add(groupBucket);
  }
  if (hosts.size !== 1) {
    throw new Error(`groups name more than one R2 host: ${[...hosts].join(", ")}`);
  }
  if (buckets.size !== 1) {
    throw new Error(`groups name more than one bucket: ${[...buckets].join(", ")}`);
  }
  const [host] = [...hosts];
  const [manifestBucket] = [...buckets];
  const resolvedEndpoint = endpoint ?? `https://${host}`;
  let endpointUrl: URL;
  try {
    endpointUrl = new URL(resolvedEndpoint);
  } catch {
    throw new Error(`--endpoint ${resolvedEndpoint} is not a URL`);
  }
  if (endpointUrl.protocol !== "https:") {
    throw new Error(`--endpoint ${resolvedEndpoint} must use https`);
  }
  if (endpointUrl.host !== host) {
    throw new Error(`--endpoint ${resolvedEndpoint} does not match the manifest host ${host}`);
  }
  if (bucket !== null && bucket !== manifestBucket) {
    throw new Error(`--bucket ${bucket} does not match the manifest bucket ${manifestBucket}`);
  }
  return { endpoint: resolvedEndpoint, bucket: manifestBucket };
}

async function readSecrets(path: string): Promise<Record<string, string>> {
  const output = await new Deno.Command("sops", {
    args: ["-d", path],
    stdout: "piped",
    stderr: "inherit",
    stdin: "inherit",
  }).output();
  if (!output.success) throw new Error(`sops failed to decrypt ${path}`);

  const secrets: Record<string, string> = {};
  for (const line of new TextDecoder().decode(output.stdout).split("\n")) {
    const match = /^([A-Za-z0-9_-]+):[ \t]*(.*)$/.exec(line);
    if (!match) continue;
    let value = match[2].trim();
    if (
      (value.startsWith('"') && value.endsWith('"')) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }
    if (value) secrets[match[1]] = value;
  }
  return secrets;
}

function requireSecret(secrets: Record<string, string>, name: string): string {
  const value = secrets[name];
  if (!value) throw new Error(`sops is missing ${name}`);
  return value;
}

/**
 * Prove one group's newest snapshot holds its declared data_root and that the
 * directory is not empty. The check-only run and the build both fail closed: a
 * data_root of "/" or a directory with nothing in it is a broken backup, not a
 * group to browse.
 */
export async function checkGroupRoot(
  repository: Pick<ResticRepository, "listDirectory">,
  snapshot: ResticSnapshot,
  group: RecoveryGroup,
): Promise<string> {
  const root = normalizeDataRoot(group.data_root);
  if (!root) throw new Error("the declared data_root is the snapshot root");
  const resolved = await resolveDataRoot(repository, snapshot, group.data_root);
  if (resolved === null) throw new Error(`the newest snapshot does not contain ${root}`);
  const entries = await repository.listDirectory(snapshot, resolved);
  if (entries.length === 0) throw new Error(`${resolved}/ is empty`);
  return resolved;
}

/**
 * Open every group's repository and prove the newest snapshot exists and holds
 * the declared data_root. Every group is attempted so one broken manifest entry
 * does not hide the rest; the command still fails if any group fails.
 */
async function checkGroups(keys: DataKeys, manifest: RecoveryManifest): Promise<void> {
  const failures: string[] = [];
  for (const group of manifest.groups) {
    try {
      const store = groupStore(keys, group);
      const backend = new R2Backend({ ...keys.r2, endpoint: store.endpoint, prefix: store.prefix });
      const repository = await openRepository(backend, keys.restic.password);
      if (repository.snapshots.length === 0) {
        throw new Error("the repository has no snapshots");
      }
      const snapshot = repository.snapshots[0];
      const resolved = await checkGroupRoot(repository, snapshot, group);
      console.log(
        `group ${group.id}: snapshot ${snapshot.id} (${snapshot.time}) contains ${resolved}/`,
      );
    } catch (error) {
      const reason = error instanceof Error ? error.message : String(error);
      failures.push(`group ${group.id}: ${reason}`);
      console.error(`group ${group.id}: FAILED: ${reason}`);
    }
  }
  if (failures.length > 0) {
    throw new Error(`${failures.length} group(s) failed: ${failures.join("; ")}`);
  }
}

async function checkExisting(args: Args): Promise<void> {
  let text: string;
  try {
    text = await Deno.readTextFile(args.out);
  } catch {
    throw new Error(`${args.out} is missing; build it first`);
  }
  const envelope = JSON.parse(text) as DataKeysBlob;
  const manifest = await readManifest(args.manifest);
  console.log("The recovery password is written on the media; it is not stored anywhere.");
  const keys = await decryptBlob(envelope, await promptHidden("recovery password: "));
  console.log(`${args.out}: decrypts with the recovery password; checking every group`);
  await checkGroups(keys, manifest);
  console.log("done");
}

async function main(): Promise<void> {
  const args = parseArgs(Deno.args);
  if (args.checkOnly) {
    await checkExisting(args);
    return;
  }
  console.log("The recovery password is written on the media; it is not stored anywhere.");
  const recoveryPassword = await promptNewPassword("recovery password: ");

  const manifest = await readManifest(args.manifest);
  const store = sharedStore(manifest, args.endpoint, args.bucket);
  const secrets = await readSecrets(args.secrets);
  const keys: DataKeys = {
    version: 1,
    r2: {
      endpoint: store.endpoint,
      bucket: store.bucket,
      accessKeyId: requireSecret(secrets, "r2-access-key-id-readonly"),
      secretAccessKey: requireSecret(secrets, "r2-secret-access-key-readonly"),
      region: "auto",
    },
    restic: {
      password: requireSecret(secrets, "restic-password"),
    },
  };

  console.log(`store: ${store.endpoint}/${store.bucket}; ${manifest.groups.length} group(s)`);
  console.log("Deriving the key with Argon2id...");
  const envelope = await encryptBlob(keys, recoveryPassword);

  // Land the blob only after every check passes: a failed self-test must not
  // leave a broken envelope where the build and git both pick it up.
  const staged = `${args.out}.tmp`;
  await Deno.writeTextFile(staged, JSON.stringify(envelope, null, 2) + "\n");
  let keep = false;
  try {
    const check = await decryptBlob(envelope, recoveryPassword);
    if (JSON.stringify(check) !== JSON.stringify(keys)) {
      throw new Error("the self-test decrypted different data");
    }
    console.log("self-test: the blob decrypts with the recovery password");

    if (args.check) await checkGroups(keys, manifest);

    // Everything above reused the string captured at the first prompt, so it
    // cannot catch a typo, a paste artifact, or a Unicode form that the browser
    // will not reproduce. Ask again from scratch and open the file that was
    // actually written.
    console.log("Type the recovery password once more, to prove the written file opens with it.");
    const retyped = await promptHidden("recovery password again: ");
    if ((await verifyBlobPassword(staged, retyped)) !== true) {
      throw new Error(
        "the written blob did not open with the password typed again; the two entries differ, " +
          "so the letter would print a password that cannot unlock the page",
      );
    }
    console.log("re-entry: the written blob opens with the password typed again");

    await Deno.rename(staged, args.out);
    keep = true;
    console.log(`wrote ${args.out}`);
  } finally {
    if (!keep) await Deno.remove(staged).catch(() => undefined);
  }
  console.log("done");
}

if (import.meta.main) {
  main().catch((error: unknown) => {
    console.error(`blob failed: ${error instanceof Error ? error.message : String(error)}`);
    Deno.exit(1);
  });
}
