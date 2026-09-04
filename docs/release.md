# AppleBooksCLI 发布流程

> Audience：维护者。本文是 release version、channel、tag preflight 与 GitHub Actions 发布路径的长期 owner。用户安装入口留在 README；具体实现以 `.github/workflows/release.yml`、`scripts/release-metadata.sh`、`scripts/check-release-order.mjs` 与 `scripts/build-release.sh` 为最终执行证据。

## Version owner

Git tag 是 release version 的产品 owner。`skills/applebookscli/SKILL.md` 的 `metadata.cli_version` 必须在打 tag 前更新为同一版本；release build 会拒绝不一致的 tag。

- stable：`vMAJOR.MINOR.PATCH`，发布到 npm `latest`，并创建普通 GitHub Release。
- beta：`vMAJOR.MINOR.PATCH-beta` 或 `vMAJOR.MINOR.PATCH-beta.N`，发布到 npm `beta`，并创建 GitHub prerelease。
- 普通开发构建的 `applebookscli --version` 为 `dev`；release binary 的版本由对应 tag 注入。

## Tag preflight

Release workflow 只接受指向 `main` 历史的 release tag，并在构建前验证：

1. 该 SHA 已有成功的 `ci.yml` push run；
2. GitHub 中不存在相同 Release；
3. candidate version 满足 stable/beta 的单调发布顺序。

因此不要用 release workflow 代替 CI，也不要在没有 exact-SHA CI success 时提前打 tag。

## Publication pipeline

推送 `v*` tag 后，`.github/workflows/release.yml` 负责：

1. 解析 release metadata 与 channel；
2. 执行上述 preflight；
3. 调用 `scripts/build-release.sh` 构建一次正式 arm64 npm package；
4. 验证 binary、package metadata 与 npm install smoke；
5. 为 release asset 生成 GitHub attestation；
6. 按 channel 发布 `@chiimagnus/applebookscli` 到 npm；
7. 创建对应 GitHub Release，并上传同一个 `.tgz` asset。

Release workflow 不重复执行完整测试套件；完整测试属于 tag 所指 exact SHA 的 CI gate。`skills/applebookscli` 随 GitHub source/tag 发布，不进入 npm tarball；首次安装仍由 Agent Skills CLI 选择目标 Agent。npm 包只携带一个 postinstall bridge：如果发现 Agent Skills CLI 已管理该 Skill，就把其 source ref 对齐到当前 CLI tag，再委托 `skills update` 更新现有 targets；没有已管理 Skill 时静默跳过。

## 修改触发

以下变化必须同步检查本文：

- tag/version 语法；
- stable/beta channel 或 npm dist-tag；
- exact-SHA CI gate；
- npm/GitHub publication 顺序；
- release artifact、attestation 或 package architecture；
- version injection 方式。
