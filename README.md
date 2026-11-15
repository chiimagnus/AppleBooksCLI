# AppleBooksCLI

English | [简体中文](README.zh.md)

AppleBooksCLI lets you browse your Apple Books library, read local EPUBs, manage highlights
and notes, export annotations, and safely manage collections, backups, and sync from macOS.

**EPUB only since v0.5.0.** PDF content and highlights are no longer supported,
although book listings may still show PDF metadata. v0.4.2 was the last release with PDF support.

## Requirements

- AppleBooksCLI targets macOS 15.6+ on Apple Silicon (`arm64`). Homebrew installs the precompiled
  ARM64 release.
- The terminal or calling process may need Full Disk Access.
- AppleBooksCLI reads only locally available content; it does not hydrate iCloud placeholders
  or bypass DRM/system protections.

## Install

Homebrew:

```sh
brew install chiimagnus/tap/applebookscli
```

Or npm:

```sh
npm install --global @chiimagnus/applebookscli@latest
```

Optional Agent Skill:

```sh
npx -y skills add "chiimagnus/AppleBooksCLI#v$(applebookscli --version)" --skill applebookscli --global
```

If Agent Skills CLI already manages the AppleBooksCLI Skill, normal npm upgrades attempt to
align it to the same CLI release tag. `--ignore-scripts` disables that optional npm step.

## Find and read

Check the installed CLI's help for current commands and options:

```sh
applebookscli --help
applebookscli annotations --help
applebookscli annotations create --help
```

In the examples, replace `BOOK_ASSET_ID`, `ANNOTATION_UUID`, and `COLLECTION_ID`
with IDs returned by the list commands.

```sh
applebookscli doctor
applebookscli books list
applebookscli books search "history" --field all
applebookscli reading in-progress
applebookscli annotations list --has-note true --order modified
applebookscli annotations get "ANNOTATION_UUID"
applebookscli annotations context "ANNOTATION_UUID"
applebookscli reading position "BOOK_ASSET_ID"
applebookscli content chapters --book "BOOK_ASSET_ID"
applebookscli content chapter --book "BOOK_ASSET_ID" --chapter 1
```

## Export EPUB notes

Export writes to a chosen file or directory. Markdown is for reading;
`--format json` preserves archival annotation data:

```sh
applebookscli export --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
applebookscli export --book "BOOK_ASSET_ID" --output notes.md
```

## Edit and recover

These commands modify your Apple Books data; use them only when you intend to make the change.
`delete` soft-deletes; `restore` works while its tombstone remains.
`set-created-at` also updates the modification time.

```sh
applebookscli collections create "My Shelf"
applebookscli collections add-book --collection "COLLECTION_ID" --book "BOOK_ASSET_ID"
printf '%s' 'New note' | applebookscli annotations update-note "ANNOTATION_UUID"
applebookscli annotations set-created-at "ANNOTATION_UUID" --created-at "2023-06-02T11:58:15+08:00"
applebookscli annotations delete "ANNOTATION_UUID"
applebookscli annotations restore "ANNOTATION_UUID"
applebookscli sync
```

Inspect available backups and recent operations without changing data:

```sh
applebookscli backups list
applebookscli history list
```

## Create EPUB highlights and notes

Use text from the book's current EPUB in a JSON file; replace the sample text and chapter with
an exact selection. Preview checks locations without writing; create accepts 1–500 entries for one book:

```sh
cat > annotations.json <<'JSON'
{"annotations":[{"text":"The sample text","chapterOrder":2,"color":"yellow","note":"A sample note"}]}
JSON
applebookscli annotations preview --book "BOOK_ASSET_ID" --input annotations.json
applebookscli annotations create --book "BOOK_ASSET_ID" --input annotations.json
```

For a batch, check `complete` and each item even if the command exits with code 0.
Repair `cloud_projection_failed` on the **existing** UUID with `annotations repair-sync`;
if `changedCount > 0`, run `applebookscli sync` once after repairs.
Never blindly rerun a partially completed or interrupted batch.
See [write safety](docs/write-safety.md) for recovery and missing highlights after replacing an EPUB.

## Working safely

- Reads are read-only; writes use safety backups. `--sync` confirms acknowledgement only on this Mac,
  not whether another device has displayed the change.
- Data commands return JSON on stdout; fatal errors return JSON on stderr. Help/version are plain text.
  Continue paginated queries with `nextCursor` unchanged. `truncatedFields` means display text is
  incomplete; export JSON for full archival data.
- Use returned asset IDs, annotation UUIDs, collection IDs, or backup IDs for exact operations.
  Local primary keys must be selected explicitly.
- For automated writes, assign a fresh lowercase UUID as `APPLEBOOKSCLI_OPERATION_ID` per logical
  request and reuse it on retry. An `incomplete` history entry is not permission to retry blindly.

See the [documentation index](docs/index.md), [CLI contract](docs/cli-contract.md),
and [write safety](docs/write-safety.md) for detailed behavior and recovery rules.

## Optional configuration

Most users do not need a configuration file. `~/.config/applebookscli/config.json` only
configures the supported supplemental EPUB root and historical metadata mapping. See
[`Config/applebookscli.example.json`](Config/applebookscli.example.json).

## Development

Start with [`AGENTS.md`](AGENTS.md), then use [`docs/index.md`](docs/index.md) to find the
canonical owner for the contract you are changing.

## Acknowledgements

AppleBooksCLI benefited from prior art and ideas in:

- [57uff3r/ibooks_notes_exporter](https://github.com/57uff3r/ibooks_notes_exporter)
- [denya/apple-books-export](https://github.com/denya/apple-books-export)
- [eristoddle/apple-books-annotation-import](https://github.com/eristoddle/apple-books-annotation-import)
- [ragmha/apple-books-mcp](https://github.com/ragmha/apple-books-mcp)
- [vgnshiyer/apple-books-mcp](https://github.com/vgnshiyer/apple-books-mcp)
- [vgnshiyer/py-apple-books](https://github.com/vgnshiyer/py-apple-books)

## License

AppleBooksCLI is licensed under the [AGPLv3 LICENSE](LICENSE). Third-party notices and license
texts are in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) and
[`ThirdPartyLicenses/`](ThirdPartyLicenses/).
