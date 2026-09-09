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

## Local operation history

`history list` returns JSON summaries; `history get <id>` is the explicit full-record JSON read and may include original argv/stdout/stderr.

History persistence is part of the state-changing CLI boundary: failure to persist `started` blocks dispatch; failure to persist completion happens after the command outcome and must not change its exit status or primary stdout. Completion failure emits one sanitized `history_completion_failed` diagnostic JSONL line on stderr. `incomplete` means outcome unknown, not permission to replay the mutation.

## Edit trigger / evidence

Update this page when exit codes, public error codes, stdout/stderr placement, JSON envelope, mutation presentation, parse/help behavior, or history read/persistence semantics change. Evidence: CLI output/history/contract tests.
