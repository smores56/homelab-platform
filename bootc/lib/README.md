# `bootc/lib`

Shared inputs of the OS artifacts under `bootc/`. One rule decides what lives
here:

> A file lives in `bootc/lib` only if it is consumed by more than one artifact
> under `bootc/`, or by an `images/` publisher.

A file with one consumer belongs in that consumer's tree. The rule is what keeps
a server-only helper out of the edge image and an edge-only Caddyfile out of the
server's, and it is why the deploy decision is here: the server and the edge run
the same queue loop over the same file format, and differ only in the policy each
passes in. Neither receives anything: since #1010 there is no listener on either
host, and the poll is what fills the queue.

## What is here

| Path | Consumed by |
| --- | --- |
| `pins.env` | `bootc/server/Containerfile`, `images/*` publishers, `scripts/refresh-pins.sh` |
| `deploy/decisions.py` | both verifiers and both drains: the repo allowlist per role, the tag name, the digest and label shapes, descendancy, the journal vocabulary, the coalesce key, the state and denylist records |
| `deploy/drain.sh` | both drains: the FIFO/pop/retry loop, with the role's gate and action as hooks |
| `deploy/fixtures/` | both verifiers: one JSON document per accept/hold/refuse outcome, replayed by `tests/deploy/fixtures.bats` (the server's programs) and `tests/deploy/edge-verify.bats` (the same documents through both verifiers, which is what makes the set a contract between the roles rather than a description of one) |

The image installs `deploy/` at `/usr/libexec/deploy/`; each program resolves the
shared directory from its own location, so a checkout runs the checkout's copy and
a host runs the image's.
