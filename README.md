# AppleBooksCLI

English | [简体中文](README.zh.md)

[AppleBooksCLI](https://github.com/chiimagnus/AppleBooksCLI) is a macOS CLI for reading and safely managing Apple Books data: library records, reading state, annotations, EPUB/PDF content, exports, notes, and collections.

## Install

```sh
npm install --global @chiimagnus/applebookscli@latest
npx -y skills@1.5.23 add "chiimagnus/AppleBooksCLI#v$(applebookscli --version)" --skill applebookscli --global
```

The npm install provides the CLI. The second command installs the matching Agent Skill. npm upgrades keep an Agent Skills CLI-managed Skill on the same CLI release tag unless lifecycle scripts are disabled.

## Requirements

- macOS. Reading Apple Books data may require Full Disk Access for the calling terminal or process.
- AppleBooksCLI does not bypass DRM or intentionally hydrate unavailable iCloud content.

## Start here

```sh
applebookscli books list
applebookscli reading in-progress
applebookscli annotations recent
applebookscli stats
```

Use `--json` for structured command results where supported:

```sh
applebookscli books list --json
applebookscli annotations recent --json
```

The installed CLI is the source of truth for commands and arguments:

```sh
applebookscli --help
applebookscli <group> --help
applebookscli <group> <subcommand> --help
```

## Common tasks

| Goal | Command family |
| --- | --- |
| Browse/search books and reading state | `books`, `reading`, `stats` |
| Read/search annotations and notes | `annotations` |
| Read EPUB content or annotation context | `content` |
| Inspect PDFs and PDF highlights | `pdf` |
| Export JSON/CSV/Markdown/HTML | `export` |
| Manage collections | `collections` |
| Inspect/restore guarded backups | `backups` |
| Inspect recent write/sync history | `history` |
| Diagnose access or schema readiness | `doctor` |

A single annotation result may include `appleBooksURL`, which can reopen the corresponding book or highlight location in Apple Books.

For the complete current capability boundary, see [`docs/capability-matrix.md`](docs/capability-matrix.md).

## Writes and iCloud sync

Writes use the guarded mutation rail: preflight, Books lifecycle handling, safety backup, transaction, read-back, and cloud projection. Ordinary reads never enter that rail.

For one change that should be acknowledged immediately by iCloud, add `--sync`:

```sh
applebookscli annotations update-note <annotation-uuid> --note "New note" --sync --json
```

For several changes, avoid reopening/syncing Books after each mutation. Commit the batch first, then flush pending changes once:

```sh
applebookscli collections create "Shelf A" --json
applebookscli annotations update-note <annotation-uuid> --note "New note" --json
applebookscli sync --json
```

A successful `--sync` or root `sync` confirms acknowledgement on the **current Mac** only; it does not prove another device has already rendered the change. A post-commit warning must not trigger an automatic replay of the mutation.

Detailed write, restore, lifecycle, and CloudKit invariants live in [`docs/write-safety.md`](docs/write-safety.md).

## Export and local content

```sh
applebookscli export --format markdown --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
```

Use `applebookscli export --help`, `content --help`, and `pdf --help` for current options. EPUB/PDF availability depends on local materialization, DRM, and readable local sources.

## Configuration

Most users do not need a configuration file. `~/.config/applebookscli/config.json` is only for optional supplemental EPUB lookup or historical annotation metadata. See [`Config/applebookscli.example.json`](Config/applebookscli.example.json).

## Maintainers

Start with [`docs/index.md`](docs/index.md). It identifies the canonical owner for architecture, capabilities, process contracts, write safety, schema baselines, and release behavior.

## License

AppleBooksCLI is licensed under the [AGPLv3 LICENSE](LICENSE). Third-party notices are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
