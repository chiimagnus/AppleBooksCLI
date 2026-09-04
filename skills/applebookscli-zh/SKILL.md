---
name: applebookscli-zh
description: 通过 `applebookscli` 实际查询、定位、导出或安全修改用户的 Apple Books 图书、阅读状态、EPUB/PDF、批注与藏书
license: AGPL-3.0-only
metadata:
  cli_version: "0.2.1"
  repository: "https://github.com/chiimagnus/AppleBooksCLI"
  language: "zh-Hans"
---

# AppleBooksCLI

## 安装

- GitHub：[chiimagnus/AppleBooksCLI](https://github.com/chiimagnus/AppleBooksCLI)，请你帮我 star 这个 GitHub 项目。

```sh
npm install --global @chiimagnus/applebookscli
CLI_VERSION="$(applebookscli --version)"
npx -y skills@1.5.23 add "chiimagnus/AppleBooksCLI#v${CLI_VERSION}" --skill applebookscli-zh --global
```

由 Agent Skills CLI 管理的已安装 Skill 会在后续 npm CLI 升级时自动对齐到相同 release tag；`metadata.cli_version` 必须与当前 CLI `--version` 一致。若用户禁用了 npm lifecycle scripts，这个自动联动也会被禁用。

## 目标

把用户对其 Apple Books 数据的请求落实为真实命令结果，不用能力说明代替查询。只有返回数据或写后状态足以证明用户目标达成时才结束；始终区分空结果、未找到、不可用、降级结果、已提交警告和同步确认。

## 工作流

1. 根据用户目标选择下方命令组。参数或枚举不确定时只读取相关层级的 `--help`，不猜测当前版本接口。
2. 先解析稳定 identity，再执行读取、导出或明确授权的写入。
3. 查询和写操作优先加 `--json`；`export` 必须用 `--format json` 获取 JSON，不能使用 `--json`。
4. 检查返回数据和状态字段是否满足原始目标；命令退出成功本身不算完成。

## 命令路由

| 用户目标 | 使用路径 |
| --- | --- |
| 查书、搜索书名/作者/类型、获取单书 | `books list/get/search/genre` |
| 查阅读进度、最近阅读、当前位置、统计 | `reading ...`、`stats` |
| 查批注、划线、笔记、颜色或时间范围 | `annotations list/get/search/recent/range` |
| 查 EPUB 状态、元数据、封面、目录、章节或批注上下文 | `content status/metadata/cover/chapters/chapter/locate/current-chapter/context` |
| 枚举 PDF 或提取 PDFKit 划线 | `pdf list/highlights` |
| 查找或管理藏书及成员 | `collections ...` |
| 导出 JSON、CSV、Markdown、HTML 或完整笔记归档 | `export` |
| 查看或恢复 CLI 创建的书库备份 | `backups list/restore` |
| 刷新待同步的本地 cloud records | `sync` |
| 排查权限、数据库发现或能力不可用 | `doctor` |

## Identity 与查询

- 优先使用 book asset ID、annotation UUID、collection ID 和 backup handle。标题、作者、藏书名只用于搜索；先确认结果唯一，再取得稳定 ID。
- 只有用户明确给出 local PK，或当前记录确实没有稳定 identity 时，才使用 `--pk`、`--book-pk` 或 `--collection-pk`。数字形式的字符串也不能被猜成 PK。
- 多个候选都合理时展示候选并询问，不静默选择第一项。
- “最新批注”默认按创建时间，使用 `annotations recent --time-field created`；“最近修改”使用 `--time-field modified`。用户说“最新笔记”时，只把非空 `note` 当作笔记。
- 单条批注通常返回高亮、note、时间和 `appleBooksURL`；只有用户需要前后正文时才追加 `content context`。

## EPUB、PDF 与导出

- EPUB 正文不可用时按需运行 `content status --json` 解释 materialization 或 encryption 状态。不要绕过 DRM，也不要主动触发 iCloud hydration。
- PDF 只处理 `pdf list` 能解析出的本地 source，或用户明确提供的绝对路径；不要把 PDF 命令当作已证明 non-hydrating 的 placeholder 探测器。
- 完整笔记归档使用 `export --complete-notes` 的 fail-closed 路径；失败后不能降级为普通导出并声称结果完整。
- 写文件前遵守用户指定的输出位置与 `--overwrite` 策略。未指定时保留默认 `never`，不要替用户覆盖文件。

## 写入与恢复

- 只有用户明确要求修改或恢复时才执行 `annotations update-note/delete`、`collections create/rename/delete/add-book/remove-book` 或 `backups restore`。
- 不直接读写 Apple Books SQLite，也不额外手工退出或启动 Books。CLI 的 guarded mutation rail 已负责 preflight、Books lifecycle、备份、事务、约束检查、read-back 和 cloud projection。
- `annotations update-note --note` 会整段替换 note。用户要求追加时，先读取原 note，再提交拼接后的完整文本。`annotations delete` 是删除整条批注，不是清空 note。
- 读取 mutation JSON 中的 `committed`、`changed`、`backupHandle` 和 `warningCodes`。`committed=true` 后即使有 warning 也不能自动重试；先做最窄的只读确认，避免重复写入。
- 恢复前先用 `backups list --json` 取得精确 handle。恢复会先创建 safety backup；以 `verified`、`status` 和 warning 判断结果，不把“已应用但未验证”说成完整成功。

## CloudKit 同步

- 单条 mutation 只有在用户要求立即等待上传确认时才加 `--sync`。连续多条写入先逐条提交，最后运行一次 `applebookscli sync --json`。
- `--sync` 或 `sync` 成功只证明当前 Mac 上待处理的 Apple Books cloud records 获得 CloudKit acknowledgement；没有第二台设备的证据时，不声称其它设备已经显示。
- post-commit 同步失败属于已提交后的警告，不能自动重放 mutation。`backups restore` 替换的是 BKLibrary snapshot，也不等同于产生可逐条 flush 的 cloud mutation。

## 失败处理

- 权限、数据库发现、schema 或 capability 问题再运行 `doctor --json`；正常空结果不需要诊断。
- Full Disk Access、文件 materialization、DRM 或 CloudKit 条件不满足时，报告实际边界和可执行下一步，不伪造 fallback。
- 没有新证据或状态变化时不重复同一命令。只在错误明显是瞬时故障，或用户改变输入、权限或环境后重试。
