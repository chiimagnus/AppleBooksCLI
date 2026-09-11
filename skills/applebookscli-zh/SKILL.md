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

本 Skill 只负责指导 AI 选择并调用 `applebookscli`。精确语法与 finite option values 以当前安装 CLI 的 `--help` 为准。

## 调用规则

1. 选择能完成请求的最小命令族；语法不确定时，只读取对应命令的 `--help`。
2. 精确操作优先 stable identity：book asset ID、annotation UUID、collection ID、opaque `pdfSourceID` 或 `backupID`。只有用户明确提供 local PK，或确实没有 stable identity 时才使用 PK；不能把数字形式的 stable ID 猜成 PK。
3. Operational command 已经直接返回 JSON；不要添加 `--json`，也不要把 help 文本当数据解析。
4. 返回 `nextCursor` 时，用相同 selector/filter/order 的查询加 `--cursor <nextCursor>` 继续，并原样传递 token；不要解码或修改 cursor。
5. `truncatedFields` 表示 ordinary presentation text 不完整。用户需要原始完整正文/CFI 时使用 archival JSON export。

## 命令路由

| 目标 | 命令 |
| --- | --- |
| 书籍 / 搜索 | `books` |
| 阅读状态 / 统计 / bookmarked chapter | `reading`、`stats` |
| 批注查询 / exact detail / 周边正文 | `annotations list`、`annotations get`、`annotations context` |
| EPUB metadata / cover / ToC / chapter text | `content` |
| PDF inventory / 分页 highlights | `pdf` |
| 藏书 / membership | `collections` |
| 完整 Markdown 或 archival JSON artifact | `export` |
| library backup / restore | `backups` |
| pending cloud acknowledgement | `sync` |
| 最近写入/同步证据 | `history` |
| 权限 / 数据库 / capability 诊断 | `doctor` |

后续 PDF 读取使用 `pdf list` 返回的 `bookAssetID` 或 `pdfSourceID`，不要拿绝对 PDF path 代替 selector。`reading position` 只报告能映射到当前 ToC 的真实 bookmark；返回 `chapterOrder` 时可直接交给 `content chapter`。

## 写入、同步与重试

- 只有用户授权修改时才执行 mutation/restore。不要直接修改 Apple Books SQLite。
- `annotations update-note` 从 stdin 读取完整 replacement Note。用户要追加时先读取当前 note；只有清空时使用 `--clear`。`annotations delete` 只 soft-delete；`annotations restore` 只恢复仍存在的 tombstone。
- Collection membership 写入使用 named selector：`--collection` / `--collection-pk` 必须且只能选一个，`--book` / `--book-pk` 也必须且只能选一个。
- 单条 mutation 只有在需要立即等待当前 Mac acknowledgement 时才加 `--sync`。批量写入不在中间加 `--sync`；只要至少一条结果 `changed=true`，批次结束后再运行一次根 `applebookscli sync`。全部 no-op 时不要 root sync。
- 如果 transport 可能自动 retry，为每个逻辑 mutation/restore/root-sync 请求生成一次 fresh lowercase UUID，并设置 `APPLEBOOKSCLI_OPERATION_ID=<uuid>`；transport retry 原样复用该 UUID。遇到 `operation_replay_blocked` 先执行 `history get <uuid>`；`incomplete` 表示 outcome unknown，不能换新 UUID 猜测性重试。
- post-commit warning 不授权 replay。当前 Mac acknowledgement 不代表另一台设备已经显示变更。
- `backups list` 是固定 newest-10 恢复目录，不分页、也不是完整历史。Restore 只使用 CLI 返回或已知仍有效的 opaque `backupID`。

## 导出与失败处理

- `export` 必须提供 `--output`，默认 Markdown；需要 archival fidelity 时用 `--format json`。Exact `--book`、`--book-pk`、`--pdf` 会自动路由媒体；没有 exact selector 时才用 `--source epub|pdf|all` 控制 bulk scope。
- Bulk export 完成后检查 `complete` 与 `warnings`。只有用户明确要替换现有受支持 export destination 时才使用 `--overwrite always`。
- 权限、数据库、schema、worker 或 capability 失败时使用 `doctor`；正常 empty result 不需要诊断。
- 用 `history list` / `history get` 检查近期写入 outcome。只有 `inverse.available=true` 才执行 history 指示的反操作；`incomplete` 或 unavailable 时不要自行猜 inverse。
