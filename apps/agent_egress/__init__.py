"""Collector egress: the allowlist forward proxy and its DNS responder.

Two processes, one image, one policy document. The proxy is the only thing a
collector container may reach off the host, and it accepts only the hostnames and
ports its source label holds; the resolver answers only those names and refuses
everything else. nftables is the first gate -- it decides which container may
reach a listener at all -- and these allowlists are the second.

Ported from smores56/nix-config's ingest plane (`modules/lib/ingest/policy.py`,
`proxy.py`, `resolver.py`) and adapted to a podman bridge network: per-tap host
addresses, guest addresses and NixOS paths have no equivalent here, so the source
label arrives as `--source` on the listener instead.
"""

from .policy import Policy, PolicyError

__all__ = ["Policy", "PolicyError"]
