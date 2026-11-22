// public/manifest.json is rendered by the platform from the recovery inventory
// (scripts/render-recovery-groups.py + the recovery backup policy). It is public:
// group ids, labels, repository URLs, and the data root to strip. It carries no
// credential; the read-only R2 key and the restic password live in the encrypted
// data-keys blob.
//
//   {"schema_version":1,"groups":[{"id","label","repo","data_root"}]}
//
// The page must fail closed on anything else: a malformed manifest means the
// picker cannot be trusted, so unlock fails instead of guessing a repository.

export type RecoveryGroup = {
  id: string;
  label: string;
  repo: string;
  /** Absolute path prefix inside the snapshot that holds the group's data. */
  data_root: string;
};

export type RecoveryManifest = {
  schema_version: 1;
  groups: RecoveryGroup[];
};

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasControlCharacter(value: string): boolean {
  for (const char of value) {
    const code = char.codePointAt(0) ?? 0;
    if (code < 0x20 || code === 0x7f) return true;
  }
  return false;
}

const GROUP_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;

/** A restic repository URL as `s3:https://host/bucket/prefix` or a bare URL. */
export function repositoryUrl(repo: string): URL | null {
  if (repo.startsWith("s3:")) repo = repo.slice(3);
  try {
    const url = new URL(repo);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    return url;
  } catch {
    return null;
  }
}

function validateRepo(repo: unknown, label: string, errors: string[]): void {
  if (!isNonEmptyString(repo)) {
    errors.push(`group ${label} is missing a repo`);
    return;
  }
  if (hasControlCharacter(repo) || /\s/.test(repo)) {
    errors.push(`group ${label} has an invalid repo URL`);
    return;
  }
  // The platform renderer prefers the r2 tier but falls back to a local tier
  // when a group has no offsite copy. A local path is a valid manifest value
  // that this page can never open; it is listed and shown unavailable instead
  // of failing the whole unlock.
  if (repo.startsWith("/")) {
    if (repo.split("/").some((segment) => segment === "." || segment === "..")) {
      errors.push(`group ${label} repo contains a traversal segment`);
    }
    return;
  }
  const url = repositoryUrl(repo);
  if (!url) {
    errors.push(`group ${label} has a non-http repo URL`);
    return;
  }
  if (repo.replace(/^s3:/, "").split("?")[0].split("#")[0].match(/\/(\.{1,2})(\/|$)/)) {
    errors.push(`group ${label} repo contains a traversal segment`);
    return;
  }
  if (url.username || url.password || url.search || url.hash) {
    errors.push(`group ${label} repo must be a bare s3 URL`);
    return;
  }
  const segments = url.pathname.split("/").filter(Boolean);
  if (segments.length === 0) {
    errors.push(`group ${label} repo must name a bucket`);
    return;
  }
  if (segments.some((segment) => segment === "." || segment === "..")) {
    errors.push(`group ${label} repo contains a traversal segment`);
  }
}

/**
 * The group's repository is `<bucket>/<group id>` under the shared bucket, or a
 * nested prefix that still ends in the group id. Anything else would let a
 * tampered manifest point one group's picker at another group's repository.
 */
function validateRepoPrefix(repo: string, id: string, label: string, errors: string[]): void {
  const url = repositoryUrl(repo);
  if (!url) return;
  const segments = url.pathname.split("/").filter(Boolean);
  const prefix = segments.slice(1).join("/");
  if (prefix !== id && !prefix.endsWith(`/${id}`)) {
    errors.push(`group ${label} repo must end with the group id ${id}`);
  }
}

function validateDataRoot(root: unknown, label: string, errors: string[]): void {
  if (typeof root !== "string") {
    errors.push(`group ${label} is missing data_root`);
    return;
  }
  if (hasControlCharacter(root)) {
    errors.push(`group ${label} data_root has a control character`);
    return;
  }
  if (!root.startsWith("/")) {
    errors.push(`group ${label} data_root must be absolute`);
    return;
  }
  if (root.includes("\\")) {
    errors.push(`group ${label} data_root must use forward slashes`);
    return;
  }
  const segments = root.split("/").filter(Boolean);
  if (segments.length === 0) {
    errors.push(`group ${label} data_root must name a directory, not the snapshot root`);
    return;
  }
  if (segments.some((segment) => segment === "." || segment === "..")) {
    errors.push(`group ${label} data_root contains a traversal segment`);
  }
}

export function validateManifest(value: unknown): string[] {
  const errors: string[] = [];
  if (!isRecord(value)) return ["manifest must be an object"];
  if (value.schema_version !== 1) errors.push("unsupported manifest schema_version");
  if (!Array.isArray(value.groups) || value.groups.length === 0) {
    return [...errors, "groups are missing"];
  }

  const ids = new Set<string>();
  for (const group of value.groups) {
    if (!isRecord(group)) {
      errors.push("a group is not an object");
      continue;
    }
    const label = isNonEmptyString(group.id) ? group.id : "?";
    if (!isNonEmptyString(group.id)) {
      errors.push("a group is missing an id");
    } else if (!GROUP_ID.test(group.id)) {
      errors.push(`group ${group.id} has an invalid id`);
    } else if (ids.has(group.id)) {
      errors.push(`duplicate group id: ${group.id}`);
    } else {
      ids.add(group.id);
    }
    if (!isNonEmptyString(group.label)) {
      errors.push(`group ${label} is missing a label`);
    } else if (hasControlCharacter(group.label)) {
      errors.push(`group ${label} has a control character in its label`);
    }
    validateRepo(group.repo, label, errors);
    if (isNonEmptyString(group.repo) && isNonEmptyString(group.id)) {
      validateRepoPrefix(group.repo, group.id, label, errors);
    }
    validateDataRoot(group.data_root, label, errors);
  }
  return errors;
}

/** Validate and return the manifest, throwing when it cannot be trusted. */
export function parseManifest(value: unknown): RecoveryManifest {
  const errors = validateManifest(value);
  if (errors.length > 0) throw new Error(`invalid manifest: ${errors.join(", ")}`);
  return value as RecoveryManifest;
}

export function escapeHtml(value: unknown): string {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}
