# AppleBooksCLI process contract

> Audience：CLI 自动化调用方与维护者。本文只拥有稳定的 **process-level contract**；command-specific 参数/字段由当前命令与 `--help` 拥有，不在这里 snapshot ArgumentParser help。exit status、public error code、stdout/stderr 或 JSON envelope 变化时必须同步本文与 output/CLI contract tests。

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

### Mutation success output

Annotation/collection mutation 的 human stdout 是稳定的最小 result contract：`changed=true` 第一行是 `Mutation committed.`，`changed=false` 第一行是 `No change.`；有 post-commit warning 时追加一行 `warnings: <comma-separated warningCodes>`；annotation result 有 `appleBooksURL` 时，raw URL 必须作为最后一行。human mutation output 不显示 backup handle、local PK、stable ID，也不回显 note/details 正文。

Mutation `--json` 仍只输出一个 JSON value，并保留 `committed`、`changed`、`backupHandle`、`localPK`、`stableID`、`warningCodes`；annotation mutation 可额外包含 optional `appleBooksURL`，nil 时无需强制编码 `null`。mutation `--sync` 只改变这一次 mutation 是否立即等待 current-Mac acknowledgement，不改变 stdout/JSON result shape；批量 pending recovery/flush 使用根 `sync` 命令。

Human operational errors are written to stderr. Machine operational errors are written as exactly one JSON value on stdout:

```json
{"ok":false,"error":{"code":"usage_invalid","message":"..."}}
```

Stable error codes are `usage_invalid`, `not_found`, `unavailable`, `internal`, `write_safety`, and `permission`. Unexpected failures use `internal` with the fixed public message `Internal error.`; private error payloads are not reflected.

## Parse failures and `--json`

A parse failure can happen before `GlobalOptions` exists. For this one case, AppleBooksCLI checks raw argv only for an exact `--json` token before the `--` terminator. It does not recognize prefixes or substrings and does not reimplement option grammar. A matching parse failure uses the machine error envelope and exit `64`; otherwise ArgumentParser's public full error text is written to stderr.

## Help, version, and completion

ArgumentParser clean exits remain its native plain-text protocol on stdout with exit `0`, including help, version, completion, and the `help` command. They are never converted to the operational JSON error envelope merely because raw argv also contains `--json`.

## Local operation history

`history list/get --json` follows the same exactly-one-JSON-value stdout contract as other operational commands. `list` exposes only non-sensitive summary fields; `get` is the explicit full-record read and can return the original argv plus captured stdout/stderr. Completed empty streams remain empty strings, while an incomplete operation has no completed timestamp, exit code, stdout, or stderr.

Human `history get` must escape control characters in stored argv/stdout/stderr instead of replaying raw terminal control bytes. A missing or expired history ID maps to `not_found`; a corrupt, unsafe, or unavailable history store maps to `unavailable`, without reflecting private path/decoding/payload details.

For recordable write/sync commands, failure to persist the started event happens before command dispatch and can block execution with `unavailable`. Failure to persist completion happens after the original command outcome: it may emit a fixed stderr warning, but must not alter the original exit code or machine stdout and therefore must not imply that a committed/applied operation is safe to retry.
