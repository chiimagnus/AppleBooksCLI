---
name: applebookscli
description: 通过 `applebookscli` 查询、定位、导出或受保护地修改 Apple Books 图书、阅读状态、EPUB/PDF、批注笔记与藏书，以及执行云同步、备份恢复或访问诊断时使用。
---

# AppleBooksCLI

使用已安装的 `applebookscli` 作为 Apple Books 数据操作入口。用户询问自己的数据时，实际查询后再回答，不用能力说明代替结果。

## 命令与 identity

命令、参数和枚举以当前 `--help` 为准；需要机器结果时优先 `--json`，`export` 使用 `--format json`。`doctor` 只用于诊断实际的 permission / unavailable / schema 问题。

优先使用稳定 identity：book asset ID、annotation UUID、collection ID、backup handle。标题/作者/名称先 search/list 并确认唯一；local PK 只在用户明确指定或没有稳定 identity 时使用。不要静默选择多候选中的第一项。

## Annotation 与写入

“最新笔记”只在 nonempty note 中比较；“最新”默认按创建时间，“最近修改”按修改时间。具体 annotation 优先返回高亮、note、必要时间与 `appleBooksURL`；需要前后正文时才用 `content context`。

`annotations update-note --note` 是整段替换。用户要求追加时先读原 note，再构造完整新值。`annotations delete` soft-delete 整条 annotation，不用于清空 note。

只有用户明确要求修改或 restore 时才写。不要直接读写 Apple Books SQLite，也不要额外手工 quit/launch Books；guarded mutation rail 已负责 backup、Books lifecycle、事务、read-back 与 cloud projection。

`committed=true` 后出现 warning 不能自动重试；结果未知时先做最窄只读确认。单条 mutation 只有在用户要求立即确认上传时才加 `--sync`。连续多条写入先正常执行，最后一次 `applebookscli sync --json`，避免每条都触发 lifecycle。

`--sync` / `sync` 成功只证明当前 Mac 的 Apple Books cloud records 获得 CloudKit acknowledgement；没有 second-device 证据时不要声称另一设备已经显示。`cloud_sync_failed` 是 post-commit warning。`backups restore` 是 BKLibrary snapshot replacement，不要把 restore 后的 `sync` 解释成 snapshot diff 已逐条上传。

## EPUB、PDF 与导出

EPUB 不可用时按需要用 `content status --json` 解释原因；不绕过 DRM，也不主动 hydration。PDF 只处理当前可解析的本地 source；不要把 PDF 命令当作已证明 non-hydrating 的 iCloud placeholder probe。

完整笔记归档使用 `--complete-notes` 的 fail-closed 路径；失败时不能降级成普通 export 后声称完整。普通导出遵守用户给定的输出与 overwrite 策略。

## 完成判断

不要把 exit 0 当成目标完成；以返回数据证明结果，并区分 empty、not found、unavailable、degraded、warning 与 CloudKit acknowledgement。