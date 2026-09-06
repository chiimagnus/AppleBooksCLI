# AppleBooksCLI

English | [简体中文](README.zh.md)

[AppleBooksCLI](https://github.com/chiimagnus/AppleBooksCLI) is a macOS command-line tool for Apple Books. It can query your library, reading state, annotations, local EPUB/PDF content, exports, backups, and a deliberately small set of guarded writes.

## Features

- Browse books, collections, reading state, and library statistics.
- Search highlights and notes, inspect recent annotations, and jump back with Apple Books deep links when available.
- Read locally available EPUB structure/content and extract PDF highlights.
- Export JSON, CSV, Markdown, HTML, Obsidian-oriented output, covers, and complete-note archives.
- Safely update existing annotation notes and manage user collections with automatic safety backups.
- Explicitly acknowledge one mutation with `--sync`, or flush pending cloud changes once after a batch.
- Inspect the last 24 hours of AppleBooksCLI mutation/restore/sync operation history.

## Requirements

- macOS may require Full Disk Access for the terminal or calling process.
- Unmaterialized EPUBs, DRM-protected content, and otherwise unreadable local resources are reported as unavailable; AppleBooksCLI does not bypass system protections.

## Install

```sh
npm install --global @chiimagnus/applebookscli@latest
npx -y skills add "chiimagnus/AppleBooksCLI#v$(applebookscli --version)" --skill applebookscli --global
```

If Agent Skills CLI already manages the AppleBooksCLI Skill, normal npm upgrades attempt to keep it on the same CLI release tag. `--ignore-scripts` disables that optional alignment.

## Help

The installed CLI is the source of truth for commands and arguments:

```sh
applebookscli --help
applebookscli <group> --help
applebookscli <group> <subcommand> --help
```

## Common tasks

```sh
# Library and reading state
applebookscli books list
applebookscli reading in-progress
applebookscli stats

# Recent annotations
applebookscli annotations recent --json

# One annotation and its surrounding EPUB text
applebookscli annotations get <annotation-uuid> --json
applebookscli content context <annotation-uuid> --json

# PDF inventory / extraction
applebookscli pdf list
applebookscli pdf highlights --help
```

Prefer stable identities for exact operations: book asset ID, annotation UUID, collection ID, or backup handle. A local PK (`Z_PK`) is only a row identifier in the current local database and must be selected explicitly.

## Export

```sh
applebookscli export --format markdown --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
applebookscli export --help
```

File outputs use guarded destination/overwrite handling. `--complete-notes` is the strict completeness mode; if it fails, an ordinary export is not an equivalent complete archive.

## Safe writes and iCloud sync

AppleBooksCLI writes only through its guarded mutation/restore rails. Ordinary queries are read-only.

A single mutation can explicitly wait for current-Mac CloudKit acknowledgement:

```sh
applebookscli collections create "My Shelf" --sync --json
```

For several mutations, commit them normally and flush pending changes once at the end:

```sh
applebookscli collections create "Shelf A" --json
applebookscli annotations update-note <annotation-uuid> --note "New note" --json
applebookscli sync --json
```

Current-Mac acknowledgement does not prove another device already displays the change. Post-commit sync/restore warnings must not be treated as permission to replay a mutation. The full safety and lifecycle contract is in [`docs/write-safety.md`](docs/write-safety.md).

## Operation history

```sh
applebookscli history list --json
applebookscli history get <history-id> --json
```

History is private local evidence of recent AppleBooksCLI mutation/restore/sync calls, not an undo engine. `history get` is the explicit full-detail read and can contain original arguments and captured output. See [`docs/cli-contract.md`](docs/cli-contract.md).

## Optional configuration

Most users do not need a configuration file. `~/.config/applebookscli/config.json` is only for the supported supplemental EPUB root and historical metadata mapping.

See [`Config/applebookscli.example.json`](Config/applebookscli.example.json).

## Development and maintenance

Start with [`AGENTS.md`](AGENTS.md), then [`docs/index.md`](docs/index.md) for canonical architecture, capability, process, write-safety, and release owners.

## License

AppleBooksCLI is licensed under the [AGPLv3 LICENSE](LICENSE). Third-party notices and license texts are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`ThirdPartyLicenses/`](ThirdPartyLicenses/).
