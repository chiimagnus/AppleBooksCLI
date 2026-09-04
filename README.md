# AppleBooksCLI

English | [简体中文](README.zh.md)

[AppleBooksCLI](https://github.com/chiimagnus/AppleBooksCLI) is a command-line tool for Apple Books on macOS. It can query your library, reading state, highlights, and notes; read available EPUB/PDF content; export notes; and safely update existing notes or collections when requested.

## Features

- Browse and search the Apple Books library and reading state.
- Query highlights, notes, and recent annotations, with book- and time-based filtering.
- Open a single annotation back at its Apple Books location when a deep link is available.
- Read available EPUB tables of contents, chapters, metadata, and annotation context.
- Extract PDF highlights and notes.
- Export JSON, CSV, Markdown, or HTML.
- **Safely update notes and manage collections, with an automatic backup before writes.**
- Provide a standard `applebookscli` Agent Skill in English and Chinese.

## Requirements

- macOS may require Full Disk Access for the terminal or calling process before Apple Books data can be read.
- Undownloaded EPUBs, DRM-protected content, or content the current system cannot read are reported as unavailable or capability-limited. AppleBooksCLI does not bypass system protections.

## Install

```sh
npm install --global @chiimagnus/applebookscli@latest
npx -y skills@1.5.23 add "chiimagnus/AppleBooksCLI#v$(applebookscli --version)" --skill applebookscli --global
```

For the Chinese Skill, replace `applebookscli` with `applebookscli-zh` in the second command.

Future npm upgrades keep an Agent Skills CLI-managed Skill on the same CLI release tag automatically. `--ignore-scripts` disables that automatic update.

## Help

The installed CLI is the source of truth for current commands and arguments:

```sh
applebookscli --help
applebookscli <group> --help
applebookscli <group> <subcommand> --help
```

## Quick start

```sh
# Browse the library
applebookscli books list

# Show books currently in progress
applebookscli reading in-progress

# Show recently created annotations
applebookscli annotations recent

# Show library statistics
applebookscli stats
```

Most query commands support `--json` when structured output is needed:

```sh
applebookscli books list --json
applebookscli annotations recent --json
```

## Notes, highlights, and locations

Find an annotation first, then inspect it by UUID:

```sh
applebookscli annotations recent --json
applebookscli annotations get <annotation-uuid>
```

A single-annotation result includes an `appleBooksURL` when available so you can jump back to the book or highlight location in Apple Books.

To read text around a highlight:

```sh
applebookscli content context <annotation-uuid>
```

Use the current help for search, book filters, colors, and time ranges:

```sh
applebookscli annotations --help
```

## EPUB and PDF

```sh
# EPUB content commands
applebookscli content --help

# List PDF inventory
applebookscli pdf list

# Extract highlights from a PDF
applebookscli pdf highlights --help
```

Before reading EPUB text, AppleBooksCLI checks local materialization state without intentionally triggering iCloud hydration and does not bypass DRM. PDF commands only operate on sources that currently resolve to readable local files; equivalent non-hydrating behavior for iCloud placeholders has not been established.

## Export

```sh
# Markdown
applebookscli export --format markdown --output ~/Desktop/apple-books.md

# JSON
applebookscli export --format json --output ~/Desktop/apple-books.json
```

CSV, HTML, grouping by book, highlight/note filtering, Obsidian formatting, covers, and complete-notes archives are also available. EPUB annotations with a CFI make the `Location` text itself an Apple Books deep link in HTML/Markdown; without a CFI, the link falls back to the book level. JSON/CSV preserve the corresponding `appleBooksURL`:

```sh
applebookscli export --help
```

## Safe writes

AppleBooksCLI can update existing notes and manage collections. It creates a backup before writing and verifies the result afterward. Ordinary queries do not implicitly modify Apple Books data.

```sh
applebookscli annotations update-note --help
applebookscli collections --help
applebookscli backups --help
```

A single collection or annotation mutation can add `--sync` to wait for current-Mac CloudKit acknowledgement after the local commit and cloud projection:

```sh
applebookscli collections create "My Shelf" --sync --json
```

For several writes, commit the normal mutations first and flush once at the end:

```sh
applebookscli collections create "Shelf A" --json
applebookscli annotations update-note <annotation-uuid> --note "New note" --json
applebookscli sync --json
```

`sync` only processes already pending collection/member/annotation cloud records and does not trigger the lifecycle when none are pending. Acknowledgement proves only that **this Mac** completed the Apple Books CloudKit upload; it does not prove that another device already displays the change. A post-commit `cloud_sync_failed` must not cause an automatic mutation retry, and restoring a BKLibrary snapshot is not equivalent to replaying individually flushable cloud mutations.

## Optional configuration

Most users do not need a configuration file. `~/.config/applebookscli/config.json` is only needed for an additional EPUB directory or to supplement title/author metadata for historical annotations.

See [`Config/applebookscli.example.json`](Config/applebookscli.example.json).

## Development and maintenance

Start with [`docs/index.md`](docs/index.md) for architecture, CLI contract, write safety, release workflow, and other maintainer documentation.

## License

AppleBooksCLI is licensed under the [AGPLv3 LICENSE](LICENSE).
Third-party notices and license texts are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`ThirdPartyLicenses/`](ThirdPartyLicenses/).
