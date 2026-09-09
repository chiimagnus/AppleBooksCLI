# AppleBooksCLI 文档索引

长期文档只保存当前契约与维护边界；实施计划/审计留在 `.github/features/`，命令参数以 `applebookscli --help` 为准。

## Canonical owners

| 文档 | 唯一职责 | 何时更新 |
| --- | --- | --- |
| [`README.md`](../README.md) / [`README.zh.md`](../README.zh.md) | 用户入口：安装、快速任务、关键限制、导航 | 安装/入口/核心用户工作流变化 |
| [`capability-matrix.md`](capability-matrix.md) | 当前能力与明确不支持项 | 用户可见 capability/safety boundary 变化 |
| [`architecture.md`](architecture.md) | store/source/identity/ownership 与长期资源边界 | 数据源、identity、Core↔CLI、content/export/cloud ownership 或 hard resource budget 变化 |
| [`cli-contract.md`](cli-contract.md) | process exit/stdout/JSON/cursor/doctor/history contract | process protocol、cursor/doctor presentation 或 history persistence/read 变化 |
| [`write-safety.md`](write-safety.md) | mutation/backup/restore/lifecycle/cloud 顺序与不可逆边界 | write rail、restore、Books lifecycle、cloud sync 变化 |
| [`release.md`](release.md) | version/channel/tag/publication | release pipeline 或 version injection 变化 |
| [`macos-27-schema-baseline.md`](macos-27-schema-baseline.md) | 2026-08-30 macOS 27 只读 schema 观测 | 只在建立新的明确版本 baseline 时更新/新增 |

## Runtime / release Markdown

- [`../AGENTS.md`](../AGENTS.md)：仓库级行动前 guardrail；全仓 posture、不可破坏边界、canonical owner 路由或验证入口变化时更新。
- [`../skills/applebookscli/SKILL.md`](../skills/applebookscli/SKILL.md) 与 [`../skills/applebookscli-zh/SKILL.md`](../skills/applebookscli-zh/SKILL.md)：Agent 实际执行规则；只有命令路由、selector、输出解释、写入/sync 等会改变 AI 调用方式的行为变化才双语同步，纯内部实现变化不触发；机械验证由 canonical `scripts/ci-gates.sh` 覆盖 Skill packaging checks。
- [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md)：依赖许可证 provenance；只随实际 dependency/license 变化更新。

## Ownership rules

- capability 是否存在 → `capability-matrix.md`
- 命令参数 → `--help`
- write/restore 顺序 → `write-safety.md`
- store/source/identity/分层 → `architecture.md`
- process protocol/history → `cli-contract.md`
- release → `release.md`
- dated schema observation →对应 baseline，不把历史观测升级成产品 contract
- mechanical test/gate 列表 → tests/scripts/workflows，不在 Markdown 复制

一个事实若必须在非 owner 页面出现，只保留最短摘要并链接 owner；phase、todo、commit、源码结构镜像不进入长期文档。
