---
name: applebookscli
description: 在 macOS 上读取、定位、导出或受保护地修改 Apple Books 图书、阅读状态、EPUB/PDF、批注笔记与藏书，以及处理批注 deep link、备份恢复和访问诊断时使用。
---

# AppleBooksCLI

使用已安装的 `applebookscli` 作为 Apple Books 数据操作的唯一入口。用户问自己的数据时必须实际查询，不能用能力说明代替真实结果。命令和参数以当前 `applebookscli <group> [<subcommand>] --help` 为唯一契约；需要时现查，结构化判断优先 `--json`。

## 工作流

1. **先解析目标**：优先 book asset ID、annotation UUID、collection ID、backup handle。标题、作者、名称只是搜索条件；先 search/list，唯一匹配后再继续。local PK 只在没有稳定 identity 或用户明确指定时使用。用户说“当前这本书”时优先复用对话中已解析的 book；否则 `reading recent --limit 1 --json` 只能作为候选。
2. **选最窄命令**：图书/阅读/统计用 `books`、`reading`、`stats`；高亮笔记用 `annotations`；EPUB 用 `content`；PDF 用 `pdf`；导出用 `export`；collection 与 restore 用各自命令。`doctor` 只在诊断请求或实际出现 permission / unavailable / schema readiness 问题时使用。
3. **具体 annotation**：用户问“最新笔记”时只比较 `note` 非空项；“最新”默认按创建时间，“最近修改”按修改时间。展示单条 annotation 时给高亮、note、必要时间，并把 CLI 返回的 `appleBooksURL` 一并提供；不要自行拼 `ibooks://`。只有需要前后正文时才用 `content context`。
4. **写 Note**：`annotations update-note` 是整段替换，不是 append。用户要求追加/评论时，先读取原 note，保留原文构造完整新 note，再用 exact UUID + `--json` 写回。
5. **判断写入结果**：`committed=true` 表示已提交，不因 warning 自动重试；`changed=false` 是成功的幂等 no-op；`read_back_failed` 或调用结果未知时先做最窄只读确认，再决定是否还需写入。CLI 生成的 safety backup 默认保留。
6. **导出/恢复**：普通导出默认不覆盖已有文件；完整笔记归档必须使用 `--complete-notes`，校验失败就停止。Restore 只在用户明确要求时执行；`restored_unverified` 表示恢复已应用但验证失败，不能自动再 restore。

## 边界

- 不直接读写 Apple Books SQLite，不绕过 CLI 重做 mutation、backup/restore、EPUB/CFI、PDF 或 export 逻辑，也不要额外手工 quit/launch Books.app。
- EPUB 正文不可用时，只有需要解释原因才运行 `content status --json`；不要绕过 DRM/encryption 或主动触发下载。PDF worker failure/timeout 与“成功但没有 highlights”要区分。
- 自定义 DB/config override 只用于用户明确指定或 fixture/test，不作为故障 fallback。
- 本地 mutation 成功不等于已经同步到 iCloud；没有另一设备或其它端到端证据时，只能确认本地 Apple Books 状态。
- 不把 exit 0 当成任务完成；empty、not found、unavailable、degraded、warning 分别报告，并只返回用户真正需要的结果。
