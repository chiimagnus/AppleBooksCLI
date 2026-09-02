# AppleBooksCLI

AppleBooksCLI 是一个面向 macOS Apple Books 本地数据的 Swift CLI。它提供稳定的只读查询、EPUB/PDF 内容读取、导出、受保护的 collection/annotation 写入、SQLite backup/restore，以及随安装包分发的 `applebookscli` Skill。

## 平台与运行边界

- macOS 12 或更高版本。
- Swift 6 / SwiftPM 项目；release 产物为 macOS universal binary（arm64 + x86_64）。
- Apple Books 数据库读取默认使用 read-only SQLite 连接。
- 部分 Apple Books 数据访问可能需要为终端或调用进程授予 Full Disk Access。
- EPUB 未下载、DRM、schema 不兼容或 PDF 解析失败时会返回结构化 unavailable/degraded 结果，不绕过系统保护。

## 当前发布状态

`v0.1.0` 已作为 immutable GitHub Release 发布，自有 Homebrew tap 也已建立；随后 clean-install gate 暴露了 `skill install` 在 macOS `/private/tmp` alias 下的路径规范化缺陷。旧 release/tag/assets 保持不可变，修复版 `0.1.1` 正在重新执行 CI、release、tap 与 clean-install 验收。最终 Homebrew 安装命令会在修复版通过安装态 gate 后写入长期文档。

从源码验证当前实现：

```sh
swift test --disable-automatic-resolution
swift build --disable-automatic-resolution -c release --product applebookscli
BIN_DIR=$(swift build --disable-automatic-resolution -c release --show-bin-path)
"$BIN_DIR/applebookscli" --version
"$BIN_DIR/applebookscli" --help
```

## 命令概览

| 命令 | 用途 |
| --- | --- |
| `doctor` | 检查数据库、配置、内容与已安装 PDF worker 的可用性 |
| `books` | 列出、读取、搜索书籍与 annotated-only 视图 |
| `reading` / `stats` | 阅读状态、最近阅读、当前位置与统计 |
| `content` | EPUB status、metadata、ToC、chapter、CFI/context |
| `annotations` | 批注读取、搜索、时间范围，以及显式 note update / soft-delete |
| `collections` | collection 读取、创建、重命名、membership 与 soft-delete |
| `pdf` | PDF inventory 与 highlight extraction |
| `export` | JSON、CSV、Markdown、HTML 与 complete-note archive |
| `backups` | 列出安全 backup handle，并按 handle restore |
| `skill install` | 安装随 CLI 分发的 `applebookscli` Skill |

具体参数以对应命令的 `--help` 为准，例如：

```sh
applebookscli books --help
applebookscli export --help
applebookscli collections --help
```

Operational command 的 `--json` 输出保持单一机器可解析值；human diagnostics 不混入 machine stdout。完整 process-level contract 见 `docs/cli-contract.md`。

## Skill

安装包包含唯一的 `applebookscli` Skill 资源；Skill 只描述如何调用 CLI，不包含第二套 Apple Books 数据实现。

```sh
applebookscli skill install
```

默认目标为 `${CODEX_HOME:-~/.codex}/skills/applebookscli`。已有目标不会被默认覆盖；只有用户显式要求时才使用：

```sh
applebookscli skill install --force
```

`--force` 使用 staging + rename + rollback，并拒绝跟随已有 target symlink；它不会递归删除未知目标目录。

## 写入与备份安全

写命令不会直接从 CLI 层执行随意 SQLite mutation。核心写入路径统一遵守：

1. read-only schema/entity/selector preflight；
2. 记录 Books.app 原运行状态，必要时 clean quit 并确认停止；
3. 对稳定 live database 创建 fresh SQLite online backup，并执行 integrity check；
4. short-lived writable connection + `BEGIN IMMEDIATE`；
5. transaction 内 revalidate、mutation 与 invariant check；
6. COMMIT/ROLLBACK 后关闭 writable handle，再用 fresh read-only handle read-back；
7. 仅在 Books.app 原本运行时恢复应用。

COMMIT 已成功但应用恢复失败时会返回 committed success + warning，而不会谎报 rollback。AppleBooksCLI 不提供创建新 highlight、修改 selected text/CFI range 或任意写 current reading position 的命令。

完整写入安全 contract 见 `docs/write-safety.md`。

## 导出安全

`export` 支持 JSON、CSV、Markdown 与 self-contained HTML。完整 note archive 使用独立 raw count 与 materialization gate；historical/unmapped annotation 不会因为当前 BKLibrary 缺少对应 book row 而被静默丢弃。输出路径、symlink、覆盖策略与多文件 archive publication 均由统一 filesystem writer 管理。

## 文档

长期产品 contract 从 `docs/index.md` 开始。能力范围以 `docs/capability-matrix.md` 为准；CLI process contract 见 `docs/cli-contract.md`。

## License

AppleBooksCLI 使用 GNU Affero General Public License v3（AGPLv3）。实际构建依赖的第三方 notice 与许可证文本见 `THIRD_PARTY_NOTICES.md` 和 `ThirdPartyLicenses/`。
