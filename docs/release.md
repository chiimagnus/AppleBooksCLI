# AppleBooksCLI 发布流程

> release version、channel、tag preflight 与 publication ordering 的长期 owner。执行真源是 `.github/workflows/release.yml` 与 `scripts/*release*` / `scripts/ci-gates.sh`。

## Version / channel

Git tag 是 release version owner：

- stable：`vMAJOR.MINOR.PATCH` → npm `latest` → normal GitHub Release
- beta：`vMAJOR.MINOR.PATCH-beta[.N]` → npm `beta` → GitHub prerelease
- 非 release build 的 CLI version 为 `dev`

双语 Skill 的 `metadata.cli_version` 必须与 release tag 一致；release build 会校验。

## CI / preflight

`.github/workflows/ci.yml` 在 PR 和 `main` push 上运行同一套 `scripts/ci-gates.sh`。`main` 的 exact-SHA run 是发布依据；Release 不再重复执行完整测试。

Release tag 必须指向当前 `origin/main` HEAD，并且：

1. 该 SHA 的 `main` push CI 已成功；若 tag 紧跟 merge 推送，Release 会有上限地等待该 CI 完成；
2. 同名 GitHub Release 尚不存在；
3. version 满足 stable/beta 单调发布顺序。

CI 缓存 `.build`，减少相邻提交重复编译；测试、privacy、Skill、license 与 diff gate 仍由 `scripts/ci-gates.sh` 统一拥有。

## Publication ordering

Release workflow 按职责拆成三个 job：

1. `prepare`：解析 metadata/channel，验证 tag + exact-SHA CI + publication state，只构建一次并 smoke-test arm64 npm package；
2. `publish-npm`：下载上述 artifact，只负责 `npm publish` 到对应 dist-tag；
3. `github-release`：仅在 npm job 成功后下载同一 artifact，生成 attestation 并创建 GitHub Release。

不再在 Release 中重复完整 CI，也不在 `npm publish` 成功后轮询 registry read-back。GitHub Release 只依赖 npm publish 命令本身成功。

Skill 随 GitHub source/tag 发布，不进入 npm tarball。npm postinstall 只在发现 Agent Skills CLI 已管理对应 Skill 时对齐 release tag并委托其更新；否则静默跳过。

## Edit trigger

仅在 tag/version 语法、channel/dist-tag、shared CI gate、artifact/architecture/attestation、publication ordering 或 version injection 变化时更新本文。
