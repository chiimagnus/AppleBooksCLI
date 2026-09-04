# AppleBooksCLI 文档索引

这里维护 AppleBooksCLI 的长期文档拓扑。实施计划、审计与一次性迁移证据属于 `.github/features/`，不进入长期产品文档；具体命令参数以当前 `applebookscli --help` 为准。

## 文档 owner

| 文档 | Audience / Job | Edit trigger | 主要 evidence / consumer |
| --- | --- | --- | --- |
| [`../README.md`](../README.md) / [`../README.zh.md`](../README.zh.md) | 最终用户英文/中文入口：产品用途、安装、快速开始、常见任务、Skill、可选配置、平台限制与 license | 安装方式、用户入口、常见任务、语言版本或顶层产品定位变化；两份 README 的产品事实应保持一致 | installed CLI / npm package |
| [`capability-matrix.md`](capability-matrix.md) | 用户与维护者：**当前能力范围与明确不支持项的唯一 owner** | 新增、删除或改变用户可见 capability / safety boundary | `CapabilityParityTests`、`CLICapabilityReachabilityTests`、`capability-anchors.json` |
| [`architecture.md`](architecture.md) | 维护者：跨模块数据流、identity、source、分层与非目标 | DB/source/identity、Core↔CLI↔worker、config、export ownership 变化 | `Sources/**` + 对应 executable tests |
| [`cli-contract.md`](cli-contract.md) | CLI/自动化调用方：process exit、stdout/stderr、JSON error contract | exit code、JSON envelope、parse/help/version/completion 行为变化 | `CLIEntrypoint`、`CLIError`、output/contract tests |
| [`write-safety.md`](write-safety.md) | 维护者与高风险调用方：mutation/backup/restore/lifecycle/cloud-sync 的唯一安全顺序 owner | writable scope、schema guard、backup/restore、Books lifecycle、cloud rail、irreversible result 变化 | mutation/restore/cloud implementation + tests/live gates |
| [`release.md`](release.md) | 维护者：release version、channel、tag preflight 与 publication pipeline 的唯一 owner | tag/version、channel、CI gate、npm/GitHub publication 或 release artifact 变化 | `.github/workflows/release.yml`、`scripts/build-release.sh`、release metadata/order tests |
| [`macos-27-schema-baseline.md`](macos-27-schema-baseline.md) | 维护者：一个**带日期和系统版本作用域**的实机 schema/behavior 观测 | 需要建立新的 macOS baseline 时新增/更新明确的采样记录；不能因产品实现变化自动改写历史观测 | 只读实机 schema sampling；不是产品 contract |

## 运行时与发布输入

这些 Markdown 不是普通说明页，修改会进入产品或发布产物：

| 文件 | Owner / consumer | Edit trigger |
| --- | --- | --- |
| [`../skills/applebookscli/SKILL.md`](../skills/applebookscli/SKILL.md) / [`../skills/applebookscli-zh/SKILL.md`](../skills/applebookscli-zh/SKILL.md) | 仓库发布的英文/中文 Agent Skill；英文 README 默认英文 Skill、中文 README 默认中文 Skill，Agent 路径由 Agent Skills CLI 负责 | CLI workflow、安全边界、语言版本或 Skill 内容变化；两份 Skill 的 CLI 契约与版本必须保持一致，并分别跑 canonical validator/packaging smoke |
| [`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md) | release archive / license provenance | `Package.swift` / `Package.resolved` 的实际 dependency/version/revision/license 变化 |

## 事实归属规则

- **能力有没有**：只改 `capability-matrix.md`，不要在 index/architecture 再维护第二份 checklist。
- **命令怎么拼**：以 `--help` 为准；长期文档只记录跨命令仍需稳定的语义。
- **mutation / restore 顺序**：只改 `write-safety.md`；architecture 只链接，不复制 ceremony。
- **稳定 identity / source / export 分层**：由 `architecture.md` 拥有。
- **当前用户安装入口**：由 `README.md` / `README.zh.md` 共同拥有并保持产品事实一致；**release version/channel/tag preflight/publication pipeline** 由 `release.md` 拥有。Git tag 仍是 release version 的唯一执行 owner，具体历史不复制进 docs。
- **一次机器上的 schema 事实**：放 dated baseline，并明确 evidence scope；不能把 observed shape 自动升级为跨版本保证。
- **机械验证命令**：由 tests、scripts、workflows 拥有；文档只说明何种变化应触发哪类验证，不复制整套 CI。

## 更新文档时

先核对当前 source/test/runtime 事实，再修改其 canonical owner。若一个事实需要在多页出现，非 owner 页面只保留一句边界说明和链接。任何页面开始出现 phase、todo、迁移 commit、候选命令树或大段 source struct 镜像，都应先判断这些内容是否已经变成过时实施历史。
