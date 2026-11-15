// Turns a group's snapshot paths into a folder tree under the directory the
// family picks. Snapshot entries are relative to the restic tree root, while
// the manifest's data_root names the group's directory inside it. The page
// browses at data_root and restores relative to its parent, so the group's own
// directory name is kept: `/srv/photos/2024/a.jpg` restores as `photos/2024/a.jpg`.

import { sanitizeFileName } from "./filenames.ts";

/** `"/srv/photos/"` -> `"srv/photos"`; `"/"` -> `""` (the snapshot root). */
export function normalizeDataRoot(root: string): string {
  return root.split("/").filter(Boolean).join("/");
}

/**
 * The restore prefix for a group root. Using the parent keeps one directory
 * named after the group (photos/, books/, memory/) instead of flattening its
 * contents into the folder the family picked.
 */
export function restorePrefix(dataRoot: string): string {
  const segments = normalizeDataRoot(dataRoot).split("/").filter(Boolean);
  return segments.length > 1 ? segments.slice(0, -1).join("/") : "";
}

/** Path segments below `prefix`, one per restore directory level. */
export function relativeSegments(
  prefix: string,
  path: string,
): string[] {
  const segments = path.split("/").filter(Boolean);
  const root = prefix ? prefix.split("/").filter(Boolean) : [];
  for (let index = 0; index < root.length; index++) {
    if (segments[index] !== root[index]) throw new Error(`not under the restore root: ${path}`);
  }

  const rest = segments.slice(root.length);
  if (rest.length === 0) throw new Error(`empty restore path: ${path}`);

  return rest.map((segment) => {
    if (segment === "." || segment === "..") throw new Error(`unsafe restore segment: ${path}`);
    return sanitizeFileName(segment);
  });
}
