---
name: applebookscli-zh
description: 使用 `applebookscli` 查询、定位、导出或安全修改用户的 Apple Books 书库、阅读状态、EPUB/PDF 内容、批注与藏书
license: AGPL-3.0-only
metadata:
  cli_version: "0.3.1"
  repository: "https://github.com/chiimagnus/AppleBooksCLI"
  language: "zh"
---

# AppleBooksCLI

本 Skill 只负责指导 AI 选择并调用 `applebookscli` 完成 Apple Books 任务。

## 使用 CLI

1. 选择能完成请求的最小命令族；语法不确定时，只读取对应命令的 `--help`。
2. 精确操作优先 stable identity：book asset ID、annotation UUID、collection ID、backup handle。只有用户明确提供 local PK，或确实没有 stable identity 时才使用 PK；不能把数字形式的 stable ID 猜成 PK。
3. Operational command 默认返回 JSON，不要添加 `--json`。
4. 返回 `nextCursor` 时，用同一查询的 `--cursor <nextCursor>` 继续，并原样传递 token。可增长的书籍、阅读状态、藏书、PDF inventory 与 `annotations list` 统一使用该游标契约（默认 20、最大 100）；这些 surface 不使用 `--offset`。
5. 出现 `truncatedFields` 时，对应字段是合法但不完整的展示文本。用户明确需要原始完整正文/CFI 时改用 archival export。

## 命令路由

| 目标 | 命令族 |
| --- | --- |
| 书籍 / 搜索 | `books` |
| 阅读状态 | `reading`、`stats` |
| 批注 / 笔记 / 最近记录 / 搜索 | 查询、搜索、最近记录统一用 `annotations list`，exact detail 用 `annotations get`，写入才使用 mutation subcommand |
| EPUB 内容 / 批注上下文 | `content` |
| PDF inventory / highlights | `pdf`；exact extraction 使用 inventory 返回的 `bookAssetID` 搭配 `--book`，或 `pdfSourceID` 搭配 `--pdf` |
| 藏书 / membership | `collections` |
| 完整 JSON / Markdown artifact | `export` |
| 备份 / 恢复 | `backups` |
| flush pending cloud changes | `sync` |
| 最近 CLI 写入/同步证据 | `history` |
| 权限 / 数据库 / capability 诊断 | `doctor` |

批注查询续页时，`annotations list` 的 selector/filter/order 都要与首请求保持一致，只原样增加返回的 cursor。reading order 必须指定一本 exact book。`annotations get` 若返回 `bookURL`，它只是无 CFI fragment 的书级链接；要读周边 EPUB 正文用 `content context`，要原始 CFI/完整正文用 archival export。

## 写入与同步

- 只有用户授权修改时才执行 mutation/restore。使用 CLI 的 mutation 命令，不要直接修改 Apple Books SQLite。
- `annotations update-note --note` 会整段替换 note；用户要追加时先读取当前 note。`annotations delete` 是 soft-delete 整条批注。
- collection membership mutation 只使用 named selector：`--collection` / `--collection-pk` 必须且只能选一个，`--book` / `--book-pk` 也必须且只能选一个；collection/book identity 不再作为 positional argument。
- 单条 mutation 只有在用户需要当前 Mac CloudKit acknowledgement 时才加 `--sync`，否则省略。多条 mutation 需要 acknowledgement 时，中间不加 `--sync`；只有至少一条结果为 `changed=true` 时，批次结束后才运行一次根 `applebookscli sync`。全部 no-op 时不要 root sync。
- 已 commit 后出现 warning 不能触发自动重放。sync acknowledgement 只确认当前 Mac，不代表另一台设备已经显示。
- restore 前先解析精确 backup handle。

## 导出与失败处理

- `export` 必须显式指定 output destination；完整 Markdown/archival JSON 写文件，stdout 只返回 compact command result。
- 权限、DB discovery、schema 或 capability 失败时使用 `doctor`；正常 empty result 不需要诊断。
- 需要确认近期 CLI 写入/同步 outcome 时使用 `history`；它不是 undo。`history list` 使用 cursor 分页，返回 `nextCursor` 时原样传给 `history list --cursor <nextCursor>`；需要完整详情时把 list 返回的 lowercase UUID 交给 `history get`。
