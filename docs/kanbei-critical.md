# Kanbei-critical paths

CODEOWNERS has no severity field: it can require a review, not label a review
"dangerous". The owner treats the patterns below as Kanbei-critical because a
diff there can publish a name in `sammohr.dev`, and run attacker-controlled code
with the deploy token. Every merge touching one of
them needs a human read of the full diff, not just a CI pass.

| Pattern | Owner | Why it is Kanbei-critical |
| --- | --- | --- |
| `*.tf` | @smores56 | The Cloudflare token decides what the zone publishes: a record added or repointed here is reachable from the internet, and the names it serves now include the media apps and the recovery reader on the edge VPS (`tofu/dns.tf`). The same token can recreate an Access application, a tunnel or a rate-limit rule, which is what SDLC #833 retired — a diff here is the only thing that can put one back. |
| `.github/` | @smores56 | Workflows run with the `cloudflare` environment on `main`. A workflow edit can exfiltrate `CLOUDFLARE_API_TOKEN`, weaken the secret boundary, or unpin an Action. CODEOWNERS review is the only gate, since Actions on forks cannot be trusted to police themselves. |

Both patterns are owned by `@smores56`, the same owner as `*`, so the list
changes what a reviewer must scrutinise, not who may approve.

`scripts/check-codeowners.sh` runs in CI and fails when a pattern in the table
above is missing from `CODEOWNERS`, when `CODEOWNERS` has no `*` entry, or when
the table is empty. Keep the two lists identical when editing either.
