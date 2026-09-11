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
2. 精确操作优先 stable identity：book asset ID、annotation UUID、collection ID、opaque `backupID`。只有用户明确提供 local PK，或确实没有 stable identity 时才使用 PK；不能把数字形式的 stable ID 猜成 PK。
3. Operational command 默认返回 JSON，不要添加 `--json`。
4. 返回 `nextCursor` 时，用同一查询的 `--cursor <nextCursor>` 继续，并原样传递 token。可增长的书籍、阅读状态、藏书、PDF inventory/highlight、`annotations list` 与 `content chapters` 统一使用该游标契约（默认 20、最大 100）；`content chapters` 只返回 `chapterOrder`、bounded title 与 depth。把 `chapterOrder` 交给 `content chapter --book|--book-pk --chapter <order>`；正文 continuation 同样只用 opaque cursor，不使用 `--offset`。
5. 出现 `truncatedFields` 时，对应字段是合法但不完整的展示文本。用户明确需要原始完整正文/CFI 时改用 archival export。

## 命令路由

| 目标 | 命令族 |
| --- | --- |
| 书籍 / 搜索 | `books` |
| 阅读状态 | `reading`、`stats` |
| 批注 / 笔记 / 最近记录 / 搜索 / 上下文 | 查询、搜索、最近记录统一用 `annotations list`，exact detail 用 `annotations get`，bounded 周边正文用 `annotations context`，写入才使用 mutation subcommand |
| EPUB 内容 | `content` |
| PDF inventory / highlights | `pdf`；使用 inventory 返回的 `bookAssetID` 搭配 `--book`，或 `pdfSourceID` 搭配 `--pdf`；highlight 是分页 summary，原样续传 `nextCursor`，raw geometry/完整正文改用 archival export |
| 藏书 / membership | `collections` |
| 完整 JSON / Markdown artifact | `export` |
| 备份 / 恢复 | `backups` |
| flush pending cloud changes | `sync` |
| 最近 CLI 写入/同步证据 | `history` |
| 权限 / 数据库 / capability 诊断 | `doctor` |

批注查询续页时，`annotations list` 的 selector/filter/order 都要与首请求保持一致，只原样增加返回的 cursor。reading order 必须指定一本 exact book。`annotations get` 若返回 `bookURL`，它只是无 CFI fragment 的书级链接；要读 bounded 周边 EPUB 正文用 `annotations context <uuid>`（或显式 `--pk`），要原始 CFI/完整正文用 archival export。`reading position <asset-id>`（或显式 `--pk`）只报告能映射到当前 ToC 的真实 type-3 bookmark，不会用最近批注猜测；返回的 `chapterOrder` 可直接交给 `content chapter --chapter`。`content metadata` 返回单一 bounded resolved metadata；`content cover --output <path>` 把图片写入文件，`<path>` 可相对当前目录，JSON 返回 canonical destination。

## 写入与同步

- 只有用户授权修改时才执行 mutation/restore。使用 CLI 的 mutation 命令，不要直接修改 Apple Books SQLite。
- `annotations update-note --note` 会整段替换 note；用户要追加时先读取当前 note。`annotations delete` 是 soft-delete 整条批注。
- collection membership mutation 只使用 named selector：`--collection` / `--collection-pk` 必须且只能选一个，`--book` / `--book-pk` 也必须且只能选一个；collection/book identity 不再作为 positional argument。
- 单条 mutation 只有在用户需要当前 Mac CloudKit acknowledgement 时才加 `--sync`，否则省略。多条 mutation 需要 acknowledgement 时，中间不加 `--sync`；只有至少一条结果为 `changed=true` 时，批次结束后才运行一次根 `applebookscli sync`。全部 no-op 时不要 root sync。
- deterministic no-op 返回 `committed=false`、`changed=false` 且没有 `backupID`；即使请求了 `--sync`，也只会有 `acknowledgementRequested=true`、`acknowledged=null`，不会真的等待 acknowledgement。已 commit 后出现 warning 不能触发自动重放。sync acknowledgement 只确认当前 Mac，不代表另一台设备已经显示。
- `backups list` 是固定恢复目录，只展示最新 10 个有效 library backup；不要分页，也不要把它当作完整备份历史。把列表返回或之前保存的有效 opaque `backupID` 原样交给 `backups restore`；不要使用 backup filename 或 path 作为 selector。

## 导出与失败处理

- `export --output <path>` 默认写 human-readable Markdown notes，archival raw fidelity 显式指定 `--format json`；archival JSON 中不可编码的 Book non-finite raw numeric 主字段为 `null`，用 `numericAnomalies` 区分 ±Infinity 与原始 null。Markdown 只保留 title/author、quote/Note、可理解位置或 PDF page、日期与 presentation 属性，不输出 raw asset ID/CFI 或 PDF absolute path。路径可相对当前目录或为绝对路径。grouping 决定单文件（`single`）或一次性原子发布的 managed directory（`per-document`）；同一 source identity 的文件名稳定。`--overwrite always` 只允许替换已验证的旧 AppleBooksCLI per-document 导出，出现额外 entry 就 `unsafe_output`；原子 swap 后旧目录清理失败时保留新 artifact，并报告 `old_export_cleanup_failed`。stdout 只返回 canonical destination 和文档数量，不枚举所有路径。
- 精确导出用 `--book <assetID>`（或显式 `--book-pk`）；没有唯一 Book identity 的 PDF 用 `pdf list` 返回的 `--pdf <pdfSourceID>`，不要传路径。selector 可重复，媒体自动路由；missing/ambiguous 失败，有效但无批注的书允许空结果。无 selector 时 bulk 默认覆盖 EPUB+PDF，只有 bulk 可用 `--source epub|pdf|all`；检查 `complete` 与 `warnings` 后再判断 artifact 是否完整，exact PDF 读取失败不写 artifact。
- 导出默认按各文档内的阅读顺序排列，无需指定 order。
- 导出属性过滤使用 `--has-highlight true|false`、`--has-note true|false`、`--underline true|false`；省略不筛，多条件按 AND 组合，Highlight 与 Note 可以同时存在。`--color` 只匹配 EPUB canonical color，不匹配 PDF 近似色；PDF highlight 即使未提取到文字仍算 highlight。
- 权限、DB discovery、schema 或 capability 失败时使用 `doctor`；正常 empty result 不需要诊断。
- 需要确认近期 CLI 写入/同步 outcome 时使用 `history`；它不是 undo。`history list` 使用 cursor 分页，返回 `nextCursor` 时原样传给 `history list --cursor <nextCursor>`；需要完整详情时把 list 返回的 lowercase UUID 交给 `history get`。
