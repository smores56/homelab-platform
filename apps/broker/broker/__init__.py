"""Credential-injecting broker for the cluster agent (sdlc #582).

The broker is the only place a logical host's credential exists. It maps an
enrolled logical host to one real endpoint, resolves and pins the address
itself, strips every credential the agent sent, injects exactly one enrolled
credential, never follows a redirect, and logs metadata plus byte counts only.

Credentials are static files from the projected Secret; there is no minting
path. The module depends on the stdlib alone.
"""

from .config import (
    Config,
    ConfigError,
    Enrollment,
    Injection,
    load_config,
    load_secrets,
)
from .credentials import CredentialUnavailable, StaticCredentials
from .policy import Denied, PinnedAddress, address_allowed, check_redirect, resolve_pinned, split_target
from .redact import redact, secret_variants
from .server import Broker, make_handler, make_server

__all__ = [
    "Broker",
    "Config",
    "ConfigError",
    "CredentialUnavailable",
    "Denied",
    "Enrollment",
    "Injection",
    "PinnedAddress",
    "StaticCredentials",
    "address_allowed",
    "check_redirect",
    "load_config",
    "load_secrets",
    "make_handler",
    "make_server",
    "redact",
    "resolve_pinned",
    "secret_variants",
    "split_target",
]
