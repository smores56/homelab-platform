"""Shared fixtures: one facade over a temporary memory root, and its helpers."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from typing import Any, Mapping

from data_plane.model import Visibility

from apps.agent_facade import memory, server, sources

TOKEN = "deployment-token-for-tests"
PROVENANCE: Mapping[str, str] = {
    "source_id": "notes/note-1",
    "revision": "1",
    "captured_at": "2026-11-01T00:00:00+00:00",
}
#: Small enough that a truncation test does not need a 256 KiB fixture.
MAX_BYTES = 4096


class FacadeCase(unittest.TestCase):
    """A facade for one deployment, its own temporary memory root."""

    deployment = Visibility.PERSONAL

    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.store = memory.MemoryIndex(self.root, self.deployment)
        self.catalog = sources.Catalog.for_deployment(self.deployment)
        self.facade = server.Facade(
            deployment=self.deployment,
            catalog=self.catalog,
            store=self.store,
            token=TOKEN,
            max_body_bytes=MAX_BYTES,
        )
        self.provenance = dict(PROVENANCE)

    def call(self, name: str, arguments: Any = None) -> dict[str, Any]:
        """Call a tool, requiring a result rather than a refusal."""

        result = self.facade.handle(
            "tools/call", {"name": name, "arguments": {} if arguments is None else arguments}
        )
        self.assertFalse(result["isError"], result)
        return result["structuredContent"]

    def refusal(self, name: str, arguments: Any = None) -> dict[str, Any]:
        """Call a tool, requiring a refusal, and return its error body."""

        result = self.facade.handle(
            "tools/call", {"name": name, "arguments": {} if arguments is None else arguments}
        )
        self.assertTrue(result["isError"], result)
        return result["structuredContent"]["error"]

    def write(self, key: str = "preference-tea", value: str = "green tea") -> dict[str, Any]:
        return self.call(
            "memory.write",
            {"key": key, "value": value, "tags": ["preference"], "provenance": self.provenance},
        )
