import { describe, it as test } from "@std/testing/bdd";
import { expect } from "@std/expect";
import type { RecoveryGroup, RecoveryManifest } from "../src/manifest.ts";
import type { ResticDirEntry, ResticRepository, ResticSnapshot } from "../src/restic/repository.ts";
import { checkGroupRoot, sharedStore } from "./blob.ts";

const group: RecoveryGroup = {
  id: "photos",
  label: "photos",
  repo: "s3:https://account.r2.cloudflarestorage.com/homelab-restic/photos",
  data_root: "/srv/photos",
};

function snapshot(): ResticSnapshot {
  return { id: "new", time: "2026-11-08T00:00:00Z", tree: "0".repeat(64), paths: [] };
}

function fakeRepository(
  directories: Record<string, ResticDirEntry[]>,
): Pick<ResticRepository, "listDirectory"> {
  return {
    listDirectory: (_snapshot: ResticSnapshot, directory: string) => {
      const entries = directories[directory];
      if (!entries) return Promise.reject(new Error(`directory not found: ${directory}`));
      return Promise.resolve(entries);
    },
  } as unknown as Pick<ResticRepository, "listDirectory">;
}

describe("checkGroupRoot", () => {
  test("accepts a resolved, non-empty directory", async () => {
    const repository = fakeRepository({
      "srv/photos": [{ name: "2024", path: "srv/photos/2024", type: "dir" }],
    });
    expect(await checkGroupRoot(repository, snapshot(), group)).toBe("srv/photos");
  });

  test("fails when the newest snapshot lacks the data_root", async () => {
    // The old check treated a missing root as "browse the snapshot root", which
    // would have shipped a page that downloads everything.
    const repository = fakeRepository({ "srv/notes": [] });
    await expect(checkGroupRoot(repository, snapshot(), group)).rejects.toThrow(
      "the newest snapshot does not contain srv/photos",
    );
  });

  test("fails when the resolved directory is empty", async () => {
    const repository = fakeRepository({ "srv/photos": [] });
    await expect(checkGroupRoot(repository, snapshot(), group)).rejects.toThrow(
      "srv/photos/ is empty",
    );
  });

  test("fails when the declared data_root is the snapshot root", async () => {
    const repository = fakeRepository({ "": [] });
    await expect(
      checkGroupRoot(repository, snapshot(), { ...group, data_root: "/" }),
    ).rejects.toThrow("the declared data_root is the snapshot root");
  });
});

describe("sharedStore", () => {
  const manifest: RecoveryManifest = { schema_version: 1, groups: [group] };

  test("accepts the manifest's https store", () => {
    expect(sharedStore(manifest, null, null)).toEqual({
      endpoint: "https://account.r2.cloudflarestorage.com",
      bucket: "homelab-restic",
    });
  });

  test("refuses a cleartext endpoint", () => {
    expect(() => sharedStore(manifest, "http://account.r2.cloudflarestorage.com", null)).toThrow(
      "must use https",
    );
  });

  test("refuses an endpoint that is not a URL", () => {
    expect(() => sharedStore(manifest, "not a url", null)).toThrow("is not a URL");
  });
});
