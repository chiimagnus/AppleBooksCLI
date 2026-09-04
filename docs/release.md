# AppleBooksCLI 发布流程

> Audience：维护者。本文是 release version、channel、tag preflight 与 GitHub Actions 发布路径的长期 owner。用户安装入口留在 README；具体实现以 `.github/workflows/ci.yml`、`.github/workflows/release.yml`、`scripts/ci-gates.sh`、`scripts/release-metadata.sh`、`scripts/check-release-order.mjs` 与 `scripts/build-release.sh` 为最终执行证据。

## Version owner

Git tag 是 release version 的产品 owner。英文 `skills/applebookscli/SKILL.md` 与中文 `skills/applebookscli-zh/SKILL.md` 的 `metadata.cli_version` 必须在打 tag 前一起更新为同一版本；release build 会拒绝任一 Skill 与 tag 不一致。

- stable：`vMAJOR.MINOR.PATCH`，发布到 npm `latest`，并创建普通 GitHub Release。
- beta：`vMAJOR.MINOR.PATCH-beta` 或 `vMAJOR.MINOR.PATCH-beta.N`，发布到 npm `beta`，并创建 GitHub prerelease。
- 普通开发构建的 `applebookscli --version` 为 `dev`；release binary 的版本由对应 tag 注入。

## Tag preflight

Release workflow 只接受指向 `main` 历史的 release tag，并在构建前验证：

1. GitHub 中不存在相同 Release；
2. candidate version 满足 stable/beta 的单调发布顺序；
3. tag checkout 通过与 PR 相同的 `scripts/ci-gates.sh` 完整 gate。

普通 `main` push 不运行 CI；PR 由 `.github/workflows/ci.yml` 执行共享 gate，release tag 由 `.github/workflows/release.yml` 在发布前执行同一 gate。

## Publication pipeline

推送 `v*` tag 后，`.github/workflows/release.yml` 负责：

1. 解析 release metadata 与 channel，并执行 publication preflight；
2. 运行 `scripts/ci-gates.sh` 完整 gate；
3. 调用 `scripts/build-release.sh` 构建一次正式 arm64 npm package；
4. 验证 binary、package metadata 与 npm install smoke；
5. 为 release asset 生成 GitHub attestation；
6. 按 channel 发布 `@chiimagnus/applebookscli` 到 npm；
7. 在有上限的重试窗口内确认该精确 npm version 已可查询，且目标 `latest` / `beta` dist-tag 已指向该版本；
8. 创建对应 GitHub Release，并上传同一个 `.tgz` asset。

`npm publish` 返回成功只表示 registry 已接受该 publication；新版本和 dist-tag 可能仍有短暂传播/处理窗口。因此 workflow 必须在创建 GitHub Release 前读回 npm registry，并同时确认精确 version 与本次 channel 对应的 dist-tag。超过有上限的验证窗口仍不可见时，workflow fail closed，不创建一个 npm 尚不可验证的 GitHub Release。

英文 `skills/applebookscli` 与中文 `skills/applebookscli-zh` 随 GitHub source/tag 发布，不进入 npm tarball；README 分别提供对应语言的最短安装命令，目标 Agent 仍由 Agent Skills CLI 负责。npm 包只携带一个 postinstall bridge：如果发现 Agent Skills CLI 已管理其中任一语言版本，就把已安装版本的 source ref 对齐到当前 CLI tag，再委托 `skills update` 更新现有 targets；没有已管理 Skill 时静默跳过。

## 修改触发

以下变化必须同步检查本文：

- tag/version 语法；
- stable/beta channel 或 npm dist-tag；
- PR / release tag 的共享 CI gate；
- npm/GitHub publication 顺序；
- release artifact、attestation 或 package architecture；
- version injection 方式。
