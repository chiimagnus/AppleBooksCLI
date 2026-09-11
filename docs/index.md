# AppleBooksCLI 文档索引

长期文档只保存当前契约与维护边界。命令参数以 `applebookscli --help` 为准；`.github/features/**` 只保留实施/审计历史，不是当前产品真源。

## Canonical owners

| 文档 | 唯一职责 | 何时更新 |
| --- | --- | --- |
| [`README.md`](../README.md) / [`README.zh.md`](../README.zh.md) | 用户入口：安装、常用任务、关键限制、导航 | 安装、支持平台或核心用户工作流变化 |
| [`capability-matrix.md`](capability-matrix.md) | 当前用户可见能力与明确不支持项 | capability、selector/output 语义或用户可见限制变化 |
| [`architecture.md`](architecture.md) | store/source/identity、Core↔CLI ownership 与长期资源边界 | 数据源、identity、分层、content/PDF/export ownership 或 hard budget 变化 |
| [`cli-contract.md`](cli-contract.md) | process exit/stdout/stderr/JSON/cursor/doctor/history contract | process protocol、cursor、doctor 或 history 行为变化 |
| [`write-safety.md`](write-safety.md) | mutation/backup/restore/Books lifecycle/cloud 边界 | write rail、restore、sync、replay 或 post-COMMIT 语义变化 |
| [`release.md`](release.md) | version/channel/tag/publication | release pipeline、version injection 或 publication ordering 变化 |
| [`macos-27-schema-baseline.md`](macos-27-schema-baseline.md) | 2026-08-30 macOS 27 的只读 schema 观测 | 旧 baseline 不改写；新系统版本另建 dated baseline |

## Runtime / governance Markdown

- [`../AGENTS.md`](../AGENTS.md)：维护者/Agent 动手前必须看到的仓库 guardrail 与 owner 路由。
- [`../skills/applebookscli/SKILL.md`](../skills/applebookscli/SKILL.md) / [`../skills/applebookscli-zh/SKILL.md`](../skills/applebookscli-zh/SKILL.md)：AI 调用 CLI 所需的最小运行规则；命令路由、selector、分页、写入/sync 行为变化时双语同步。
- [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)：依赖版本与许可证 provenance；仅随实际 dependency/license 变化更新。
- [`../.github/PULL_REQUEST_TEMPLATE.md`](../.github/PULL_REQUEST_TEMPLATE.md)：收集 reviewer 需要的变更、风险与验证证据，不重新定义 contract。

## 维护规则

同一事实只保留一个详细 owner；其它页面最多保留行动前必须知道的摘要并链接回 owner。机械测试/gate 列表由 tests/scripts/workflows 拥有，不在 Markdown 手抄；源码结构、phase/todo/commit 历史也不进入长期文档。
