"""The typed operation set the agent facade serves, and its validation.

The safety rule this module exists for: an agent reaches named sources and one
memory store through a fixed set of operations, so no argument can name a path,
a SQL statement, a URL or a command. Every argument is a bounded string, a
bounded integer, or a mapping of bounded strings; an unknown tool name and an
unknown argument are refusals rather than things a handler quietly drops, and a
value over the byte cap is refused before anything is written. The deployment is
the server's identity, never a request field, so no caller can ask for a source
outside its own deployment by naming it.

Caps are module constants. ``parse_call`` takes the byte cap because the service
has one ``--max-body-bytes`` knob that bounds both a returned body and a written
value.

The one exception is ``shell.run`` (SDLC #859): its argument is a command, and it
exists only for a facade that was given a bridge socket, so it is not in
``TOOL_NAMES`` and ``parse_call`` refuses the name unless the caller allows it. The
isolation is in the path, not in the argument: the command reaches a dispatcher
that builds every mount, image and flag from constants, so there is nothing else
for a request field to name.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from types import MappingProxyType
from typing import Any, Callable, Mapping

from data_plane.errors import ValidationError
from data_plane.memory.file_memory import PROVENANCE_FIELDS

#: Default cap for a read body and for a written memory value. A truncation is
#: always flagged, so a caller can tell a short record from a clipped one.
MAX_BODY_BYTES = 256 * 1024
MAX_SEARCH_LIMIT = 50
DEFAULT_SEARCH_LIMIT = 20
MAX_SOURCE_CHARS = 64
MAX_ID_CHARS = 256
MAX_QUERY_CHARS = 512
MAX_KEY_CHARS = 128
MAX_TAG_CHARS = 64
MAX_TAGS = 16
MAX_PROVENANCE_CHARS = 256
SNIPPET_CHARS = 160
#: One shell command, counted in characters rather than bytes: the bridge holds
#: the same bound and refuses a longer line before it parses it.
MAX_COMMAND_CHARS = 32768

#: Source names, record ids, and memory keys are one path segment: lowercase
#: alphanumerics plus ``-`` and ``_``, never a dot, so an id can never address a
#: file outside the deployment's own directories.
_IDENTIFIER = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9_-]*\Z")
#: FTS5 words are extracted, never passed through: MATCH syntax is an operator
#: language, and a caller must not be able to hand the index a query it parses.
_QUERY_WORD = re.compile(r"\w+", re.UNICODE)


class UnknownTool(ValidationError):
    """A tool name that is not in the typed operation set."""


@dataclass(frozen=True)
class Describe:
    """List the sources this deployment may reach."""


@dataclass(frozen=True)
class SourceRead:
    source: str
    id: str


@dataclass(frozen=True)
class SourceSearch:
    source: str
    query: str
    limit: int


@dataclass(frozen=True)
class MemoryRead:
    key: str


@dataclass(frozen=True)
class MemoryWrite:
    key: str
    value: str
    tags: tuple[str, ...]
    provenance: Mapping[str, str]


@dataclass(frozen=True)
class MemorySearch:
    query: str
    limit: int


@dataclass(frozen=True)
class MemoryRebuild:
    """Rebuild the derived index from the record files."""


@dataclass(frozen=True)
class ShellRun:
    """One command for the general shell class, run unsupervised.

    The class is not a field: the bridge was started with one class and a
    request names nothing else. Neither is an image, a mount, a network or a
    Podman flag -- the dispatcher builds that argument vector from constants.
    """

    command: str


Operation = (
    Describe
    | SourceRead
    | SourceSearch
    | MemoryRead
    | MemoryWrite
    | MemorySearch
    | MemoryRebuild
    | ShellRun
)


@dataclass(frozen=True)
class ToolSpec:
    """One MCP tool: its name, its description, and its declared schema."""

    name: str
    description: str
    input_schema: Mapping[str, Any]

    def as_tool(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "inputSchema": dict(self.input_schema),
        }


def _schema(
    properties: Mapping[str, Any], required: tuple[str, ...] = ()
) -> Mapping[str, Any]:
    return MappingProxyType(
        {
            "type": "object",
            "properties": dict(properties),
            "required": list(required),
            # Declared, and also enforced by ``_fields``: a schema a client
            # skips is not the only thing refusing an unknown argument.
            "additionalProperties": False,
        }
    )


TOOL_SPECS: tuple[ToolSpec, ...] = (
    ToolSpec(
        "sources.describe",
        "List the sources this deployment may reach, with their read and search support.",
        _schema({}),
    ),
    ToolSpec(
        "sources.read",
        "Read one typed source record by id. The body is capped and a truncation is flagged.",
        _schema(
            {
                "source": {"type": "string", "maxLength": MAX_SOURCE_CHARS},
                "id": {"type": "string", "maxLength": MAX_ID_CHARS},
            },
            ("source", "id"),
        ),
    ),
    ToolSpec(
        "sources.search",
        "Search one source. Returns id, title and snippet only, never record bodies.",
        _schema(
            {
                "source": {"type": "string", "maxLength": MAX_SOURCE_CHARS},
                "query": {"type": "string", "maxLength": MAX_QUERY_CHARS},
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_SEARCH_LIMIT,
                    "default": DEFAULT_SEARCH_LIMIT,
                },
            },
            ("source", "query"),
        ),
    ),
    ToolSpec(
        "memory.read",
        "Read one memory key from this deployment's own memory profile.",
        _schema({"key": {"type": "string", "maxLength": MAX_KEY_CHARS}}, ("key",)),
    ),
    ToolSpec(
        "memory.write",
        "Write one memory key with provenance. A value over the cap is refused, never clipped.",
        _schema(
            {
                "key": {"type": "string", "maxLength": MAX_KEY_CHARS},
                "value": {"type": "string"},
                "tags": {
                    "type": "array",
                    "maxItems": MAX_TAGS,
                    "items": {"type": "string", "maxLength": MAX_TAG_CHARS},
                },
                "provenance": {
                    "type": "object",
                    "properties": {
                        "source_id": {"type": "string", "maxLength": MAX_PROVENANCE_CHARS},
                        "revision": {"type": "string", "maxLength": MAX_PROVENANCE_CHARS},
                        "captured_at": {"type": "string", "maxLength": MAX_PROVENANCE_CHARS},
                    },
                    "required": ["source_id", "revision", "captured_at"],
                    "additionalProperties": False,
                },
            },
            ("key", "value", "provenance"),
        ),
    ),
    ToolSpec(
        "memory.search",
        "Search this deployment's memory through the derived full-text index.",
        _schema(
            {
                "query": {"type": "string", "maxLength": MAX_QUERY_CHARS},
                "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": MAX_SEARCH_LIMIT,
                    "default": DEFAULT_SEARCH_LIMIT,
                },
            },
            ("query",),
        ),
    ),
    ToolSpec(
        "memory.rebuild",
        "Rebuild the derived full-text index from the record files. The index is disposable.",
        _schema({}),
    ),
)

TOOL_NAMES: tuple[str, ...] = tuple(spec.name for spec in TOOL_SPECS)

#: The one operation that is not a typed source read, and the only tool whose
#: presence is a deployment fact rather than a registry entry: a facade appends
#: it to ``tools/list`` when it was given a bridge socket, and refuses the name
#: otherwise. It is deliberately outside ``TOOL_NAMES`` so "this deployment has
#: a shell" cannot be read off a module constant.
SHELL_TOOL = ToolSpec(
    "shell.run",
    "Run one shell command unsupervised in the general shell class. Output and "
    "errors are merged and capped; the command cannot name a class, an image, a "
    "mount, a network or a Podman flag.",
    _schema({"command": {"type": "string", "maxLength": MAX_COMMAND_CHARS}}, ("command",)),
)


def _arguments(value: Any) -> Mapping[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, Mapping):
        raise ValidationError("tool arguments must be a JSON object")
    return value


def _fields(
    arguments: Mapping[str, Any],
    required: tuple[str, ...] = (),
    optional: tuple[str, ...] = (),
) -> None:
    unknown = sorted(str(name) for name in set(arguments) - set(required) - set(optional))
    if unknown:
        raise ValidationError(f"unknown argument(s): {', '.join(unknown)}")
    missing = [name for name in required if name not in arguments]
    if missing:
        raise ValidationError(f"missing required argument(s): {', '.join(missing)}")


def _text(value: Any, name: str, max_chars: int) -> str:
    if not isinstance(value, str):
        raise ValidationError(f"{name} must be a string")
    if not value.strip():
        raise ValidationError(f"{name} must be non-empty")
    if len(value) > max_chars:
        raise ValidationError(f"{name} exceeds {max_chars} characters")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ValidationError(f"{name} contains control characters")
    return value


#: A shell command needs its own control-character rule: it is source code, so a
#: newline and a tab are structure, while NUL and every other control character
#: are how a value smuggles a second one.
_COMMAND_CONTROLS = frozenset("\t\n")


def _command(value: Any) -> str:
    if not isinstance(value, str):
        raise ValidationError("command must be a string")
    if not value.strip():
        raise ValidationError("command must be non-empty")
    if len(value) > MAX_COMMAND_CHARS:
        raise ValidationError(f"command exceeds {MAX_COMMAND_CHARS} characters")
    for character in value:
        if character in _COMMAND_CONTROLS:
            continue
        if ord(character) < 32 or ord(character) == 127:
            raise ValidationError(
                "command contains a control character other than a tab or a newline"
            )
    return value


def _identifier(value: Any, name: str, max_chars: int) -> str:
    text = _text(value, name, max_chars)
    if not _IDENTIFIER.match(text):
        raise ValidationError(f"{name} must match [A-Za-z0-9][A-Za-z0-9_-]*")
    return text


def _limit(value: Any, name: str) -> int:
    if value is None:
        return DEFAULT_SEARCH_LIMIT
    # A bool is an int in Python, and ``limit: true`` must not mean one hit.
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValidationError(f"{name} must be an integer")
    if value < 1:
        raise ValidationError(f"{name} must be at least 1")
    if value > MAX_SEARCH_LIMIT:
        raise ValidationError(f"{name} must be at most {MAX_SEARCH_LIMIT}")
    return value


def _query(value: Any) -> str:
    text = _text(value, "query", MAX_QUERY_CHARS)
    if not query_words(text):
        raise ValidationError("query must contain at least one word")
    return text


def _value(value: Any, max_bytes: int) -> str:
    # A memory value is free text, so newlines are allowed; only the byte cap
    # applies, and it refuses rather than clips: a silently shortened value is
    # a different value.
    if not isinstance(value, str):
        raise ValidationError("value must be a string")
    if len(value.encode("utf-8")) > max_bytes:
        raise ValidationError(f"value exceeds the {max_bytes}-byte cap")
    return value


def _tags(value: Any) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, (str, bytes)) or not isinstance(value, (list, tuple)):
        raise ValidationError("tags must be an array of strings")
    if len(value) > MAX_TAGS:
        raise ValidationError(f"tags must contain at most {MAX_TAGS} entries")
    normalized: list[str] = []
    for tag in value:
        text = _text(tag, "tag", MAX_TAG_CHARS)
        if text not in normalized:
            normalized.append(text)
    return tuple(normalized)


def _provenance(value: Any) -> Mapping[str, str]:
    if not isinstance(value, Mapping):
        raise ValidationError("provenance must be a JSON object")
    unknown = sorted(str(name) for name in set(value) - set(PROVENANCE_FIELDS))
    if unknown:
        raise ValidationError(f"unknown provenance field(s): {', '.join(unknown)}")
    missing = [name for name in PROVENANCE_FIELDS if name not in value]
    if missing:
        raise ValidationError(
            f"provenance is missing {', '.join(missing)}"
        )
    normalized: dict[str, str] = {}
    for name in PROVENANCE_FIELDS:
        normalized[name] = _text(value[name], f"provenance {name}", MAX_PROVENANCE_CHARS)
    return MappingProxyType(normalized)


def _parse_describe(arguments: Mapping[str, Any], max_bytes: int) -> Describe:
    _fields(arguments)
    return Describe()


def _parse_source_read(arguments: Mapping[str, Any], max_bytes: int) -> SourceRead:
    _fields(arguments, ("source", "id"))
    return SourceRead(
        source=_identifier(arguments["source"], "source", MAX_SOURCE_CHARS),
        id=_identifier(arguments["id"], "id", MAX_ID_CHARS),
    )


def _parse_source_search(arguments: Mapping[str, Any], max_bytes: int) -> SourceSearch:
    _fields(arguments, ("source", "query"), ("limit",))
    return SourceSearch(
        source=_identifier(arguments["source"], "source", MAX_SOURCE_CHARS),
        query=_query(arguments["query"]),
        limit=_limit(arguments.get("limit"), "limit"),
    )


def _parse_memory_read(arguments: Mapping[str, Any], max_bytes: int) -> MemoryRead:
    _fields(arguments, ("key",))
    return MemoryRead(key=_identifier(arguments["key"], "key", MAX_KEY_CHARS))


def _parse_memory_write(arguments: Mapping[str, Any], max_bytes: int) -> MemoryWrite:
    _fields(arguments, ("key", "value", "provenance"), ("tags",))
    return MemoryWrite(
        key=_identifier(arguments["key"], "key", MAX_KEY_CHARS),
        value=_value(arguments["value"], max_bytes),
        tags=_tags(arguments.get("tags")),
        provenance=_provenance(arguments["provenance"]),
    )


def _parse_memory_search(arguments: Mapping[str, Any], max_bytes: int) -> MemorySearch:
    _fields(arguments, ("query",), ("limit",))
    return MemorySearch(
        query=_query(arguments["query"]),
        limit=_limit(arguments.get("limit"), "limit"),
    )


def _parse_memory_rebuild(arguments: Mapping[str, Any], max_bytes: int) -> MemoryRebuild:
    _fields(arguments)
    return MemoryRebuild()


def _parse_shell_run(arguments: Mapping[str, Any], max_bytes: int) -> ShellRun:
    _fields(arguments, ("command",))
    return ShellRun(command=_command(arguments["command"]))


Parser = Callable[[Mapping[str, Any], int], Operation]

_PARSERS: Mapping[str, Parser] = MappingProxyType(
    {
        "sources.describe": _parse_describe,
        "sources.read": _parse_source_read,
        "sources.search": _parse_source_search,
        "memory.read": _parse_memory_read,
        "memory.write": _parse_memory_write,
        "memory.search": _parse_memory_search,
        "memory.rebuild": _parse_memory_rebuild,
        SHELL_TOOL.name: _parse_shell_run,
    }
)


def parse_call(
    name: Any,
    arguments: Any,
    *,
    max_bytes: int = MAX_BODY_BYTES,
    allow_shell: bool = False,
) -> Operation:
    """Turn one tool call into a typed operation, or refuse it.

    ``allow_shell`` is the deployment's answer to "does this process have a
    bridge socket": without it the name is unknown here, exactly as a source of
    the other deployment is absent from its table rather than refused by a check.
    """

    parser = _PARSERS.get(name) if isinstance(name, str) else None
    if parser is _parse_shell_run and not allow_shell:
        parser = None
    if parser is None:
        # The name is not echoed: a caller-supplied string has no place in a
        # log line or an error a client sees, and the served set is public.
        raise UnknownTool(f"unknown tool; this facade serves {', '.join(TOOL_NAMES)}")
    if max_bytes < 1:
        raise ValidationError("the byte cap must be positive")
    return parser(_arguments(arguments), max_bytes)


def query_words(query: str) -> tuple[str, ...]:
    """Extract searchable words so the index never parses caller syntax."""

    return tuple(_QUERY_WORD.findall(query))


def search_expression(query: str) -> str:
    """An FTS5 expression of quoted words, joined so every word must appear."""

    words = query_words(query)
    if not words:
        raise ValidationError("query must contain at least one word")
    return " AND ".join('"' + word.replace('"', '""') + '"' for word in words)


def clip_body(body: str, max_bytes: int) -> tuple[str, bool]:
    """Clip a body to the byte cap on a character boundary, flagging truncation."""

    if max_bytes < 1:
        raise ValidationError("the byte cap must be positive")
    if len(body.encode("utf-8")) <= max_bytes:
        return body, False
    clipped = body.encode("utf-8")[:max_bytes].decode("utf-8", "ignore")
    return clipped, True


def snippet(text: str, query: str, width: int = SNIPPET_CHARS) -> str:
    """One-line excerpt around the first match, never the surrounding record."""

    if width < 1:
        raise ValidationError("snippet width must be positive")
    needle = query.casefold()
    folded = text.casefold()
    index = folded.find(needle) if needle else -1
    start = 0 if index <= 0 else max(0, index - width // 3)
    window = " ".join(text[start : start + width].split())
    if start > 0:
        window = "…" + window
    if start + width < len(text):
        window = window + "…"
    return window
