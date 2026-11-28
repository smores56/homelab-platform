# Documentation

Five pages. Anything else belongs in the code it describes, in `git log`, or in
the runbook for the host it operates on.

| Document | What it is |
| --- | --- |
| `core/recovery-kit.md` | What has to survive every machine, and the drill that proves it. Start here. |
| `core/apps-tenant.md` | The `homelab-apps` tenant contract: what a merge may change and what it may not. |
| `core/backrest.md` | The hosted Backrest reader: its read-only boundary and readiness. |
| `secrets.md` | One row per credential: where it lives, who reads it, how it rotates. |
| `kanbei-critical.md` | Which paths need owner review before they land. |

Operator steps live beside the code they operate:

| Runbook | Host |
| --- | --- |
| `hosts/server/runbook.md` | smortress: install, secrets, deploy, applications, recovery. |
| `hosts/laptop/runbook.md` | smorespro: disk unlock, sudo, the tailnet widget, Syncthing, a staged update. |
| `bootc/edge/runbook.md` | smoresnet: Ignition, install, bootstrap, release. |
