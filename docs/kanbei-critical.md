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
| `scripts/ci-areas.sh` | @smores56 | The selector: which areas a diff runs. On a `pull_request` event a same-repo branch runs the head's workflow file, so a branch can rewrite the selector and hand the gate a diff it does not test. It reads the diff once and every area job follows its answer, so an edit here narrows the whole gate at once. `scripts/ci-areas.sh --guard` refuses that edit unless the actor is the owner. |
| `scripts/ci-gate.py` | @smores56 | The decision behind the one required check: what `PR gate` reports for the jobs it needs. An edit here can turn a failed area into a pass without touching a workflow, which is why the same owner guard covers it. |
| `lib/` | @smores56 | The artifacts every host installs once and runs as root: the `sudo` PAM stack and `/etc/u2f_mappings` that gate escalation, the containers signature policy with its `registries.d`, and the greenboot required check whose per-host assertion files decide a boot is healthy. `scripts/check-lib-drift.sh` compares the copies, so a diff that changes the one copy and every image that installs it is exactly the diff no comparison can refuse. |
| `hosts/` | @smores56 | A host image is the machine: the `sudo` PAM stack and `/etc/u2f_mappings` that gate escalation, the `login` stack behind the lock screen and the disk keyslot, the signature policy, and the units the box runs. A diff here reaches a booted host through `bootc upgrade`, so the reviewer reads it as code that will run as root. |

Every pattern above is owned by `@smores56`, the same owner as `*`, so the list
changes what a reviewer must scrutinise, not who may approve.

`scripts/check-codeowners.sh` runs in CI and fails when a pattern in the table
above is missing from `CODEOWNERS`, when `CODEOWNERS` has no `*` entry, or when
the table is empty. Keep the two lists identical when editing either.
