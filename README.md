# AppleBooksCLI

[AppleBooksCLI](https://github.com/chiimagnus/AppleBooksCLI) 是一个用于 macOS Apple Books 的命令行工具。你可以直接查询自己的书库、阅读状态、划线与笔记，读取可用的 EPUB/PDF 内容，导出笔记，并在需要时安全地修改笔记或藏书。

## 主要功能

- 浏览、搜索 Apple Books 书库与阅读状态。
- 查询划线、笔记、最近批注，并按书籍或时间定位。
- 查看单条批注时获得可直接跳回 Apple Books 对应划线位置的链接。
- 读取可用 EPUB 的目录、章节、元数据与批注上下文。
- 提取 PDF 划线与笔记。
- 导出 JSON、CSV、Markdown 或 HTML。
- **安全修改笔记、管理藏书，并在写入前自动备份。**
- 提供标准 `applebookscli` Agent Skill。

## 系统要求

- 读取 Apple Books 数据时，macOS 可能要求为终端或调用进程授予 Full Disk Access。
- 未下载的 EPUB、DRM 内容或当前系统无法读取的内容会明确提示不可用或能力受限；AppleBooksCLI 不绕过系统保护。

## 安装

```sh
# 安装 CLI
npm install --global @chiimagnus/applebookscli@latest

# 安装 SKILL.md
npx skills add chiimagnus/AppleBooksCLI --skill applebookscli --global

```

## 获取帮助

CLI 自带完整帮助，具体命令与参数以当前安装版本为准：

```sh
applebookscli --help
applebookscli <group> --help
applebookscli <group> <subcommand> --help
```

## 快速开始

```sh
# 浏览书库
applebookscli books list

# 查看正在阅读的书
applebookscli reading in-progress

# 查看最近创建的批注
applebookscli annotations recent

# 查看书库统计
applebookscli stats
```

需要结构化结果时，大多数查询命令支持 `--json`：

```sh
applebookscli books list --json
applebookscli annotations recent --json
```

## 笔记、划线与定位

先找到批注，再用 UUID 查看具体内容：

```sh
applebookscli annotations recent --json
applebookscli annotations get <annotation-uuid>
```

单条批注结果会包含对应的 `appleBooksURL`，可以直接跳回 Apple Books 中该书或对应划线位置。

如果需要查看划线前后的正文：

```sh
applebookscli content context <annotation-uuid>
```

搜索、按书筛选、颜色、时间范围等能力以当前帮助为准：

```sh
applebookscli annotations --help
```

## EPUB 与 PDF

```sh
# EPUB 内容相关命令
applebookscli content --help

# 查看 PDF inventory
applebookscli pdf list

# 提取某个 PDF 的 highlights
applebookscli pdf highlights --help
```

EPUB 在读取正文前会先检查本地 materialization 状态，不主动触发 iCloud hydration，也不会绕过 DRM。PDF 只处理当前可解析为可读本地文件的 source；对 iCloud placeholder 的 non-hydrating 行为尚未建立等价保证。

## 导出

```sh
# Markdown
applebookscli export --format markdown --output ~/Desktop/apple-books.md

# JSON
applebookscli export --format json --output ~/Desktop/apple-books.json
```

还支持 CSV、HTML、按书分组、筛选划线/笔记、Obsidian 格式、封面与完整笔记归档等选项。有 CFI 的 EPUB 批注在 HTML/Markdown 中会把 `Location` 本身做成 Apple Books deep link；无 CFI 时退化为书籍级链接。JSON/CSV 保留对应 `appleBooksURL`：

```sh
applebookscli export --help
```

## 安全写入

AppleBooksCLI 可以修改已有笔记和管理藏书。写入前会自动创建备份，并在写入后验证结果；普通查询不会隐式修改 Apple Books 数据。

```sh
applebookscli annotations update-note --help
applebookscli collections --help
applebookscli backups --help
```

单条 collection / annotation mutation 可加 `--sync`，在本地 commit + cloud projection 后等待当前 Mac 的 CloudKit acknowledgement：

```sh
applebookscli collections create "My Shelf" --sync --json
```

连续多条写入时，优先正常提交各 mutation，最后只 flush 一次：

```sh
applebookscli collections create "Shelf A" --json
applebookscli annotations update-note <annotation-uuid> --note "New note" --json
applebookscli sync --json
```

`sync` 只处理已存在的 pending collection/member/annotation cloud records；无 pending 时不触发生命周期。acknowledgement 只证明**当前 Mac** 已完成 Apple Books CloudKit upload，不等于另一台设备已经显示。post-commit `cloud_sync_failed` 不能触发自动重试；BKLibrary restore 也不等同于可逐条 flush 的 cloud mutation。

## 可选配置

大多数用户不需要配置文件。只有需要指定额外的 EPUB 目录，或给历史批注补充书名/作者信息时，才需要 `~/.config/applebookscli/config.json`。

示例见 [`Config/applebookscli.example.json`](Config/applebookscli.example.json)。

## 开发与维护

架构、CLI contract、写入安全、发布流程和其它维护者文档从 [`docs/index.md`](docs/index.md) 开始。

## License

AppleBooksCLI 使用 [AGPLv3 LICENSE](LICENSE) 。
第三方 notice 与许可证文本见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 和 [`ThirdPartyLicenses/`](ThirdPartyLicenses/)。