---
name: applebookscli
description: 在 macOS 上需要使用已安装的 applebookscli 访问本机 Apple Books 数据，或执行其受保护写入与备份恢复时使用。
---

# AppleBooksCLI

使用已安装的 `applebookscli` 作为 Apple Books 数据操作的唯一执行入口。需要精确命令或参数时读取对应 `applebookscli <group> [<subcommand>] --help`；不要在 Skill 中维护第二份命令手册。

## 按任务选择路径

- **查询**：书籍、阅读状态、统计、批注和 collection 直接使用对应只读命令。普通查询不要机械先跑 `doctor`；只有用户本来就在诊断，或实际返回 permission / unavailable 时，再用 `doctor --json` 定位环境条件。用户只给标题、名称等展示文本时，先 search/list；只有唯一匹配后才把稳定 identity 传给后续命令，不静默选择多个候选中的第一项。向用户展示一条已经唯一解析的具体 annotation（高亮或带 note 的笔记）时，优先使用 `annotations get --json` 或已有的等价单条结果；若 CLI 返回 `appleBooksURL`，一并提供给用户作为 Apple Books 一键跳转入口。不要在 Skill 中自行拼接 `ibooks://`，也不要为了生成该链接额外调用 `content locate`。
- **EPUB / PDF**：先解析 exact book/source，再直接调用完成请求所需的最窄 content/PDF 命令；只有需要解释 EPUB 为什么不可用时才用 `content status --json` 诊断 materialization、DRM/encryption 或 not-downloaded。不可用时按结果报告，不自行绕过或触发额外下载。PDF 没有 exact book/path 时先 `pdf list --json` 解析唯一 source；worker failure 与“没有 highlights”是不同结果。
- **导出**：先确定用户要求的范围、格式和输出目标，再运行 `export`。用户没有要求覆盖时保持 no-clobber，不因为文件已存在就自行升级 overwrite policy。“完整笔记归档”必须使用 complete-notes 路径；安全或完整性校验失败时停止并报告，不能降级成普通 export 后声称归档完整。
- **写入**：只有用户明确要求 annotation 或 collection 变更时才执行 mutation。涉及既有对象时先只读解析 exact target，并用 `--json` 执行写命令。以 `committed` / `changed` 判定结果；已 committed 的操作不能因后续 warning 自动重试，`changed=false` 是成功的幂等 no-op。只有 CLI 报 read-back warning，或返回值仍不足以证明用户要求的最终状态时，才补一条最窄只读确认。
- **Restore**：只在用户明确要求时执行，不作为普通 mutation 的自动 fallback。用户给了 exact backup handle 就直接使用，否则先 `backups list --json` 解析唯一目标，并用 `--json` 执行 restore。以 `changed` / `status` 判定结果；`changed=true` 或 `restored_unverified` 都不能自动再 restore。只有返回状态仍不足以证明用户要求的最终结果时，才补最窄只读检查。

## 硬规则

- 不直接读写 Apple Books SQLite，也不自行复制 backup/restore、EPUB/CFI、PDF 或 export 逻辑来绕过 CLI；写入/restore 时也不要额外手工 quit/launch Books.app。
- 优先使用稳定 identity：book asset ID、annotation UUID、collection ID、backup handle；local PK 只在没有稳定 identity 或用户明确指定时使用。
- 只读取完成请求所需的最小内容；不要为了预检扩大 EPUB/PDF 正文或批注范围。
- 自定义 DB/config override 只在用户明确指定或任务本来就是 fixture/test 场景时使用，不作为故障 fallback。
- 只清理当前任务明确创建的临时文件；用户指定的导出产物、CLI 创建的 safety backup、既有 Apple Books 数据与配置默认保留。
- mutation/restore 的调用结果若因超时、中断等变成未知，先只读确认目标状态，不直接重发副作用；其它失败也只有在出现新证据、输入或环境变化后才重试。

任务结束时返回用户真正要的结果，并明确必要的 empty / unavailable / degraded / warning 状态。不要把“命令执行成功”本身当成完成。
