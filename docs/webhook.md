# Inbound webhooks

SDLC #627. GitHub (and any other provider) delivers events to
`agent-hooks.sammohr.dev`, which terminates on the cluster tunnel, lands on the
`webhook` Deployment in the `webhook` namespace, and is enqueued into the agent
through nanobot's WebSocket gateway. The agent still has no inbound listener of
its own and no public egress.

```text
provider --HTTPS--> agent-hooks.sammohr.dev (Access bypass)
          --> cluster tunnel (ingress/cloudflared)
          --> webhook.webhook.svc:8080            capability id, HMAC, 1 MiB, dedupe
          --> ws://nanobot.tenant-apps.svc:8765   one enqueue frame
          --> the agent's session
```

Source: `apps/webhook/` (Python stdlib, 78 unit tests). Manifests:
`clusters/homelab/webhook/`. Applied by the Flux stage `platform-webhook`.

**Status.** The manifests, the tunnel and the Flux stage above went with the
k3s/Flux tree, and the gateway this receiver enqueued into is retired with the
nanobot runtime. Nothing in this repository deploys `apps/webhook`, nothing
serves `ws://nanobot.tenant-apps.svc:8765`, and no gateway config exists from
which to read `enqueue-token`. What remains true is the receiver's own contract
below (capability URL, HMAC, size limit, dedupe, the exact frames of the
researched WebUI protocol) and the unit tests that pin it; a future enqueue
target needs its own address, its own token source and its own reviewed change.
Do not read the deployment commands here as runnable.

## Trust boundary and non-goals

The receiver is **unauthenticated by construction**. It has no session, no
cookie and no Access policy: GitHub cannot complete an Access login and holds
no service token, so the only workable edge decision is a bypass. What stands
between the internet and an agent turn is:

1. a **capability URL**: a 256-bit, URL-safe id that is the path segment
   (`/hooks/<id>`). It is compared by exact dictionary lookup, so a guess is a
   404. The id is never logged.
2. an optional **GitHub HMAC**: a source registered with a secret requires
   `X-Hub-Signature-256` to verify over the exact body. A source registered
   without one accepts unsigned deliveries; the capability id is then the only
   credential.
3. a **size limit** and **dedupe**, so one hook cannot be used to pump the
   agent or to replay a redelivery.
4. an **admin token** on registration and revocation. Without it, anyone who
   found the public hostname could mint their own capability and enqueue into
   the agent. The registration route is the reason the admin secret exists.

Not in scope: it is not a general event bus, it stores nothing but source
records, and it does not call any provider API. Its only outbound request is
the enqueue path below.

## Request contract

| Request | Auth | Result |
| --- | --- | --- |
| `GET /healthz` | none | `200 {"status":"ok"}`; also the kubelet probes |
| `POST /endpoints` | `Authorization: Bearer <admin-token>` | `201` with `name`, `capability_id`, `capability_url`, `hmac` |
| `DELETE /endpoints/<capability-id>` | admin token | `204`, or `404` for an unknown id |
| `POST /hooks/<capability-id>` | capability id + HMAC when the source has a secret | `202 accepted`; `200 duplicate`; `401` bad/missing signature; `404` unknown id; `413` oversized; `502` gateway unavailable |

Registration body: `{"name": "github-platform", "secret": "<github webhook
secret>"}`. `secret` is optional. The name is 1–64 lowercase alphanumerics and
hyphens; it is the unit of rotation.

- **Rotation.** Registering an existing name issues a new id and deletes the old
  one in the same write, so the old URL 404s immediately. Rotate both the id and
  the HMAC secret with one call; update the provider's webhook URL to the new
  `capability_url`.
- **Revocation.** `DELETE /endpoints/<id>` removes the source (and its secret).
- **Size.** A body over **1 MiB** (`MAX_BODY_BYTES`) is refused with `413` before
  it is read. A missing `Content-Length` is `411`; a chunked body is not
  accepted. The text forwarded to the agent is capped at **64 KiB**
  (`MAX_FORWARD_BYTES`) and marked `[body truncated …]`; the full body is not
  retained anywhere.
- **Dedupe.** The key is `<source-name>:<delivery-id>`, where the delivery id is
  `X-GitHub-Delivery`, else `X-Delivery-Id`/`X-Request-Id`, else the body's
  SHA-256. A repeat within the window is `200 duplicate` and is not enqueued. The
  cache is bounded (4096 ids, 6 h) and in memory: a restart forgets the window,
  which is why a provider retry that crosses a rollout can enqueue twice.
- **Failure.** If the gateway cannot be reached, the delivery gets `502`, the
  dedupe claim is released, and the provider's retry is accepted normally.

Logging is one line per request: method, route (`hook`, `endpoints`, …), status
and byte count. No header value, body, capability id or secret is logged.

## Persistence

Sources live on the `webhook-sources` PVC (`local-path`, 64 MiB, RWO):
`sources.json`, mode `0600`, written atomically. The claim holds the per-source
HMAC secrets, so it is why the pod has one replica (`Recreate`) and why no other
namespace can mount it. A PVC was chosen over memory so a capability URL
survives a rollout; the dedupe cache deliberately does not.

The tokens are separate, operator-created Secret keys (`webhook-tokens`):

| Key | Used for | Source |
| --- | --- | --- |
| `admin-token` | `POST`/`DELETE /endpoints` | `openssl rand -hex 32` |
| `enqueue-token` | `/webui/bootstrap` bearer | the enqueue target's own token; the retired gateway minted it as `channels.websocket.tokenIssueSecret` |

The Deployment mounts the Secret with `optional: false`, so a missing Secret
leaves the pod pending instead of serving a public hostname with no tokens.

The enqueue target was the retired agent runtime: nothing in this repository
serves the gateway endpoint the receiver used to call, so the protocol notes it
relied on went with it. `apps/webhook/` still implements the trust boundary and
the request contract above, and `docs/manual-steps.md` has the publish and token
steps that apply to it today.
