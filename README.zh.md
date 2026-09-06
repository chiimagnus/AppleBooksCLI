# AppleBooksCLI

[English](README.md) | 简体中文

[AppleBooksCLI](https://github.com/chiimagnus/AppleBooksCLI) 是一个 macOS 命令行工具，用于读取并安全管理 Apple Books 数据：书库、阅读状态、批注、EPUB/PDF 内容、导出、笔记和藏书。

## 安装

```sh
npm install --global @chiimagnus/applebookscli@latest
npx -y skills@1.5.23 add "chiimagnus/AppleBooksCLI#v$(applebookscli --version)" --skill applebookscli-zh --global
```

第一条命令安装 CLI；第二条安装对应版本的中文 Agent Skill。除非禁用 npm lifecycle scripts，后续 npm 升级会让 Agent Skills CLI 管理的 Skill 跟随同一个 CLI release tag。

## 系统要求

- macOS。读取 Apple Books 数据时，调用终端或进程可能需要 Full Disk Access。
- AppleBooksCLI 不绕过 DRM，也不会主动 hydration 当前不可用的 iCloud 内容。

## 快速开始

```sh
applebookscli books list
applebookscli reading in-progress
applebookscli annotations recent
applebookscli stats
```

需要结构化结果时使用 `--json`：

```sh
applebookscli books list --json
applebookscli annotations recent --json
```

当前命令和参数始终以已安装 CLI 的 help 为准：

```sh
applebookscli --help
applebookscli <group> --help
applebookscli <group> <subcommand> --help
```

## 常见任务

| 目标 | 命令族 |
| --- | --- |
| 浏览/搜索书籍和阅读状态 | `books`、`reading`、`stats` |
| 读取/搜索批注和笔记 | `annotations` |
| 读取 EPUB 内容或批注上下文 | `content` |
| 查看 PDF 与 PDF highlights | `pdf` |
| 导出 JSON/CSV/Markdown/HTML | `export` |
| 管理藏书 | `collections` |
| 查看/恢复 guarded backup | `backups` |
| 查看近期写入/同步历史 | `history` |
| 诊断权限或 schema readiness | `doctor` |

单条批注结果可能包含 `appleBooksURL`，可重新打开 Apple Books 中对应的书或划线位置。

完整当前能力边界见 [`docs/capability-matrix.md`](docs/capability-matrix.md)。

## 写入与 iCloud 同步

写入统一经过 guarded mutation rail：preflight、Books lifecycle、safety backup、transaction、read-back 与 cloud projection。普通读取不会进入这条写入路径。

只有一条修改且希望立即获得 iCloud acknowledgement 时，加 `--sync`：

```sh
applebookscli annotations update-note <annotation-uuid> --note "New note" --sync --json
```

连续多条修改时，不要让 Books 每条都重新触发同步；先完成本地批次，最后统一 flush 一次：

```sh
applebookscli collections create "Shelf A" --json
applebookscli annotations update-note <annotation-uuid> --note "New note" --json
applebookscli sync --json
```

`--sync` 或根 `sync` 成功只证明**当前 Mac** 获得 acknowledgement，不代表另一台设备已经显示该修改。post-commit warning 不能触发自动重放 mutation。

完整写入、恢复、lifecycle 与 CloudKit 不变量见 [`docs/write-safety.md`](docs/write-safety.md)。

## 导出与本地内容

```sh
applebookscli export --format markdown --output ~/Desktop/apple-books.md
applebookscli export --format json --output ~/Desktop/apple-books.json
```

当前选项以 `applebookscli export --help`、`content --help`、`pdf --help` 为准。EPUB/PDF 是否可读取决于本地 materialization、DRM 和可读本地 source。

## 配置

大多数用户不需要配置文件。`~/.config/applebookscli/config.json` 只用于可选 supplemental EPUB 查找或 historical annotation metadata。示例见 [`Config/applebookscli.example.json`](Config/applebookscli.example.json)。

## 维护者

从 [`docs/index.md`](docs/index.md) 开始。它列出 architecture、capability、process contract、write safety、schema baseline 与 release 行为的唯一 owner。

## License

AppleBooksCLI 使用 [AGPLv3 LICENSE](LICENSE)。第三方声明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。
