import { cp, mkdir, rm } from "node:fs/promises";
// esbuild's npm package reads ESBUILD_* from process.env and spawns its native
// binary, so the task needs --allow-env and --allow-run; this file itself uses
// only --allow-read and --allow-write.
import * as esbuild from "esbuild";
import { parseManifest } from "../src/manifest.ts";

const dist = new URL("../dist/", import.meta.url);

// Fail the build on a manifest the page would reject at unlock. The renderer
// owns the file; this only catches a bad render or a hand edit before it ships.
const manifest = parseManifest(
  JSON.parse(await Deno.readTextFile(new URL("../public/manifest.json", import.meta.url))),
);

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

await esbuild.build({
  entryPoints: [new URL("../src/main.ts", import.meta.url).pathname],
  outfile: new URL("main.js", dist).pathname,
  bundle: true,
  minify: true,
  sourcemap: "linked",
  platform: "browser",
  format: "esm",
  target: ["es2022"],
  logLevel: "info",
});

try {
  await cp(
    new URL("../public/data-keys.enc", import.meta.url),
    new URL("data-keys.enc", dist),
  );
} catch (error) {
  if ((error as { code?: string }).code !== "ENOENT") throw error;
  console.log("no public/data-keys.enc yet; run deno task blob to create it");
}

for (
  const [from, to] of [
    ["index.html", "index.html"],
    ["src/style.css", "style.css"],
    ["public/manifest.json", "manifest.json"],
    ["public/manifest.webmanifest", "manifest.webmanifest"],
    ["public/sw.js", "sw.js"],
    ["public/_headers", "_headers"],
    ["public/icon-192.png", "icon-192.png"],
    ["public/icon-512.png", "icon-512.png"],
  ] as const
) {
  await cp(new URL(`../${from}`, import.meta.url), new URL(to, dist));
}

console.log(`built ${dist.pathname} with ${manifest.groups.length} group(s)`);
