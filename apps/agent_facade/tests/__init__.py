"""Facade tests: stdlib unittest, no network, no credentials.

Discovery runs with ``-t apps/agent_facade``, which puts this app directory on
``sys.path`` but not the repository root or ``libs/``. The facade imports the
data-plane libraries, so both are added here, the same bootstrap
``tests/data-plane/test_services.py`` performs per module.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
for candidate in (str(ROOT), str(ROOT / "libs")):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)
