# AppleBooksCLI

English | [简体中文](README.zh.md)

[AppleBooksCLI](https://github.com/chiimagnus/AppleBooksCLI) is a macOS command-line tool for Apple Books. It can query your library, reading state, annotations, local EPUB/PDF content, exports, backups, and a deliberately small set of guarded writes.

## Features

- Browse books, collections, reading state, and library statistics.
- Search highlights and notes, inspect recent annotations, and jump back with Apple Books deep links when available.
- Read locally available EPUB structure/content and extract PDF highlights.
- Export JSON and Markdown.
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
applebookscli books search "history" --field all
applebookscli books search "Fiction" --field genre
applebookscli reading in-progress
applebookscli stats

# Recent annotations
applebookscli annotations recent

# One annotation and its surrounding EPUB text
applebookscli annotations get <annotation-uuid>
applebookscli content context <annotation-uuid>

# PDF inventory / extraction
applebookscli pdf list
applebookscli pdf highlights --help
```

Prefer stable identities for exact operations: book asset ID, annotation UUID, collection ID, or backup handle. A local PK (`Z_PK`) is only a row identifier in the current local database and must be selected explicitly. `stats` separates historical, unmapped, ambiguous-current, and identity-unavailable annotation counts; `topAnnotatedBooks` contains only a consumable book identity plus `annotationCount`.

## Export

```sh
applebookscli export --format markdown --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
applebookscli export --help
```

Export artifacts are written only to the explicit output file/directory. Stdout returns a compact JSON write result; all operational commands otherwise return JSON directly on stdout.

## Safe writes and iCloud sync

AppleBooksCLI writes only through its guarded mutation/restore rails. Ordinary queries are read-only.

A single mutation can explicitly wait for current-Mac CloudKit acknowledgement:

```sh
applebookscli collections create "My Shelf" --sync
```

For several mutations, commit them normally and flush pending changes once at the end:

```sh
applebookscli collections create "Shelf A"
applebookscli annotations update-note <annotation-uuid> --note "New note"
applebookscli sync
```

Current-Mac acknowledgement does not prove another device already displays the change. Post-commit sync/restore warnings must not be treated as permission to replay a mutation. The full safety and lifecycle contract is in [`docs/write-safety.md`](docs/write-safety.md).

## Operation history

```sh
applebookscli history list
applebookscli history get <history-id>
```

History is private local evidence of recent AppleBooksCLI mutation/restore/sync calls, not an undo engine. `history get` is the explicit full-detail read and can contain original arguments and captured output. See [`docs/cli-contract.md`](docs/cli-contract.md).

## Optional configuration

Most users do not need a configuration file. `~/.config/applebookscli/config.json` is only for the supported supplemental EPUB root and historical metadata mapping.

See [`Config/applebookscli.example.json`](Config/applebookscli.example.json).

## Development and maintenance

Start with [`AGENTS.md`](AGENTS.md), then [`docs/index.md`](docs/index.md) for canonical architecture, capability, process, write-safety, and release owners.

## Acknowledgements

AppleBooksCLI benefited from prior art and ideas in the following open-source projects. Thanks to their authors and contributors:

- [57uff3r/ibooks_notes_exporter](https://github.com/57uff3r/ibooks_notes_exporter)
- [denya/apple-books-export](https://github.com/denya/apple-books-export)
- [eristoddle/apple-books-annotation-import](https://github.com/eristoddle/apple-books-annotation-import)
- [ragmha/apple-books-mcp](https://github.com/ragmha/apple-books-mcp)
- [vgnshiyer/apple-books-mcp](https://github.com/vgnshiyer/apple-books-mcp)
- [vgnshiyer/py-apple-books](https://github.com/vgnshiyer/py-apple-books)

## License

AppleBooksCLI is licensed under the [AGPLv3 LICENSE](LICENSE). Third-party notices and license texts are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`ThirdPartyLicenses/`](ThirdPartyLicenses/).
