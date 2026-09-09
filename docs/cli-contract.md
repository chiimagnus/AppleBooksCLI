# AppleBooksCLI process contract

> CLI automation 与维护者的稳定 process-level contract。command-specific 参数以 `--help` 为准。

## Exit status

| Status | Meaning |
| ---: | --- |
| `0` | success / clean help-version-completion exit |
| `64` | invalid usage / validation |
| `66` | requested stable identity not found |
| `69` | required capability unavailable/degraded |
| `70` | unexpected internal failure |
| `74` | write/backup/I/O safety failure |
| `77` | permission/path-access failure |

## stdout / stderr / JSON

Operational commands have one public presentation: success writes exactly one JSON value to stdout. There is no public `--json` or `--verbose` mode switch.

Fatal parse/runtime errors write exactly one JSON error envelope to stderr and leave stdout empty:

```json
{"ok":false,"error":{"code":"usage_invalid","reason":null,"message":"Invalid command-line arguments.","recoveryHint":null}}
```

The envelope always contains `code`, `reason`, `message`, and `recoveryHint`; optional fields are encoded as JSON `null`, not omitted. Stable coarse error codes are `usage_invalid`, `not_found`, `unavailable`, `internal`, `write_safety`, and `permission`. Unexpected failures expose only `Internal error.` rather than private payloads. Parse failures are synthetic and must not replay ArgumentParser text, raw argv values, paths, selectors, or search text.

Post-outcome diagnostics that cannot change the primary command result use JSON Lines on stderr. Each diagnostic is one sanitized line shaped as `{"diagnostic":{"severity":"warning","code":"...","message":"..."}}`. A successful command with no transport diagnostic leaves stderr empty.

### Mutation output

Mutation commands use the same JSON-only operational transport. The current result keeps `committed`, `changed`, `backupHandle`, `localPK`, `stableID`, `warningCodes`, plus optional annotation `appleBooksURL`. User note/details bodies are not echoed merely because a mutation succeeded. `--sync` changes acknowledgement behavior, not the transport.

### Export output

`export` requires explicit `--output`. Full Markdown or archival JSON payloads are written only through the guarded file/directory writer and never streamed to stdout. Stdout contains only the compact write result (`destination`, `disposition`, `documentCount`, `warningCount`, `complete`); multi-document results do not enumerate every generated path.

## Parse / help behavior

Any non-clean parse failure uses the sanitized stderr JSON envelope above. Removed `--json` and `--verbose` tokens are invalid options, not compatibility aliases.

Help, version, completion, and `help` remain ArgumentParser plain-text clean exits on stdout with status `0`.

## Cursor continuation

For any record query that returns `nextCursor`, treat that token as opaque. Continue by invoking the **same command** with the same query-defining selectors, filters, and ordering plus `--cursor <nextCursor>`. `--limit` is only the requested page size and may change between pages within `1...100`; cursor-capable record queries default to 20 items per page.

A cursor is a bounded versioned base64url token, at most 4,096 ASCII bytes. It contains only digests plus a bounded numeric continuation locator: raw search text, note bodies, titles, database/config/source paths, and other private text are not embedded. Tokens are bound to command/query semantics and the ordered set of mutable dependencies that affect selection, order, identity, or classification. Reusing a token with a different command/filter/order is invalid; changing a participating database, WAL, config/file, or source inventory makes the token stale. `-shm` metadata is deliberately not a SQLite generation input.

Cursor generation is conservative continuity evidence, not cross-process snapshot isolation. Owners compare the complete dependency generation before and after a page query; a change during the query invalidates the page rather than signing a mixed-generation continuation. On invalid/stale cursor, restart from the first page with the intended query instead of decoding, editing, or guessing token contents.

## Doctor capability status

`doctor` is an explicit broad diagnostic and returns a fixed, bounded capability report. Its canonical `status` is `ready`, `partial`, or `unavailable`: `ready` means every declared ordinary capability prerequisite is ready; `partial` means at least one ordinary capability is usable but not all; `unavailable` means none can be proven usable.

Use `components` for the underlying library/annotations/config/backup/cloud-sync/PDF-worker readiness and `capabilities` for direct command-level prerequisites such as `booksRead`, `annotationsRead`, `collectionsRead`, `collectionsWrite`, `annotationWrite`, `contentReadPrerequisites`, `pdfReadPrerequisites`, `backups`, and `syncPrerequisites`. Write capabilities require both compatible write schema and a usable backup location because every mutation creates a backup before modifying a store. `syncPrerequisites` is separate from write-schema readiness: it is true only when both live client-side CloudKit stores can be located and their pending-state queries succeed; explicit database overrides therefore do not claim live sync readiness. A fatal issue for one store is diagnostic detail and does **not** by itself mean the whole CLI is unavailable. `doctor` never claims that every EPUB/PDF is materialized or DRM-readable; actual content commands remain the authority for per-book availability.

## Local operation history

`history list` returns JSON summaries; `history get <id>` is the explicit full-record JSON read and may include original argv/stdout/stderr.

History persistence is part of the state-changing CLI boundary: failure to persist `started` blocks dispatch; failure to persist completion happens after the command outcome and must not change its exit status or primary stdout. Completion failure emits one sanitized `history_completion_failed` diagnostic JSONL line on stderr. `incomplete` means outcome unknown, not permission to replay the mutation.

## Edit trigger / evidence

Update this page when exit codes, public error codes, stdout/stderr placement, JSON envelope, mutation presentation, parse/help behavior, cursor continuation, or history read/persistence semantics change. Evidence: CLI output/history/cursor/contract tests.
