"""The general facade's one shell tool: a client for the root bridge.

SDLC #859 (T17 of #702). ``shell.run`` is the one operation on this server that
is not a typed read of a named source, so everything that makes it safe lives
outside this module: the bridge (``scripts/agent-shell-bridge.py``) owns the
class, the dispatcher path, the caps and the deadline, and the socket is a file
reachable only by this container's group. What is left here is a transport with
one job -- put one command on the socket, read one bounded line back -- and no
way to ask for anything else. There is no field for a class, an image, a mount,
a network or a Podman flag to send, and no second endpoint to send it to.

A missing socket is ``ShellUnavailable``: the facade stays up and the tool says
the shell is not reachable, which is the same shape as a source whose replica has
not published yet. A reply the bridge refused or could not answer is
``ShellError``; falling back to a local shell would be the escape hatch this
whole design exists to remove.
"""

from __future__ import annotations

import json
import socket
from dataclasses import dataclass

from data_plane.errors import ValidationError

#: The bridge's own backstop, restated here so this side can refuse a reply it
#: could never have produced. Both numbers come from the bridge's contract.
MAX_OUTPUT_BYTES = 1024 * 1024
MAX_REQUEST_BYTES = 64 * 1024
#: Above the bridge's 330 s deadline plus the time it needs to answer: the process
#: that owns the wall clock is the dispatcher, and this timeout only stops a hung
#: read from holding the caller. A shorter one would race the bridge's own timeout
#: reply.
DEFAULT_TIMEOUT_SECONDS = 345


class ShellUnavailable(ValidationError):
    """The bridge socket is missing, closed or refuses this process."""


class ShellError(ValidationError):
    """The bridge answered an error, or something that is not an answer."""


@dataclass(frozen=True)
class ShellResult:
    """One merged, capped job: its exit status, its output and whether it was cut."""

    status: int
    output: str
    truncated: bool


class ShellRunner:
    """One connection per call to the bridge socket."""

    def __init__(
        self,
        socket_path: str,
        timeout_seconds: float = DEFAULT_TIMEOUT_SECONDS,
        max_output_bytes: int = MAX_OUTPUT_BYTES,
    ) -> None:
        if not isinstance(socket_path, str) or not socket_path:
            raise ValueError("the shell socket path is required")
        if isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, (int, float)):
            raise ValueError("the shell timeout must be a number")
        if timeout_seconds <= 0:
            raise ValueError("the shell timeout must be positive")
        if isinstance(max_output_bytes, bool) or not isinstance(max_output_bytes, int):
            raise ValueError("the shell output cap must be an integer")
        if max_output_bytes < 1:
            raise ValueError("the shell output cap must be positive")

        self.socket_path = socket_path
        self.timeout_seconds = float(timeout_seconds)
        self.max_output_bytes = max_output_bytes

    def run(self, command: str) -> ShellResult:
        """Run one command in the bridge's class and return its merged output."""

        request = json.dumps({"command": command}).encode("utf-8") + b"\n"
        if len(request) > MAX_REQUEST_BYTES:
            # The bridge refuses this too; refusing here keeps an unaskable
            # request off the socket instead of earning a second refusal.
            raise ShellError(f"the command exceeds the {MAX_REQUEST_BYTES}-byte request cap")

        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(self.timeout_seconds)
        try:
            try:
                connection.connect(self.socket_path)
            except OSError as error:
                raise ShellUnavailable(
                    f"the shell bridge at {self.socket_path} is not reachable: "
                    f"{error.strerror or error}"
                ) from error
            try:
                connection.sendall(request)
                reply = self._read_reply(connection)
            except OSError as error:
                raise ShellError(f"the shell bridge dropped the request: {error}") from error
        finally:
            connection.close()
        return self._parse(reply)

    def _read_reply(self, connection: socket.socket) -> bytes:
        """One newline-terminated line, bounded by what a legal reply can be."""

        # JSON escaping can inflate the body, so the read bound is a multiple of
        # the output cap rather than the cap: an answer past it is not one this
        # server could have produced and is refused instead of buffered.
        limit = self.max_output_bytes * 8 + 4096
        buffer = bytearray()
        while b"\n" not in buffer:
            chunk = connection.recv(65536)
            if not chunk:
                if buffer:
                    raise ShellError("the shell bridge closed mid-reply")
                raise ShellError("the shell bridge closed without a reply")
            buffer += chunk
            if len(buffer) > limit:
                raise ShellError(f"the reply exceeds the {limit}-byte cap")
        return bytes(buffer).partition(b"\n")[0]

    def _parse(self, line: bytes) -> ShellResult:
        try:
            reply = json.loads(line.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise ShellError("the shell bridge answered something that is not JSON") from None
        if not isinstance(reply, dict):
            raise ShellError("the shell bridge answered something that is not a JSON object")
        if "error" in reply:
            error = reply["error"]
            if not isinstance(error, dict) or not isinstance(error.get("code"), str):
                raise ShellError("the shell bridge answered an error with no code")
            message = error.get("message")
            detail = f": {message}" if isinstance(message, str) and message else ""
            if error["code"] == "unavailable":
                raise ShellUnavailable(f"the shell bridge is busy{detail}")
            raise ShellError(f"the shell bridge refused the job ({error['code']}){detail}")

        status = reply.get("status")
        output = reply.get("output")
        truncated = reply.get("truncated")
        if isinstance(status, bool) or not isinstance(status, int):
            raise ShellError("the shell bridge answered a non-integer status")
        if not isinstance(output, str):
            raise ShellError("the shell bridge answered a non-string output")
        if not isinstance(truncated, bool):
            raise ShellError("the shell bridge answered a non-boolean truncation flag")
        if len(output.encode("utf-8")) > self.max_output_bytes:
            raise ShellError(
                f"the shell bridge answered more than the {self.max_output_bytes}-byte cap"
            )
        return ShellResult(status=status, output=output, truncated=truncated)
