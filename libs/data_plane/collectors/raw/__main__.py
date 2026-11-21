"""``python -m data_plane.collectors.raw``: the three collector units' entry point.

Every collector unit in ``units/systemd/`` names the package rather than
``.cli``: ``data_plane.collectors.raw.cli`` carries its own ``__main__`` guard,
but ``-m`` on a package looks for ``__main__.py`` inside it and fails without
one. This shim is that file, and it keeps the single copy of the CLI that the
package has already imported.
"""

import sys

from .cli import main

if __name__ == "__main__":
    raise SystemExit(main())
