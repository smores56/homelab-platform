# Agent shell jobs (T5 of #702)

The agent runtime never runs a shell itself and never holds a Podman socket. A
shell request reaches one of two class-fixed entry points, and
`scripts/agent-job.sh` alone builds a `podman run` vector from constants: the
image, every mount, the network authority, the limits and the environment. The
caller supplies one shell command and nothing else.

## Two classes, two entry points

| Entry point | Class | Runner uid | Host mounts | Network |
| --- | --- | --- | --- | --- |
| `agent-job-personal` | personal/local | `agent-shell-personal` | none | `none` |
| `agent-job-general` | general/external | `agent-shell-general` | `/var/srv/git` → `/work` (rw) | pasta + fixed public DNS |

The class is not a request field. Each wrapper compiles it in, the shared core
takes it from the wrapper, and the core is installed root-only. There is no
shared submission surface through which a caller can name the other class, so
"cross-class submission" is a missing code path rather than a check that could
be bypassed.

A personal job therefore has no host path to read and no route to send one out:
its whole writable state is a bounded tmpfs, and its only filesystem is the
container's read-only root. General content cannot be copied, sourced or
interpreted into a personal job because the personal job cannot see a general
tree. A general job sees the one general tree and no personal dataset, no
private workspace and no agent state.

## Containment

Every command gets:

- `podman run --rm --replace --pull=never` with a digest-pinned image from
  `/etc/smortress/agent/job-image`, so a tag cannot move what runs and a missing
  prepull fails instead of reaching a registry;
- read-only root filesystem, `--cap-drop=all`,
  `--security-opt=no-new-privileges`, default seccomp, private IPC/PID/UTS/cgroup
  namespaces, no devices and no host namespace;
- `--tmpfs /tmp` and `--tmpfs /work` with size and `nosuid`/`nodev` bounds; the
  general class adds the single live bind mount;
- a transient systemd unit with `RuntimeMaxSec=300`, `CPUQuota=100%`,
  `MemoryMax=1G`, `TasksMax=256`, `Delegate=yes`, and `TimeoutStopSec=10`. The
  unit, not a rootless user manager, owns the limits, so a host without
  delegated controllers still fails closed on a limit it cannot set; on timeout
  the whole cgroup is killed and the dispatcher removes any leftover container.
- an output cap of 1 MiB, applied by the dispatcher after the command.

The general class's egress is filtered by the uid-keyed table in
`image/rootfs/etc/nftables/smortress-agent-jobs.nft`: `fib daddr type local`,
IPv4 and IPv6 private, link-local, CGNAT/Tailscale, loopback, multicast and the
metadata range are dropped. DNS goes to the fixed public resolvers in the
argument vector, never the host stub on loopback. The personal class is dropped
outright and also runs with `--network=none`, so the rule is a second lock
rather than the only one.

The shared tree keeps its stable label and ownership. The dispatcher never emits
`:z`, `:Z` or `label=disable`; the provisioning unit grants the general runner
an ACL on `/var/srv/git`, and the dispatcher refuses to start a general job whose
workspace the runner cannot write.

## Runners and provisioning

`image/rootfs/etc/sysusers.d/smortress-agent-shell.conf` allocates both login-less
accounts; nothing names their ids. `smortress-agent-job-provision.service` runs
`scripts/agent-job-provision.sh` at boot to:

1. add a non-overlapping subuid/subgid range to each runner (300000:65536 and
   400000:65536; an overlap is refused, never remapped);
2. apply the general runner's ACL and default ACL on `/var/srv/git`;
3. load the egress table before any job exists.

`scripts/agent-job-provision.sh --check` reports drift and writes nothing. The
dispatcher re-loads the egress table itself before every launch, so a skipped or
failed boot unit cannot leave a job running without the boundary.

## Approval seam

Shell jobs are unsupervised YOLO by design: there is no command approval,
source-content approval, second diff review or transactional commit, and this
dispatcher must never grow one. The single approval contract in the platform is
`libs/data_plane/approval.py`, held by the write broker for dangerous broker
effects. A shell job carries no approval token and the dispatcher reads none; a
dangerous effect outside the shell path is approved by the effect owner through
that contract. Nothing below the class entry point consults approval, and
nothing here may be used to record or complete one.

## Operator steps

See `docs/manual-steps.md` section 47 for prepulling the pinned image as each
runner, verifying the units, and running the two probes. `tests/core/agent-jobs.sh`
covers the offline half: class-fixed entry points, the mount/network split, the
containment flags, the firewall ranges, the digest pin and the subuid overlap
refusal.
