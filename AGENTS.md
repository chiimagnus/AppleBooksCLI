# AppleBooksCLI Repository Rules

## 不可破坏的边界

- 本仓库是 Swift 6 / SwiftPM 项目，公开 `AppleBooksCore` library、`applebookscli` executable 和独立 `applebookscli-pdf-worker`。业务语义归 `AppleBooksCore`；CLI 只负责 composition、参数、输出与 operation history。不要在 CLI 或其它 transport 层复制 SQLite 查询/写入、EPUB/PDF 解析、cloud projection 等业务路径，也不要为了 CLI 特例静默改变公开 Core API 的既有语义。
- BKLibrary 与 AEAnnotation 是独立 store，分别发现、override 和管理 lifecycle。普通查询保持 SQLite read-only；optional read schema 可降级，required write schema/entity 漂移必须 fail closed。精确操作优先 stable identity；数字形式的 stable ID 不能猜成 local PK，多候选也不能自动挑一个。
- production mutation 只能走 guarded write rail。`COMMIT` 是不可逆边界：commit 前失败可以 rollback；commit 后 read-back、projection、acknowledgement、deeplink、Books restore 等失败只能作为 committed warning，绝不能自动重放同一 mutation。normal mutation 的 `closed / background / frontmost` 生命周期由 `MutationCoordinator` 拥有，不要用前后 `isRunning` 猜 temporary-launch ownership。
- 保持显式同步模型：普通 mutation 做 local commit + read-back + Apple-native cloud projection，不等待 acknowledgement；单条需要确认时显式 `--sync`；同一批多条 mutation 仅在至少一条 `changed=true` 时最后调用一次根 `applebookscli sync`。全部 no-op 时不要 root sync；current-Mac acknowledgement 也不代表其它设备已经显示。
- EPUB 只消费可安全读取、已 materialized 的本地资源；不要主动 hydration iCloud placeholder 或绕过 DRM。PDFKit 保持隔离在独立 worker process。export renderer 保持 DB-free，文件落盘继续经过 `ExportFileWriter` 的 confinement/overwrite rail。
- `AppleBooksCloudBridge` 是当前唯一允许的非 Swift production runtime；不要把它扩成自建 Apple Books CloudKit client，也不要伪造 Apple identity、entitlement 或私有 store schema。
- recordable mutation / restore / root sync 必须在 dispatch 前成功记录 history `started`；completion history 失败只能追加 warning，不能改变原 command outcome。默认错误和 mutation 输出不得反射用户正文、私有 SQLite payload 或绝对路径。
- fixture、文档与提交历史只能使用 synthetic / repository-owned 数据。不得提交真实用户书名、asset ID、annotation UUID/CFI、笔记正文或本机私有绝对路径。

## AI-Agent-first CLI contract

- `applebookscli` 的主要调用者是 AI Agent，不以人类交互式终端体验作为 API 设计前提。普通 operational command 的 canonical contract 是稳定、最小、可机器解析的 JSON；human text 只能作为 secondary/debug presentation，不能反过来决定数据模型。
- 所有可能增长到大量结果的 list/search/recent/range/read 默认 bounded。record-oriented query 默认 page size 为 20、单页上限 100（payload 可采用更低上限），continuation 使用稳定的 opaque cursor；Agent 只负责原样回传 cursor，不解析内部值。完整自然全量读取属于 `export`，不能靠省略 `--limit` 隐式触发。
- list/search 只返回完成下一步所需的 semantic summary；exact get 返回 detail；archival export 才承担 raw fidelity。稳定 identity 优先于 local PK，missing/ambiguous exact selector 必须 fail closed，presentation/grouping 不能改变 selection 或 ordering。
- Agent 只表达业务意图，不要求它选择数据库、媒体 routing、worker timeout、type-3/raw CFI 等内部实现。普通 help 不暴露死参数、无效参数或纯诊断 tuning；需要保留的内部/诊断能力放 advanced/doctor 或内部测试路径。
- stdout 只承载主结果；error/diagnostic 走 stderr；默认不依赖 TTY、pager、ANSI、prompt 或人工确认。错误必须有稳定 code 和足够的 recovery hint。用户正文、Note 等敏感内容不能把 argv 作为唯一输入路径。

## Canonical owners

- 架构、store/source/identity 与 subsystem ownership：[`docs/architecture.md`](docs/architecture.md)。
- mutation、backup/restore、cloud sync 与 Books lifecycle：[`docs/write-safety.md`](docs/write-safety.md)。
- stdout/stderr/JSON 与 operation history：[`docs/cli-contract.md`](docs/cli-contract.md)。
- 用户可见能力：[`docs/capability-matrix.md`](docs/capability-matrix.md)；implemented capability 同时维护 `Tests/Fixtures/Parity/capability-anchors.json`，保持 implementation、test、CLI help reachability 一致。
- 文档 owner 导航：[`docs/index.md`](docs/index.md)。`.github/features/` 中的 plan/audit/todo 是实施历史，不得用 superseded 中间态覆盖当前源码、tests 与 canonical docs。
- dependency 变化同时维护 `Package.swift` / `Package.resolved`、`THIRD_PARTY_NOTICES.md` 与 `ThirdPartyLicenses/`。`dist/` 是生成产物；release 规则由 [`docs/release.md`](docs/release.md)、`.github/workflows/release.yml` 与现有 release scripts 拥有。

## Repository Skill 规范

- `skills/*/SKILL.md` 是给 AI **使用 `applebookscli`** 的运行说明，不是开发者设计文档。正文只保留会直接影响正确调用的内容：命令路由、`--help` 使用方式、stable selector、分页/JSON 结果解释，以及 state-changing 命令必要的授权、sync 与失败处理。
- 不在 Skill 复制架构、SQLite/schema、内部 owner/type、具体资源预算、实现历史、task/commit 或测试清单。某个内部边界只有在调用者不知道它就会误用 CLI 时才保留最短的用户可见规则；详细事实回到 `docs/index.md` 指向的 canonical owner。
- 新建 Skill 前先确认它有独立调用场景；已有 Skill 能覆盖就不要再建。创建或实质更新时遵循 `$skill-creator` 的最小化与渐进式披露原则，默认只维护必要的 `SKILL.md`，不为“文档齐全”新增 README/reference/changelog。
- 只有命令路由、selector、输出解释、写入/sync 或其它会改变 AI 调用方式的用户可见行为变化才触发 Skill 更新；纯内部实现、架构重构、schema/资源预算或测试变化不触发。中英文 AppleBooksCLI Skill 必须同步。修改后按 `$skill-creator` 运行 `quick_validate.ts`，并用 `scripts/ci-gates.sh` 验证 packaging/runtime contract。

## 开发与验证

- 在源码 checkout 中执行、测试或调用 CLI 前先 `swift build`，随后固定使用 `$(swift build --show-bin-path)/applebookscli`；不要混用 PATH 中可能更旧的全局安装版本，命令面以这个 binary 的 `--help` 为准。
- 按 blast radius 先跑 targeted tests；需要跨模块、capability、packaging、privacy、dependency 或完成级验证时使用仓库唯一 broad gate：`scripts/ci-gates.sh`。不要在 AGENTS 再维护一份机械测试清单。
- 独立产品行为必须在验证后原子提交，中文 commit message 直接写清“对象 + 行为结果”，例如 `批注查询改为游标分页`、`导出改用批注属性过滤`；不要使用“调整”“修复若干问题”“cleanup”这类无法从 message 判断行为边界的笼统描述。
- 一个 commit 只包含一个可独立审核、验证和回滚的产品行为；同一命令的必要 Core/CLI/tests/docs 更新放在同一 commit，不把无关命令顺手捆绑。真正不可分割的跨命令 contract（例如统一 output/pagination primitive）可以作为一个 cross-cutting commit，但必须在 message 中明确该 contract。
- feature plan 中每个实现 task 默认就是一个 commit boundary；完成 task 前先跑其 targeted verification，提交后再进入下一 task。phase 结束再跑相称的 broad gate / audit，不用“大提交 + 最后统一补测试”代替逐 task 验证。
- 真实 Apple Books mutation / CloudKit / UI integration 是显式 opt-in。fixture、state-machine、process test 或 current-Mac acknowledgement 不能被描述成真实用户数据端到端、第二设备 render 或 live UI 已验证。
