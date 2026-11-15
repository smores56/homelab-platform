// The group picker's data model. The public manifest lists every recovery
// group; each group names its own restic repository on the one shared R2
// bucket. This module opens a group's repository, records the newest snapshot
// time for the picker, and caches the opened repository so choosing a group the
// second time costs nothing.

import type { DataKeys } from "./blob.ts";
import { escapeHtml, type RecoveryGroup, repositoryUrl } from "./manifest.ts";
import { normalizeDataRoot, restorePrefix } from "./restore.ts";
import { R2Backend } from "./restic/r2.ts";
import {
  openRepository,
  type ResticRepository,
  type ResticSnapshot,
  sortSnapshots,
} from "./restic/repository.ts";

export type GroupStore = {
  endpoint: string;
  bucket: string;
  /** Path under the bucket, taken from the group's repository URL. */
  prefix: string;
};

/**
 * Resolve a group's repo URL against the blob's read-only token. The manifest is
 * public and untrusted, so a repo off the configured store is refused: the
 * secret in the blob must never authenticate against a host the manifest names.
 */
export function groupStore(keys: DataKeys, group: RecoveryGroup): GroupStore {
  const url = repositoryUrl(group.repo);
  if (!url) {
    throw new Error(
      `group ${group.id} repository is not an R2 URL; it can only be restored on the host`,
    );
  }
  let configured: URL;
  try {
    configured = new URL(keys.r2.endpoint);
  } catch {
    throw new Error("the data-keys blob has an invalid R2 endpoint");
  }
  if (url.host !== configured.host) {
    throw new Error(`group ${group.id} repository is not on the configured store`);
  }
  const segments = url.pathname.split("/").filter(Boolean);
  const [bucket, ...prefix] = segments;
  if (bucket !== keys.r2.bucket) {
    throw new Error(`group ${group.id} repository names a different bucket`);
  }
  if (prefix.some((segment) => segment === "." || segment === "..")) {
    throw new Error(`group ${group.id} repository contains a traversal segment`);
  }
  return { endpoint: keys.r2.endpoint, bucket: keys.r2.bucket, prefix: prefix.join("/") };
}

export function openGroupRepository(
  keys: DataKeys,
  group: RecoveryGroup,
): Promise<ResticRepository> {
  const store = groupStore(keys, group);
  const backend = new R2Backend({
    endpoint: store.endpoint,
    bucket: store.bucket,
    accessKeyId: keys.r2.accessKeyId,
    secretAccessKey: keys.r2.secretAccessKey,
    region: keys.r2.region,
    prefix: store.prefix,
  });
  return openRepository(backend, keys.restic.password);
}

export type GroupState = {
  group: RecoveryGroup;
  /** Newest snapshot time, once the repository has been opened. */
  snapshotTime: string | null;
  error: string | null;
};

export type OpenedGroup = {
  group: RecoveryGroup;
  repository: ResticRepository;
  snapshot: ResticSnapshot;
  /** Directory the browser opens at (the resolved manifest data_root). */
  browseRoot: string;
  /** Prefix downloads are made relative to; keeps the group directory name. */
  restorePrefix: string;
};

const MAX_ROOT_DEPTH = 12;
const MAX_ROOT_SCAN = 5000;

/**
 * Find the group's directory in a snapshot. The renderer writes a data_root
 * relative to the group mount (`/photos`), while restic stores a backup of an
 * absolute staged path as `run/data-plane/current/photos`. The exact path is
 * tried first; otherwise the shallowest directory whose trailing segments match
 * the data_root wins. Returns null when nothing matches.
 */
export async function resolveDataRoot(
  repository: Pick<ResticRepository, "listDirectory">,
  snapshot: ResticSnapshot,
  dataRoot: string,
): Promise<string | null> {
  const wanted = normalizeDataRoot(dataRoot);
  // A manifest data_root of "/" is refused by validation; treat it as
  // unresolved here too so nothing widens a selection to the snapshot root.
  if (!wanted) return null;
  const suffix = wanted.split("/").filter(Boolean);
  const matches = (path: string): boolean => {
    const segments = path.split("/").filter(Boolean);
    return (
      segments.length >= suffix.length &&
      suffix.every(
        (segment, index) => segments[segments.length - suffix.length + index] === segment,
      )
    );
  };

  try {
    await repository.listDirectory(snapshot, wanted);
    return wanted;
  } catch {
    // Fall through to the suffix search.
  }

  const queue: string[] = [""];
  let scanned = 0;
  while (queue.length > 0 && scanned < MAX_ROOT_SCAN) {
    const current = queue.shift()!;
    let entries;
    try {
      entries = await repository.listDirectory(snapshot, current);
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry.type !== "dir") continue;
      scanned++;
      if (matches(entry.path)) return entry.path;
      if (current.split("/").filter(Boolean).length < MAX_ROOT_DEPTH) {
        queue.push(entry.path);
      }
    }
  }
  return null;
}

export type RepositoryOpener = (group: RecoveryGroup) => Promise<ResticRepository>;

export class GroupCatalog {
  private readonly byId = new Map<string, GroupState>();
  private readonly opened = new Map<
    string,
    { repository: ResticRepository; snapshot: ResticSnapshot }
  >();

  constructor(
    readonly groups: RecoveryGroup[],
    private readonly opener: RepositoryOpener,
  ) {
    for (const group of groups) {
      this.byId.set(group.id, { group, snapshotTime: null, error: null });
    }
  }

  get states(): GroupState[] {
    return this.groups.map((group) => this.byId.get(group.id)!);
  }

  state(id: string): GroupState | undefined {
    return this.byId.get(id);
  }

  private async open(
    id: string,
  ): Promise<{ repository: ResticRepository; snapshot: ResticSnapshot }> {
    const state = this.byId.get(id);
    if (!state) throw new Error(`unknown group: ${id}`);
    const cached = this.opened.get(id);
    if (cached) return cached;
    const repository = await this.opener(state.group);
    const newest = sortSnapshots(repository.snapshots)[0];
    if (!newest) throw new Error(`group ${id} has no snapshots`);
    const opened = { repository, snapshot: newest };
    this.opened.set(id, opened);
    return opened;
  }

  /**
   * Open every group once to fill the picker's newest-snapshot dates. One
   * failure is recorded for that group and never stops the others.
   */
  async probe(onUpdate?: (state: GroupState) => void): Promise<GroupState[]> {
    for (const state of this.groups.map((group) => this.byId.get(group.id)!)) {
      if (state.snapshotTime || state.error) continue;
      try {
        const { snapshot } = await this.open(state.group.id);
        state.snapshotTime = snapshot.time;
      } catch (error) {
        state.error = error instanceof Error ? error.message : String(error);
      }
      onUpdate?.(state);
    }
    return this.states;
  }

  async select(id: string): Promise<OpenedGroup> {
    const state = this.byId.get(id);
    if (!state) throw new Error(`unknown group: ${id}`);
    const { repository, snapshot } = await this.open(id);
    state.snapshotTime = snapshot.time;
    state.error = null;
    const resolved = await resolveDataRoot(repository, snapshot, state.group.data_root);
    if (resolved === null) {
      const reason = `the newest snapshot does not contain ${state.group.data_root}`;
      state.error = reason;
      throw new Error(reason);
    }
    return {
      group: state.group,
      repository,
      snapshot,
      browseRoot: resolved,
      restorePrefix: restorePrefix(resolved),
    };
  }
}

export function renderGroupList(
  states: GroupState[],
  formatTime: (value: string) => string,
  selectedId: string | null = null,
): string {
  return states
    .map(({ group, snapshotTime, error }) => {
      const selected = group.id === selectedId;
      const meta = error
        ? `<span class="group-error">Unavailable: ${escapeHtml(error)}</span>`
        : snapshotTime
        ? `<span class="group-time">Latest ${escapeHtml(formatTime(snapshotTime))}</span>`
        : `<span class="group-time">Checking latest snapshot...</span>`;
      return `<li class="group-row">
  <button type="button" class="group-button${selected ? " selected" : ""}" data-group-id="${
        escapeHtml(group.id)
      }"${selected ? ' aria-current="true"' : ""}>
    <span class="group-label">${escapeHtml(group.label)}</span>
    <span class="group-id">${escapeHtml(group.id)}</span>
    ${meta}
  </button>
</li>`;
    })
    .join("\n");
}
