---
name: applebookscli-zh
description: 使用 `applebookscli` 查询、读取、导出、诊断、恢复、同步或安全修改 Apple Books 的书籍、阅读状态、EPUB 正文、批注、藏书、备份与操作历史
license: AGPL-3.0-only
metadata:
  cli_version: "0.5.0"
  repository: "https://github.com/chiimagnus/AppleBooksCLI"
  language: "zh"
---

# AppleBooksCLI

本 Skill 只负责指导 AI 选择并调用 `applebookscli`。精确语法与 finite option values 以当前安装 CLI 对应 leaf command 的 `--help` 为准。

**自 v0.5.0 起不再支持 PDF；仅 v0.4.2 及更早版本支持 PDF。**
当前 CLI 不得调用 `pdf`、`export --pdf` 或 `export --source`。

## 调用规则

1. 按下面的意图路由选择最小 leaf command；语法不确定时，只读取该 leaf command 的 `--help`。
2. 用户没有 exact selector 时，先用对应 list/search 命令取得 selector，再做 exact read/write。优先使用 book asset ID、annotation UUID、collection ID 或 `backupID`；只有用户明确提供 local PK，或确实没有 stable identity 时才使用 PK。不能把数字形式的 stable ID 猜成 PK。
3. Operational command 已直接返回 JSON。失败时按 `error.code`、`error.reason`、`error.recoveryHint` 做机器分支；`message` 只作展示。不要添加 `--json`，也不要把 help 文本当数据解析。
4. Bounded query 不是隐式全库扫描。只有确实还需要更多结果时，才用相同 selector/filter/order 加 `--cursor <nextCursor>` 继续，并原样传递 token。满足用户请求就停止；需要完整 artifact 时使用 `export`。
5. `truncatedFields` 表示 ordinary presentation text 不完整。需要原始完整批注正文/CFI fidelity 时使用 archival JSON export。

## 意图路由

| 目标 | 命令 |
| --- | --- |
| 查找/列出书籍；查看一本书 | `books list`、`books search`、`books get` |
| 阅读队列；书库统计 | `reading in-progress`、`reading finished`、`reading unstarted`、`reading recent`、`stats` |
| 当前 bookmarked chapter 正文 | `reading position` → `content chapter` |
| 查询/详情/上下文批注 | `annotations list`、`annotations get`、`annotations context` |
| 设置/清空/删除/恢复批注 | `annotations update-note`、`annotations delete`、`annotations restore` |
| 创建 EPUB 划线与笔记；修复云投影 | `annotations preview` → `annotations create`；已提交 UUID 使用 `annotations repair-sync` |
| 回填已有原生高亮的创建时间 | `annotations set-created-at <uuid> --created-at <带时区 RFC3339>` |
| EPUB metadata/cover/ToC/chapter text | `content metadata`、`content cover`、`content chapters`、`content chapter` |
| 读取藏书与 membership | `collections list`、`collections search`、`collections get`、`collections books` |
| 修改藏书与 membership | `collections create`、`collections rename`、`collections delete`、`collections add-book`、`collections remove-book` |
| 完整 Markdown 或 archival JSON artifact | `export` |
| library recovery | `backups list`、`backups restore` |
| flush pending cloud changes | `sync` |
| 最近写入/同步 outcome 或 inverse | `history list`、`history get` |
| 权限/数据库/capability 诊断 | `doctor` |

`reading position` 只在真实 bookmark 能映射当前 ToC 时成功；把返回的 `chapterOrder` 交给 `content chapter`。

## 写入、同步与重试

- 只有用户授权修改时才执行 mutation/restore。不要直接修改 Apple Books SQLite。
- `annotations update-note` 从 stdin 读取完整 replacement Note。用户要追加时先读取当前 note；只有清空时使用 `--clear`。`annotations delete` 只 soft-delete；`annotations restore` 只恢复仍存在的 tombstone。
- 创建高亮前准备含 `annotations` 数组的 JSON 文件，例如 `{ "text": "…", "chapterOrder": 1, "color": "yellow", "note": "…", "createdAt": "2023-06-02T11:58:15+08:00" }`；`createdAt` 可选、必须带时区，创建时直接保存原始时间，重复导入不覆盖已有批注的时间；先运行 `annotations preview --book <asset-id> --input <file>`，解决缺失、歧义和冲突后，再用相同 selector 与文件调用 `annotations create`。不传入 raw CFI。标准 Debug CLI 和正式发行版均可为一本书创建第一个原生云父对象；自定义未携带版本信息的程序在 COMMIT 前返回 `application_version_unavailable`，需换用标准构建。`preview` 不检测可执行文件的版本信息。
- EPUB 原位替换后如高亮不可见或页码异常，不要重新创建；
  应先核对书籍标识及阅读缓存（见仓库 `docs/write-safety.md`）。
- `annotations set-created-at` 只修改已有原生高亮的创建时间，不重建、不改变 UUID/选区/笔记；由于原生云端版本规则，修改时间会更新到本次回填时刻。支持 `--sync`，重复相同时间为无写入 no-op；已提交但云投影失败必须先检查本地与云端状态，不能盲目重试。
- 批量 `create` 的 `status=partial` 或 `preflight_failed` 即使退出码为 0，也必须检查 `complete`、逐项状态/UUID、`changedCount` 与 `syncRequired`。若有 `cloud_projection_failed`，先用 `annotations repair-sync <uuid>` 修复**已有 UUID**，再独立调用根 `sync`；不要重复创建。`--sync` 只适用于单条创建。
- Collection membership 写入使用 named selector：`--collection` / `--collection-pk` 必须且只能选一个，`--book` / `--book-pk` 也必须且只能选一个。
- 把 mutation result 当状态读取：`changed=false` 是成功 no-op；`committed=true` 表示本地写入已经跨过 COMMIT。出现 post-commit `warningCodes` 不授权 replay。
- 单条 mutation 只有在需要立即等待当前 Mac acknowledgement 时才加 `--sync`。批量写入不在中间加 `--sync`；只要至少一条结果 `changed=true`，批次结束后再运行一次根 `applebookscli sync`。全部 no-op 时不要 root sync。当前 Mac acknowledgement 不代表另一台设备已经显示变更。
- 如果 transport 可能自动 retry，为每个逻辑 mutation/restore/root-sync 请求生成一次 fresh lowercase UUID，并设置 `APPLEBOOKSCLI_OPERATION_ID=<uuid>`；transport retry 原样复用该 UUID。遇到 `operation_replay_blocked` 先执行 `history get <uuid>`；`incomplete` 表示结果未知，必须用同一输入的只读 `annotations preview` 和 `annotations get/list` 核销后才能用新的操作 ID 继续，不得盲目重放批次。
- `backups list` 只是 newest-10 discovery window。Restore 使用 CLI 返回或已知仍有效的 opaque `backupID`；成功 restore 会返回新的 `safetyBackupID`，只要对应 backup 仍存在，就可继续用于 recovery。

## 导出与失败恢复

- `export` 必须提供 `--output`，默认 Markdown；需要 archival fidelity 时用 `--format json`。仅导出 EPUB 批注；可通过 `--book`、`--book-pk` 精确选择书籍，不提供 selector 时默认导出所有符合条件的 EPUB 批注。
- 导出后检查 `destination`、`disposition`、`documentCount`、`warningCount` 和 `warnings`；只有用户明确要替换现有受支持 export destination 时才使用 `--overwrite always`。
- 权限、数据库、schema 或 capability 失败时使用 `doctor`；正常 empty result 不需要诊断。存在 `recoveryHint` 时优先按它恢复。
- 用 `history list` / `history get` 检查近期 state-changing outcome。只有 `inverse.available=true` 才执行 history 指示的反操作；`incomplete` 或 unavailable 时不要自行猜 inverse。
