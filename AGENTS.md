# AppleBooksCLI Repository Rules

## 不可破坏的边界

- 本仓库是 Swift 6 / SwiftPM 项目，公开 `AppleBooksCore` library、`applebookscli` executable 和独立 `applebookscli-pdf-worker`。业务语义归 `AppleBooksCore`；CLI 只负责 composition、参数、输出与 operation history。不要在 CLI 或其它 transport 层复制 SQLite 查询/写入、EPUB/PDF 解析、cloud projection 等业务路径，也不要为了 CLI 特例静默改变公开 Core API 的既有语义。
- BKLibrary 与 AEAnnotation 是独立 store，分别发现、override 和管理 lifecycle。普通查询保持 SQLite read-only；optional read schema 可降级，required write schema/entity 漂移必须 fail closed。精确操作优先 stable identity；数字形式的 stable ID 不能猜成 local PK，多候选也不能自动挑一个。
- production mutation 只能走 guarded write rail。`COMMIT` 是不可逆边界：commit 前失败可以 rollback；commit 后 read-back、projection、acknowledgement、deeplink、Books restore 等失败只能作为 committed warning，绝不能自动重放同一 mutation。normal mutation 的 `closed / background / frontmost` 生命周期由 `MutationCoordinator` 拥有，不要用前后 `isRunning` 猜 temporary-launch ownership。
- 保持显式同步模型：普通 mutation 做 local commit + read-back + Apple-native cloud projection，不等待 acknowledgement；单条需要确认时显式 `--sync`；同一批多条 mutation 仅在至少一条 `changed=true` 时最后调用一次根 `applebookscli sync`。全部 no-op 时不要 root sync；current-Mac acknowledgement 也不代表其它设备已经显示。
- EPUB 只消费可安全读取、已 materialized 的本地资源；不要主动 hydration iCloud placeholder 或绕过 DRM。PDFKit 保持隔离在独立 worker process。export renderer 保持 DB-free，文件落盘继续经过 `ExportFileWriter` 的 confinement/overwrite rail；`--complete-notes` 失败时不能降级普通 export 后仍声称完整。
- `AppleBooksCloudBridge` 是当前唯一允许的非 Swift production runtime；不要把它扩成自建 Apple Books CloudKit client，也不要伪造 Apple identity、entitlement 或私有 store schema。
- recordable mutation / restore / root sync 必须在 dispatch 前成功记录 history `started`；completion history 失败只能追加 warning，不能改变原 command outcome。默认错误和 mutation 输出不得反射用户正文、私有 SQLite payload 或绝对路径。
- fixture、文档与提交历史只能使用 synthetic / repository-owned 数据。不得提交真实用户书名、asset ID、annotation UUID/CFI、笔记正文或本机私有绝对路径。

## Canonical owners

- 架构、store/source/identity 与 subsystem ownership：[`docs/architecture.md`](docs/architecture.md)。
- mutation、backup/restore、cloud sync 与 Books lifecycle：[`docs/write-safety.md`](docs/write-safety.md)。
- stdout/stderr/JSON 与 operation history：[`docs/cli-contract.md`](docs/cli-contract.md)。
- 用户可见能力：[`docs/capability-matrix.md`](docs/capability-matrix.md)；implemented capability 同时维护 `Tests/Fixtures/Parity/capability-anchors.json`，保持 implementation、test、CLI help reachability 一致。
- 文档 owner 导航：[`docs/index.md`](docs/index.md)。`.github/features/` 中的 plan/audit/todo 是实施历史，不得用 superseded 中间态覆盖当前源码、tests 与 canonical docs。
- dependency 变化同时维护 `Package.swift` / `Package.resolved`、`THIRD_PARTY_NOTICES.md` 与 `ThirdPartyLicenses/`。`dist/` 是生成产物；release 规则由 [`docs/release.md`](docs/release.md)、`.github/workflows/release.yml` 与现有 release scripts 拥有。

## 开发与验证

- 在源码 checkout 中执行、测试或调用 CLI 前先 `swift build`，随后固定使用 `$(swift build --show-bin-path)/applebookscli`；不要混用 PATH 中可能更旧的全局安装版本，命令面以这个 binary 的 `--help` 为准。
- 按 blast radius 先跑 targeted tests；需要跨模块、capability、packaging、privacy、dependency 或完成级验证时使用仓库唯一 broad gate：`scripts/ci-gates.sh`。不要在 AGENTS 再维护一份机械测试清单。
- 真实 Apple Books mutation / CloudKit / UI integration 是显式 opt-in。fixture、state-machine、process test 或 current-Mac acknowledgement 不能被描述成真实用户数据端到端、第二设备 render 或 live UI 已验证。
