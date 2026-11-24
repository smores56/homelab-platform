# Documentation

One index of the documents this repository keeps. Everything here describes the
host that is running: the image, its Quadlets, its backups and its edge.

| Document | What it is |
| --- | --- |
| `manual-steps.md` | The operator runbook: install, secrets and rotation, deploy, recover, decommission, all with exact commands. |
| `runbook.md` | The GitHub settings an operator applies by hand: branch protection and repository settings. |
| `negative-tests.md` | The adversarial properties proven against the live platform, and how each was measured. |
| `cloudflare.md` | The zone's DNS, the public names behind the edge VPS, the retired gate and tunnels, and the OpenTofu state. |
| `secrets.md` | Where a secret lives, which identity reads it, and what is not a secret. |
| `broker.md` | The broker's trust boundary, request contract, and logical-host enrollment. |
| `webhook.md` | The webhook receiver's trust boundary and request contract. |
| `raw-replicas.md` | The raw-replica shape the collectors publish, source by source. |
| `agent-identity.md` | The two machine credentials a general agent job receives. |
| `agent-facade.md` | The facade's MCP surface and how a deployment's sources are described. |
| `agent-jobs.md` | The agent shell dispatcher, its runners and its two probes. |
| `migration-gates.md` | The gate sequence a destructive migration had to pass, as the record of it. |
| `kanbei-critical.md` | Which paths are Kanbei-critical, and why their review is Code Owners'. |
| `core/server-image.md` | The bootc image: contents, build and sign, install, the deploy path, access, disks, secrets. |
| `core/restic-plane.md` | The three Restic destinations, their restore units, freshness and restore procedures. |
| `core/recovery-kit.md` | The offline recovery kit: its items, its drill and its rotation. |
| `core/t0-gate.md` | The T0 gate the core migration had to pass, and the evidence it left. |
| `core/public-edge.md` | The edge VPS: what runs, DNS and cutover, metering, failure modes, rebuild. |
| `core/applications.md` | The application and agent Quadlets: images, storage, secrets, access and restore paths. |
| `core/apps-tenant.md` | The unprivileged `homelab-apps` tenant: plan, bounds, boot order, apply. |
| `core/backrest.md` | The hosted Backrest reader: the read-only boundary, readiness and its gate matrix. |
| `core/storage-migration.md` | The storage layout move onto ZFS recovery groups, and its attic. |
| `core/pool-rebuild.md` | Rebuilding the pool from the datasets a restore returns. |
