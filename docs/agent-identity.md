# Agent identity: one dev credential, one capability credential

Two credentials exist, and neither is a GitHub App. This note records the model
that replaced `smores56-homelab-agent` and its per-request installation tokens on
2026-11-22, so the next person does not rebuild the thing that was retired.

## The two credentials

| Who | Identity | Kind |
| --- | --- | --- | --- |
| A Maki session you launch | **yours** (`smores56`) | your own `gh auth` login, nothing injected |
| The Hermes general agent | `smores56-agent` (machine user) | classic PAT, non-expiring, `repo` |
| The Hermes general agent, SDLC registry | `smores56` | fine-grained PAT: only `smores56/sdlc`, **Issues: read/write**, **Metadata: read**, no Contents |

Both machine credentials are **agent-only**. They are never placed in a home
directory, never exported in an interactive shell, and never reach the Hermes
gateway container, which has no shell and no Podman socket. They live as
ciphertext (`secrets/server/`) and are delivered per job by the trusted shell
dispatcher through systemd credentials, so the plaintext exists only inside one
general job's namespace:

```ini
# the dispatcher unit (T5), root
LoadCredential=github-token:/var/lib/homelab/agent/github-token
LoadCredential=sdlc-token:/var/lib/homelab/agent/sdlc-token
```

```sh
# general job class only; personal jobs receive neither
export GH_TOKEN="$(cat /run/secrets/github-token)"
export SDLC_GH_TOKEN_FILE=/run/secrets/sdlc-token
```

Until that dispatcher exists (#702 T5), the general agent has **no** GitHub
identity: its native shell is disabled, so it has nothing to push with. Staging
either token on the host beforehand would only create a second, weaker path.

### Staging the pair

Two ciphertexts, one scalar each (`value` format, because the job reads the file's
bytes directly), and their manifest lines land together — the decrypt fails
closed when the set and the manifest disagree:

```sh
# one key holding one bare scalar
( umask 077
  printf 'token: %s\n' '<the token>' >/tmp/t.yaml
  sops --encrypt --input-type yaml --output-type yaml \
    --filename-override secrets/server/agent-github-token.yaml /tmp/t.yaml \
    >secrets/server/agent-github-token.yaml
  rm -f /tmp/t.yaml
)
```

```text
# image/rootfs/usr/share/smortress/secrets.manifest
agent-github-token.yaml  root  root  0400  value
sdlc-github-token.yaml   root  root  0400  value
```

`check-server-image.sh` asserts the owner, mode and `value` format whenever a
ciphertext is present, and treats absence as the correct pre-T5 state.

The dev token can push branches, open and update pull requests, comment, and
enable auto-merge. It **cannot** merge except where a ruleset says so, and it
cannot edit `.github/workflows/**` — that needs the `workflow` scope, which is
deliberately absent. The registry token cannot read or write contents at all, so
the agent's registry work cannot touch code in `sdlc`, and code work cannot touch
the registry.

They are one *identity* in the sense that matters: the dev credential is a single
machine user for every repository, and the second token exists because "issues on
a private repo, and nothing else" is not expressible with a classic scope and
cannot be owned by the machine user (a fine-grained PAT must belong to the
account that owns the repository).

## Why not the `smores56` account for dev

Because it is the ruleset **bypass actor**. Every `main` ruleset lists
`{"actor_id":5,"actor_type":"RepositoryRole","bypass_mode":"always"}` and the API
answers `current_user_can_bypass: "always"` for that account, so a token under it
could push `main` and merge anything — the one thing the agent must not do. The
machine user is a Write collaborator, which the rules bind.

## Why not a GitHub App

An App installation token is narrower and shorter-lived, but it costs a second
identity, an app-wide permission set that has to be re-consented on every install,
per-host enrollment configuration, and a minting path that the host shell would
have to reach. The measured workflow — push, open PR, enable auto-merge — needs
none of it. The App's remaining unique capability was repository hooks, which the
human configures once by hand.

## How "cannot merge" is enforced

The token has the merge API: GitHub gates a REST merge on contents write, and any
token that can push branches has that. Enforcement is therefore the ruleset, not
the scope.

- `homelab-platform`, `nix-config`, `kanbei`, `dotfiles`, `smorespro-image`:
  the `main` ruleset requires one approving review. The agent is the pull-request
  author and GitHub forbids self-approval, so it cannot merge. It can still enable
  auto-merge; **your approval is the merge trigger**.
- `homelab-apps`: `main` requires **zero** approvals and owns only `.github/**`
  through CODEOWNERS, so an app-only PR merges itself once `apps-schema` is green.
  That is the deliberate exception: the agent owns the tenant repository.
- `sdlc`: no ruleset (private repository, free plan refuses them) and no code
  access from the registry token. It is the agent-driven registry, so writable is
  the point.

## What the agent may not do to itself

An interactive session acts as you, with your full authority — including the
ruleset bypass — because it is you. The machine user acts only inside a general
job, where the dispatcher, not the model, chose the mount.

It may restart its runtime; it may not re-pin it. Bumping `agent-runtime`, the
server image, or any other pin is a pull request to `homelab-platform`, and the
required approving review makes that a human merge. The bytes the agent runs
cannot be changed by the agent alone.

## Things that follow from this model

- No broker logical host is named `github-*`; a test asserts that, so a
  reintroduced App enrollment fails first.
- Rotating the dev token is one revocation, one ciphertext edit and a restart of
  the decrypt unit; there is no file on the host to forget and no installation to
  uninstall.
- Leaking the dev token is bounded by the rulesets and by the missing `workflow`
  scope, not by token lifetime. The owner accepted that trade on 2026-11-22.
