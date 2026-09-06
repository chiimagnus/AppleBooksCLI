# AppleBooksCLI Repository Rules

## 本地开发调用

- 在本仓库源码 checkout 中执行、测试或调用 AppleBooksCLI 前，先运行 `swift build`，再用 `$(swift build --show-bin-path)/applebookscli` 解析并固定使用当前 checkout 的最新编译产物。不要混用 PATH 中可能更旧的全局安装版本。

## 不可破坏的产品边界

- 不要把普通 mutation 改成默认逐条等待 iCloud acknowledgement。普通 mutation 只做 local commit + cloud projection；单条需要立即确认时显式使用 `--sync`，同一任务的多条 mutation 应全部本地提交后只调用一次根 `applebookscli sync`。完整顺序与例外由 [`docs/write-safety.md`](docs/write-safety.md) 拥有。
- `COMMIT` 后的 warning 不能触发同一 mutation 自动重放。需要确认结果时先做最窄的只读检查；restore、Books lifecycle、schema guard 与 CloudKit evidence boundary 同样以 [`docs/write-safety.md`](docs/write-safety.md) 为唯一详细 owner。
- 不新增绕过 `AppleBooksCore` / guarded mutation rail 的第二套 Apple Books SQLite、cloud、EPUB/PDF 或 operation-history 业务路径。跨模块 ownership 与 identity 边界见 [`docs/architecture.md`](docs/architecture.md)。

## 文档与验证 owner

- 长期文档归属从 [`docs/index.md`](docs/index.md) 开始；用户可见 capability 变化更新 [`docs/capability-matrix.md`](docs/capability-matrix.md)，process/history contract 更新 [`docs/cli-contract.md`](docs/cli-contract.md)，release 规则更新 [`docs/release.md`](docs/release.md)。命令参数以当前 repo-local `applebookscli --help` 为准，不在 Markdown 复制 help 快照。
- broad verification 使用仓库唯一机械入口 `scripts/ci-gates.sh`；按改动风险先跑针对性测试，再在需要完整 gate 时运行该脚本，不在 AGENTS 维护第二份测试清单。
