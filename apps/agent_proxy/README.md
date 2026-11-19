# agent_proxy

One stdlib-only Python file that is the only thing on smortress allowed to dial a
hosted model provider, and the only thing that holds that provider's key.

## Why the key lives here and not in the gateway

The general gateway (`units/quadlet/agent-general.container`) is internet-connected
by design and runs a broad tool surface: browser automation, code execution, a
terminal inside its own filesystem. The hosted credential is a paid account. If the
key sat in the gateway's config or `.env`, every tool the agent can reach would sit
next to it, and a tool that reads a file would be one request away from spending
it.

So the gateway's model block points at this proxy — `base_url:
http://smortress-agent-proxy:18003/v1`, no `api_key` — and the proxy adds
`Authorization: Bearer <key>` on the way out. The key is a Podman secret mounted
from SOPS ciphertext at `/run/secrets/agent-hosted-key`, at uid 1000 mode 0400.

## What it refuses, structurally

- One pinned upstream (`https://api.neuralwatt.com`) is a module constant. No
  request field, header or environment variable moves it, so another host costs a
  source change and an image rebuild.
- Four routes only: `GET /v1/models`, `POST /v1/chat/completions`,
  `POST /v1/completions`, `GET /healthz`. Everything else is a 404 with a JSON
  body and `Cache-Control: no-store`.
- A request body over 1 MiB is refused from its `Content-Length`, before a byte
  of it is read.
- The inbound `Authorization` is dropped and replaced. `Host`, hop-by-hop headers
  and every `X-Forwarded-*` are never forwarded — the request headers are an
  allowlist (`Content-Type`, `Accept`), not a filter.
- Redirects are not followed, and an upstream `Location` header is dropped so the
  caller cannot be sent off the pinned host either.
- Responses are relayed unbuffered, so `stream: true` keeps streaming.
- The key is never logged, echoed or placed in argv. The log line is the method,
  the path and the status.

## Run

```sh
AGENT_PROXY_KEY_FILE=/run/secrets/agent-hosted-key \
AGENT_PROXY_HOST=127.0.0.1 AGENT_PROXY_PORT=18003 \
  ./proxy.py
```

On the host this is `units/quadlet/agent-proxy.container`, which sets
`AGENT_PROXY_HOST=0.0.0.0`: the published port is loopback-only, and a process
bound to `127.0.0.1` inside its own network namespace would never see the DNATed
traffic that arrives on `eth0`. A missing or empty key file stops the unit rather
than serving requests that can only fail upstream.

## Test

```sh
python3 -m unittest discover -s apps/agent_proxy/tests -t apps/agent_proxy
```

The suite runs the real handler on a random loopback port and replaces the
upstream connection with a fake, so there is no network and no TLS: allowed
routes and their forwarded URL and `Authorization`, the 404 for anything else, the
413 for an oversized body before it is read, credential replacement, a streamed
response, the dropped `Location`, and the fixed upstream under hostile request
arguments.
