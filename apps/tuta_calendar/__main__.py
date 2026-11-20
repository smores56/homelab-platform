"""Entry point: ``python3 -m apps.tuta_calendar {init,dump}``."""

from __future__ import annotations

from .dump import main

if __name__ == "__main__":
    raise SystemExit(main())
