# AppleBooksCLI

English | [简体中文](README.zh.md)

AppleBooksCLI is a macOS command-line tool for querying and safely updating Apple Books data. It covers books, reading state, annotations, local EPUB/PDF content, exports, backups, collections, sync, and recent write history.

## Requirements

- The published npm package targets macOS 12+ on Apple Silicon (`arm64`).
- The terminal or calling process may need Full Disk Access.
- AppleBooksCLI reads only locally available content; it does not hydrate iCloud placeholders or bypass DRM/system protections.

## Install

```sh
npm install --global @chiimagnus/applebookscli@latest
npx -y skills add "chiimagnus/AppleBooksCLI#v$(applebookscli --version)" --skill applebookscli --global
```

If Agent Skills CLI already manages the AppleBooksCLI Skill, normal npm upgrades attempt to align it to the same CLI release tag. `--ignore-scripts` disables that optional step.

## Use

The installed CLI is the source of truth for commands and arguments:

```sh
applebookscli --help
applebookscli <group> --help
applebookscli <group> <subcommand> --help
```

Common reads:

```sh
applebookscli doctor
applebookscli books list
applebookscli books search "history" --field all
applebookscli reading in-progress
applebookscli annotations list --has-note true --order modified
applebookscli annotations get <annotation-uuid>
applebookscli annotations context <annotation-uuid>
applebookscli reading position <asset-id>
applebookscli content chapters --book <asset-id>
applebookscli content chapter --book <asset-id> --chapter 1
applebookscli pdf list
applebookscli pdf highlights --book <asset-id>
```

Export writes a file or managed directory; Markdown is the default and archival JSON is explicit:

```sh
applebookscli export --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
applebookscli export --book <asset-id> --output notes.md
applebookscli export --pdf <pdfSourceID> --output pdf-notes.md
```

Guarded writes and recovery:

```sh
applebookscli collections create "My Shelf"
applebookscli collections add-book --collection <collection-id> --book <asset-id>
printf '%s' 'New note' | applebookscli annotations update-note <annotation-uuid>
applebookscli annotations delete <annotation-uuid>
applebookscli annotations restore <annotation-uuid>
applebookscli sync
applebookscli backups list
applebookscli history list
```

## Key contracts

- Operational commands use JSON on stdout; fatal errors use sanitized JSON on stderr. Help/version remain plain text.
- Prefer stable identities: book asset ID, annotation UUID, collection ID, opaque `pdfSourceID`, or `backupID`. Local PKs are machine-local fallbacks and must be selected explicitly.
- Growing queries use opaque `nextCursor` continuation. Pass the token unchanged to the same query; do not decode or edit it. `backups list` is different: it is a fixed newest-10 recovery catalog, not paginated history.
- Ordinary reads are bounded semantic views. `truncatedFields` means presentation text was shortened; use archival JSON export when full raw text/CFI fidelity is required.
- Ordinary reads are read-only. Mutations use guarded transactions and safety backups. `--sync` waits only for current-Mac acknowledgement; it does not prove another device already displays the change.
- When a transport may automatically retry a mutation, restore, or root sync, generate one fresh lowercase UUID for that logical request, set it as `APPLEBOOKSCLI_OPERATION_ID`, and reuse it on retry so the write cannot be redispatched blindly.
- Export artifacts are written only to the explicit destination; stdout returns a compact write result rather than the full artifact.

Detailed contracts live in [`docs/index.md`](docs/index.md). In particular, see [`docs/cli-contract.md`](docs/cli-contract.md) for process/history behavior and [`docs/write-safety.md`](docs/write-safety.md) for mutation, backup, restore, and sync semantics.

## Optional configuration

Most users do not need a configuration file. `~/.config/applebookscli/config.json` only configures the supported supplemental EPUB root and historical metadata mapping. See [`Config/applebookscli.example.json`](Config/applebookscli.example.json).

## Development

Start with [`AGENTS.md`](AGENTS.md), then use [`docs/index.md`](docs/index.md) to find the canonical owner for the contract you are changing.

## Acknowledgements

AppleBooksCLI benefited from prior art and ideas in:

- [57uff3r/ibooks_notes_exporter](https://github.com/57uff3r/ibooks_notes_exporter)
- [denya/apple-books-export](https://github.com/denya/apple-books-export)
- [eristoddle/apple-books-annotation-import](https://github.com/eristoddle/apple-books-annotation-import)
- [ragmha/apple-books-mcp](https://github.com/ragmha/apple-books-mcp)
- [vgnshiyer/apple-books-mcp](https://github.com/vgnshiyer/apple-books-mcp)
- [vgnshiyer/py-apple-books](https://github.com/vgnshiyer/py-apple-books)

## License

AppleBooksCLI is licensed under the [AGPLv3 LICENSE](LICENSE). Third-party notices and license texts are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and [`ThirdPartyLicenses/`](ThirdPartyLicenses/).
