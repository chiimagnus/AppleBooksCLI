---
name: applebookscli
description: Use `applebookscli` to query, locate, export, or safely modify the user's Apple Books library, reading state, EPUB/PDF content, annotations, and collections
license: AGPL-3.0-only
metadata:
  cli_version: "0.3.1"
  repository: "https://github.com/chiimagnus/AppleBooksCLI"
  language: "en"
---

# AppleBooksCLI

Use this Skill to choose and run `applebookscli` commands for Apple Books tasks.

## Use the CLI

1. Choose the smallest command family that answers the request. If syntax is uncertain, read only that command's `--help`.
2. Prefer stable identity for exact operations: book asset ID, annotation UUID, collection ID, or backup handle. Use a local PK only when it was explicitly supplied or no stable identity exists; never reinterpret a numeric-looking stable ID as a PK.
3. Operational commands return JSON by default. Do not add `--json`.
4. When a result returns `nextCursor`, continue the same query with `--cursor <nextCursor>` and pass the token unchanged. Growing book, reading-state, collection, PDF inventory, and `annotations list` queries use this cursor contract (default 20, max 100); do not use `--offset` on those surfaces.
5. If `truncatedFields` is present, those fields are valid but incomplete presentation text. Use archival export when the user explicitly needs the original full text/CFI.

## Command routing

| Goal | Command family |
| --- | --- |
| Books / search | `books` |
| Reading state | `reading`, `stats` |
| Annotations / notes / recent / search | `annotations`; use `annotations list` for bounded composable filters and exact-book reading order |
| EPUB content / annotation context | `content` |
| PDF inventory / highlights | `pdf`; use inventory `bookAssetID` with `--book` or `pdfSourceID` with `--pdf` for exact extraction |
| Collections / membership | `collections` |
| Full JSON / Markdown artifact | `export` |
| Backup / restore | `backups` |
| Flush pending cloud changes | `sync` |
| Recent CLI write/sync evidence | `history` |
| Permission / database / capability diagnosis | `doctor` |

For annotation reads, repeat every selector/filter/order when continuing `annotations list` with its cursor. Reading order requires one exact book selector. `annotations get` may return a book-level `bookURL`, but it never carries the annotation CFI; use `content context` for surrounding EPUB text or archival export when raw CFI/full text is required.

## Writes and sync

- Run mutation or restore commands only when the user authorized that change. Use the CLI mutation commands; do not edit Apple Books SQLite directly.
- `annotations update-note --note` replaces the whole note. Read the current note first when the user wants to append. `annotations delete` soft-deletes the annotation.
- Use `--sync` on a single mutation only when the user wants current-Mac CloudKit acknowledgement; otherwise omit it. For several mutations that need acknowledgement, omit intermediate `--sync` and run root `applebookscli sync` once after the batch only if at least one result has `changed=true`. Do not root-sync an all-no-op batch.
- A committed result with a later warning must not be replayed automatically. Sync acknowledgement only confirms the current Mac, not that another device already shows the change.
- Resolve the exact backup handle before restore.

## Export and failures

- `export` requires an explicit output destination. Full Markdown/archival JSON goes to files; stdout contains the compact command result.
- Use `doctor` for permission, database-discovery, schema, or capability failures. Do not use it for a normal empty result.
- Use `history` to inspect recent CLI writes/syncs when outcome evidence is needed; it is not an undo mechanism. `history list` is cursor-paginated, so pass any returned `nextCursor` unchanged to `history list --cursor <nextCursor>`; use the returned lowercase UUID with `history get` for full detail.
