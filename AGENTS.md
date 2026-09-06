# AppleBooksCLI Repository Rules

## 开始前

- 本仓库是 Swift 6 / SwiftPM 项目，公开 `AppleBooksCore` library、`applebookscli` executable 和独立 `applebookscli-pdf-worker`。业务语义优先放在 Core；CLI 只负责 composition、参数/输出与 operation history。不要为了 CLI 特例静默改变公开 Core API 的既有语义。
- 在源码 checkout 中执行、测试或调用 CLI 前先运行 `swift build`，再固定使用 `$(swift build --show-bin-path)/applebookscli`。不要混用 PATH 中可能更旧的全局安装版本；命令和参数以这个 repo-local binary 的 `--help` 为准。
- 架构、能力、process、写安全和 release 的详细 owner 从 [`docs/index.md`](docs/index.md) 进入。AGENTS 只保存行动前 guardrail，不复制这些文档的实现细节。

## 数据、身份与依赖边界

- BKLibrary 与 AEAnnotation 是独立 store：分别发现、override、打开和管理 lifecycle。普通查询保持 SQLite read-only；optional read schema 可以降级，required write schema/entity 漂移必须 fail closed。发现多个数据库候选时不要按 mtime、文件名或猜测自动选一个。
- 精确操作优先 stable identity：book asset ID、annotation UUID、collection ID、backup handle。local primary key（PK / `Z_PK`）只属于当前本机 store；数字形式的 stable ID 不能被重新解释成 PK，多个合理候选也不能静默选第一项。
- `AppleBooksCore` 是 Apple Books 数据/content/export/mutation 的业务 owner。不要在 CLI 或其它 transport 层新增第二套 SQLite 查询/写入、EPUB/PDF resolver、cloud projection 或 operation-history 解析逻辑。`AppleBooksCloudBridge` 是当前唯一允许的非 Swift production runtime；不要改造成自建 Apple Books CloudKit client 或伪造 Apple identity/entitlement。
- EPUB 只消费当前可安全读取、已 materialized 的本地资源；不要主动 hydration iCloud placeholder，也不要绕过 DRM。supplemental EPUB / historical metadata 只能 enrichment/fallback，不能制造 current-library identity。PDFKit 保持隔离在独立 worker process，Core/CLI 只消费其 versioned protocol。
- export renderer 保持 DB-free，只消费上游 canonical DTO；所有导出/内容文件落盘继续经过统一 confinement/overwrite rail，不要绕过 `ExportFileWriter` 直接写用户目标。`--complete-notes` 是独立 completeness contract，失败时不能降级普通 export 后仍声称“完整”。详见 [`docs/architecture.md`](docs/architecture.md)。

## 写入、同步与恢复

- production mutation 只能走 guarded write rail；不要直接写 Apple Books SQLite，也不要在 writer/command 外围另造 Books.app lifecycle。`COMMIT` 是不可逆边界：commit 前失败可 rollback；commit 后 close/read-back/projection/ack/deeplink/restore failure 只能作为 committed warning，绝不能自动重放同一 mutation。
- 保持当前显式同步模型：普通 mutation = local commit + read-back + Apple-native cloud projection，不等待 acknowledgement；单条需要立即确认时显式 `--sync`；同一任务多条 mutation 可先全部本地提交，在本批至少一条 `changed=true` 后只调用一次根 `applebookscli sync`。本批全部 `changed=false` 时不要为了收尾调用 root sync，因为它会处理其它既有 pending records。no-op 不触发 projection、acknowledgement、service recycle 或 sync-only launch；current-Mac acknowledgement 也不等于另一台设备已显示。
- `MutationCoordinator` 拥有 normal mutation 的初始 `closed / background / frontmost` 快照与最终恢复；single-record synchronizer 只能报告自己实际拥有的 temporary launch。不要通过前后 `isRunning` 猜 ownership，也不要关闭用户自己打开或切到前台的 Books。
- writable scope 有意保持狭窄：不要把 current-reading/system annotation、system collection 或未知 schema “顺手支持”为可写。annotation 保持 note replacement / soft-delete，collection 保持当前 user-collection 与 membership guard。扩大 writable scope 必须先更新 safety contract 与对应 failure-path tests。
- safety backup / restore 使用受控 SQLite backup rail 和 opaque owned handle；不要把任意文件路径当 restore source。restore 一旦 apply，后续 verification/relaunch failure 同样只能表达为 applied-but-warning/unverified，不能自动重复 restore。完整顺序和例外只由 [`docs/write-safety.md`](docs/write-safety.md) 拥有。

## CLI process、history 与隐私

- 保持 [`docs/cli-contract.md`](docs/cli-contract.md) 的 stdout/stderr/JSON 边界：machine success/error 不能混入额外 human 文本，默认错误和 mutation 输出不能反射用户正文、私有 SQLite payload 或绝对路径。
- annotation/collection mutation、backup restore 与 root sync 这些 recordable command 必须在 dispatch 前成功记录 history `started`；这一步失败就不能执行目标操作。completion history 写入发生在 command outcome 之后，失败只能额外 warning，不能改变原 exit status 或 machine stdout。`incomplete` 表示 outcome unknown，不是重放授权。
- 测试 fixture、文档和提交历史只能使用 synthetic/repository-owned 数据。严禁提交真实用户书名、asset ID、annotation UUID/CFI、笔记正文或本机私有绝对路径；`scripts/check-private-data.swift` 会检查当前 tracked 内容和 Git history。

## Capability、依赖、文档与发布

- 用户可见 capability 变化必须同步 [`docs/capability-matrix.md`](docs/capability-matrix.md) 和 `Tests/Fixtures/Parity/capability-anchors.json`；每个“已实现”能力都必须继续指向真实 implementation path、executable test 和 CLI help reachability。不要只改 matrix 文案或只改 help。
- 长期文档按 [`docs/index.md`](docs/index.md) 的唯一 owner 更新；命令参数不在 Markdown 复制 help snapshot。`.github/features/` 的 plan/audit/todo 是实施历史，不是当前产品 truth；superseded audit 不能覆盖当前源码、tests 与 canonical docs。dated schema baseline 只记录当时只读观测，不用新实现反向改写历史 baseline。
- 修改 SwiftPM dependency 时同时维护 `Package.swift` / `Package.resolved`、`THIRD_PARTY_NOTICES.md` 与对应 `ThirdPartyLicenses/`；canonical CI 会与 checkout 中 upstream license 做精确比对。
- `dist/` 是生成/忽略的发布产物，不作为源码手工维护。release version/channel/package/publication 只按 [`docs/release.md`](docs/release.md)、`.github/workflows/release.yml` 和 `scripts/*release*` 的现有 owner 修改；不要建立第二套 release gate。

## 验证

- 先按 blast radius 跑最小 targeted tests；跨模块、capability、packaging、privacy、dependency 或完成级验证使用唯一 broad gate：`scripts/ci-gates.sh`。不要在 AGENTS 维护第二份机械测试清单。
- `CapabilityParityTests` / `CLICapabilityReachabilityTests` 是 capability 文档与真实实现的机械一致性 gate；改 capability/command surface 时必须覆盖。
- 真实 Apple Books mutation / CloudKit / UI 行为的 live integration 是显式 opt-in。fixture、state-machine、process test 或 current-Mac acknowledgement 不能被描述成真实用户数据端到端、第二设备 render 或 live UI 已验证。
