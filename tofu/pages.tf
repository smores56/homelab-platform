# The recovery page is static on Cloudflare Pages. GitHub Actions builds `recovery/dist`
# with Deno and uploads it with wrangler; nothing here holds the content itself.
#
# The wildcard record above sends every other name to the tunnel, so the page needs its own
# record: a specific name wins over `*.sammohr.dev`, and without it the letter's URL would
# reach smortress and 404.

# The project name is the public default host (<name>.pages.dev). Renaming it replaces the
# project: Cloudflare rebuilds it empty.
#
# `recovery.sammohr.dev` moved to the hosted Backrest reader in T4 (#707): the static
# letter and its custom domain are gone, and the Worker owns the hostname. The project
# itself stays until T6 so the Pages deployment can still be inspected; nothing serves it.
resource "cloudflare_pages_project" "recovery" {
  account_id        = var.account_id
  name              = "sam-mohr-data-recovery"
  production_branch = "main"
}
