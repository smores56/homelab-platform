import { describe, it as test } from "@std/testing/bdd";
import { expect } from "@std/expect";
import type { DataKeys } from "./blob.ts";
import {
  GroupCatalog,
  type GroupState,
  groupStore,
  renderGroupList,
  resolveDataRoot,
} from "./groups.ts";
import type { RecoveryGroup } from "./manifest.ts";
import type { ResticDirEntry, ResticRepository, ResticSnapshot } from "./restic/repository.ts";

const keys: DataKeys = {
  version: 1,
  r2: {
    endpoint: "https://account.r2.cloudflarestorage.com",
    bucket: "homelabs-restic-personal",
    accessKeyId: "access",
    secretAccessKey: "secret",
  },
  restic: { password: "restic-password" },
};

const groups: RecoveryGroup[] = [
  {
    id: "photos",
    label: "Photos",
    repo: "s3:https://account.r2.cloudflarestorage.com/homelabs-restic-personal/photos",
    data_root: "/srv/photos",
  },
  {
    id: "notes",
    label: "Notes",
    repo: "s3:https://account.r2.cloudflarestorage.com/homelabs-restic-personal/notes",
    data_root: "/srv/notes",
  },
  {
    id: "books",
    label: "Books",
    repo: "s3:https://account.r2.cloudflarestorage.com/homelabs-restic-general/books",
    data_root: "/srv/books",
  },
];

function snapshot(id: string, time: string): ResticSnapshot {
  return { id, time, tree: "0".repeat(64), paths: [] };
}

function fakeRepository(
  snapshots: ResticSnapshot[],
  directories: Record<string, ResticDirEntry[]> = {},
): ResticRepository {
  return {
    snapshots,
    listDirectory: (_snapshot: ResticSnapshot, directory: string) => {
      const entries = directories[directory];
      if (!entries) return Promise.reject(new Error(`directory not found: ${directory}`));
      return Promise.resolve(entries);
    },
  } as unknown as ResticRepository;
}

describe("groupStore", () => {
  test("takes the repository prefix from the group's URL", () => {
    expect(groupStore(keys, groups[0])).toEqual({
      endpoint: "https://account.r2.cloudflarestorage.com",
      bucket: "homelabs-restic-personal",
      prefix: "photos",
    });
    const nested = { ...groups[0], repo: `${groups[0].repo}/immich` };
    expect(groupStore(keys, nested).prefix).toBe("photos/immich");
  });

  test("refuses a repository off the configured store or bucket", () => {
    expect(() => groupStore(keys, { ...groups[0], repo: "s3:https://evil.example/bucket/photos" }))
      .toThrow("not on the configured store");
    expect(() =>
      groupStore(keys, {
        ...groups[0],
        repo: "s3:https://account.r2.cloudflarestorage.com/other-bucket/photos",
      })
    ).toThrow("different bucket");
    expect(() => groupStore(keys, { ...groups[0], repo: "nope" })).toThrow("not an R2 URL");
    // The platform renderer falls back to a local tier for a group without an
    // offsite copy; the browser must list it as unavailable, never dial it.
    expect(() => groupStore(keys, { ...groups[0], repo: "/var/backups/secondary/restic/photos" }))
      .toThrow("not an R2 URL");
  });
});

describe("resolveDataRoot", () => {
  const snap = snapshot("new", "2026-11-08T00:00:00Z");
  const staged: Record<string, ResticDirEntry[]> = {
    "": [{ name: "run", path: "run", type: "dir" }],
    run: [{ name: "data-plane", path: "run/data-plane", type: "dir" }],
    "run/data-plane": [{ name: "current", path: "run/data-plane/current", type: "dir" }],
    "run/data-plane/current": [
      { name: "photos", path: "run/data-plane/current/photos", type: "dir" },
    ],
  };

  test("opens the exact data_root when the snapshot has it", async () => {
    const repository = fakeRepository([snap], { "srv/photos": [] });
    expect(await resolveDataRoot(repository, snap, "/srv/photos")).toBe("srv/photos");
  });

  test("finds the data_root under the staged snapshot path", async () => {
    // restic stores /run/data-plane/current/photos as run/data-plane/current/photos
    // while the renderer's data_root is /photos.
    const repository = fakeRepository([snap], staged);
    expect(await resolveDataRoot(repository, snap, "/photos")).toBe(
      "run/data-plane/current/photos",
    );
  });

  test("refuses the snapshot root as a data_root", async () => {
    // "/" would browse and download the whole snapshot; the manifest rejects it
    // and resolution must not turn it into the empty root either.
    const repository = fakeRepository([snap], staged);
    expect(await resolveDataRoot(repository, snap, "/")).toBeNull();
  });

  test("returns null when the snapshot does not contain the data_root", async () => {
    const repository = fakeRepository([snap], {});
    expect(await resolveDataRoot(repository, snap, "/photos")).toBeNull();
  });
});

describe("GroupCatalog", () => {
  test("starts with every manifest group and no dates", () => {
    const catalog = new GroupCatalog(groups, () => Promise.resolve(fakeRepository([])));
    expect(catalog.states.map((state) => state.group.id)).toEqual(["photos", "notes", "books"]);
    expect(catalog.states.every((state) => state.snapshotTime === null)).toBe(true);
  });

  test("probe fills the newest snapshot date, sorted by instant", async () => {
    const seen: string[] = [];
    const catalog = new GroupCatalog(groups, (group) => {
      if (group.id === "books") return Promise.reject(new Error("repository refused"));
      return Promise.resolve(
        fakeRepository([
          snapshot("old", "2026-11-06T00:00:00Z"),
          snapshot("new", "2026-11-08T00:00:00Z"),
          snapshot("mid", "2026-11-07T00:00:00Z"),
        ]),
      );
    });

    const states = await catalog.probe((state) => seen.push(state.group.id));
    expect(seen).toEqual(["photos", "notes", "books"]);
    expect(states[0].snapshotTime).toBe("2026-11-08T00:00:00Z");
    expect(states[1].snapshotTime).toBe("2026-11-08T00:00:00Z");
    expect(states[2].error).toContain("repository refused");
  });

  test("select opens at data_root and restores relative to its parent", async () => {
    let opened = 0;
    const catalog = new GroupCatalog(groups, () => {
      opened++;
      return Promise.resolve(
        fakeRepository(
          [snapshot("old", "2026-11-06T00:00:00Z"), snapshot("new", "2026-11-08T00:00:00Z")],
          { "srv/photos": [], "srv/books": [] },
        ),
      );
    });

    const photos = await catalog.select("photos");
    expect(photos.snapshot.id).toBe("new");
    expect(photos.browseRoot).toBe("srv/photos");
    expect(photos.restorePrefix).toBe("srv");
    expect(photos.group.id).toBe("photos");

    const books = await catalog.select("books");
    expect(books.browseRoot).toBe("srv/books");
    expect(books.restorePrefix).toBe("srv");

    // A second selection reuses the opened repository.
    await catalog.select("photos");
    expect(opened).toBe(2);
  });

  test("select refuses a snapshot that lacks the data_root instead of widening", async () => {
    // A manifest entry whose data_root is absent must mark that row, not fall
    // back to the snapshot root and let the user download everything.
    const catalog = new GroupCatalog(groups, () =>
      Promise.resolve(
        fakeRepository([snapshot("new", "2026-11-08T00:00:00Z")], {
          "srv/notes": [],
        }),
      ));

    await expect(catalog.select("photos")).rejects.toThrow(
      "the newest snapshot does not contain /srv/photos",
    );
    const state = catalog.state("photos");
    expect(state?.error).toBe("the newest snapshot does not contain /srv/photos");
    expect(renderGroupList(catalog.states, () => "date")).toContain(
      "Unavailable: the newest snapshot does not contain /srv/photos",
    );
  });

  test("select refuses an unknown group or one without snapshots", async () => {
    const catalog = new GroupCatalog(groups, () => Promise.resolve(fakeRepository([])));
    await expect(catalog.select("missing")).rejects.toThrow("unknown group");
    await expect(catalog.select("photos")).rejects.toThrow("has no snapshots");
  });
});

describe("renderGroupList", () => {
  const states: GroupState[] = [
    { group: groups[0], snapshotTime: "2026-11-08T00:00:00Z", error: null },
    { group: groups[1], snapshotTime: null, error: "Failed to fetch" },
    { group: { ...groups[2], label: "<Books & more>" }, snapshotTime: null, error: null },
  ];

  test("lists every group id and label with the newest snapshot", () => {
    const html = renderGroupList(states, () => "8 Nov 2026");
    for (const id of ["photos", "notes", "books"]) {
      expect(html).toContain(`data-group-id="${id}"`);
    }
    expect(html).toContain("Photos");
    expect(html).toContain("Latest 8 Nov 2026");
    expect(html).toContain("Checking latest snapshot");
    expect(html).toContain("Unavailable: Failed to fetch");
  });

  test("marks the selected group and escapes labels and errors", () => {
    const html = renderGroupList(states, () => "date", "photos");
    expect(html).toContain("group-button selected");
    expect(html).toContain('aria-current="true"');
    expect(html).toContain("&lt;Books &amp; more&gt;");
    expect(html).not.toContain("<Books & more>");
  });
});
