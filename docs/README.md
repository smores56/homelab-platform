# Documentation

One index of the documents this repository keeps. Everything here describes the
host that is running: the image, its Quadlets, its backups and its edge.

| Document | What it is |
| --- | --- |
| `manual-steps.md` | The operator runbook: install, secrets and rotation, deploy, recover, decommission, all with exact commands. |
| `cloudflare.md` | The zone's DNS, the public names behind the edge VPS, the retired gate and tunnels, and the OpenTofu state. |
| `secrets.md` | Where a secret lives, which identity reads it, and what is not a secret. |
| `raw-replicas.md` | The raw-replica shape the collectors publish, source by source. |
| `kanbei-critical.md` | Which paths are Kanbei-critical, and why their review is Code Owners'. |
| `core/server-image.md` | The bootc image: contents, build and sign, install, the deploy path, access, disks, secrets. |
| `core/restic-plane.md` | The three Restic destinations, their restore units, freshness and restore procedures. |
| `core/recovery-kit.md` | The offline recovery kit: its items, its drill and its rotation. |
| `core/public-edge.md` | The edge VPS: what runs, DNS and cutover, metering, failure modes, and the rebuild from the image artifact. |
| `core/applications.md` | The application and agent Quadlets: images, storage, secrets, access and restore paths. |
| `core/apps-tenant.md` | The unprivileged `homelab-apps` tenant: plan, bounds, boot order, apply. |
| `core/backrest.md` | The hosted Backrest reader: the read-only boundary, readiness and its gate matrix. |
| `laptop/manual-steps.md` | The laptop's operator runbook: FIDO2 enrolment for the disk keyslot, the lock screen and sudo, and rotating the mapping. |
