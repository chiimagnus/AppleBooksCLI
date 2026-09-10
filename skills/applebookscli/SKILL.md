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
2. Prefer stable identity for exact operations: book asset ID, annotation UUID, collection ID, or opaque `backupID`. Use a local PK only when it was explicitly supplied or no stable identity exists; never reinterpret a numeric-looking stable ID as a PK.
3. Operational commands return JSON by default. Do not add `--json`.
4. When a result returns `nextCursor`, continue the same query with `--cursor <nextCursor>` and pass the token unchanged. Growing book, reading-state, collection, PDF inventory/highlight, `annotations list`, and `content chapters` queries use this cursor contract (default 20, max 100); `content chapters` returns only `chapterOrder`, bounded title, and depth. Feed `chapterOrder` to `content chapter --book|--book-pk --chapter <order>`, whose text continuation is also opaque and never uses `--offset`.
5. If `truncatedFields` is present, those fields are valid but incomplete presentation text. Use archival export when the user explicitly needs the original full text/CFI.

## Command routing

| Goal | Command family |
| --- | --- |
| Books / search | `books` |
| Reading state | `reading`, `stats` |
| Annotations / notes / recent / search / context | Use `annotations list` for queries/search/recent filters, `annotations get` for exact detail, `annotations context` for bounded surrounding text, and mutation subcommands only for writes |
| EPUB content | `content` |
| PDF inventory / highlights | `pdf`; use inventory `bookAssetID` with `--book` or `pdfSourceID` with `--pdf`; highlights are paged summaries, so pass `nextCursor` unchanged and use archival export for raw geometry/full text |
| Collections / membership | `collections` |
| Full JSON / Markdown artifact | `export` |
| Backup / restore | `backups` |
| Flush pending cloud changes | `sync` |
| Recent CLI write/sync evidence | `history` |
| Permission / database / capability diagnosis | `doctor` |

For annotation reads, repeat every selector/filter/order when continuing `annotations list` with its cursor. Reading order requires one exact book selector. `annotations get` may return a book-level `bookURL`, but it never carries the annotation CFI; use `annotations context <uuid>` (or explicit `--pk`) for bounded surrounding EPUB text, or archival export when raw CFI/full text is required. `reading position <asset-id>` (or explicit `--pk`) reports only a real type-3 bookmark that maps to the current ToC; it never guesses from a recent annotation, and its `chapterOrder` can be passed directly to `content chapter --chapter`. `content metadata` returns one bounded resolved metadata view. `content cover --output <path>` writes the image; `<path>` may be relative to the current directory, and JSON returns the canonical destination.

## Writes and sync

- Run mutation or restore commands only when the user authorized that change. Use the CLI mutation commands; do not edit Apple Books SQLite directly.
- `annotations update-note --note` replaces the whole note. Read the current note first when the user wants to append. `annotations delete` soft-deletes the annotation.
- Collection membership mutations use named selectors only: choose exactly one of `--collection` / `--collection-pk` and exactly one of `--book` / `--book-pk`; never pass collection/book identities as positional arguments.
- Use `--sync` on a single mutation only when the user wants current-Mac CloudKit acknowledgement; otherwise omit it. For several mutations that need acknowledgement, omit intermediate `--sync` and run root `applebookscli sync` once after the batch only if at least one result has `changed=true`. Do not root-sync an all-no-op batch.
- A committed result with a later warning must not be replayed automatically. Sync acknowledgement only confirms the current Mac, not that another device already shows the change.
- `backups list` is a fixed recovery catalog of the newest 10 valid library backups; do not paginate it or treat it as complete backup history. Feed the exact opaque `backupID` returned by the list or a previously saved valid `backupID` to `backups restore`; do not use backup filenames or paths as selectors.

## Export and failures

- `export --output <path>` writes Markdown by default; request `--format json` for archival JSON. Paths may be relative or absolute. Grouping alone chooses a file (`single`) or directory (`per-document`), never the extension. Per-document filenames are stable for the same source identity and do not depend on encounter order. Stdout returns the canonical destination and document count, not every generated path. `output_exists` means the default never-overwrite policy refused an existing target; `unsafe_output` means the path or node type cannot be used.
- Export an exact book with `--book <assetID>` (or explicit `--book-pk`), or a non-Book-identified PDF with `--pdf <pdfSourceID>` from `pdf list`; selectors are repeatable and media routing is automatic. Missing/ambiguous selectors fail, while a valid empty book is allowed. With no selectors, bulk export covers EPUB+PDF; only bulk accepts `--source epub|pdf|all`. Check `complete` and `warnings` before treating a bulk artifact as complete; exact PDF read failure writes no artifact.
- Export records use reading order within each document by default; no order flag is needed.
- Filter export with `--has-highlight true|false`, `--has-note true|false`, and `--underline true|false`; omitted properties are unrestricted, combined properties use AND. Highlight and Note can overlap. `--color` matches canonical EPUB colors, never approximate PDF colors. PDF highlights count as highlights even without extracted text.
- Use `doctor` for permission, database-discovery, schema, or capability failures. Do not use it for a normal empty result.
- Use `history` to inspect recent CLI writes/syncs when outcome evidence is needed; it is not an undo mechanism. `history list` is cursor-paginated, so pass any returned `nextCursor` unchanged to `history list --cursor <nextCursor>`; use the returned lowercase UUID with `history get` for full detail.
