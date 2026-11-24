# The agent broker

SDLC #582. nanobot has no credentials, no cluster token and no direct egress.
Every outbound request leaves through one broker Deployment in the `broker`
namespace; the broker maps an enrolled **logical host** to one real endpoint,
resolves and pins the address itself, strips whatever credential the agent sent,
injects exactly one enrolled credential, refuses redirects that leave the
enrolled endpoint, and logs metadata only.

Source: `apps/broker/` (Python stdlib, 123 unit tests). The reviewed
enrollment ships beside it at `apps/broker/config/broker.json`; the k3s/Flux
manifests were retired with the cluster tree.

**Status.** The cluster plane described below is historical: the `broker`
namespace, its Deployment, ServiceAccount, NetworkPolicies, the `tenant-apps`
caller identity, the `agent-debug` ceiling and the tunnel route to
`tenant-apps/nanobot` all went with the k3s/Flux tree, and the nanobot runtime
that made the calls is retired. The request contract, the enrollment, the
predicates and the code remain the source of truth for the broker itself, which
is what `apps/broker/tests` asserts. Do not read the `kubectl` and manifest
commands here as runnable.

## Trust boundary and non-goals

The broker is inside the boundary: it holds the provider and GitHub tokens and
is the only place they exist in the cluster. It is **not** an egress proxy and
**not** a policy engine: there is no user identity, no per-tool authorization
and no action model. It enforces two reviewed layers before a credential is
attached — target integrity (the agent names a logical host and a relative
path, never a hostname, IP, SNI or `Host`) and the per-host request predicates
below (SDLC #624). A predicate is a narrow, config-reviewed gate on one
enrollment; everything a predicate does not forbid is limited only by
provider-side authorization, so an enrolled token remains a credential oracle
within its scope.

`nanobot` holds no credential, including no broker token. Caller authentication
is the namespace boundary: `NetworkPolicy` admits only tenant-tier pods to the
Service, and the agent's own `Authorization`, `Cookie`, `X-Api-Key`,
`Proxy-Authorization`, `X-Scope-OrgID` and `X-Forwarded-For` headers are
dropped before injection. There is no shared secret to leak, rotate or mount.

## Request contract

```text
<method> http://broker.broker.svc.cluster.local:8080/<logical-host>/<path>?<query>
```

- The first path segment is the logical host; the rest is the upstream path.
  `/tinyfish` and `/tinyfish/` both mean "/" upstream.
- `Host` must be a DNS name, not an IP literal; absolute-form targets
  (`GET http://host/...`), `//`-ambiguous paths, NUL and backslash bytes are
  refused with 400.
- `CONNECT` and `TRACE` are refused with 405. The broker is not a forward
  proxy, so there is no tunnel and no `HTTPS_PROXY` setting in the agent.
- Every other method is forwarded when the destination passes the checks.
- A request that fails its logical host's predicates is refused with `403` (or
  `413` for a body over that host's cap) before DNS resolution; nothing is
  forwarded. See "Per-host request predicates".
- The request body is read up to 64 MiB, or less when the logical host sets
  `max_body_bytes`; a chunked request body is refused (411) rather than
  half-forwarded.
- `/healthz` is the kubelet probe and never proxied.

The agent's environment points at this Service:

```text
BROKER_URL=http://broker.broker.svc.cluster.local:8080
TINYFISH_BASE_URL=http://broker.broker.svc.cluster.local:8080/tinyfish
```

## Logical-host enrollment

`apps/broker/config/broker.json` is the reviewed, non-secret
enrollment. Credentials are files in the `broker-credentials` Secret; the broker
reads each one once at start and injects exactly one per request.

| Logical host | Real endpoint | Injection | Credential | Private allowed |
| --- | --- | --- | --- | --- |
| `neuralwatt` | `https://api.neuralwatt.com:443` | `Authorization: Bearer` | `neuralwatt-api-key` | no |
| `tinyfish` | `https://api.search.tinyfish.ai:443` | `X-Api-Key: <token>` | `tinyfish-api-key` | no |
| `loki` | `http://loki-gateway.observability.svc.cluster.local:3100` | `Authorization: Bearer`, fixed `X-Scope-OrgID: data` | `loki-gateway-token` | yes |
| `memory` | `http://memory-mcp.graphiti.svc.cluster.local:8182` | `Authorization: Bearer` | `memory-mcp-token` (optional) | yes |
| `notify` | `https://ntfy.sammohr.dev:443` | `Authorization: Bearer` | `notify-token` (optional) | no |
| `self` | `http://agent-control.tenant-apps.svc.cluster.local:8081` (prefix `/self`) | none | — | yes |
| `cluster` | `http://agent-control.tenant-apps.svc.cluster.local:8081` (prefix `/cluster`) | none | — | yes |
| `status` | `http://status-exporter.observability.svc.cluster.local:9101` | none (metrics text) | — | yes |

`path_prefix` restores a service's own route namespace after the broker
strips the logical host: the caller addresses `BROKER_URL/self/status`, and
the service sees `/self/status`; `BROKER_URL/cluster/pods` becomes
`/cluster/pods`. Without it the upstream would only see the trailing path.

GitHub is **not** a broker logical host, and there is nothing left to mint
for: the App, its minting code and every enrollment that used it were removed
on 2026-11-22. One identity serves GitHub now, a classic `repo` PAT held by the
machine user `smores56-agent`, and it never passes through this gateway. The
replacement model, including why the App lost, is `docs/agent-identity.md`.

`memory` (SDLC #631) is the graphiti memory wrapper
(`memory-mcp.graphiti.svc.cluster.local:8182`), the same MCP endpoint
`memory.sammohr.dev` used to front, reached in-cluster. That name has no DNS
record since the cluster tunnel went (SDLC #833); the enrollment is in-cluster
`http`, so nothing about it depended on the public name.
It is plain HTTP with `allow_private: true` — the documented private exception —
and injects `Authorization: Bearer <memory-mcp-token>`. The value is the one the
wrapper already uses, projected from the graphiti Secret into
`broker-credentials` at its own start. The enrollment sets
`optional_secret`, so until that file exists the host answers
`credential_unavailable` (503) and the rest of the broker is unaffected; a
request is never forwarded without the credential.

Every repository named on a host goes into a single token request, so one name
that is not in the app installation fails the whole host with a 422. Add a
repository only after confirming it is in the installation.

`notify` (SDLC #640, #649) is the ntfy bus at `https://ntfy.sammohr.dev`. The
path is the topic, the message is the plain-text body, and `title`, `priority`
and `tags` ride in the query string — the broker matches `allow_paths` against
the path only, so the query is forwarded untouched. It admits `POST` on a
single-segment topic of at most 64 characters, caps the body at 4 KiB and
injects `Authorization: Bearer <notify-token>`. `allow_private` stays `false`:
the endpoint is a public TLS name, so the broker never becomes a path into a
private network.

**The `notify` enrollment is inactive.** The ntfy bus, its cluster manifests and
the tunnel that published `ntfy.sammohr.dev` are retired with the k3s tree, and
the name has no DNS record (SDLC #833), so a call to that host fails at
dial/resolve, not at the broker's predicates. The enrollment stays in
`apps/broker/config/broker.json` deliberately: it is the reviewed contract for
what the agent may publish once ntfy is redeployed behind a public name again,
and `optional_secret` already makes an absent `notify-token` a 503 rather than a
startup failure. Deleting it would have to be undone by the same diff that
redeploys the bus.

The token is the ntfy `agent` user's, which is write-only on the `agent` topic.
That is deliberate: `allow_paths` is a path regex, not a topic allowlist, so a
`publisher` token would let the agent page `alerts`. The bus enforces the
boundary, not the broker. The enrollment sets `optional_secret`, so an absent
`notify-token` denies that host with `credential_unavailable` (503) instead of
aborting the broker at startup — the broker also serves GitHub, SDLC, memory
and Loki, and a missing notification token must not take those down. A request
is never forwarded without the credential.

`self` (SDLC #637) is the platform's `agent-control` service in `tenant-apps`:
plain HTTP inside the cluster, `allow_private: true` and no credential. The
broker forwards whatever paths agent-control serves; the service, its RBAC and
its own ingress policy are owned by the agent-control change. The namespace
boundary is the caller authentication, exactly as for the rest of the broker.

The private enrollments (`loki`, `memory`, `status`) are the only exception to
the TLS rule: they never leave the cluster network and their credentials are
already cluster-local. A credentialed enrollment over plain HTTP is otherwise
rejected at load time. `self` carries no credential, so the exception does not
apply to it.

## Per-host request predicates

Every enrollment may carry predicates (SDLC #624). All of them are optional and
every default is empty, so an enrollment without them forwards exactly what it
did before the feature existed.

| Key | Meaning |
| --- | --- |
| `allow_methods` | Non-empty list: the request method must be in it. |
| `deny_methods` | The request method is refused. A method cannot be in both lists. |
| `allow_paths` | Non-empty list: the upstream path must `fullmatch` one regex. |
| `deny_paths` | The upstream path is refused when a regex matches its start (prefix). |
| `deny_body_patterns` | The body (UTF-8, undecodable bytes replaced) is refused when a regex `search` matches. |
| `body_guards` | Conditional JSON gate, described below. |
| `max_body_bytes` | Per-host cap, 1..64 MiB; a larger `Content-Length` is `413` before the body is read. |

`allow_paths` and a guard's `paths` match the **normalized** upstream path
(`posixpath.normpath` of everything after the logical host), so `/<host>/a/../b`
is checked as `/b` and cannot dodge a prefix. `deny_paths` is a prefix match so
a reviewed `^/admin(/|$)` denies the subtree while a near-miss
(`/administrators`) does not match by accident.

A denial is `403` with `broker: <reason>` and no body detail, and it happens
before DNS resolution, before connecting and before credential injection. The
reason is a fixed token: `method_denied`, `path_denied`, `body_denied`,
`body_json_invalid`, `body_field_denied`, or `request_too_large` (413).
Patterns are reviewed config, and the per-host body cap bounds the work they can
do on agent-supplied input.

The one conditional rule is `body_guards`: each entry names `methods` (empty
means any), one or more `paths` regexes, a `field` (dot-separated JSON keys) and
an `allow` regex. When a request matches the method and path, the body must be
valid UTF-8 JSON with no repeated key, and the named field must be a string
matching `allow` at its start. A repeated key is `body_json_invalid` because two
JSON parsers can read two different values from it. The canonical shape is an
outbound call whose URL must stay inside one origin (the retired `github-hooks`
enrollment used exactly this):

```json
"body_guards": [
  {
    "methods": ["POST"],
    "paths": ["^/repos/[^/]+/[^/]+/hooks$"],
    "field": "config.url",
    "allow": "^https://agent-hooks\\.sammohr\\.dev/"
  }
]
```

`https://agent-hooks.sammohr.dev.evil.example/` and
`https://evil.example/?https://agent-hooks.sammohr.dev/` both fail: `allow` is
anchored at the start of the value (`re.match`), so only a URL that begins with
the enrolled origin passes.

## DNS self-resolution and IP pinning

For each request the broker resolves the enrolled host exactly once, checks
**every** address in the answer, and dials the address it checked. TLS uses that
address with the enrolled hostname for SNI and certificate verification, so the
name-to-address decision and the connection cannot disagree.

Refused for every enrollment, including a private one:

- the k3s pod CIDR `10.42.0.0/16` (the agent's own network);
- loopback (`127.0.0.0/8`, `::1`), link-local (`169.254.0.0/16`, `fe80::/10`,
  including the cloud metadata address), multicast, unspecified, reserved;
- CGNAT `100.64.0.0/10`;
- any address listed in `BROKER_DENY_ADDRESSES` (the node's real address);
- IPv4-mapped IPv6 forms of all of the above (`::ffff:10.42.0.9`);
- loopback names (`localhost`, `ip6-localhost`);
- any address that is not global unicast (TEST-NET, documentation and
  benchmarking ranges included).

Refused unless the enrollment is one of the private ones (`loki`, `status`,
`self`): RFC1918
(`10/8`, `172.16/12`, `192.168/16`), the service CIDR `10.43.0.0/16`, IPv6 ULA
(`fc00::/7`). A DNS answer that mixes a public and a private address is a
denial, not a fallback to the public one: that mix is the rebinding signature.
A DNS failure, empty answer or filtered address is a denial, never a second
lookup.

## Redirects

The broker never follows a redirect. A 3xx with a `Location` on a different real
host, port or scheme is refused with 502 and logged as `cross_host_redirect`;
a relative or same-endpoint redirect is returned to the agent untouched. The
agent must issue a new broker request naming a logical host, which is a fresh
enrollment lookup and a fresh injection.

## Logging and redaction

Each request writes one line at INFO:

```text
logical=<host> method=<method> path=<path> status=<status> bytes=<n> outcome=<proxied|denied|error>[ reason=<token>]
```

- The path is the broker path, **without the query string** (search queries
  stay out of logs). Path and denial text are redacted against every known
  credential.
- `reason=` appears only on a denial and is the fixed token from the request
  predicate or target check; it never contains the body, a header or a URL.
- No header value, request body or response body is logged. Upstream failures
  log the exception class only.
- Response headers that can carry a URL or a reflected credential (`Location`,
  `Content-Location`, `Link`, `Refresh`, `Set-Cookie`, `WWW-Authenticate`,
  `Proxy-Authenticate`) are redacted.
- Response bodies up to 1 MiB are buffered and redacted; beyond the cap the
  broker streams and marks `X-Broker-Redaction: partial` rather than claiming
  full coverage. The broker asks upstreams for `Accept-Encoding: identity` so a
  compressed body cannot hide a known secret from the matcher.
- Redaction replaces exact values and their URL, URL-plus, JSON, escaped-slash,
  HTML and base64 encodings with `[REDACTED:<logical-host>]`. A provider that
  transforms or re-encrypts a secret can still echo it undetected; that is the
  documented residual (spec §6.7), not a guarantee.

The broker is not deployed by this repository: no unit under `units/` runs it, so
the address policy, the agent identity and the `agent.sammohr.dev` routing that
the retired cluster enforced here are gone with it. What survives is the request
contract and the identity rules above, which `apps/broker/` still implements.
## Verification

```sh
# broker unit tests (no network, no cluster)
python3 -m unittest discover -s apps/broker/tests -t apps/broker -v

# static policy, RBAC, network and broker-manifest assertions
tests/policies/check.sh

# admission and can-i probes on the throwaway apiserver
scripts/install-ci-tools.sh "$HOME/.local/bin"   # etcd, kube-apiserver, kubectl
tests/policies/check.sh --runtime
```

The runtime probe evaluates `system:serviceaccount:tenant-apps:nanobot` against
every row in `tests/policies/rbac.tsv` marked `agent`: events and `delete pods`
are the only `yes` answers; secrets, `pods/log`, exec, attach, portforward,
proxy, deployment patches and nodes are all `no`.

Live-gated (need the cluster, the real tokens and the operator):

- publishing the broker image and replacing the digest placeholder;
- creating `broker-credentials` from SOPS (manual steps);
- the broker's first real call to each logical host (GitHub push, platform PR,
  the `sdlc` registry push/issues, Neuralwatt, TinyFish, Loki, memory, notify,
  agent-control);
- the notify bus's first real publish, once ntfy is redeployed behind
  `ntfy.sammohr.dev`; the enrollment and its `agent` user token wait for it
  (inactive, above);
- agent-control's Service, RBAC and tenant-side ingress
  (`tenant-apps` -> port 8081);
- the retired tunnel/Access routing and the `nanobot.sammohr.dev`
  retirement, which SDLC #833 completed;
- NetworkPolicy and gVisor enforcement (no CNI/kubelet on the test bench).
