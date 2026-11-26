#!/usr/bin/env python3
"""The one door from the general facade to the rootless-Podman shell dispatcher.

SDLC #859 (T17 of #702). A coordination server has one tool that is not a typed
source: it has to run a command. That command may not go through the gateway,
because the gateway is where untrusted content arrives, and it may not go through
a Podman socket, because that is the container escape. So the facade holds a
connection to this program, and this program holds the dispatcher:

    facade container --(unix socket, one line JSON)--> bridge (root)
      --> /usr/libexec/agent-job-<class> "<one command>"
      --> systemd-run --wait --pipe --property=RuntimeMaxSec=300 --> podman run

Three properties follow from that shape and none of them is a policy check:

* The class is a constant here. ``--class`` selects ``/usr/libexec/agent-job-general``
  at startup; a request has no field that could name another class, an image, a
  mount, a network or a Podman flag, because the only field a request has is
  ``command``. A flag-shaped command is still one argument to the dispatcher,
  which passes it to ``/bin/sh -lc`` inside the container.
* The socket is the reachability control. It is a file in a root-owned 0700
  directory from systemd's ``RuntimeDirectory``, mode 0660 with the facade
  container's group, and it is mounted into that one container. There is no TCP
  listener: a port would be addressed by anything that can route to the host and
  would need its own authentication, while a socket reachable only by one
  container's uid needs none.
* The wall clock belongs to the dispatcher, not here. It runs the job under a
  transient unit with `RuntimeMaxSec=300`, which kills the job's cgroup; this
  program's 330 s deadline sits above that and kills the dispatcher's process
  group, so the only timeline that reaches it is one where the dispatcher already
  failed. The 1 MiB output cap is the same shape of backstop over the
  dispatcher's own cap.

Everything a request can cause is therefore: one command, run unsupervised in one
fixed class, with merged capped output. ``docs/agent-jobs.md`` carries the
contract and why approval does not live on this path.

Test-only override: ``SMORTRESS_AGENT_SHELL_JOB_DIR`` moves the dispatcher
directory so ``tests/agent-shell-bridge`` can drive this program against a fake
dispatcher. It is read once at startup and never from a request; a unit sets none.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Any, Mapping, NoReturn, Sequence

PROGRAM = "agent-shell-bridge"
LOG = logging.getLogger(PROGRAM)

#: The classes this program can serve. The name is interpolated into the one
#: dispatcher path it will run, and nothing else selects that path.
CLASSES = ("general", "personal")
JOB_DIR_ENV = "SMORTRESS_AGENT_SHELL_JOB_DIR"
JOB_DIR_DEFAULT = "/usr/libexec"
JOB_NAME_PATTERN = "agent-job-%s"

#: One JSON line per connection: 64 KiB is far more than a 32 KiB command and
#: bounds what a client can make this program buffer before it has parsed one.
MAX_REQUEST_BYTES = 64 * 1024
MAX_COMMAND_CHARS = 32768
#: The dispatcher caps at 1 MiB too; this bound is the backstop for a dispatcher
#: that does not (or a wrapper that forgets), so the answer is always bounded.
MAX_OUTPUT_BYTES = 1024 * 1024
#: Four jobs at once, and a fifth caller is told to come back rather than queued:
#: a queue here would be work the dispatcher's wall clock does not cover.
MAX_IN_FLIGHT = 4
#: Above the dispatcher's 300 s on purpose. Only tests lower it.
DEFAULT_TIMEOUT_SECONDS = 330
SOCKET_MODE = 0o660
LISTEN_BACKLOG = 8
#: A client that cannot send one line in this long is not a facade waiting for an
#: answer, and holding one of the four slots for it would wedge the socket.
REQUEST_READ_TIMEOUT_SECONDS = 10


class BadRequest(Exception):
    """A request this program will not turn into a job."""

    code = "invalid_request"


class JobTimeout(Exception):
    """The dispatcher outlived this program's deadline and was killed."""


@dataclass(frozen=True)
class Outcome:
    """What one dispatcher run produced, already merged and capped."""

    status: int
    output: str
    truncated: bool


def startup_failure(message: str) -> NoReturn:
    """Fail closed: one line, exit 2, and no socket is ever created."""

    print(f"{PROGRAM}: {message}", file=sys.stderr)
    raise SystemExit(2)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog=PROGRAM,
        description="Serve one shell class over a Unix socket to one facade.",
    )
    parser.add_argument(
        "--class",
        dest="job_class",
        required=True,
        help="general or personal; this picks the dispatcher path and is not a "
        "request field",
    )
    parser.add_argument(
        "--socket", required=True, help="socket path inside a root-owned 0700 directory"
    )
    parser.add_argument(
        "--socket-group",
        type=int,
        required=True,
        help="gid the socket is chowned to and made 0660 for: the facade's group",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=DEFAULT_TIMEOUT_SECONDS,
        help=f"backstop above the dispatcher's 300 s wall clock (default {DEFAULT_TIMEOUT_SECONDS})",
    )
    return parser


def dispatcher_path(job_class: str, job_directory: str) -> str:
    """The one dispatcher for a class; the class is the only input."""

    return os.path.join(job_directory, JOB_NAME_PATTERN % job_class)


def check_socket_directory(path: str) -> None:
    """Prove the directory that decides who may connect has the shape tmpfiles set.

    Ownership is not re-checked: /run/smortress is root:root 0700, so the child
    can only have been created by root. What a misconfiguration can change is the
    mode, and a group- or world-writable directory would let another uid replace
    the socket and answer the facade's jobs itself.
    """

    directory = os.path.dirname(path) or "."
    try:
        mode = os.stat(directory).st_mode
    except FileNotFoundError:
        startup_failure(f"the socket directory {directory} is missing")
    if not stat.S_ISDIR(mode):
        startup_failure(f"{directory} is not a directory")
    if mode & 0o022:
        startup_failure(f"{directory} is writable by group or other; refusing to serve")


def listen(path: str, group: int) -> socket.socket:
    """Bind the one socket, root-owned and reachable only by its group."""

    # The directory is systemd's RuntimeDirectory (root, 0700) and this program
    # never creates it: a missing directory is a start failure, because a
    # permissive mkdir here would be the reachability control creating itself.
    try:
        mode = os.lstat(path).st_mode
    except FileNotFoundError:
        pass
    else:
        if not stat.S_ISSOCK(mode):
            startup_failure(f"{path} exists and is not a socket; refusing to replace it")
        os.unlink(path)

    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(path)
    except OSError as error:
        listener.close()
        startup_failure(f"cannot bind {path}: {error.strerror}")
    # 0660 root:<facade gid>: connect(2) needs write permission on the inode, and
    # the group is the only thing that grants it. Root ownership means no other
    # user can replace the file either.
    os.chmod(path, SOCKET_MODE)
    os.chown(path, 0, group)
    listener.listen(LISTEN_BACKLOG)
    return listener


def read_request(connection: socket.socket) -> bytes:
    """One newline-terminated line, capped before it is parsed."""

    buffer = bytearray()
    while b"\n" not in buffer:
        chunk = connection.recv(65536)
        if not chunk:
            raise BadRequest("request must be one JSON line ending in a newline")
        buffer += chunk
        if len(buffer) > MAX_REQUEST_BYTES + 1:
            raise BadRequest(f"request exceeds {MAX_REQUEST_BYTES} bytes")
    line = bytes(buffer).partition(b"\n")[0]
    if len(line) > MAX_REQUEST_BYTES:
        raise BadRequest(f"request exceeds {MAX_REQUEST_BYTES} bytes")
    return line


def parse_command(line: bytes) -> str:
    """The one command in a request, or a refusal naming no request value."""

    try:
        request = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise BadRequest("request is not a UTF-8 JSON object") from None
    if not isinstance(request, dict):
        raise BadRequest("request must be a JSON object")
    unknown = sorted(str(name) for name in set(request) - {"command"})
    if unknown:
        # No request value is echoed: the class, image, mount, network and flags
        # this program uses are constants, so no field for them exists.
        raise BadRequest(f"unknown request field(s): {', '.join(unknown)}")
    if "command" not in request:
        raise BadRequest("request needs a command")
    command = request["command"]
    if not isinstance(command, str):
        raise BadRequest("command must be a string")
    if not command:
        raise BadRequest("command must be non-empty")
    if len(command) > MAX_COMMAND_CHARS:
        raise BadRequest(f"command exceeds {MAX_COMMAND_CHARS} characters")
    if "\0" in command:
        raise BadRequest("command contains a NUL byte")
    return command


def kill_group(process: subprocess.Popen) -> None:
    """Kill the dispatcher and everything it started, then reap it."""

    try:
        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    try:
        process.kill()
    except ProcessLookupError:
        pass
    process.wait()


def run_job(dispatcher: str, command: str, timeout_seconds: float) -> Outcome:
    """Run the dispatcher with exactly one argument; merge, cap and time it out."""

    deadline = time.monotonic() + timeout_seconds
    # stdin is closed: a job has no console. Its own session means one signal
    # reaches the dispatcher, the transient unit and the container beneath it.
    process = subprocess.Popen(
        [dispatcher, command],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    # stdout=PIPE above, so there is always a pipe to read.
    handle = process.stdout
    captured = bytearray()
    total = 0
    timed_out = False
    try:
        descriptor = handle.fileno()
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            ready, _, _ = select.select([descriptor], [], [], remaining)
            if not ready:
                continue
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            # One byte past the cap is the whole question; reading continues so a
            # chatty job is not blocked on a pipe nobody drains, and nothing past
            # that byte is kept.
            if len(captured) <= MAX_OUTPUT_BYTES:
                captured += chunk[: MAX_OUTPUT_BYTES + 1 - len(captured)]
    finally:
        handle.close()

    if not timed_out:
        try:
            status = process.wait(timeout=max(deadline - time.monotonic(), 0))
        except subprocess.TimeoutExpired:
            timed_out = True
    if timed_out:
        kill_group(process)
        raise JobTimeout(
            f"the job exceeded its {timeout_seconds:g}s wall clock and was killed (status 124)"
        )

    # Killed by a signal is the shell's 128+n, not a negative number a caller
    # would have to know how to read.
    exit_status = status if status >= 0 else 128 - status
    data = bytes(captured)
    truncated = total > MAX_OUTPUT_BYTES
    if truncated:
        data = data[:MAX_OUTPUT_BYTES]
    return Outcome(
        status=exit_status, output=data.decode("utf-8", "replace"), truncated=truncated
    )


def answer(connection: socket.socket, payload: Mapping[str, Any]) -> None:
    connection.sendall(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode() + b"\n")


def peer_credentials(connection: socket.socket) -> tuple[int, int]:
    """(uid, pid) of the caller from the kernel, never from the request."""

    try:
        raw = connection.getsockopt(
            socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")
        )
        pid, uid, _gid = struct.unpack("3i", raw)
        return uid, pid
    except OSError:  # pragma: no cover - SO_PEERCRED is always there on Linux
        return -1, -1


def handle(
    connection: socket.socket,
    peer: tuple[int, int],
    *,
    dispatcher: str,
    timeout_seconds: float,
    release: Any,
) -> None:
    """One request, one reply, one log line, and never the command text."""

    began = time.monotonic()
    uid, pid = peer
    status = "closed"
    length = 0
    reply: Mapping[str, Any] | None = None
    try:
        connection.settimeout(REQUEST_READ_TIMEOUT_SECONDS)
        command = parse_command(read_request(connection))
        length = len(command)
        try:
            outcome = run_job(dispatcher, command, timeout_seconds)
        except JobTimeout as error:
            status = "timeout"
            reply = {"error": {"code": "timeout", "status": 124, "message": str(error)}}
        else:
            status = str(outcome.status)
            reply = {
                "status": outcome.status,
                "output": outcome.output,
                "truncated": outcome.truncated,
            }
    except BadRequest as error:
        status = error.code
        reply = {"error": {"code": error.code, "message": str(error)}}
    except OSError:
        # A client that vanished mid-exchange is its own problem; the job, if one
        # ran, was already bounded by the dispatcher.
        LOG.warning("peer uid=%d pid=%d: the connection failed", uid, pid)
    except Exception:  # noqa: BLE001 - a crashed thread would answer nothing at all
        status = "failed"
        LOG.exception("peer uid=%d pid=%d: the request failed", uid, pid)
        reply = {"error": {"code": "unavailable", "message": "the bridge could not serve the job"}}
    finally:
        release()
    # The line lands before the reply, not after it: a bridge stopped the instant
    # its answer arrives would otherwise take the handler's line down with the
    # daemon thread, and a caller reading the log after a reply would see none.
    LOG.info(
        "peer uid=%d pid=%d command_length=%d status=%s duration_ms=%d",
        uid,
        pid,
        length,
        status,
        int((time.monotonic() - began) * 1000),
    )
    if reply is not None:
        try:
            answer(connection, reply)
        except OSError:
            LOG.warning("peer uid=%d pid=%d: the connection failed", uid, pid)
    connection.close()


def serve(listener: socket.socket, *, dispatcher: str, timeout_seconds: float) -> None:
    """Accept and serve until a signal arrives; never queue past the in-flight cap."""

    in_flight = 0
    guard = threading.Lock()
    stopping = threading.Event()

    def stop(signum: int, _frame: Any) -> None:
        LOG.info("signal %d: stopping", signum)
        stopping.set()
        # Closing unblocks accept() in the main thread, which is the only place a
        # handler runs.
        listener.close()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    def release() -> None:
        nonlocal in_flight
        with guard:
            in_flight -= 1

    try:
        while not stopping.is_set():
            try:
                connection, _ = listener.accept()
            except OSError:
                if stopping.is_set():
                    break
                raise
            peer = peer_credentials(connection)
            with guard:
                busy = in_flight >= MAX_IN_FLIGHT
                if not busy:
                    in_flight += 1
            if busy:
                try:
                    answer(
                        connection,
                        {
                            "error": {
                                "code": "unavailable",
                                "message": f"{MAX_IN_FLIGHT} jobs are already running; retry later",
                            }
                        },
                    )
                except OSError:
                    pass
                finally:
                    connection.close()
                LOG.info(
                    "peer uid=%d pid=%d status=unavailable in_flight=%d",
                    peer[0],
                    peer[1],
                    in_flight,
                )
                continue
            threading.Thread(
                target=handle,
                args=(connection, peer),
                kwargs={
                    "dispatcher": dispatcher,
                    "timeout_seconds": timeout_seconds,
                    "release": release,
                },
                daemon=True,
            ).start()
    finally:
        listener.close()


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(list(sys.argv[1:] if argv is None else argv))
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    # The socket is root-owned and the dispatcher switches to a runner uid and
    # creates systemd units: an unprivileged invocation is a bug or an attempt,
    # never a request to serve.
    if os.geteuid() != 0:
        startup_failure("must run as root; the socket is root-owned and jobs need root")
    if args.job_class not in CLASSES:
        startup_failure(
            f"unknown class {args.job_class!r}; this program serves {', '.join(CLASSES)}"
        )
    if args.timeout_seconds <= 0:
        startup_failure("--timeout-seconds must be positive")
    if args.socket_group < 0:
        startup_failure("--socket-group must be a gid")

    job_directory = os.environ.get(JOB_DIR_ENV) or JOB_DIR_DEFAULT
    dispatcher = dispatcher_path(args.job_class, job_directory)
    if not os.path.isfile(dispatcher):
        startup_failure(f"the dispatcher {dispatcher} is missing")
    if not os.access(dispatcher, os.X_OK):
        startup_failure(f"the dispatcher {dispatcher} is not executable")
    check_socket_directory(args.socket)

    listener = listen(args.socket, args.socket_group)
    LOG.info(
        "serving %s on %s for group %d, deadline %gs",
        dispatcher,
        args.socket,
        args.socket_group,
        args.timeout_seconds,
    )
    try:
        serve(listener, dispatcher=dispatcher, timeout_seconds=args.timeout_seconds)
    finally:
        try:
            os.unlink(args.socket)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
