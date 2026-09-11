---
name: applebookscli
description: Use `applebookscli` to query, read, export, diagnose, recover, sync, or safely modify Apple Books books, reading state, EPUB/PDF content, annotations, collections, backups, and operation history
license: AGPL-3.0-only
metadata:
  cli_version: "0.3.1"
  repository: "https://github.com/chiimagnus/AppleBooksCLI"
  language: "en"
---

# AppleBooksCLI

Use this Skill to choose and run `applebookscli` commands. Let the installed CLI's leaf `--help` own exact syntax and finite option values.

## Calling rules

1. Route the request to the smallest leaf command below. Inspect only that leaf command's `--help` when syntax is uncertain.
2. If the request lacks an exact selector, use the relevant list/search command to obtain one before an exact read/write. Prefer book asset ID, annotation UUID, collection ID, opaque `pdfSourceID`, or `backupID`; use a local PK only when explicitly supplied or no stable identity exists. Never reinterpret a numeric-looking stable ID as a PK.
3. Operational commands already return JSON. On failure, branch on `error.code`, `error.reason`, and `error.recoveryHint`; treat `message` as presentation text. Do not add `--json` or parse help text as data.
4. Bounded queries are not implicit full scans. If more results are actually needed, repeat the same selectors/filters/order with `--cursor <nextCursor>` and pass the token unchanged. Stop when the user's request is satisfied; use `export` when the goal is a complete artifact.
5. `truncatedFields` means ordinary presentation text is incomplete. Use archival JSON export when original full annotation/CFI fidelity is required.

## Intent routing

| Goal | Command |
| --- | --- |
| Find/list books; inspect one book | `books list`, `books search`, `books get` |
| Reading queues; library statistics | `reading in-progress`, `reading finished`, `reading unstarted`, `reading recent`, `stats` |
| Current bookmarked chapter text | `reading position` → `content chapter` |
| Query/detail/context for annotations | `annotations list`, `annotations get`, `annotations context` |
| Set/clear/delete/restore an annotation | `annotations update-note`, `annotations delete`, `annotations restore` |
| EPUB metadata/cover/ToC/chapter text | `content metadata`, `content cover`, `content chapters`, `content chapter` |
| PDF discovery and highlights | `pdf list` → `pdf highlights` |
| Read collections and membership | `collections list`, `collections search`, `collections get`, `collections books` |
| Modify collections and membership | `collections create`, `collections rename`, `collections delete`, `collections add-book`, `collections remove-book` |
| Complete Markdown or archival JSON artifact | `export` |
| Library recovery | `backups list`, `backups restore` |
| Flush pending cloud changes | `sync` |
| Recent write/sync outcome or inverse | `history list`, `history get` |
| Permission/database/capability diagnosis | `doctor` |

For PDF reads, use the `bookAssetID` or `pdfSourceID` returned by `pdf list`; never substitute an absolute PDF path. `reading position` only succeeds for a real bookmark that maps to the current ToC; pass its `chapterOrder` to `content chapter`.

## Writes, sync, and retry

- Run mutation or restore commands only when the user authorized that change. Never edit Apple Books SQLite directly.
- `annotations update-note` reads the complete replacement Note from stdin. Read the current note first when the user wants to append; use `--clear` only to clear it. `annotations delete` is soft-delete; `annotations restore` only restores the still-existing tombstone.
- Collection membership writes use named selectors: exactly one of `--collection` / `--collection-pk` and exactly one of `--book` / `--book-pk`.
- Read mutation results as state: `changed=false` is a successful no-op; `committed=true` means the local write crossed COMMIT. A post-commit `warningCodes` entry does not authorize replay.
- Add `--sync` to one mutation only when immediate current-Mac acknowledgement is needed. For a batch, omit intermediate `--sync`; if at least one result has `changed=true`, run root `applebookscli sync` once at the end. Do not root-sync an all-no-op batch. Current-Mac acknowledgement does not prove another device already displays the change.
- If the transport may retry automatically, generate one fresh lowercase UUID per logical mutation/restore/root-sync request and set `APPLEBOOKSCLI_OPERATION_ID=<uuid>`. Reuse that UUID on transport retry. On `operation_replay_blocked`, inspect `history get <uuid>` before any new attempt; an `incomplete` record is outcome-unknown and must not be retried under a new UUID.
- `backups list` is only a newest-10 discovery window. Restore by an opaque `backupID` returned by the CLI or already known to remain valid; a successful restore returns a new `safetyBackupID` that can be used for recovery while its backup still exists.

## Export and failure recovery

- `export` requires `--output`, writes Markdown by default, and uses `--format json` for archival fidelity. Exact `--book`, `--book-pk`, and `--pdf` selectors route media automatically; without exact selectors, `--source epub|pdf|all` controls bulk scope.
- Before treating a bulk export as complete, inspect `complete`, `warningCount`, `warnings`, and `warningsTruncated`. Use `--overwrite always` only when the user intends to replace an existing supported export destination.
- Use `doctor` for permission, database, schema, worker, or capability failures—not for a normal empty result. Prefer an error's `recoveryHint` when present.
- Use `history list` / `history get` for recent state-changing outcomes. Execute an indicated inverse only when `inverse.available=true`; never invent an inverse for `incomplete` or unavailable history.
