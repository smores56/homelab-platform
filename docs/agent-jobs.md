# Agent shell jobs (T5 of #702)

The agent runtime never runs a shell itself and never holds a Podman socket. A
shell request reaches one of two class-fixed entry points, and
`scripts/agent-job.sh` alone builds a `podman run` vector from constants: the
image, every mount, the network authority, the limits and the environment. The
caller supplies one shell command and nothing else. What a caller addresses is a
Unix socket served by `scripts/agent-shell-bridge.py`, not the dispatcher
(see [Transport](#transport)).

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

## Transport

The dispatcher has no network surface at all. One program above it does the
addressing, and it is the whole transport (SDLC #859, #860). There is one bridge
per class, so each class's dispatcher path and socket path are literals in a unit:

| Piece | Where it lives | Who can reach it |
| --- | --- | --- |
| `smortress-agent-shell-bridge.service` | root service, `scripts/agent-shell-bridge.py` at `/usr/libexec/agent-shell-bridge`, `--class general` | — |
| `/run/smortress/agent-shell-general/general.sock` | a tmpfiles directory, 0710 root:1000, under the root 0700 `/run/smortress`; the socket is 0660, group 1000 | the general facade container, by a mount of that directory |
| `/usr/libexec/agent-job-general` | a constant in the general bridge | the general bridge |
| `smortress-agent-shell-bridge-personal.service` | the same program, `--class personal` | — |
| `/run/smortress/agent-shell-personal/personal.sock` | the same directory mode and parent, in its own directory | the personal facade container, by a mount of that directory |
| `/usr/libexec/agent-job-personal` | a constant in the personal bridge | the personal bridge |

The bridge serves one tool, `shell.run`, to one client. A request is one JSON
line whose only field is `command`: unknown fields, a non-string or empty command,
one over 32768 characters, a NUL, a line over 64 KiB or a missing newline are
refused with `{"error": {"code": "invalid_request", ...}}`. The reply is `{status,
output, truncated}` — the dispatcher's exit status, its merged stderr and stdout,
and whether the 1 MiB cap clipped it — or `{"error": {"code": "timeout" |
"unavailable" | ...}}`. One request per connection, four at a time; a fifth caller
is told to come back rather than queued behind a 300 s job. The bridge's own
deadline (330 s) is a backstop above the dispatcher's `RuntimeMaxSec=300` and
kills the dispatcher's process group.

Why a socket and not a port: the class is a constant and the command is the only
field, so what is left to protect is *who can ask at all*. A Unix socket answers
that with the filesystem — the parent is root 0700, the socket's directory is
0710 with one group and the inode is 0660, and only that group's container mounts
the directory. The directory rather than the file is mounted so a bridge restart
rebinds a socket this container still sees. One directory per class is what makes
cross-class access impossible rather than merely unused: both facades run as uid
1000, so file mode cannot tell them apart, but a container can only dial a socket
whose directory it mounts, and the personal facade mounts
`agent-shell-personal` alone while the general facade mounts
`agent-shell-general` alone. A TCP listener would be a second
way in with no consumer, reachable by anything that can route to the host, needing
its own authentication on top of a token that already exists for the MCP surface.
There is no such listener, and the gateway, the model server and the web UI have
no path to the socket to use instead.

One SELinux rule makes the mount usable: for AF_UNIX the `connectto` check is
against the domain of the process that created the socket, so the bridge's socket
is `unconfined_service_t` whatever label `:z` puts on the file, and `container_t`
may not connect to it. `smortress-selinux-agent-shell.service` loads
`bootc/server/rootfs/usr/share/selinux/smortress/agent-shell.cil` before the bridge; the
rule pairs those two domains on `unix_stream_socket` and widens nothing else.

The facade mounts the socket's *directory*, not the socket: tmpfiles owns that
directory for the boot, so a bridge restart rebinds the socket inside an inode the
container already has mounted and no facade restart is needed. The quadlet still
`Requires=`/`After=` the bridge, because the mount source must exist before the
container starts.

The bridge never creates its directory: tmpfiles does, and the bridge refuses to
serve from one that is writable by group or other. The personal class is the same
program with a different `--class`, in its own unit and directory
(`smortress-agent-shell-bridge-personal.service`); a facade without a socket has
no shell tool at all rather than a tool that refuses.

## Containment

Every command gets:

- `podman run --rm --replace --pull=never` with a digest-pinned image from
  `/etc/smortress/agent/job-image`, so a tag cannot move what runs and a missing
  prepull fails instead of reaching a registry;
- read-only root filesystem, `--cap-drop=all`,
  `--security-opt=no-new-privileges`, podman's built-in seccomp profile (no
  `seccomp=` flag: podman 6 reads `seccomp=default` as a file path), private
  IPC/PID/UTS/cgroup
  namespaces, no devices and no host namespace;
- `--tmpfs /tmp` and `--tmpfs /work` with size and `nosuid`/`nodev` bounds; the
  general class adds the single live bind mount;
- a transient systemd unit with `RuntimeMaxSec=300`, `CPUQuota=100%`,
  `MemoryMax=1G`, `TasksMax=256`, `Delegate=yes`, and `TimeoutStopSec=10`. The
  unit, not a rootless user manager, owns the limits, so a host without
  delegated controllers still fails closed on a limit it cannot set; on timeout
  the whole cgroup is killed and the dispatcher removes any leftover container.
- an output cap of 1 MiB, applied where the bytes are written: the unit runs a
  per-job script that pipes the container into `head -c`, so the file can never
  outgrow the cap and a job that prints forever stops itself on the closed pipe.
  `pipefail` keeps the container's status rather than `head`'s. The dispatcher
  reads that file after the unit exits, truncates and reports `truncated` when
  the byte past the cap exists.

The job's files live under `/run/smortress-agent-job`, itself `0711 root` and
holding one `0750 root:<runner group>` directory per job, with a `0550` script
and the runner's `0600` output file inside. It is not under
`/run/smortress`: that tree is `0700 root` so no host uid can reach the bridge
socket, and a unit that runs as a runner uid cannot traverse it either — systemd
fails the exec and the job comes back with status `203`. The script is readable
only by the runner's group because it carries the command the caller sent.

The unit is started without `--pipe`. That option asks PID1 to hand the unit the
dispatcher's own descriptors, and on this host every such start from a service
domain is refused — `Failed to start transient service unit: Connection reset by
peer` — while the identical call from a login shell succeeds and dropping only
`--pipe` makes it work:

```
no-pipe        rc=0
pipe-no-wait   rc=1  Connection reset by peer
pipe-wait      rc=1  Connection reset by peer
```

A policy rule allowing `init_t` and `unconfined_service_t` to share
`fifo_file` did not change it, and it reproduces on a fresh boot. Nothing about
the containment depends on the pipe, so the capture moved into the unit rather
than the platform being asked to accept a start that this host refuses.

The general class's egress is filtered by the uid-keyed table in
`bootc/server/rootfs/etc/nftables/smortress-agent-jobs.nft`: `fib daddr type local`,
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

`bootc/server/rootfs/etc/sysusers.d/smortress-agent-shell.conf` allocates both login-less
accounts; nothing names their ids. `smortress-agent-job-provision.service` runs
`scripts/agent-job-provision.sh` at boot to:

1. add a non-overlapping subuid/subgid range to each runner (300000:65536 and
   400000:65536; an overlap is refused, never remapped);
2. enable linger, which is what makes logind create and keep `/run/user/<uid>`;
3. pull the digest in `/etc/smortress/agent/job-image` as each runner, into that
   runner's own rootless store;
4. apply the general runner's ACL and default ACL on `/var/srv/git`;
5. load the egress table before any job exists.

Step 3 comes before step 5 because it has to: the personal runner is dropped
outright by the table, so once that rule exists it could never fetch a digest a
pin bump names, and every personal job would fail closed on `has not prepulled`.
Pulling as the account rather than copying from root storage is what records the
digest reference the dispatcher checks. A pin bump therefore needs no operator
step beyond the reboot that carries it.

The runtime directory is a prerequisite, not an implementation detail: handed a
private directory under `/run/smortress`, rootless Podman fails in namespace setup
with `error opening namespace handles: Permission denied` even when the runner
owns it, and the same command succeeds under `/run/user/<uid>`. The dispatcher
therefore never creates that path; it derives it from the account and refuses to
start a job whose runtime directory is missing or owned by someone else.

`scripts/agent-job-provision.sh --check` reports drift and writes nothing. The
dispatcher re-loads the egress table itself before every launch, so a skipped or
failed boot unit cannot leave a job running without the boundary. Both bridges
require and follow that unit, because a bridge serving a socket whose every job
fails is worse than one that did not start.

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

See `docs/manual-steps.md#agent-shell-jobs` for verifying the units and running
each class's probe plus the cross-class refusals. `tests/core/agent-jobs.bats` covers the offline half: class-fixed entry
points, the mount/network split, the containment flags, the firewall ranges, the
digest pin and the subuid overlap refusal; `tests/core/app-quadlets.bats` covers the
transport wiring — two directories, two bridges, one facade mount each and neither
naming the other class.
