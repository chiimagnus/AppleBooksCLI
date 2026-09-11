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

The envelope always contains `code`, `reason`, `message`, and `recoveryHint`; optional fields are encoded as JSON `null`, not omitted. Stable coarse error codes are `usage_invalid`, `not_found`, `unavailable`, `internal`, `write_safety`, and `permission`. When a caller can branch or recover more precisely, `reason` is a stable machine token and `recoveryHint` is a concise sanitized next action; when no reliable recovery exists, the hint remains `null`. Current public reasons are `ambiguous_identity`, `annotation_not_found`, `annotation_restore_unavailable`, `backup_not_found`, `book_not_found`, `chapter_not_found`, `collection_not_found`, `configuration_invalid`, `content_unavailable`, `context_unavailable`, `cursor_stale`, `database_unavailable`, `history_entry_not_found`, `history_unavailable`, `operation_id_conflict`, `operation_id_invalid`, `operation_replay_blocked`, `output_exists`, `pdf_source_not_found`, `pdf_worker_unavailable`, `reading_order_requires_book`, `reading_position_unavailable`, `schema_unavailable`, `selector_not_found`, `sync_ack_failed`, `sync_unavailable`, and `unsafe_output`. Unexpected failures expose only `Internal error.` rather than private payloads. Parse failures are synthetic and must not replay ArgumentParser text, raw argv values, paths, selectors, or search text.

Post-outcome diagnostics that cannot change the primary command result use JSON Lines on stderr. Each diagnostic is one sanitized line shaped as `{"diagnostic":{"severity":"warning","code":"...","message":"..."}}`. A successful command with no transport diagnostic leaves stderr empty.

Ordinary read DTOs may include `truncatedFields`. Each entry names a field whose published presentation was shortened by a Core byte budget or CLI grapheme budget; the shortened value is valid UTF-8 and ends on a complete Swift `Character`. Absence of `truncatedFields` is not an archival-fidelity guarantee—raw/full-fidelity reads belong to explicit export/Core compatibility surfaces.

### Mutation output

Mutation commands use the same JSON-only operational transport. Common outcome fields are `committed`, `changed`, explicit `acknowledgementRequested`, explicit nullable `acknowledged`, and `warningCodes`; generic `stableID` / `localPK` and annotation `appleBooksURL` are not mutation-result fields. Successful-result `warningCodes` are business outcome warnings, separate from fatal transport `reason`; for example, a committed mutation may report `cloud_sync_failed`, while a failed root sync acknowledgement uses `reason=sync_ack_failed`. Annotation mutations return `annotationUUID` or, only when no public UUID is available, `annotationLocalPK`; their internal safety backup is never public. Collection mutations return `collectionID` or fallback `collectionLocalPK`, while membership mutations additionally return `bookAssetID` or fallback `bookLocalPK`; library-backed collection/membership mutations may return an opaque `backupID`. Deterministic quiet-state no-op returns `committed=false`, `changed=false`, no `backupID`; `acknowledgementRequested` still records whether the caller asked for `--sync`, while `acknowledged` is `null` unless a real committed mutation actually ran acknowledgement. Backup/restore command JSON likewise uses `backupID`/`safetyBackupID`; raw backup filenames and paths are not public recovery identities. User note/details bodies are not echoed merely because a mutation succeeded. `--sync` changes acknowledgement behavior, not the transport.

### Export output

`export` requires explicit `--output` and defaults to Markdown; `--format json` requests archival JSON. In archival JSON, non-finite Book raw numerics are encoded as `null`; `numericAnomalies` distinguishes ±Infinity from an original null. Relative paths resolve against cwd, and results use the canonical absolute destination. Grouping determines the publish unit: `single` is one file, while `per-document` is one AppleBooksCLI-managed directory transaction. Per-document filenames are `<bounded-display-stem>-<full-document-key>.<ext>` and remain stable across selector/input order. Root, `.`/`..`, and internal hidden names are invalid destinations. `overwrite=never` rejects any existing target with `code=write_safety`, `reason=output_exists`. For `per-document`, `overwrite=always` is accepted only when the existing directory has a valid managed-export ownership manifest and contains exactly the declared regular files plus that manifest; missing/malformed ownership evidence, extra files, subdirectories, symlinks, or destination identity races use `reason=unsafe_output`. The replacement directory is atomically swapped as a complete tree. Failure before publication leaves the previous tree unchanged; old-tree cleanup failure after a successful swap keeps the new tree and adds the bounded warning `old_export_cleanup_failed`. The same descriptor-relative single-file writer-error mapping applies to content-cover writes.

Full Markdown or archival JSON payloads are written only through the guarded file/directory writer and never streamed to stdout. Stdout contains only the compact write result (`destination`, `disposition`, `documentCount`, `warningCount`, `complete`, `warnings`); multi-document results do not enumerate every generated path. The canonical CLI uses count-only writer methods, which do not accumulate destination URLs; the public Core file-list methods remain explicit compatibility APIs.

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

`history list` returns bounded JSON summary pages (default 20, maximum 100) with opaque `nextCursor` continuation; summaries contain operation/outcome metadata only. Pass a returned cursor unchanged to `history list --cursor <nextCursor>`. `history get <id>` returns the structured `request`, `result`, and `inverse` for that record; IDs are exact lowercase UUIDs. New history records do not persist raw argv or captured stdout/stderr. An available inverse may contain the exact prior Note or collection title needed to reverse the committed mutation; unrelated database/config/private filesystem paths are not recovery data.

For a state-changing command sent through a transport that may retry, the caller may set `APPLEBOOKSCLI_OPERATION_ID` to a fresh lowercase UUID for that logical request. The UUID becomes the history ID and is claimed atomically before dispatch. Reusing the same UUID for the same request returns `operation_replay_blocked` without dispatching again; reusing it for a different request returns `operation_id_conflict`; malformed values return `operation_id_invalid`. A replay-blocked `incomplete` record remains outcome-unknown and must be inspected with `history get <operation-id>` before any new attempt.

History persistence is part of the state-changing CLI boundary: failure to persist `started` blocks dispatch. After a mutation commits, its structured completion evidence is captured before presentation, so a later JSON/output failure can still leave `result.committed=true` and an available inverse even though the command exit status is failure. Failure to persist completion must not change the already-determined command outcome and emits one sanitized `history_completion_failed` diagnostic JSONL line on stderr.

`inverse.available=true` means history has enough transaction-authentic evidence and stable public identity to describe a safe inverse operation; callers may execute the returned operation/selector/payload through the ordinary guarded command. `inverse.available=false` must not be filled in by guessing from local PKs or request text. A PK-only annotation can still be restored explicitly with `annotations restore --pk <pk>` when the caller already knows that current-row identity, but history does not advertise it as automatic undo. `incomplete` means outcome unknown and never authorizes replay. Operation history accepts only the current schema; unsupported history schemas fail closed.

## Edit trigger / evidence

Update this page when exit codes, public error codes, stdout/stderr placement, JSON envelope/common truncation evidence, mutation presentation, parse/help behavior, cursor continuation, doctor capability presentation, or history read/persistence semantics change. Evidence: CLI output/history/cursor/doctor/contract tests.
