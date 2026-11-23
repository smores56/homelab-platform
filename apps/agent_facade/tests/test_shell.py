"""The shell runner against a fake bridge socket.

The fake is a real AF_UNIX listener in a temporary directory, so the runner's
connect, deadline, cap and reply parsing are the real code and a failure here is
about this module. No root, no dispatcher, no job: what crosses the socket is a
line the test scripted.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import tempfile
import threading
import unittest
from pathlib import Path

from apps.agent_facade import shell


class FakeBridge:
    """One Unix listener that answers every connection with a fixed reply."""

    def __init__(self, directory: Path, reply: bytes | None = b"") -> None:
        self.path = directory / "general.sock"
        self.reply = reply
        self.requests: list[bytes] = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.path.unlink(missing_ok=True)
        self.server.bind(str(self.path))
        self.server.listen(8)
        # A timeout, not a blocking accept: closing a listening socket does not
        # wake a thread already blocked in accept(2), so close() would wait it out.
        self.server.settimeout(0.05)
        self.closed = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def _serve(self) -> None:
        while not self.closed.is_set():
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            with connection:
                connection.settimeout(5)
                line = bytearray()
                try:
                    while b"\n" not in line:
                        chunk = connection.recv(65536)
                        if not chunk:
                            break
                        line += chunk
                except OSError:
                    continue
                self.requests.append(bytes(line))
                if self.reply:
                    try:
                        connection.sendall(self.reply)
                    except OSError:  # pragma: no cover - the client hung up
                        pass

    def close(self) -> None:
        self.closed.set()
        self.server.close()
        self.thread.join(5)


class ShellRunnerTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = Path(tempfile.mkdtemp(prefix="agent-shell-runner-"))
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)

    def bridge(self, reply: bytes | None = b"") -> FakeBridge:
        fake = FakeBridge(self.directory, reply)
        self.addCleanup(fake.close)
        return fake

    def runner(self, fake: FakeBridge, **kwargs: object) -> shell.ShellRunner:
        return shell.ShellRunner(str(fake.path), **kwargs)

    def line(self, payload: object) -> bytes:
        return json.dumps(payload).encode() + b"\n"

    def test_a_successful_job_returns_status_output_and_the_flag(self) -> None:
        fake = self.bridge(self.line({"status": 0, "output": "hi\n", "truncated": False}))
        result = self.runner(fake).run("printf hi")
        self.assertEqual(result, shell.ShellResult(status=0, output="hi\n", truncated=False))
        self.assertEqual(fake.requests, [self.line({"command": "printf hi"})])

    def test_a_truncated_answer_keeps_the_flag(self) -> None:
        fake = self.bridge(self.line({"status": 0, "output": "x" * 8, "truncated": True}))
        self.assertTrue(self.runner(fake).run("yes").truncated)

    def test_a_non_zero_status_is_a_result_and_not_an_error(self) -> None:
        fake = self.bridge(self.line({"status": 7, "output": "", "truncated": False}))
        self.assertEqual(self.runner(fake).run("false").status, 7)

    def test_a_missing_socket_is_unavailable(self) -> None:
        runner = shell.ShellRunner(str(self.directory / "absent.sock"))
        with self.assertRaises(shell.ShellUnavailable):
            runner.run("ls")

    def test_a_socket_that_nobody_listens_on_is_unavailable(self) -> None:
        fake = self.bridge()
        fake.close()
        runner = shell.ShellRunner(str(fake.path))
        with self.assertRaises(shell.ShellUnavailable):
            runner.run("ls")

    def test_an_unavailable_reply_is_unavailable(self) -> None:
        fake = self.bridge(self.line({"error": {"code": "unavailable", "message": "busy"}}))
        with self.assertRaises(shell.ShellUnavailable):
            self.runner(fake).run("ls")

    def test_a_timeout_reply_or_a_failed_job_is_a_shell_error(self) -> None:
        for code in ("timeout", "invalid_request", "shell_failed"):
            with self.subTest(code=code):
                fake = self.bridge(
                    self.line({"error": {"code": code, "message": "x", "status": 124}})
                )
                with self.assertRaises(shell.ShellError):
                    self.runner(fake).run("ls")

    def test_a_malformed_reply_is_refused(self) -> None:
        replies = [
            b"not json\n",
            b"[]\n",
            b"{}\n",
            self.line({"status": "0", "output": "", "truncated": False}),
            self.line({"status": True, "output": "", "truncated": False}),
            self.line({"status": 0, "output": 7, "truncated": False}),
            self.line({"status": 0, "output": "", "truncated": "no"}),
            self.line({"output": "", "truncated": False}),
            self.line({"error": {"message": "no code"}}),
            self.line({"error": "not an object"}),
        ]
        for reply in replies:
            with self.subTest(reply=reply):
                fake = self.bridge(reply)
                with self.assertRaises(shell.ShellError):
                    self.runner(fake).run("ls")

    def test_a_reply_over_the_cap_is_refused(self) -> None:
        fake = self.bridge(
            self.line({"status": 0, "output": "x" * 8192, "truncated": False})
        )
        with self.assertRaises(shell.ShellError):
            self.runner(fake, max_output_bytes=1024).run("ls")

    def test_a_bridge_that_never_answers_is_a_shell_error(self) -> None:
        fake = self.bridge(None)
        runner = shell.ShellRunner(str(fake.path), timeout_seconds=0.3)
        with self.assertRaises(shell.ShellError):
            runner.run("ls")

    def test_the_runner_refuses_a_bad_configuration(self) -> None:
        for kwargs in (
            {"socket_path": ""},
            {"socket_path": "/run/agent-shell/general.sock", "timeout_seconds": 0},
            {"socket_path": "/run/agent-shell/general.sock", "max_output_bytes": 0},
            {"socket_path": "/run/agent-shell/general.sock", "timeout_seconds": True},
        ):
            with self.subTest(kwargs=kwargs):
                with self.assertRaises(ValueError):
                    shell.ShellRunner(**kwargs)

if __name__ == "__main__":
    unittest.main()
