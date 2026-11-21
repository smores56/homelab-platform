"""``python -m data_plane.collectors.stream``: the mail collector's entry point.

Running the submodule directly (``-m data_plane.collectors.stream.imap``) makes
``runpy`` execute the file a second time under ``__main__``: the package has
already imported it, so the process ends up with two copies of every class in
it and a ``RuntimeWarning`` that says so. This shim keeps one copy, which is
what the unit names.
"""

import sys

from .imap import main

if __name__ == "__main__":
    sys.exit(main())
