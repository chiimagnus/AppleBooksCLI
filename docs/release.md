# AppleBooksCLI 发布流程

> release version、channel、tag preflight 与 publication ordering 的长期 owner。执行真源是 `.github/workflows/release.yml` 与 `scripts/*release*` / `scripts/ci-gates.sh`。

## Version / channel

Git tag 是 release version owner：

- stable：`vMAJOR.MINOR.PATCH` → npm `latest` → normal GitHub Release
- beta：`vMAJOR.MINOR.PATCH-beta[.N]` → npm `beta` → GitHub prerelease
- 非 release build 的 CLI version 为 `dev`

双语 Skill 的 `metadata.cli_version` 必须与 release tag 一致；release build 会校验。

## Preflight

Release tag 必须位于 `main` 历史，并且：

1. 同名 GitHub Release 尚不存在；
2. version 满足 stable/beta 单调发布顺序；
3. checkout 通过共享 `scripts/ci-gates.sh`。

PR CI 与 release 共用该 canonical gate；普通 `main` push 不单独运行 CI。

## Publication ordering

Release workflow 依次：

1. 解析 metadata/channel 并做 preflight；
2. 运行 CI gate，构建并 smoke-test arm64 npm package；
3. 为 release asset 生成 attestation；
4. `npm publish` 到对应 dist-tag，并 bounded read-back 验证 exact version + dist-tag；
5. npm 可验证后才创建 GitHub Release 并上传同一个 `.tgz`。

`npm publish` 成功不等于 registry 已可查询；bounded verification 失败时 fail closed，不创建 GitHub Release。

Skill 随 GitHub source/tag 发布，不进入 npm tarball。npm postinstall 只在发现 Agent Skills CLI 已管理对应 Skill 时对齐 release tag并委托其更新；否则静默跳过。

## Edit trigger

仅在 tag/version 语法、channel/dist-tag、shared CI gate、artifact/architecture/attestation、publication ordering 或 version injection 变化时更新本文。
