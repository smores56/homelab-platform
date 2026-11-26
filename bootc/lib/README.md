# `bootc/lib`

Shared inputs of the OS artifacts under `bootc/`. One rule decides what lives
here:

> A file lives in `bootc/lib` only if it is consumed by more than one artifact
> under `bootc/`, or by an `images/` publisher.

A file with one consumer belongs in that consumer's tree. The rule is what keeps
a server-only helper out of the edge image and an edge-only Caddyfile out of the
server's, and it is why the deploy decision is here: the server and the edge run
the same wire contract, the same listener and the same queue loop, and differ
only in the policy each passes in.

## What is here

| Path | Consumed by |
| --- | --- |
| `pins.env` | `bootc/server/Containerfile`, `images/*` publishers, `scripts/refresh-pins.sh` |
| `deploy/deploy-receiver.py` | the server's listener (`/usr/libexec/deploy-receiver.py`) and the edge's (design #939) |
| `deploy/decisions.py` | both verifiers, both receivers, both drains: the repo allowlist per role, the tag name, the digest and label shapes, descendancy, the journal vocabulary, the coalesce key, the state and denylist records |
| `deploy/drain.sh` | both drains: the FIFO/pop/retry loop, with the role's gate and action as hooks |
| `deploy/fixtures/` | both verifiers: one JSON document per accept/hold/refuse outcome, replayed by `tests/deploy/fixtures.bats` (the server's programs) and `tests/deploy/edge-verify.bats` (the same documents through both verifiers, which is what makes the set a contract between the roles rather than a description of one) |

The image installs `deploy/` at `/usr/libexec/deploy/` and the receiver at
`/usr/libexec/deploy-receiver.py`, the name the listener unit already runs; each
program resolves the shared directory from its own location, so a checkout runs
the checkout's copy and a host runs the image's.
