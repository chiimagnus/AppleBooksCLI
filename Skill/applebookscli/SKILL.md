---
name: applebookscli
description: 通过 `applebookscli` 查询、定位、导出或受保护地修改 Apple Books 图书、阅读状态、EPUB/PDF、批注笔记与藏书，以及执行备份恢复或访问诊断时使用。
---

# AppleBooksCLI

使用已安装的 `applebookscli` 作为 Apple Books 数据操作的唯一入口。用户询问自己的 Apple Books 数据时，实际查询后再回答，不用能力说明代替结果。

## 回答前先查阅

CLI 自身是命令契约。需要确认命令、参数或枚举值时，优先读取当前帮助，不依赖记忆，也不在 Skill 中维护第二份命令手册：

- `applebookscli --help`
- `applebookscli <group> --help`
- `applebookscli <group> <subcommand> --help`

使用完成目标所需的最窄命令；普通查询、写入和状态判断需要结构化结果时优先 `--json`。`export` 的 JSON 输出使用 `--format json`，不要把 operational `--json` 套到 export。`doctor` 只用于诊断请求，或实际出现 permission、unavailable、schema readiness 一类问题时。`--library-db`、`--annotations-db`、`--config` 只用于用户明确指定或 fixture/test，不作为故障 fallback。

## Identity

优先使用稳定 identity：book asset ID、annotation UUID、collection ID、backup handle。标题、作者和名称只是搜索条件；先 search/list，唯一匹配后再继续。不要静默选择多个候选中的第一项；local PK 只在没有稳定 identity 或用户明确指定时使用。

阅读状态以 `reading` 的 canonical 结果为准，不从进度百分比推断 finished/in-progress/unstarted。“最近打开”也不等于“当前正在前台阅读”；用户说“当前这本书”时优先复用已经唯一解析的上下文，若只能得到 recent 结果就按 recent 候选表述。

## Annotations

用户问“最新笔记”时，只在 `note` 非空的 annotation 中比较；“最新”默认按创建时间，“最近修改”按修改时间。不要把普通高亮误报成笔记。

展示一条具体 annotation 时，优先返回高亮文本、note、必要时间和 `appleBooksURL`。不要自行拼接 `ibooks://`，也不要为了生成 deep link 调用 `content locate`。只有用户需要高亮前后正文时才使用 `content context`。

`annotations update-note` 的 `--note` 是**整段替换文本**。用户要求追加、补充或加评论时，先读取原 note，保留原文构造完整新 note，再用 exact UUID 和 `--json` 写回。`annotations delete` soft-delete 的是整条 annotation，不要用它代替“清空 note 文本”。

## 写入与恢复

只有用户明确要求修改 annotation、collection 或恢复备份时才执行写操作。CLI 的 guarded mutation rail 已负责安全备份、Books.app 生命周期、事务与 read-back；不要直接读写 Apple Books SQLite，也不要额外手工 quit/launch Books.app。

`committed=true` 表示事务已经提交，不能因为后续 warning 自动重试；`changed=false` 是成功的幂等 no-op。出现 `read_back_failed`，或调用超时/中断导致结果未知时，先做最窄只读确认，再决定是否还需要写入。CLI 创建的 safety backup 默认保留。

`backups list/restore` 只面向 library database；不要假定 annotation mutation 返回的 backup handle 可以交给这个恢复面。Restore 以返回的 `changed`、`status`、`verified` 为准；`restored_unverified` 表示恢复已经应用但验证失败，不能自动再 restore。

## EPUB、PDF 与导出

EPUB 内容不可用时，只有需要解释原因才运行 `content status --json`；不要绕过 DRM/encryption，也不要主动触发下载。PDF 没有 exact book/path 时先用 `pdf list --json` 解析唯一 source；worker failure/timeout 与“成功读取但没有 highlights”是不同结果。

用户要求完整笔记归档时必须使用 `--complete-notes` 的 fail-closed 路径；完整性校验失败就停止并报告，不能降级为普通 export 后声称归档完整。普通导出遵守用户给定的输出与 overwrite 策略，不擅自覆盖已有文件。

## 返回结果

不要把 exit 0 当成用户目标已经完成；以实际返回数据证明结果，并区分 empty、not found、unavailable、degraded 和 warning。本地 mutation 成功也不等于已经同步到 iCloud；没有另一设备或其它端到端证据时，只确认本地 Apple Books 状态。
