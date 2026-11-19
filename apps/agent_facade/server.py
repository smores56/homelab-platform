"""One MCP server, two transports, exactly one deployment identity.

The safety rule this module exists for: a facade process is one deployment, and
the only thing that decides which deployment a caller is talking to is the token
the process was given. There is no per-session identity and no taint layer,
because there is no shared process: the personal and general facades are two
processes with two tokens and two source tables.

* Over stdio the token arrives in the environment (or in a file it names), since
  a child process has no request headers. A missing token refuses **every** tool
  call, before the tool name is even looked at.
* Over Streamable HTTP only ``POST /mcp`` is served, and ``X-Deployment-Token``
  must equal the configured token. A missing or wrong token is a ``401`` with a
  JSON-RPC error, answered before the body is read, so no tool can have run.
  Notifications are answered ``202`` with no body.
* An unknown method is ``-32601``; an unknown tool is an ``isError`` result; a
  refused argument is an ``isError`` result carrying the repository's
  ``{"error": {"code", "message"}}`` shape.

The token is compared with ``hmac.compare_digest``, never logged, never echoed in
an error, and never placed in the response. The request headers are not logged
either: a log line is the method, the path and the status.
"""

from __future__ import annotations

import hmac
import json
import logging
import signal
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Mapping, TextIO
from urllib.parse import urlsplit

from data_plane.errors import ContractError, DataPlaneError, ValidationError
from data_plane.model import Visibility

from . import contracts, memory, sources

LOG = logging.getLogger("agent-facade")

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "agent-facade"
SERVER_VERSION = "0.1.0"
MCP_PATH = "/mcp"
TOKEN_HEADER = "X-Deployment-Token"

PARSE_ERROR = -32700
INVALID_REQUEST = -32600
METHOD_NOT_FOUND = -32601
INVALID_PARAMS = -32602
INTERNAL_ERROR = -32603
UNAUTHORIZED = -32001

# Most specific first: several of these are ValidationError subclasses.
_ERROR_CODES: tuple[tuple[type[DataPlaneError], str], ...] = (
    (sources.UnknownSource, "unknown_source"),
    (sources.SourceUnsupported, "unsupported"),
    (sources.SourceNotFound, "not_found"),
    (memory.MemoryNotFound, "not_found"),
    (ValidationError, "validation"),
)


class JsonRpcError(Exception):
    """A JSON-RPC failure with its protocol code."""

    code = INTERNAL_ERROR

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class ParseError(JsonRpcError):
    code = PARSE_ERROR


class InvalidRequest(JsonRpcError):
    code = INVALID_REQUEST


class MethodNotFound(JsonRpcError):
    code = METHOD_NOT_FOUND


class InvalidParams(JsonRpcError):
    code = INVALID_PARAMS


class Unauthorized(JsonRpcError):
    code = UNAUTHORIZED


def _error_code(error: DataPlaneError) -> str:
    for types, code in _ERROR_CODES:
        if isinstance(error, types):
            return code
    return "data_plane_error"


def _tool_error(code: str, message: str) -> dict[str, Any]:
    payload = {"error": {"code": code, "message": message}}
    return {
        "content": [{"type": "text", "text": json.dumps(payload, sort_keys=True)}],
        "structuredContent": payload,
        "isError": True,
    }


def _tool_result(result: Mapping[str, Any]) -> dict[str, Any]:
    return {
        "content": [
            {
                "type": "text",
                "text": json.dumps(result, sort_keys=True, ensure_ascii=False),
            }
        ],
        "structuredContent": dict(result),
        "isError": False,
    }


def _internal_error() -> JsonRpcError:
    return JsonRpcError("the facade could not complete the request")


def _error_response(request_id: Any, error: JsonRpcError) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {"code": error.code, "message": error.message},
    }


class Facade:
    """One deployment's tool surface: its catalog, its memory, its token."""

    def __init__(
        self,
        deployment: Visibility,
        catalog: sources.Catalog,
        store: memory.MemoryIndex,
        token: str | None = None,
        max_body_bytes: int = contracts.MAX_BODY_BYTES,
    ) -> None:
        if catalog.deployment is not deployment:
            raise ContractError(
                f"a {deployment.value} facade cannot serve a "
                f"{catalog.deployment.value} catalog"
            )
        if store.deployment is not deployment:
            raise ContractError(
                f"a {deployment.value} facade cannot serve "
                f"{store.deployment.value} memory"
            )
        if isinstance(max_body_bytes, bool) or not isinstance(max_body_bytes, int):
            raise ContractError("the byte cap must be an integer")
        if max_body_bytes < 1:
            raise ContractError("the byte cap must be positive")

        self.deployment = deployment
        self.catalog = catalog
        self.store = store
        self.max_body_bytes = max_body_bytes
        self._token = token or None

    @property
    def token_configured(self) -> bool:
        return self._token is not None

    def authorised(self, presented: Any) -> bool:
        """Constant-time check of one deployment token; no token means no."""

        if self._token is None or not isinstance(presented, str) or not presented:
            return False
        return hmac.compare_digest(presented, self._token)

    def handle(self, method: str, params: Any) -> Mapping[str, Any]:
        """Dispatch one JSON-RPC method to a typed operation."""

        if method == "initialize":
            return self._initialize()
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": [spec.as_tool() for spec in contracts.TOOL_SPECS]}
        if method == "tools/call":
            return self._call_tool(params)
        raise MethodNotFound(f"method not found: {method[:contracts.MAX_SOURCE_CHARS]}")

    def _initialize(self) -> Mapping[str, Any]:
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {
                "name": f"{SERVER_NAME}-{self.deployment.value}",
                "version": SERVER_VERSION,
            },
        }

    def _call_tool(self, params: Any) -> Mapping[str, Any]:
        if not self.token_configured:
            # Fail closed, and before the tool name is looked at: with no
            # configured identity there is no deployment a call could belong to.
            return _tool_error("unauthorized", "deployment identity is not configured")

        name, arguments = _tool_call_arguments(params)
        try:
            operation = contracts.parse_call(
                name, arguments, max_bytes=self.max_body_bytes
            )
        except contracts.UnknownTool as error:
            return _tool_error("unknown_tool", str(error))
        except ValidationError as error:
            return _tool_error("validation", str(error))

        try:
            return _tool_result(self._execute(operation))
        except DataPlaneError as error:
            return _tool_error(_error_code(error), str(error))
        except OSError:
            # A filesystem failure is a 500-shaped refusal: the path stays in
            # the log, the client gets a fixed message.
            LOG.exception("tool %s failed on the record store", name)
            return _tool_error("internal", "the facade could not complete the operation")

    def _execute(self, operation: contracts.Operation) -> Mapping[str, Any]:
        if isinstance(operation, contracts.Describe):
            return {
                "deployment": self.deployment.value,
                "sources": [
                    description.as_dict() for description in self.catalog.describe()
                ],
            }
        if isinstance(operation, contracts.SourceRead):
            record = self.catalog.read(operation.source, operation.id)
            body, truncated = contracts.clip_body(record.body, self.max_body_bytes)
            return {
                "id": record.id,
                "source": record.source,
                "title": record.title,
                "body": body,
                "provenance": dict(record.provenance),
                "revision": record.revision,
                "truncated": truncated,
            }
        if isinstance(operation, contracts.SourceSearch):
            hits = self.catalog.search(
                operation.source, operation.query, operation.limit
            )
            return {
                "source": operation.source,
                "hits": [hit.as_dict() for hit in hits],
            }
        if isinstance(operation, contracts.MemoryRead):
            record = self.store.get(operation.key)
            return {
                "key": record.id,
                "value": record.content,
                "tags": list(record.tags),
                "provenance": dict(record.provenance),
                "revision": record.updated_at,
                "digest": record.sha256,
            }
        if isinstance(operation, contracts.MemoryWrite):
            record = self.store.write(
                operation.key,
                operation.value,
                operation.tags,
                operation.provenance,
            )
            return {
                "key": record.id,
                "revision": record.updated_at,
                "digest": record.sha256,
            }
        if isinstance(operation, contracts.MemorySearch):
            hits = self.store.search(operation.query, operation.limit)
            return {
                "query": operation.query,
                "hits": [hit.as_dict() for hit in hits],
            }
        if isinstance(operation, contracts.MemoryRebuild):
            return {"indexed": self.store.rebuild()}
        raise ContractError(f"unhandled operation {type(operation).__name__}")


def _tool_call_arguments(params: Any) -> tuple[str, Any]:
    """Read the name and arguments of one ``tools/call``, refusing anything else."""

    if params is None:
        params = {}
    if not isinstance(params, Mapping):
        raise InvalidParams("tools/call params must be a JSON object")
    unknown = sorted(str(name) for name in set(params) - {"name", "arguments"})
    if unknown:
        raise InvalidParams(f"unknown tools/call field(s): {', '.join(unknown)}")
    name = params.get("name")
    if not isinstance(name, str):
        raise InvalidParams("tools/call needs a string tool name")
    return name, params.get("arguments")


def process(facade: Facade, message: Any) -> dict[str, Any] | None:
    """One JSON-RPC message in, one response out; None for a notification.

    A notification is never answered, not even with an error: the caller asked
    for no reply, and a refusal it never reads is a refusal it cannot act on.
    """

    if not isinstance(message, Mapping):
        raise InvalidRequest("a JSON-RPC message must be an object")
    method = message.get("method")
    if not isinstance(method, str):
        raise InvalidRequest("a JSON-RPC message needs a string method")
    request_id = message.get("id")
    if request_id is not None and (
        isinstance(request_id, bool) or not isinstance(request_id, (str, int))
    ):
        raise InvalidRequest("a JSON-RPC id must be a string, an integer or absent")
    notification = "id" not in message

    try:
        result = facade.handle(method, message.get("params"))
    except JsonRpcError as error:
        return None if notification else _error_response(request_id, error)
    if notification:
        return None
    return {"jsonrpc": "2.0", "id": request_id, "result": dict(result)}


def _emit(writer: TextIO, response: Mapping[str, Any]) -> None:
    writer.write(json.dumps(response, sort_keys=True, ensure_ascii=False) + "\n")
    writer.flush()


def serve_stdio(
    facade: Facade, stdin: TextIO | None = None, stdout: TextIO | None = None
) -> None:
    """Newline-delimited JSON-RPC on stdin/stdout until stdin closes."""

    reader = stdin if stdin is not None else sys.stdin
    writer = stdout if stdout is not None else sys.stdout

    for line in reader:
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            _emit(writer, _error_response(None, ParseError("line is not valid JSON")))
            continue
        try:
            response = process(facade, message)
        except JsonRpcError as error:
            _emit(writer, _error_response(None, error))
            continue
        except Exception:
            LOG.exception("unhandled failure serving a stdio message")
            _emit(writer, _error_response(None, _internal_error()))
            continue
        if response is not None:
            _emit(writer, response)


class FacadeHandler(BaseHTTPRequestHandler):
    """``POST /mcp`` and nothing else, behind one deployment token."""

    protocol_version = "HTTP/1.1"
    server_version = SERVER_NAME
    sys_version = ""

    #: Set by ``build_server``.
    facade: Facade
    max_body_bytes = contracts.MAX_BODY_BYTES

    def do_POST(self) -> None:
        self._dispatch()

    def do_GET(self) -> None:
        self._refuse_method()

    def do_PUT(self) -> None:
        self._refuse_method()

    def do_PATCH(self) -> None:
        self._refuse_method()

    def do_DELETE(self) -> None:
        self._refuse_method()

    def do_HEAD(self) -> None:
        self._refuse_method()

    def do_OPTIONS(self) -> None:
        self._refuse_method()

    def do_TRACE(self) -> None:
        self._refuse_method()

    def do_CONNECT(self) -> None:
        self._refuse_method()

    def _refuse_method(self) -> None:
        self._send(
            405,
            _error_response(None, InvalidRequest(f"only POST {MCP_PATH} is served")),
            {"Allow": "POST"},
        )

    def _dispatch(self) -> None:
        if urlsplit(self.path).path != MCP_PATH:
            self._send(
                404, _error_response(None, InvalidRequest(f"only POST {MCP_PATH} is served"))
            )
            return

        # Identity first: before the body is read, and before any tool could be
        # dispatched, so a wrong token has no side effect at all.
        if not self.facade.authorised(self.headers.get(TOKEN_HEADER)):
            self._send(
                401,
                _error_response(
                    None, Unauthorized("deployment identity missing or unknown")
                ),
            )
            return

        body = self._read_body()
        if body is None:
            return
        try:
            message = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send(400, _error_response(None, ParseError("body is not valid UTF-8 JSON")))
            return

        try:
            response = process(self.facade, message)
        except JsonRpcError as error:
            self._send(400, _error_response(None, error))
            return
        except Exception:
            # A fixed body, as the data-plane services do: the detail stays in
            # the log, so a path or a record cannot leak through the wire.
            LOG.exception("unhandled failure serving a JSON-RPC message")
            self._send(500, _error_response(None, _internal_error()))
            return
        if response is None:
            # A notification is accepted and has no body to return.
            self._send(202, None)
            return
        self._send(200, response)

    def _read_body(self) -> bytes | None:
        """Return the body, or None once an error has been answered."""

        if self.headers.get("Transfer-Encoding"):
            self._send(
                411,
                _error_response(
                    None, InvalidRequest("send Content-Length, not a chunked body")
                ),
            )
            return None
        declared = self.headers.get("Content-Length", "0")
        try:
            length = int(declared)
        except ValueError:
            self._send(400, _error_response(None, InvalidRequest("Content-Length is not an integer")))
            return None
        if length < 0:
            self._send(400, _error_response(None, InvalidRequest("Content-Length is negative")))
            return None
        if length > self.max_body_bytes:
            self._send(
                413,
                _error_response(
                    None,
                    InvalidRequest(f"request body exceeds the {self.max_body_bytes}-byte cap"),
                ),
            )
            return None
        if not length:
            return b""
        body = self.rfile.read(length)
        if len(body) != length:
            self._send(
                400,
                _error_response(None, InvalidRequest("body is shorter than Content-Length")),
            )
            return None
        return body

    def _send(
        self, status: int, payload: Mapping[str, Any] | None, extra: Mapping[str, str] | None = None
    ) -> None:
        body = (
            b""
            if payload is None
            else json.dumps(payload, sort_keys=True, ensure_ascii=False).encode("utf-8")
        )
        self.send_response(status)
        if body:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def log_request(self, code: Any = "-", size: Any = "-") -> None:
        # The request line and the status only: no headers, so no token,
        # whatever a future change decides to read from them.
        LOG.info("%s %s -> %s", self.command, urlsplit(self.path).path, code)

    def log_message(self, format: str, *args: Any) -> None:
        LOG.info("%s", format % args)


def build_server(facade: Facade, host: str, port: int) -> ThreadingHTTPServer:
    handler = type(
        "ConfiguredFacadeHandler",
        (FacadeHandler,),
        {"facade": facade, "max_body_bytes": facade.max_body_bytes},
    )
    server = ThreadingHTTPServer((host, port), handler)
    server.daemon_threads = True
    return server


def serve_http(facade: Facade, host: str, port: int) -> None:
    """Serve Streamable HTTP on one address until a signal arrives."""

    server = build_server(facade, host, port)
    LOG.info(
        "listening on %s:%d; deployment=%s token=%s",
        host,
        port,
        facade.deployment.value,
        "configured" if facade.token_configured else "absent",
    )

    def stop(signum: int, _frame: Any) -> None:
        LOG.info("signal %d: draining", signum)
        # shutdown() waits for serve_forever() to return, so it cannot run on
        # this thread.
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        server.serve_forever()
    finally:
        server.server_close()
        LOG.info("stopped")
