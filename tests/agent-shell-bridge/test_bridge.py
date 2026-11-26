"""The bridge, driven over its real Unix socket against a fake dispatcher.

The program refuses a caller that is not root, and this suite runs unprivileged,
so every serving case runs the real file in a subprocess whose harness stubs
``os.geteuid`` to 0 and records ``os.chown``: that is the path a root run takes,
and the recorded target proves the socket would be root-owned. The guard itself
is proved unmodified, without the harness, by
``BridgeStartupTest.test_a_non_root_caller_is_refused``.

What the cases pin down: the dispatcher receives one argument and nothing else,
no request field can name a class, an image, a mount, a network or a Podman
flag, the output is merged and capped, and the deadline kills the job's whole
process group.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "scripts" / "agent-shell-bridge.py"
COMMAND_CAP = 32768
OUTPUT_CAP = 1024 * 1024
REQUEST_CAP = 65536

#: Runs the bridge with what a root run has and a test does not: euid 0 and a
#: chown that succeeds. The chown is recorded instead of performed, so the case
#: can assert the target uid the socket would carry on the host.
HARNESS = '''\
import importlib.util
import os
import sys

record = os.environ["HARNESS_CHOWN_RECORD"]


def chown(path, uid, gid):
    with open(record, "a", encoding="utf-8") as handle:
        handle.write("%s %d %d\\n" % (path, int(uid), int(gid)))


os.chown = chown
os.geteuid = lambda: 0

spec = importlib.util.spec_from_file_location("agent_shell_bridge", sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
sys.exit(module.main(sys.argv[2:]))
'''

#: A stand-in for /usr/libexec/agent-job-general. It records the argv it was
#: given, one element per line, and answers from a control file the test writes,
#: so one bridge serves every case.
FAKE_DISPATCHER = '''\
#!/bin/sh
printf '%s\\n' "$@" >>"$FAKE_ARGV_FILE"
control=$(cat "$FAKE_CONTROL" 2>/dev/null) || control=ok
case $control in
  big)
    head -c 2097152 /dev/zero | tr '\\0' x
    ;;
  sleep)
    sleep 30 &
    printf '%s %s\\n' "$$" "$!" >"$FAKE_PID_FILE"
    wait
    ;;
  fail:*)
    printf 'refused\\n' >&2
    exit "${control#fail:}"
    ;;
  *)
    printf 'argc=%s\\n' "$#"
    printf 'arg=%s\\n' "$1"
    printf 'stderr=merged\\n' >&2
    ;;
esac
'''


def read_line(connection: socket.socket) -> bytes:
    """One newline-terminated reply, refusing a body larger than any answer."""

    buffer = bytearray()
    while b"\n" not in buffer:
        chunk = connection.recv(65536)
        if not chunk:
            raise AssertionError("the bridge closed without a reply")
        buffer += chunk
        if len(buffer) > 8 * OUTPUT_CAP:
            raise AssertionError("the bridge answered more than any legal reply")
    return bytes(buffer).partition(b"\n")[0]


def wait_for(predicate, timeout: float = 10.0) -> bool:
    """Poll a predicate; the bridge is a separate process with no ready signal."""

    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.02)
    return predicate()


def running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:  # pragma: no cover - the pid is our own child
        return True
    return True


class BridgeStartupTest(unittest.TestCase):
    """Startup fails closed, one line on stderr, before any socket exists."""

    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="agent-shell-bridge-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.job_dir = self.directory / "libexec"
        self.job_dir.mkdir()
        self.socket_path = self.directory / "general.sock"
        self.harness = self.directory / "harness.py"
        self.harness.write_text(HARNESS, encoding="utf-8")
        self.chown_record = self.directory / "chown"
        self.dispatcher = self.job_dir / "agent-job-general"
        self.dispatcher.write_text(FAKE_DISPATCHER, encoding="utf-8")
        self.dispatcher.chmod(0o755)

    def run_bridge(self, *extra: str, harness: bool = True) -> subprocess.CompletedProcess:
        argv = [sys.executable]
        if harness:
            argv += [str(self.harness), str(BRIDGE)]
        else:
            argv.append(str(BRIDGE))
        argv += list(
            extra
            or [
                "--class",
                "general",
                "--socket",
                str(self.socket_path),
                "--socket-group",
                str(os.getgid()),
            ]
        )
        return subprocess.run(
            argv,
            env={
                "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                "PYTHONDONTWRITEBYTECODE": "1",
                "SMORTRESS_AGENT_SHELL_JOB_DIR": str(self.job_dir),
                "HARNESS_CHOWN_RECORD": str(self.chown_record),
            },
            capture_output=True,
            text=True,
            timeout=30,
        )

    def refusal(self, result: subprocess.CompletedProcess) -> list[str]:
        self.assertEqual(result.returncode, 2, result.stderr)
        lines = [line for line in result.stderr.splitlines() if line.strip()]
        self.assertEqual(len(lines), 1, result.stderr)
        self.assertFalse(self.socket_path.exists(), "a refused start leaves no socket")
        return lines

    def test_a_non_root_caller_is_refused(self) -> None:
        if os.geteuid() == 0:  # pragma: no cover - the suite runs unprivileged
            self.skipTest("this case needs a non-root caller")
        lines = self.refusal(self.run_bridge(harness=False))
        self.assertIn("root", lines[0])

    def test_an_unknown_class_is_refused(self) -> None:
        lines = self.refusal(
            self.run_bridge(
                "--class",
                "privileged",
                "--socket",
                str(self.socket_path),
                "--socket-group",
                str(os.getgid()),
            )
        )
        self.assertIn("class", lines[0])

    def test_a_missing_dispatcher_is_refused(self) -> None:
        self.dispatcher.unlink()
        lines = self.refusal(self.run_bridge())
        self.assertIn("agent-job-general", lines[0])

    def test_a_dispatcher_that_is_not_executable_is_refused(self) -> None:
        self.dispatcher.chmod(0o644)
        self.refusal(self.run_bridge())

    def test_the_class_selects_a_constant_dispatcher_path(self) -> None:
        # The path follows --class and nothing else: an uninstalled class is a
        # refused start, never a fallback to the other class's entry point.
        lines = self.refusal(
            self.run_bridge(
                "--class",
                "personal",
                "--socket",
                str(self.socket_path),
                "--socket-group",
                str(os.getgid()),
            )
        )
        self.assertIn("agent-job-personal", lines[0])

    def test_a_group_writable_socket_directory_is_refused(self) -> None:
        # The directory, not the socket, is what a misconfiguration widens: a
        # group-writable one would let another uid replace the socket and answer
        # the facade's jobs itself.
        self.directory.chmod(0o770)
        self.addCleanup(self.directory.chmod, 0o700)
        lines = self.refusal(self.run_bridge())
        self.assertIn("writable", lines[0])

    def test_a_path_that_is_not_a_socket_is_never_unlinked(self) -> None:
        self.socket_path.write_text("a regular file\n", encoding="utf-8")
        result = self.run_bridge()
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("not a socket", result.stderr)
        self.assertEqual(
            self.socket_path.read_text(encoding="utf-8"), "a regular file\n"
        )


class BridgeSocketTest(unittest.TestCase):
    """One bridge process serving a fake dispatcher over a temporary socket."""

    timeout_seconds = 2

    def setUp(self) -> None:
        if not BRIDGE.exists():  # pragma: no cover - the red run
            self.fail(f"{BRIDGE} does not exist")
        self.directory = Path(tempfile.mkdtemp(prefix="agent-shell-bridge-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.job_dir = self.directory / "libexec"
        self.job_dir.mkdir()
        self.argv_file = self.directory / "argv"
        self.control_file = self.directory / "control"
        self.pid_file = self.directory / "pids"
        self.chown_record = self.directory / "chown"
        self.socket_path = self.directory / "general.sock"
        self.control_file.write_text("ok\n", encoding="utf-8")
        self.dispatcher = self.job_dir / "agent-job-general"
        self.dispatcher.write_text(FAKE_DISPATCHER, encoding="utf-8")
        self.dispatcher.chmod(0o755)
        self.harness = self.directory / "harness.py"
        self.harness.write_text(HARNESS, encoding="utf-8")
        self.process = self.start()

    def environment(self) -> dict[str, str]:
        # A minimal environment on purpose: anything the bridge needs that is not
        # in a unit's Environment= would be invisible on the host.
        return {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "SMORTRESS_AGENT_SHELL_JOB_DIR": str(self.job_dir),
            "HARNESS_CHOWN_RECORD": str(self.chown_record),
            "FAKE_ARGV_FILE": str(self.argv_file),
            "FAKE_CONTROL": str(self.control_file),
            "FAKE_PID_FILE": str(self.pid_file),
        }

    def start(self, *extra: str) -> subprocess.Popen:
        # The chown record is the start's own ready beacon: it is written once
        # the socket is bound, which a stale file on disk is not.
        self.chown_record.unlink(missing_ok=True)
        process = subprocess.Popen(
            [
                sys.executable,
                str(self.harness),
                str(BRIDGE),
                "--class",
                "general",
                "--socket",
                str(self.socket_path),
                "--socket-group",
                str(os.getgid()),
                "--timeout-seconds",
                str(self.timeout_seconds),
                *extra,
            ],
            env=self.environment(),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.close_pipes, process)
        self.addCleanup(self.stop, process)
        self.assertTrue(
            wait_for(
                lambda: self.socket_path.exists() and self.chown_record.exists()
            ),
            process.stderr.read() if process.poll() is not None else "no socket",
        )
        return process

    def stop(self, process: subprocess.Popen) -> None:
        process.terminate()
        try:
            process.wait(5)
        except subprocess.TimeoutExpired:  # pragma: no cover - a hung bridge
            process.kill()
            process.wait(5)

    def close_pipes(self, process: subprocess.Popen) -> None:
        for pipe in (process.stdout, process.stderr):
            if pipe is not None and not pipe.closed:
                pipe.close()

    def connect(self, timeout: float = 10.0) -> socket.socket:
        # The socket file exists from bind(), and the harness records the chown
        # that happens before listen(): a connect that wins that window is
        # refused, not absent. There is no ready signal from the bridge process,
        # so the connection itself is the poll.
        deadline = time.monotonic() + timeout
        while True:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(timeout)
            try:
                connection.connect(str(self.socket_path))
            except ConnectionRefusedError:
                connection.close()
                if time.monotonic() >= deadline:
                    raise
                time.sleep(0.02)
                continue
            self.addCleanup(connection.close)
            return connection

    def ask(self, payload: object) -> dict:
        connection = self.connect()
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        connection.sendall(body if body.endswith(b"\n") else body + b"\n")
        return json.loads(read_line(connection))

    def refusal(self, payload: object) -> dict:
        reply = self.ask(payload)
        self.assertIn("error", reply, reply)
        self.assertEqual(reply["error"]["code"], "invalid_request", reply)
        return reply["error"]

    def sent_argv(self) -> list[str]:
        if not self.argv_file.exists():
            return []
        return self.argv_file.read_text(encoding="utf-8").splitlines()

    # --- the socket itself ---------------------------------------------------

    def test_the_socket_is_group_gated_and_root_owned(self) -> None:
        info = self.socket_path.stat()
        self.assertTrue(stat.S_ISSOCK(info.st_mode))
        # 0660 root:<group>: the facade's group can connect, nobody else on the
        # host can, and connect(2) needs write permission on the inode.
        self.assertEqual(stat.S_IMODE(info.st_mode), 0o660)
        self.assertEqual(info.st_gid, os.getgid())
        recorded = self.chown_record.read_text(encoding="utf-8").split()
        self.assertEqual(recorded[0], str(self.socket_path))
        self.assertEqual(int(recorded[1]), 0, "the socket is owned by root")
        self.assertEqual(int(recorded[2]), os.getgid())

    def test_a_stale_socket_is_replaced(self) -> None:
        # A crash can leave the socket file behind; the bridge unlinks it because
        # it is a socket, and starts on the same path.
        self.stop(self.process)
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(str(self.socket_path))
        stale.close()
        self.assertTrue(stat.S_ISSOCK(self.socket_path.stat().st_mode))
        self.process = self.start()
        self.assertEqual(self.ask({"command": "ls"})["status"], 0)

    def test_a_connect_is_polled_until_the_bridge_listens(self) -> None:
        # bind() creates the file and the harness records the chown that runs
        # before listen(), so a connect can be refused in that window. Waiting
        # for the file alone made CI's client race the bridge on a loaded
        # runner; the connect itself is the readiness signal.
        late = self.directory / "late.sock"
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.bind(str(late))
        self.addCleanup(listener.close)
        started = threading.Event()

        def start_listening() -> None:
            time.sleep(0.2)
            listener.listen(4)
            started.set()

        thread = threading.Thread(target=start_listening, daemon=True)
        thread.start()
        self.socket_path = late
        connection = self.connect()
        connection.close()
        self.assertTrue(started.is_set())

    # --- one command, one argument ------------------------------------------

    def test_the_dispatcher_receives_exactly_one_argument(self) -> None:
        reply = self.ask({"command": "printf 'hello'"})
        self.assertEqual(reply["status"], 0)
        self.assertEqual(reply["truncated"], False)
        self.assertIn("argc=1\n", reply["output"])
        self.assertIn("arg=printf 'hello'\n", reply["output"])
        self.assertEqual(self.sent_argv(), ["printf 'hello'"])

    def test_a_newline_in_the_command_stays_one_argument(self) -> None:
        command = "printf 'a'\nprintf 'b'"
        reply = self.ask({"command": command})
        self.assertEqual(reply["status"], 0)
        # The fake records one line per argument, so a two-line file would be two
        # arguments -- which is the thing a shell transport usually gets wrong.
        self.assertEqual(self.argv_file.read_text(encoding="utf-8"), command + "\n")

    def test_a_flag_shaped_command_is_still_one_argument(self) -> None:
        command = "--privileged --volume=/:/host --network=host"
        reply = self.ask({"command": command})
        self.assertEqual(reply["status"], 0)
        self.assertIn("argc=1\n", reply["output"])
        self.assertEqual(self.sent_argv(), [command])

    def test_the_dispatchers_status_is_returned(self) -> None:
        self.control_file.write_text("fail:7\n", encoding="utf-8")
        reply = self.ask({"command": "false"})
        self.assertEqual(reply["status"], 7)
        self.assertEqual(reply["output"], "refused\n")

    def test_stderr_is_merged_into_the_output(self) -> None:
        reply = self.ask({"command": "true"})
        self.assertEqual(
            reply["output"], "argc=1\narg=true\nstderr=merged\n"
        )

    def test_the_output_is_capped_and_the_clipping_is_flagged(self) -> None:
        self.control_file.write_text("big\n", encoding="utf-8")
        reply = self.ask({"command": "head -c 2097152 /dev/zero"})
        self.assertEqual(reply["status"], 0)
        self.assertEqual(len(reply["output"]), OUTPUT_CAP)
        self.assertEqual(reply["truncated"], True)

    def test_the_deadline_answers_timeout_and_kills_the_group(self) -> None:
        self.control_file.write_text("sleep\n", encoding="utf-8")
        began = time.monotonic()
        reply = self.ask({"command": "sleep 30"})
        self.assertLess(time.monotonic() - began, self.timeout_seconds + 10)
        self.assertIn("error", reply, reply)
        self.assertEqual(reply["error"]["code"], "timeout")
        self.assertEqual(reply["error"]["status"], 124)
        pids = [int(pid) for pid in self.pid_file.read_text().split()]
        self.assertEqual(len(pids), 2, "the fake dispatcher and its child")
        self.assertTrue(
            wait_for(lambda: not any(running(pid) for pid in pids), 10),
            f"a killed job left {[pid for pid in pids if running(pid)]}",
        )

    # --- refusals ------------------------------------------------------------

    def test_no_request_field_can_name_a_class_image_mount_network_or_flag(self) -> None:
        for field in ("class", "image", "mount", "mounts", "network", "podman", "flags"):
            with self.subTest(field=field):
                self.refusal({"command": "ls", field: "general"})
        self.assertEqual(self.sent_argv(), [], "a refused request starts no job")

    def test_a_missing_or_wrong_command_is_refused(self) -> None:
        for payload in ({}, {"class": "general"}, {"command": ""}, {"command": 7},
                        {"command": ["ls"]}, {"command": "a\u0000b"}, {"command": None}):
            with self.subTest(payload=payload):
                self.refusal(payload)
        self.assertEqual(self.sent_argv(), [])

    def test_a_non_object_request_is_refused(self) -> None:
        for payload in (b"[]\n", b'"ls"\n', b"7\n", b"not json\n", b"\n"):
            with self.subTest(payload=payload):
                self.refusal(payload)
        self.assertEqual(self.sent_argv(), [])

    def test_an_oversized_command_is_refused(self) -> None:
        self.refusal({"command": "x" * (COMMAND_CAP + 1)})
        self.assertEqual(self.sent_argv(), [])

    def test_a_line_over_the_request_cap_is_refused(self) -> None:
        body = json.dumps({"command": "x" * (REQUEST_CAP + 1)}).encode()
        self.refusal(body)
        self.assertEqual(self.sent_argv(), [])

    def test_a_request_without_a_newline_is_refused(self) -> None:
        connection = self.connect()
        connection.sendall(b'{"command": "ls"}')
        connection.shutdown(socket.SHUT_WR)
        reply = json.loads(read_line(connection))
        self.assertEqual(reply["error"]["code"], "invalid_request")
        self.assertEqual(self.sent_argv(), [])

    def test_the_command_text_never_reaches_the_log(self) -> None:
        secret = "a-command-nobody-should-log"
        self.ask({"command": secret})
        self.stop(self.process)
        stderr = self.process.stderr.read()
        self.assertIn("command_length", stderr)
        self.assertNotIn(secret, stderr)

    # --- concurrency ---------------------------------------------------------

    def test_a_request_beyond_the_four_in_flight_is_refused_at_once(self) -> None:
        self.control_file.write_text("sleep\n", encoding="utf-8")
        held = []
        for _ in range(4):
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            connection.settimeout(10)
            connection.connect(str(self.socket_path))
            connection.sendall(b'{"command": "sleep 30"}\n')
            held.append(connection)
            self.addCleanup(connection.close)
        # The refusal is the signal: the four jobs are in flight once the
        # bridge turns a fifth request away, which under load can take longer
        # than a fixed pause. A reply instead of a refusal means the jobs had
        # not started yet, so ask again; a closed socket is the same refusal,
        # because the request never took a queue slot.
        began = time.monotonic()
        deadline = began + 10
        while True:
            try:
                reply = self.ask({"command": "ls"})
            except (BrokenPipeError, ConnectionResetError):
                break
            if reply.get("error", {}).get("code") == "unavailable":
                break
            self.assertLess(
                time.monotonic(), deadline, f"no refusal, last reply {reply!r}"
            )
            time.sleep(0.05)
        # Refused at once, not after waiting for one of the four to finish.
        self.assertLess(time.monotonic() - began, self.timeout_seconds)


if __name__ == "__main__":
    unittest.main()
