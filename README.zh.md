# AppleBooksCLI

[English](README.md) | 简体中文

AppleBooksCLI 是 macOS 命令行工具，可查看 Apple Books 书库与本地 EPUB 正文、管理划线和笔记、
导出批注，以及安全地操作藏书、备份和同步。

**自 v0.5.0 起仅支持 EPUB。** 不再读取和导出 PDF 正文与高亮，
但书库列表仍可能显示 PDF 元数据。最后支持 PDF 的版本是 v0.4.2。

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

## 查找和阅读

命令与参数以已安装 CLI 的帮助为准：

```sh
applebookscli --help
applebookscli annotations --help
applebookscli annotations create --help
```

下面的 `BOOK_ASSET_ID`、`ANNOTATION_UUID`、`COLLECTION_ID` 是占位符，
请替换为列表查询返回的真实标识。

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

## 导出 EPUB 笔记

导出到指定的文件或目录。Markdown 便于阅读，
`--format json` 保留完整归档数据：

```sh
applebookscli export --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
applebookscli export --book "BOOK_ASSET_ID" --output notes.md
```

## 修改和恢复

以下命令会修改 Apple Books 数据，请确认操作意图后使用。
`delete` 是软删除，仅在删除记录仍存在时才能用 `restore` 恢复。
`set-created-at` 也会更新修改时间。

```sh
applebookscli collections create "My Shelf"
applebookscli collections add-book --collection "COLLECTION_ID" --book "BOOK_ASSET_ID"
printf '%s' 'New note' | applebookscli annotations update-note "ANNOTATION_UUID"
applebookscli annotations set-created-at "ANNOTATION_UUID" --created-at "2023-06-02T11:58:15+08:00"
applebookscli annotations delete "ANNOTATION_UUID"
applebookscli annotations restore "ANNOTATION_UUID"
applebookscli sync
```

只读查看可用备份和近期操作记录：

```sh
applebookscli backups list
applebookscli history list
```

## 创建 EPUB 划线与笔记

在 JSON 文件中填写当前 EPUB 的原文与章节信息，替换下面的示例文字和章节号。
`preview` 仅检查位置、不写入；`create` 可在同一本书中创建 1～500 条：

```sh
cat > annotations.json <<'JSON'
{"annotations":[{"text":"The sample text","chapterOrder":2,"color":"yellow","note":"A sample note"}]}
JSON
applebookscli annotations preview --book "BOOK_ASSET_ID" --input annotations.json
applebookscli annotations create --book "BOOK_ASSET_ID" --input annotations.json
```

批量创建即使退出码为 0，也要检查 `complete` 和各条结果。
出现 `cloud_projection_failed` 时，先对**已有 UUID** 执行 `annotations repair-sync`；
若 `changedCount > 0`，处理好警告后独立运行一次 `applebookscli sync`。
批次部分完成或中断时，不得直接重放。
原位替换 EPUB 后若高亮消失，应先排查阅读缓存；详见[写入与恢复](docs/write-safety.md)。

## 安全使用

- 读取不会修改数据；写入有安全备份。`--sync` 只确认当前 Mac 已接收同步，
  不代表另一台设备已经显示变更。
- 数据命令在 stdout 返回 JSON，致命错误在 stderr 返回 JSON；帮助和版本信息为纯文本。
  分页按原样传递 `nextCursor`；`truncatedFields` 表示展示文本被截短，
  需要完整归档时使用 JSON 导出。
- 精确操作使用列表返回的书籍 ID、批注 UUID、藏书 ID 或备份 ID；
  本地数据库主键必须显式选择。
- 自动化写入时，每个逻辑请求生成一个新的小写 UUID 作为 `APPLEBOOKSCLI_OPERATION_ID`，
  同一请求重试时复用；历史标记为 `incomplete` 时不能盲目重试。

详细说明见[文档索引](docs/index.md)、[CLI 契约](docs/cli-contract.md)
与[写入和恢复安全](docs/write-safety.md)。

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
