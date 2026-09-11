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

Use this Skill to choose and run `applebookscli` commands. Let the installed CLI's `--help` own exact syntax and finite option values.

## Calling rules

1. Choose the smallest command family that answers the request; inspect only that command's `--help` when syntax is uncertain.
2. Prefer stable identities for exact operations: book asset ID, annotation UUID, collection ID, opaque `pdfSourceID`, or `backupID`. Use a local PK only when explicitly supplied or no stable identity exists; never reinterpret a numeric-looking stable ID as a PK.
3. Operational commands already return JSON. Do not add `--json` or parse help text as data.
4. When a result contains `nextCursor`, repeat the same query selectors/filters/order with `--cursor <nextCursor>` and pass the token unchanged. Do not decode or edit cursors.
5. `truncatedFields` means ordinary presentation text is incomplete. Use archival JSON export when the user needs original full text/CFI fidelity.

## Command routing

| Goal | Command |
| --- | --- |
| Books / search | `books` |
| Reading state / stats / bookmarked chapter | `reading`, `stats` |
| Annotation query / exact detail / surrounding text | `annotations list`, `annotations get`, `annotations context` |
| EPUB metadata / cover / ToC / chapter text | `content` |
| PDF inventory / paged highlights | `pdf` |
| Collections / membership | `collections` |
| Full Markdown or archival JSON artifact | `export` |
| Library backup / restore | `backups` |
| Pending cloud acknowledgement | `sync` |
| Recent write/sync evidence | `history` |
| Permission / database / capability diagnosis | `doctor` |

Use the `bookAssetID` or `pdfSourceID` returned by `pdf list` for later PDF reads; never substitute an absolute PDF path. `reading position` reports only a real bookmark that maps to the current ToC; if it returns a `chapterOrder`, pass that order to `content chapter`.

## Writes, sync, and retry

- Run mutation or restore commands only when the user authorized that change. Never edit Apple Books SQLite directly.
- `annotations update-note` reads the complete replacement Note from stdin. Read the current note first when the user wants to append; use `--clear` only for clearing the note. `annotations delete` is soft-delete; `annotations restore` only restores the still-existing tombstone.
- Collection membership writes use named selectors: exactly one of `--collection` / `--collection-pk` and exactly one of `--book` / `--book-pk`.
- Add `--sync` to a single mutation only when immediate current-Mac acknowledgement is needed. For a batch, omit intermediate `--sync`; if at least one result has `changed=true`, run root `applebookscli sync` once at the end. Do not root-sync an all-no-op batch.
- If the transport may retry automatically, generate one fresh lowercase UUID per logical mutation/restore/root-sync request and set `APPLEBOOKSCLI_OPERATION_ID=<uuid>`. Reuse that UUID on transport retry. On `operation_replay_blocked`, inspect `history get <uuid>` before any new attempt; an `incomplete` record is outcome-unknown and must not be retried under a new UUID.
- A post-commit warning does not authorize replay. Current-Mac acknowledgement does not prove another device already displays the change.
- `backups list` is a fixed newest-10 recovery catalog, not paginated history. Restore only by an opaque `backupID` returned by the CLI or already known to be valid.

## Export and failures

- `export` requires `--output`, writes Markdown by default, and uses `--format json` for archival fidelity. Exact `--book`, `--book-pk`, and `--pdf` selectors route media automatically; without exact selectors, `--source epub|pdf|all` controls bulk scope.
- Check `complete` and `warnings` before treating a bulk export as complete. Use `--overwrite always` only when the user intends to replace an existing supported export destination.
- Use `doctor` for permission, database, schema, worker, or capability failures—not for a normal empty result.
- Use `history list` / `history get` to inspect recent write outcomes. Execute an indicated inverse only when `inverse.available=true`; never invent an inverse for `incomplete` or unavailable history.
