# AppleBooksCLI

[English](README.md) | 简体中文

[AppleBooksCLI](https://github.com/chiimagnus/AppleBooksCLI) 是一个用于 macOS Apple Books 的命令行工具，可查询书库、阅读状态、批注、本地 EPUB/PDF 内容、导出与备份，并提供一组刻意保持狭窄的安全写入能力。

## 主要功能

- 浏览书籍、藏书、阅读状态与书库统计。
- 搜索划线和笔记、查看最近批注，并在可用时通过 Apple Books deep link 跳回原位置。
- 读取本地可用 EPUB 的结构/正文，并提取 PDF highlights。
- 导出 JSON 与 Markdown。
- 通过自动 safety backup 安全修改已有 annotation note 与 user collection。
- 单条 mutation 可显式 `--sync`，批量修改可最后一次 flush pending cloud changes。
- 查看最近 24 小时的 AppleBooksCLI mutation/restore/sync operation history。

## 系统要求

- macOS 可能要求为终端或调用进程授予 Full Disk Access。
- 未 materialize 的 EPUB、DRM 内容和其它当前不可读的本地资源会返回 unavailable；AppleBooksCLI 不绕过系统保护。

## 安装

```sh
npm install --global @chiimagnus/applebookscli@latest
npx -y skills add "chiimagnus/AppleBooksCLI#v$(applebookscli --version)" --skill applebookscli-zh --global
```

如果 Agent Skills CLI 已管理 AppleBooksCLI Skill，正常 npm 升级会尝试把它对齐到相同的 CLI release tag。`--ignore-scripts` 会关闭这项可选对齐。

## 获取帮助

命令和参数以当前安装 CLI 为准：

```sh
applebookscli --help
applebookscli <group> --help
applebookscli <group> <subcommand> --help
```

## 常见任务

```sh
# 书库与阅读状态
applebookscli books list
applebookscli books search "history" --field all
applebookscli books search "Fiction" --field genre
applebookscli reading in-progress
applebookscli stats
applebookscli collections list   # 返回 nextCursor 时用 --cursor 继续
applebookscli doctor   # ready / partial / unavailable + 固定 capability map

# 最近批注
applebookscli annotations recent

# 单条批注与对应 EPUB 上下文
applebookscli annotations get <annotation-uuid>
applebookscli content context <annotation-uuid>

# PDF inventory / 提取
applebookscli pdf list   # 返回 nextCursor 时用 --cursor 继续
applebookscli pdf highlights --help
```

精确操作优先 stable identity：book asset ID、annotation UUID、collection ID 或 backup handle。local PK（`Z_PK`）只是在当前本机数据库中的行标识，必须显式选择。`books list/search`、可增长的 reading-state 查询、`collections list/search/books` 与 `pdf list` 使用 opaque cursor；返回 `nextCursor` 时把它原样传给同一查询的 `--cursor`。PDF inventory 会返回 `bookAssetID` 或 opaque `pdfSourceID`；后续用 `pdf highlights --book` 或 `--pdf` 消费该 identity，不把绝对文件路径当 ordinary selector。普通 read 会限制超长展示文本，并用 `truncatedFields` 标明被缩短字段；需要原始完整正文时使用显式 archival export，不要把普通查询结果当 raw dump。`stats` 会把 historical、unmapped、当前书库 identity 歧义、identity 不可用的批注分别计数；`topAnnotatedBooks` 只返回可继续使用的书籍 identity 与 `annotationCount`。

## 导出

```sh
applebookscli export --format markdown --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
applebookscli export --help
```

完整导出 artifact 只写入显式 output file/directory；stdout 返回 compact JSON write result。其它 operational command 也统一直接在 stdout 返回 JSON。

## 安全写入与 iCloud 同步

AppleBooksCLI 的写入只能经过 guarded mutation/restore rail；普通查询保持只读。

单条 mutation 可以显式等待当前 Mac 的 CloudKit acknowledgement：

```sh
applebookscli collections create "My Shelf" --sync
```

连续多条 mutation 时，先正常提交，最后统一 flush 一次：

```sh
applebookscli collections create "Shelf A"
applebookscli annotations update-note <annotation-uuid> --note "New note"
applebookscli sync
```

当前 Mac acknowledgement 不代表另一台设备已经显示。post-commit sync/restore warning 也不能当成重放 mutation 的授权。完整安全与生命周期契约见 [`docs/write-safety.md`](docs/write-safety.md)。

## 操作历史

```sh
applebookscli history list   # 返回 nextCursor 时用 --cursor 继续
applebookscli history get <history-id>
```

History 是最近 AppleBooksCLI mutation/restore/sync 调用的本机私有证据，不是 undo engine。`history list` 有界分页（默认 20、最大 100）；`history get` 是显式完整读取面，可能包含原始参数与捕获输出。详见 [`docs/cli-contract.md`](docs/cli-contract.md)。

## 可选配置

多数用户不需要配置文件。`~/.config/applebookscli/config.json` 只用于受支持的 supplemental EPUB root 与 historical metadata mapping。

示例见 [`Config/applebookscli.example.json`](Config/applebookscli.example.json)。

## 开发与维护

先读 [`AGENTS.md`](AGENTS.md)，再从 [`docs/index.md`](docs/index.md) 进入架构、能力、process、写安全与 release 的 canonical owner。

## 致谢

AppleBooksCLI 的设计与实现受益于以下开源项目的相关工作与思路，感谢这些项目的作者和贡献者：

- [57uff3r/ibooks_notes_exporter](https://github.com/57uff3r/ibooks_notes_exporter)
- [denya/apple-books-export](https://github.com/denya/apple-books-export)
- [eristoddle/apple-books-annotation-import](https://github.com/eristoddle/apple-books-annotation-import)
- [ragmha/apple-books-mcp](https://github.com/ragmha/apple-books-mcp)
- [vgnshiyer/apple-books-mcp](https://github.com/vgnshiyer/apple-books-mcp)
- [vgnshiyer/py-apple-books](https://github.com/vgnshiyer/py-apple-books)

## License

AppleBooksCLI 使用 [AGPLv3 LICENSE](LICENSE)。第三方 notice 与许可证文本见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 和 [`ThirdPartyLicenses/`](ThirdPartyLicenses/)。
