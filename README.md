# AppleBooksCLI

AppleBooksCLI 是一个面向 macOS Apple Books 本地数据的 Swift CLI。它提供稳定的只读查询、EPUB/PDF 内容读取、导出、受保护的 collection/annotation 写入、SQLite backup/restore，以及随安装包分发的 `applebookscli` Skill。

## 平台与运行边界

- macOS 12 或更高版本。
- Swift 6 / SwiftPM 项目；预编译 release 只发布 macOS Apple Silicon（arm64），不提供 Intel/x86_64 binary。
- Apple Books 数据库读取默认使用 read-only SQLite 连接。
- 部分 Apple Books 数据访问可能需要为终端或调用进程授予 Full Disk Access。
- EPUB 未下载、DRM、schema 不兼容或 PDF 解析失败时会返回结构化 unavailable/degraded 结果，不绕过系统保护。

## 安装

```sh
npm install --global @chiimagnus/applebookscli
applebookscli --version
```

Beta 版本使用独立 npm dist-tag，不会改动稳定版 `latest`：

```sh
npm install --global @chiimagnus/applebookscli@beta
```

## Release channels

Git tag 是 release 版本的唯一 owner；源码不保存手工版本号。稳定版 tag 使用 `vMAJOR.MINOR.PATCH`（如 `v1.2.1`），beta 使用 `vMAJOR.MINOR.PATCH-beta` 或后续迭代的 `vMAJOR.MINOR.PATCH-beta.N`。push 合法 tag 后，GitHub Actions 会执行完整测试/隐私/license/package gate，再发布 npm 与 GitHub Release：稳定版进入 npm `latest` 并成为普通 GitHub Release，beta 进入 npm `beta` 并标记 GitHub prerelease。普通开发构建的 `applebookscli --version` 显示 `dev`；release binary 的版本由对应 tag 注入。

## 配置

默认配置文件是 `~/.config/applebookscli/config.json`，不存在时按空配置运行。仓库提供 `Config/applebookscli.example.json` 示例；当前配置只用于：

- `epub_root`：为 current Book 提供 exact-basename packed EPUB supplemental root；
- `historical_assets`：按 exact asset ID 补充 historical annotation 的 title/author metadata。

也可以用全局 `--config <path>` 指定其它配置文件；`--library-db` / `--annotations-db` 用于显式 DB override、fixture 与诊断。配置不会把 historical metadata 升级成 current Book/content identity。

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

## 文档

长期产品文档从 `docs/index.md` 开始。能力范围以 `docs/capability-matrix.md` 为准；架构与 identity/source 边界见 `docs/architecture.md`；CLI process contract 见 `docs/cli-contract.md`；mutation/restore safety 见 `docs/write-safety.md`。

## License

AppleBooksCLI 使用 GNU Affero General Public License v3（AGPLv3）。实际构建依赖的第三方 notice 与许可证文本见 `THIRD_PARTY_NOTICES.md` 和 `ThirdPartyLicenses/`。
