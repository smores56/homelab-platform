# data-plane services

Thin, stdlib-only HTTP front ends over the libraries in `libs/data_plane/`.
Each service parses JSON, checks one credential, calls a library method, and
renders the result. The libraries own every safety rule; these modules add no
policy of their own.

## Status: offline and fixture-only

These services are **offline fixtures until images and secrets are
provisioned**. `run.py` opens local SQLite files and in-process adapters. It
never runs `restic`, never dials a cluster or a provider, and never reads live
personal data. The broker's effect path is real — the SQLite intent journal,
pre-images, revision checks, and operator-signed approvals — while its source
adapters are stand-ins (`FixtureAdapter` in `run.py`, a list sink for the relay)
so the endpoint contracts can be exercised before a deployment exists.
Backups are not a service: the host runs the `data_plane` CLI (`backup-run`,
`backup-freshness`, ...) over one recursive ZFS snapshot instead.

Nothing here issues a secret, and no secret is stored in the repository. A
secret is read once from a file named on the command line or in the
environment, held in memory, and never logged.

## Run

```sh
python -m apps.data_plane.run event  --db state/events.db \
  --append-token-file /run/secrets/event/append-token \
  --read-token-file /run/secrets/event/read-token
python -m apps.data_plane.run relay  --schema relay-schema.json --secret-file /run/secrets/relay
python -m apps.data_plane.run broker --db state/intents.db --catalog catalog.json \
  --secret-file /run/secrets/identity \
  --operator-key-file /run/secrets/operator/signing-key \
  --approval-db state/intents.db
python -m apps.data_plane.run confirmation --db state/intents.db --catalog catalog.json \
  --operator-key-file /run/secrets/operator/signing-key \
  --operator-token-file /run/secrets/operator/token
```

Every flag also has an environment variable: `DATA_PLANE_HOST`,
`DATA_PLANE_PORT`, `DATA_PLANE_DB`, `DATA_PLANE_SECRET_FILE`,
`DATA_PLANE_SCHEMA`, `DATA_PLANE_CATALOG`, `DATA_PLANE_OPERATOR_KEY_FILE`,
`DATA_PLANE_OPERATOR_TOKEN_FILE`, `DATA_PLANE_APPROVAL_DB`,
`APPROVAL_TTL_SECONDS`, and `DATA_PLANE_MAX_BODY_BYTES`. Logs go to stderr.
The default bind is `127.0.0.1:8080`; a container sets `DATA_PLANE_HOST=0.0.0.0`
and a real port.

## Common transport

- Request bodies must be a JSON object, sent with `Content-Length`. The default
  cap is 1 MiB; a larger declaration is refused with `413 payload_too_large`
  before any bytes are parsed.
- Responses are JSON with `Cache-Control: no-store`; every connection closes
  after one response.
- Errors have one shape:

  ```json
  {"error": {"code": "validation", "message": "kind must be a non-empty string"}}
  ```

  Library `ValidationError` -> 400, `AuthorizationError` -> 403, cursor, epoch,
  stale, idempotency, and unknown-outcome conflicts -> 409. An unexpected
  failure is a fixed `500 internal`; its detail stays in the log.
- `GET /healthz` on every service is unauthenticated.

## Event service

Auth uses two separate tokens, both sent as `X-Event-Token`: the append token
authorises `POST /events` only, and the read token authorises `GET /events` and
`GET /events/tail` only. A producer cannot read the log and a reader cannot
inject events; the service refuses to start when the two tokens are equal.

The header format is `v1:<unix-timestamp>:<nonce>:<hex>` where the digest is

```
HMAC-SHA256(secret, "<METHOD>\n<request-target>\n<sha256(body) hex>\n<timestamp>\n<nonce>")
```

`<request-target>` is the path **including the query string**, exactly as sent.
A token is accepted once inside a 60-second freshness window; its nonce is
cached (bounded) so a replay is refused. A missing token is 401, a malformed,
stale, replayed, or wrong token is 403. `request_token()` in `common.py` is the
reference signer.

`POST /events/ack` is authenticated with the **consumer's own** secret from the
service's consumer-to-secret mapping, not either service token: a caller
cannot acknowledge another consumer.

| Route | Body / query | Result |
| --- | --- | --- |
| `POST /events` | `{"kind","entity","payload"?,"idempotency_key"}` (event ids are server-assigned) | 201 event |
| `GET /events` | `?after=&limit=` (limit <= 1000) | 200 `{"epoch","events"}` |
| `GET /events/tail` | `?consumer=&timeout=` (timeout <= 30s) | 200 `{"event"}`, or 204 when the wait expires |
| `POST /events/ack` | `{"consumer","position"}` | 200 `{"consumer","position","epoch"}` |
| `GET /healthz` | none | 200 `{"status","service"}` |

The tail long-polls the durable cursor and does **not** acknowledge the event;
the consumer acknowledges once it has handled it.

## Broker service

Auth: `X-Workload-Token: <token>` carries signed workload claims. The service
verifies the token with the identity issuer; it does not mint one.

**The confirmation surface is external and operator-controlled.** This service
never issues an operator confirmation token. A delete, bulk, irreversible, or
cross-domain write leaves the intent `awaiting_confirmation`; the operator
surface signs the intent's stored operation and the token comes back in the
request body. `POST /apply` without it returns `403 confirmation_required`.

A routine write is one target with an allowed field set, a pinned revision, a
captured pre-image, and a `run_id`. It applies without a human. Everything else
needs an approval:

- a capability that declares it (`delete`, `bulk`, `irreversible`,
  `reclassify`), or a local profile writing a general source;
- more than one target, which is an exact target-set approval;
- a second routine effect in one `run_id`; the journal counts effects that
  already started for the run, so bulk is per user intent, not per tool call.

`POST /propose` reads the live revision of every target and stores the pre-image
with the operation, so an approval always names the base state it overwrites.
A supplied `base_revision` that has moved is `409 stale` before the intent is
written.

| Route | Body | Result |
| --- | --- | --- |
| `POST /propose` | write request | 201 `{"intent","operation"}` |
| `POST /confirm` | write request + `"confirmation_token"` | 200 `{"intent"}` |
| `POST /apply` | write request + optional `"confirmation_token"` | 200 `{"effect"}` |
| `POST /reconcile` | `{"intent_id"}` | 200 `{"intent"}` |
| `GET /healthz` | none | 200 `{"status","service"}` |

A write request is `source_id`, `capability`, `targets` (non-empty string
list), `idempotency_key`, and optional `field_diff` (`[[field, before, after]]`),
`base_revision`, `recurrence`, `attendee_scope`, `destination`, `epoch`,
`run_id`. `run_id` is required for any write that does not need an approval.

## Confirmation service

Auth: `X-Operator-Token`, a secret distinct from the workload identity key and
from every source credential. It is the only surface that mints an approval.

**It renders the effect owner's canonical record, never a request body.** The
operation and pre-image come from the intent row the broker wrote; `/approve`
refuses a body carrying `operation`, `operation_hash`, `targets`, or
`field_diff` with `400 validation`. A runtime that shows one diff to a human
therefore cannot have another approved, and no workload token can reach this
surface. `/reject` settles the intent as `rejected`, which no later apply can
resurrect.

| Route | Request | Result |
| --- | --- | --- |
| `GET /pending` | `?intent_id=` | 200 `{"pending","render"}` |
| `POST /approve` | `{"intent_id","approved_by","ttl"?}` | 200 `{"approval_token","claims","pending"}` |
| `POST /reject` | `{"intent_id","approved_by","reason"?}` | 200 `{"intent_id","state"}` |
| `GET /healthz` | none | 200 `{"status","service"}` |

The token's lifetime never outlives the intent. The broker spends the nonce in
the same SQLite transaction that marks the effect `applying`, so an approval is
single-use across pods, a stale revision cannot burn one, and a restore
(`IntentStore.cancel_pending`) expires every intent that has not started.

## Relay service

Auth is the relay's own body HMAC: `X-Relay-Signature: sha256=<hex>` over
`source_id + "\0" + idempotency_key + "\0" + body`, plus `X-Idempotency-Key`.
The relay is bound to one configured source id at startup; the HMAC covers it,
the record's `source_id` must equal it, and rate-limit/cursor state is keyed by
it — never by the body. Replaying the same key and body returns the first
result; reusing the key with another body is `409 idempotency_conflict`. A
missing or wrong signature is 403. The record schema rejects unknown fields
(`additionalProperties: false`) and bodies nested deeper than 8 levels.

The schema is a JSON file loaded at startup:

```json
{
  "required_fields": ["source_id", "object_id", "tombstone"],
  "field_types": {"source_id": "str", "object_id": "str", "tombstone": "bool"},
  "max_bytes": 65536,
  "max_records_per_second": 10
}
```

| Route | Request | Result |
| --- | --- | --- |
| `POST /ingest` | body + `X-Idempotency-Key` + `X-Relay-Signature`, cursor in `?cursor=` or `X-Cursor` | 202 result object |
| `GET /healthz` | none | 200 `{"status","service"}` |
