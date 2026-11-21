"""Brave: the provider half of the browsing-history collector.

Brave has no CLI to join a Sync chain, so the headless profile this deployment
runs is seeded rather than joined: ``seed`` plants the OSCrypt blob the desktop's
own join wrote into ``Preferences`` before the browser starts, and ``snapshot``
takes the one quiesced copy of ``History`` that the raw collector reads.

``docs/raw-replicas.md`` ("Brave") describes the shape of what lands and
``docs/manual-steps.md`` section 40.17 is the operator's half: exporting the seed,
encrypting it, and proving it planted.
"""

__all__ = ["seed", "snapshot"]
