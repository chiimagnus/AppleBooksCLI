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

Operational `--json` success writes exactly one JSON value to stdout. Human success also uses stdout; progress/verbose diagnostics stay off machine stdout.

Human errors use stderr. Machine errors use one stdout JSON envelope:

```json
{"ok":false,"error":{"code":"usage_invalid","message":"..."}}
```

Stable error codes: `usage_invalid`, `not_found`, `unavailable`, `internal`, `write_safety`, `permission`. Unexpected errors expose only `Internal error.` rather than private payloads.

### Mutation output

Human mutation output is intentionally small:

1. `Mutation committed.` or `No change.`
2. optional `warnings: code1,code2`
3. optional annotation `appleBooksURL` as the final line

It does not print backup handle, local PK, stable ID, note, or details.

Mutation JSON keeps `committed`, `changed`, `backupHandle`, `localPK`, `stableID`, `warningCodes`, plus optional annotation `appleBooksURL`. `--sync` changes acknowledgement behavior, not this result shape.

## Parse / help behavior

Before `GlobalOptions` exists, parse failure treats only an exact `--json` before `--` as a request for the machine error envelope; otherwise ArgumentParser owns the error text.

Help, version, completion, and `help` remain ArgumentParser plain-text clean exits on stdout with status `0`, even when raw argv also contains `--json`.

## Local operation history

`history list --json` returns summaries; `history get <id> --json` is the explicit full-record read and may include original argv/stdout/stderr. Human `history get` escapes control characters instead of replaying terminal control bytes.

History persistence is part of the state-changing CLI boundary: failure to persist `started` blocks dispatch; failure to persist completion happens after the command outcome and must not change its exit status or machine stdout. `incomplete` means outcome unknown, not permission to replay the mutation.

## Edit trigger / evidence

Update this page when exit codes, public error codes, stdout/stderr placement, JSON envelope, mutation presentation, parse/help behavior, or history read/persistence semantics change. Evidence: CLI output/history/contract tests.
