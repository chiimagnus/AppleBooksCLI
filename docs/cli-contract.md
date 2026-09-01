# AppleBooksCLI process contract

This document records the stable process-level contract. Command-specific fields are documented with their owning commands instead of snapshotting ArgumentParser help text.

## Exit status

| Status | Meaning |
| ---: | --- |
| `0` | Success, including help/version/completion clean exits |
| `64` | Invalid CLI usage or command validation |
| `66` | Requested stable identity was not found |
| `69` | Required capability is unavailable or degraded |
| `70` | Unexpected internal failure |
| `74` | Write-safety, backup, or I/O safety failure |
| `77` | Permission or path-access failure |

Commands throw typed `CLIError` or ArgumentParser `ValidationError`; command implementations do not hardcode numeric process statuses.

## Standard output and standard error

Operational `--json` success writes exactly one compact Codable JSON value to stdout. Human-readable success output is also stdout. Warnings, progress, verbose diagnostics, and other non-result information must not be mixed into machine stdout; they belong on stderr or in an explicitly documented JSON result field.

Human operational errors are written to stderr. Machine operational errors are written as exactly one JSON value on stdout:

```json
{"ok":false,"error":{"code":"usage_invalid","message":"..."}}
```

Stable error codes are `usage_invalid`, `not_found`, `unavailable`, `internal`, `write_safety`, and `permission`. Unexpected failures use `internal` with the fixed public message `Internal error.`; private error payloads are not reflected.

## Parse failures and `--json`

A parse failure can happen before `GlobalOptions` exists. For this one case, AppleBooksCLI checks raw argv only for an exact `--json` token before the `--` terminator. It does not recognize prefixes or substrings and does not reimplement option grammar. A matching parse failure uses the machine error envelope and exit `64`; otherwise ArgumentParser's public full error text is written to stderr.

## Help, version, and completion

ArgumentParser clean exits remain its native plain-text protocol on stdout with exit `0`, including help, version, completion, and the `help` command. They are never converted to the operational JSON error envelope merely because raw argv also contains `--json`.
