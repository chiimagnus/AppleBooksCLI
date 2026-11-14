# AppleBooksCLI

[English](README.md) | 简体中文

AppleBooksCLI 是一个用于查询并安全修改 Apple Books 数据的 macOS 命令行工具，
覆盖书籍、阅读状态、批注、本地 EPUB 正文、导出、备份、藏书、同步与近期写入历史。

## 0.5.0 起不再支持 PDF

**AppleBooksCLI 自 v0.5.0 起完全移除 PDF 专用功能。**
不再提供 PDF 命令、PDF 高亮提取和 PDF 导出。
**只有 v0.4.2 及更早版本支持 PDF。**
一般书库列表可能仍包含 PDF 的书籍元数据，但不会读取或导出 PDF 正文和高亮。

## 系统要求

- AppleBooksCLI 支持 macOS 15.6+ Apple Silicon（`arm64`）；Homebrew 安装已编译的 ARM64 发行版。
- 终端或调用进程可能需要 Full Disk Access。
- AppleBooksCLI 只读取本地已可用内容，不主动下载 iCloud placeholder，也不绕过 DRM 或系统保护。

## 安装

Homebrew：

```sh
brew install chiimagnus/tap/applebookscli
```

或使用 npm：

```sh
npm install --global @chiimagnus/applebookscli@latest
```

可选安装 Agent Skill：

```sh
npx -y skills add "chiimagnus/AppleBooksCLI#v$(applebookscli --version)" --skill applebookscli-zh --global
```

如果 Agent Skills CLI 已管理 AppleBooksCLI Skill，正常 npm 升级会尝试把 Skill 对齐到同一 CLI
release tag；`--ignore-scripts` 可关闭这项可选的 npm 步骤。

## 使用

命令与参数以当前安装的 CLI 为准：

```sh
applebookscli --help
applebookscli <group> --help
applebookscli <group> <subcommand> --help
```

常用读取：

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
```

导出只写入显式文件或受管目录；默认 Markdown，归档 JSON 需显式指定：

```sh
applebookscli export --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
applebookscli export --book <asset-id> --output notes.md
```

安全写入与恢复：

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

通过来源无关的 JSON 文件创建 EPUB 划线与笔记。先只读预检，
再针对同一本书创建一条或多条：

```sh
cat > annotations.json <<'JSON'
{"annotations":[{"text":"The sample text","chapterOrder":2,"color":"yellow","note":"A sample note"}]}
JSON
applebookscli annotations preview --book <asset-id> --input annotations.json
applebookscli annotations create --book <asset-id> --input annotations.json
```

批量创建即使进程退出码为 0，也必须检查 `complete` 和各条索引结果。
`changedCount > 0` 时，在处理好 `cloud_projection_failed` 警告后，
独立调用一次 `applebookscli sync`；云投影失败的现有记录用
`annotations repair-sync <annotation-uuid>` 修复，不重新插入。
CLI 支持直接为尚无批注的 EPUB 创建第一条原生高亮。首次云父对象创建要求可执行文件携带自身应用版本信息：标准 Debug 构建嵌入 `dev`，正式发行构建嵌入发布版本。未携带版本信息的自定义构建会在本地提交前返回 `application_version_unavailable`；只读 `preview` 不检测执行文件的版本信息。
历史为 `incomplete` 时先通过只读 preview/get 核销，不能盲目重试。

## 关键契约

- Operational command 在 stdout 输出 JSON；fatal error 在 stderr 输出净化后的 JSON。
  help/version 保持纯文本。
- 精确操作优先 stable identity：book asset ID、annotation UUID、collection ID 或 `backupID`。
  local PK 只是本机 fallback，必须显式选择。
- 可增长查询使用 opaque `nextCursor`；续页时把 token 原样交回同一查询，不解析、不修改。
  `backups list` 不分页，只是最新 10 个恢复备份的固定目录。
- 普通读取是有界 semantic view；出现 `truncatedFields` 表示展示文本被缩短。
  需要完整 raw text/CFI 时使用 archival JSON export。
- 普通读取保持只读；mutation 经过 guarded transaction 与 safety backup。
  `--sync` 只等待当前 Mac acknowledgement，不代表另一台设备已经显示变更。
- 通过可能自动重试的 transport 执行 mutation、restore 或 root sync 时，
  为该逻辑请求生成一次 fresh lowercase UUID，设为 `APPLEBOOKSCLI_OPERATION_ID`，并在重试时原样复用，
  避免再次派发写操作。
- Export artifact 只写显式 destination；stdout 只返回 compact write result，不返回完整 artifact。

详细契约统一从 [`docs/index.md`](docs/index.md) 进入。
Process/history 见 [`docs/cli-contract.md`](docs/cli-contract.md)，
mutation/backup/restore/sync 见 [`docs/write-safety.md`](docs/write-safety.md)。

## 可选配置

多数用户不需要配置文件。`~/.config/applebookscli/config.json` 只配置受支持的 supplemental EPUB
root 与 historical metadata mapping。
示例见 [`Config/applebookscli.example.json`](Config/applebookscli.example.json)。

## 开发

先读 [`AGENTS.md`](AGENTS.md)，再从 [`docs/index.md`](docs/index.md) 找到本次修改对应的 canonical
owner。

## 致谢

AppleBooksCLI 受益于以下项目的既有工作与思路：

- [57uff3r/ibooks_notes_exporter](https://github.com/57uff3r/ibooks_notes_exporter)
- [denya/apple-books-export](https://github.com/denya/apple-books-export)
- [eristoddle/apple-books-annotation-import](https://github.com/eristoddle/apple-books-annotation-import)
- [ragmha/apple-books-mcp](https://github.com/ragmha/apple-books-mcp)
- [vgnshiyer/apple-books-mcp](https://github.com/vgnshiyer/apple-books-mcp)
- [vgnshiyer/py-apple-books](https://github.com/vgnshiyer/py-apple-books)

## License

AppleBooksCLI 使用 [AGPLv3 LICENSE](LICENSE)。
第三方 notice 与许可证文本见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 和
[`ThirdPartyLicenses/`](ThirdPartyLicenses/)。
