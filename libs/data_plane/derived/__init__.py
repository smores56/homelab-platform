"""Derived projections over a published raw replica.

A projection is a pure function of one generation: nothing here reads a clock, a
network or a second store, so it can be rebuilt at any time and the generation
stays the only authority for what a provider said.

``hledger`` renders the finance replica as one hledger journal, which is what
makes a ledger a view of the transactions instead of another place they are
written down: ``python3 -m data_plane.derived.hledger``. The package body stays
empty on purpose -- importing the module here would import it a second time under
``-m``, and the unit would print that warning on every run.
"""

__all__: list[str] = []
