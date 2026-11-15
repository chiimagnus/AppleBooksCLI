---
name: applebookscli
description: Use `applebookscli` to query, read, export, diagnose, recover, sync, or safely modify Apple Books books, reading state, EPUB content, annotations, collections, backups, and operation history
license: AGPL-3.0-only
metadata:
  cli_version: "0.5.0"
  repository: "https://github.com/chiimagnus/AppleBooksCLI"
  language: "en"
---

# AppleBooksCLI

Use this Skill to choose and run `applebookscli` commands. Let the installed CLI's leaf `--help` own exact syntax and finite option values.

**PDF support was removed in v0.5.0. Only v0.4.2 and earlier support PDF.**
Do not invoke `pdf`, `export --pdf`, or `export --source` on the current CLI.

## Calling rules

1. Route the request to the smallest leaf command below. Inspect only that leaf command's `--help` when syntax is uncertain.
2. If the request lacks an exact selector, use the relevant list/search command to obtain one before an exact read/write. Prefer book asset ID, annotation UUID, collection ID, or `backupID`; use a local PK only when explicitly supplied or no stable identity exists. Never reinterpret a numeric-looking stable ID as a PK.
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
| Create EPUB highlights or notes; recover cloud projection | `annotations preview` → `annotations create`; `annotations repair-sync` for an already committed UUID |
| Restore an existing native highlight's creation time | `annotations set-created-at <uuid> --created-at <timezone-bearing RFC3339>` |
| Fix an existing highlight shown on the wrong page | `annotations repair-location <uuid> [--sync]` |
| EPUB metadata/cover/ToC/chapter text | `content metadata`, `content cover`, `content chapters`, `content chapter` |
| Read collections and membership | `collections list`, `collections search`, `collections get`, `collections books` |
| Modify collections and membership | `collections create`, `collections rename`, `collections delete`, `collections add-book`, `collections remove-book` |
| Complete Markdown or archival JSON artifact | `export` |
| Library recovery | `backups list`, `backups restore` |
| Flush pending cloud changes | `sync` |
| Recent write/sync outcome or inverse | `history list`, `history get` |
| Permission/database/capability diagnosis | `doctor` |

`reading position` only succeeds for a real bookmark that maps to the current ToC; pass its `chapterOrder` to `content chapter`.

## Writes, sync, and retry

- Run mutation or restore commands only when the user authorized that change. Never edit Apple Books SQLite directly.
- `annotations update-note` reads the complete replacement Note from stdin. Read the current note first when the user wants to append; use `--clear` only to clear it. `annotations delete` is soft-delete; `annotations restore` only restores the still-existing tombstone.
- To create highlights, prepare a JSON file with an `annotations` array of `{ "text": "…", "chapterOrder": 1, "color": "yellow", "note": "…", "createdAt": "2023-06-02T11:58:15+08:00" }` entries. Optional `createdAt` must include a timezone and is persisted on first creation; duplicate imports never overwrite existing dates. First run `annotations preview --book <asset-id> --input <file>`. Resolve ambiguous/missing/conflicting locations before `annotations create` with the same selectors and file. Do not supply raw CFI. The normal Debug CLI and versioned release can create a book's first native cloud parent. A custom unversioned executable returns `application_version_unavailable` before COMMIT; use a normal build instead. Preview does not check binary metadata.
- If an existing highlight appears on the wrong page, use `annotations repair-location <uuid>`; do not recreate it.
  The selection, note, and creation date stay intact. Verify the result in Books, not only in local/cloud data.
  If the location is already correct but a highlight disappears after EPUB replacement, inspect the reader cache
  before changing annotations (see repository `docs/write-safety.md`).
- `annotations set-created-at` restores the original creation time for an existing native highlight without changing its UUID, selection, or note. Native cloud versioning requires advancing modification time to the restoration instant. Supports `--sync`; repeating an already matching date is a no-op. After a committed cloud projection warning, inspect local and native state before retrying.
- For multi-entry create, `status=partial` or `preflight_failed` may still exit 0: always inspect `complete`, per-item status/UUID, `changedCount` and `syncRequired`. On `cloud_projection_failed`, repair the **existing** UUID using `annotations repair-sync <uuid>` before a separate root `sync`; never recreate it. `--sync` applies only to single-entry create.
- Collection membership writes use named selectors: exactly one of `--collection` / `--collection-pk` and exactly one of `--book` / `--book-pk`.
- Read mutation results as state: `changed=false` is a successful no-op; `committed=true` means the local write crossed COMMIT. A post-commit `warningCodes` entry does not authorize replay.
- Add `--sync` to one mutation only when immediate current-Mac acknowledgement is needed. For a batch, omit intermediate `--sync`; if at least one result has `changed=true`, run root `applebookscli sync` once at the end. Do not root-sync an all-no-op batch. Current-Mac acknowledgement does not prove another device already displays the change.
- If the transport may retry automatically, generate one fresh lowercase UUID per logical mutation/restore/root-sync request and set `APPLEBOOKSCLI_OPERATION_ID=<uuid>`. Reuse that UUID on transport retry. On `operation_replay_blocked`, inspect `history get <uuid>` before any new attempt; an `incomplete` record is outcome-unknown. Reconcile the same create input with read-only `annotations preview` and `annotations get/list` before a new operation ID; never blindly reissue a batch.
- `backups list` is only a newest-10 discovery window. Restore by an opaque `backupID` returned by the CLI or already known to remain valid; a successful restore returns a new `safetyBackupID` that can be used for recovery while its backup still exists.

## Export and failure recovery

- `export` requires `--output`, writes Markdown by default, and uses `--format json` for archival fidelity. Export includes EPUB annotations only. Use `--book` or `--book-pk` for exact book selection; omitted selectors export all eligible EPUB annotations.
- After export, inspect `destination`, `disposition`, `documentCount`, `warningCount`, and `warnings`. Use `--overwrite always` only when the user intends to replace an existing supported export destination.
- Use `doctor` for permission, database, schema, or capability failures—not for a normal empty result. Prefer an error's `recoveryHint` when present.
- Use `history list` / `history get` for recent state-changing outcomes. Execute an indicated inverse only when `inverse.available=true`; never invent an inverse for `incomplete` or unavailable history.
