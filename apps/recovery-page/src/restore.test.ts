import { describe, it as test } from "@std/testing/bdd";
import { expect } from "@std/expect";
import { normalizeDataRoot, relativeSegments, restorePrefix } from "./restore.ts";

describe("normalizeDataRoot", () => {
  test("strips leading, trailing, and repeated slashes", () => {
    expect(normalizeDataRoot("/srv/photos")).toBe("srv/photos");
    expect(normalizeDataRoot("/srv/photos/")).toBe("srv/photos");
    expect(normalizeDataRoot("//srv//photos")).toBe("srv/photos");
    expect(normalizeDataRoot("/")).toBe("");
  });
});

describe("restorePrefix", () => {
  test("keeps the group's own directory so photos restore as photos/...", () => {
    expect(restorePrefix("/srv/photos")).toBe("srv");
    expect(restorePrefix("/photos")).toBe("");
    expect(
      relativeSegments(restorePrefix("/srv/photos"), "srv/photos/2024/a.jpg"),
    ).toEqual(["photos", "2024", "a.jpg"]);
  });

  test("a repository-root group restores its whole tree", () => {
    expect(restorePrefix("/")).toBe("");
    expect(relativeSegments(restorePrefix("/"), "srv/books/a.epub")).toEqual([
      "srv",
      "books",
      "a.epub",
    ]);
  });
});

describe("relativeSegments", () => {
  test("returns the path under the prefix, sanitized per segment", () => {
    expect(relativeSegments("srv", "srv/photos/a:b.jpg")).toEqual(["photos", "a_b.jpg"]);
  });

  test("rejects a path outside the prefix", () => {
    expect(() => relativeSegments("srv/photos", "srv/books/x")).toThrow(
      "not under the restore root",
    );
    expect(() => relativeSegments("srv/photos", "srv/photos")).toThrow("empty restore path");
  });

  test("rejects traversal segments", () => {
    expect(() => relativeSegments("", "../etc/passwd")).toThrow("unsafe restore segment");
    expect(() => relativeSegments("", "a/../b")).toThrow("unsafe restore segment");
  });
});
