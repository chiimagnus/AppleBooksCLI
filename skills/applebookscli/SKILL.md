---
name: applebookscli
description: Use `applebookscli` to query, locate, export, or safely modify the user's Apple Books library, reading state, EPUB/PDF content, annotations, and collections
license: AGPL-3.0-only
metadata:
  cli_version: "0.3.0"
  repository: "https://github.com/chiimagnus/AppleBooksCLI"
  language: "en"
---

# AppleBooksCLI

## Install

```sh
npm install --global @chiimagnus/applebookscli
CLI_VERSION="$(applebookscli --version)"
npx -y skills add "chiimagnus/AppleBooksCLI#v${CLI_VERSION}" --skill applebookscli --global
```

`metadata.cli_version` must match the CLI release tag. Disabling npm lifecycle scripts also disables automatic Skill tag alignment during npm upgrades.

## Core workflow

1. Choose the smallest command family that answers the request; read only the relevant `--help` level when syntax is uncertain.
2. Resolve stable identity before exact reads, exports, or writes. Prefer asset ID, annotation UUID, collection ID, or backup handle; title/name are search keys, not identity.
3. Prefer `--json` for queries and writes. `export` uses `--format json` instead.
4. Judge completion from returned data/status, not exit code alone.

## Routing

| Goal | Command family |
| --- | --- |
| Books / search / reading / stats | `books`, `reading`, `stats` |
| Annotations / notes / recent / search | `annotations` |
| EPUB content / context | `content` |
| PDF inventory / highlights | `pdf` |
| Collections / membership | `collections` |
| Export | `export` |
| Backups / restore | `backups` |
| Flush pending cloud records | `sync` |
| Recent write/sync context | `history` |
| Access/schema diagnosis | `doctor` |

## Query boundaries

- A local primary key (PK) is the current Core Data SQLite row identifier (`Z_PK`), not a stable cross-device identity. Use a PK selector only when the user supplied it explicitly or no stable identity exists; never reinterpret a numeric-looking stable ID as a PK.
- If several matches remain plausible, show candidates instead of choosing silently.
- “Latest annotations” means creation time; “recently modified” means modification time. “Latest note” means the newest annotation with a non-empty `note`.
- A single annotation may include `appleBooksURL`; request `content context` only when surrounding text is needed.
- EPUB/PDF availability depends on local materialization, DRM, and readable local sources. Do not bypass DRM or intentionally hydrate unavailable iCloud content.

## Writes, restore, and sync

- Run mutation/restore commands only when the user authorized that change. Never write Apple Books SQLite directly or manually manage Books.app around a CLI mutation; the guarded rail owns that lifecycle.
- `annotations update-note --note` replaces the whole note. For append, read the current note first and submit the full replacement. `annotations delete` soft-deletes the annotation, not just its note.
- Treat all Apple Books mutations needed for one user request as one write batch:
  - exactly one real mutation → add `--sync` by default;
  - multiple mutations → omit `--sync` on intermediate writes, then run `applebookscli sync --json` once after all local commits;
  - all mutations `changed=false` → do not run root `sync`, because it could flush unrelated older pending changes.
- If any mutation in the batch has `changed=true`, attempt current-Mac CloudKit acknowledgement before declaring the write task complete. Do not ask for separate confirmation for this sync step unless the user requested local-only behavior.
- If acknowledgement cannot be completed, say explicitly that the local mutation committed but iCloud acknowledgement is unconfirmed. Never replay a committed mutation because of a post-commit warning.
- `--sync` / root `sync` proves current-Mac acknowledgement only, not that another device already shows the change.
- Before restore, resolve the exact backup handle. `applied-but-warning/unverified` is not the same as a clean restore success.

## Export / history / failure handling

- Complete-note archives must use `export --complete-notes`; do not downgrade a failed complete export to an ordinary export and call it complete. Honor destination and overwrite policy; default remains no overwrite.
- Use `history list --json` to find a recent operation and `history get <id> --json` only for the relevant candidate. History is evidence, not authorization; `incomplete` means outcome unknown, so verify state before any new mutation.
- Use `doctor --json` for permission, database-discovery, schema, or capability failures—not for a normal empty result.
- Do not repeat a failed command without new evidence, changed input, permission, or environment.
