import { readFileSync } from "node:fs";
import { describe, it as test } from "@std/testing/bdd";
import { expect } from "@std/expect";
import {
  escapeHtml,
  parseManifest,
  type RecoveryManifest,
  repositoryUrl,
  validateManifest,
} from "./manifest.ts";

const manifest: RecoveryManifest = {
  schema_version: 1,
  groups: [
    {
      id: "photos",
      label: "Photos",
      repo: "s3:https://account.r2.cloudflarestorage.com/homelabs-restic-personal/photos",
      data_root: "/srv/photos",
    },
    {
      id: "books",
      label: "Books",
      repo: "s3:https://account.r2.cloudflarestorage.com/homelabs-restic-general/books",
      data_root: "/srv/books",
    },
  ],
};

function clone(): RecoveryManifest {
  return structuredClone(manifest);
}

describe("recovery manifest", () => {
  test("accepts a groups manifest with the platform schema", () => {
    expect(validateManifest(manifest)).toEqual([]);
    expect(parseManifest(manifest)).toEqual(manifest);
  });

  test("accepts a bare https repository URL", () => {
    const bare = clone();
    bare.groups[0].repo = "https://account.r2.cloudflarestorage.com/bucket/photos";
    expect(validateManifest(bare)).toEqual([]);
    expect(repositoryUrl(bare.groups[0].repo)?.host).toBe(
      "account.r2.cloudflarestorage.com",
    );
  });
  test("accepts the platform renderer's exact document shape", () => {
    // libs/data_plane/recovery/manifest.py emits "<tier root>/<group id>" and
    // "/<group path>" with the label equal to the id.
    const rendered = {
      schema_version: 1,
      groups: [
        {
          id: "photos",
          label: "photos",
          repo: "s3:https://account.r2.cloudflarestorage.com/homelabs-restic/photos",
          data_root: "/photos",
        },
      ],
    };
    expect(validateManifest(rendered)).toEqual([]);
  });

  test("requires the repo prefix after the bucket to end with the group id", () => {
    const mismatch = clone();
    mismatch.groups[0].repo =
      "s3:https://account.r2.cloudflarestorage.com/homelabs-restic-personal/notes";
    expect(validateManifest(mismatch).join(" ")).toContain(
      "must end with the group id photos",
    );

    // The renderer's exact `<bucket>/<group id>` form and a nested prefix that
    // still ends in the id are both accepted.
    const exact = clone();
    exact.groups[0].repo =
      "s3:https://account.r2.cloudflarestorage.com/homelabs-restic-personal/photos";
    expect(validateManifest(exact)).toEqual([]);
    const nested = clone();
    nested.groups[0].repo =
      "s3:https://account.r2.cloudflarestorage.com/homelabs-restic-personal/teams/photos";
    expect(validateManifest(nested)).toEqual([]);
  });

  test("accepts a local-tier path as shape but never as an R2 repository", () => {
    // The renderer falls back to a local tier when a group has no r2 copy. The
    // document is well-formed; the page must show that group unavailable
    // instead of failing every other group's unlock.
    const local = clone();
    local.groups[0].repo = "/var/backups/secondary/restic/photos";
    expect(validateManifest(local)).toEqual([]);
    expect(repositoryUrl(local.groups[0].repo)).toBeNull();
  });

  test("rejects an unknown or missing schema_version", () => {
    expect(validateManifest({ ...manifest, schema_version: 2 }).join(" ")).toContain(
      "schema_version",
    );
    expect(validateManifest({ ...manifest, schema_version: undefined }).join(" ")).toContain(
      "schema_version",
    );
    expect(validateManifest({ groups: manifest.groups })).not.toEqual([]);
  });

  test("fails closed when groups are missing or empty", () => {
    expect(validateManifest({ schema_version: 1 }).join(" ")).toContain("groups");
    expect(validateManifest({ schema_version: 1, groups: [] }).join(" ")).toContain("groups");
    expect(validateManifest({ schema_version: 1, groups: [null] })).not.toEqual([]);
  });

  test("rejects duplicate and unsafe group ids", () => {
    const dup = clone();
    dup.groups[1].id = "photos";
    expect(validateManifest(dup).join(" ")).toContain("duplicate group id: photos");

    for (const id of ["", "has space", "../escape", "-leading", "a/b"]) {
      const bad = clone();
      bad.groups[0].id = id;
      expect(validateManifest(bad)).not.toEqual([]);
    }
  });

  test("rejects missing labels and control characters", () => {
    const missing = clone();
    missing.groups[0].label = "";
    expect(validateManifest(missing).join(" ")).toContain("label");
    const control = clone();
    control.groups[0].label = "Photos\u0000";
    expect(validateManifest(control).join(" ")).toContain("control character");
  });

  test("rejects a repo that is not a bare s3 URL", () => {
    for (
      const repo of [
        "javascript:alert(1)",
        "s3:https://account.r2.cloudflarestorage.com",
        "s3:https://user:pass@account.r2.cloudflarestorage.com/bucket/prefix",
        "s3:https://account.r2.cloudflarestorage.com/bucket/prefix?x=1",
        "s3:https://account.r2.cloudflarestorage.com/bucket/../escape",
        "not a url",
      ]
    ) {
      const bad = clone();
      bad.groups[0].repo = repo;
      expect(validateManifest(bad), repo).not.toEqual([]);
    }
  });

  test("requires an absolute, traversal-free data_root", () => {
    for (const root of ["", "srv/photos", "/srv/../etc", "/srv\\photos", "/srv/\u0000"]) {
      const bad = clone();
      bad.groups[0].data_root = root;
      expect(validateManifest(bad), root).not.toEqual([]);
    }
    const trailing = clone();
    trailing.groups[0].data_root = "/srv/photos/";
    expect(validateManifest(trailing)).toEqual([]);
  });

  test("rejects the snapshot root as a data_root", () => {
    // "/" would browse and download the whole snapshot at once.
    const root = clone();
    root.groups[0].data_root = "/";
    expect(validateManifest(root).join(" ")).toContain("must name a directory");
  });

  test("parseManifest names every problem instead of guessing", () => {
    expect(() =>
      parseManifest({ schema_version: 9, groups: [{ id: "x", label: "X", repo: "nope" }] })
    ).toThrow(/invalid manifest/);
  });

  test("ships an example manifest with no placeholders", () => {
    const text = readFileSync(new URL("../public/manifest.json", import.meta.url), "utf8");
    const shipped = JSON.parse(text);
    expect(validateManifest(shipped)).toEqual([]);
    expect(shipped.schema_version).toBe(1);
    expect(shipped.groups.length).toBeGreaterThan(0);
    expect(text).not.toContain("ACCOUNT.");
    expect(text).not.toContain("<");
    expect(text).not.toContain(">");
    for (const group of shipped.groups) {
      expect(Object.keys(group).sort()).toEqual(["data_root", "id", "label", "repo"]);
    }
  });

  test("escapes untrusted text", () => {
    expect(escapeHtml("<img src=x onerror=alert(1)>")).toBe(
      "&lt;img src=x onerror=alert(1)&gt;",
    );
  });
});
