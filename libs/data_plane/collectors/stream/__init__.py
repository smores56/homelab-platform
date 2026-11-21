"""Push-based collectors: a provider event becomes a published generation.

Mail is the one source that pushes. The bridge presents the mailbox as IMAP and
tells an IDLE-ing session about ``EXISTS``/``EXPUNGE``; this package turns those
events into whole generations, so a reader never sees a half-applied change.
"""

from .imap import (
    FolderReport,
    IdleLine,
    ImapMailbox,
    Mailbox,
    StreamCollector,
    backoff_delay,
    collect_folder,
    collect_mailbox,
    message_headers,
    normalize_flags,
    parse_idle_line,
    pinned_tls_context,
    uid_diff,
    validate_folder,
)

__all__ = [
    "FolderReport",
    "IdleLine",
    "ImapMailbox",
    "Mailbox",
    "StreamCollector",
    "backoff_delay",
    "collect_folder",
    "collect_mailbox",
    "message_headers",
    "normalize_flags",
    "parse_idle_line",
    "pinned_tls_context",
    "uid_diff",
    "validate_folder",
]
