"""Typed source facades and portable memory for the two agent deployments.

The modules are transports over the data-plane libraries: ``contracts`` types
and validates the operations, ``sources`` holds one table per deployment,
``memory`` wraps ``FileMemory`` with a derived index, ``server`` speaks MCP over
stdio or Streamable HTTP, and this module parses configuration. Every safety
rule lives in a module below; nothing here adds policy of its own.
"""

from __future__ import annotations

__all__: list[str] = []
