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

## 核心工作流

1. 选择能完成请求的最小命令族；不确定语法时只读取相关层级的 `--help`。
2. 精确读取、导出或写入前先解析 stable identity。优先 asset ID、annotation UUID、collection ID、backup handle；title/name 只是搜索键。
3. 查询和写入优先 `--json`；`export` 的 JSON 使用 `--format json`。
4. 以返回数据/状态判断是否完成，不能只看 exit code。

## 路由

| 目标 | 命令族 |
| --- | --- |
| 书籍 / 搜索 / 阅读状态 / 统计 | `books`、`reading`、`stats` |
| 批注 / 笔记 / 最近记录 / 搜索 | `annotations` |
| EPUB 内容 / 上下文 | `content` |
| PDF inventory / highlights | `pdf` |
| 藏书 / membership | `collections` |
| 导出 | `export` |
| 备份 / 恢复 | `backups` |
| flush pending cloud records | `sync` |
| 近期写入/同步上下文 | `history` |
| 权限/schema 诊断 | `doctor` |

## 查询边界

- local primary key（PK）指当前 Core Data SQLite 行的 `Z_PK`，不是跨设备稳定 identity。只有用户明确提供 PK，或确实没有 stable identity 时才用 PK selector；数字形式的 stable ID 不能被猜成 PK。
- 多个候选都合理时展示候选，不静默选第一项。
- “最新批注”按创建时间；“最近修改”按修改时间；“最新笔记”只统计 `note` 非空的批注。
- 单条批注可能包含 `appleBooksURL`；只有需要前后正文时才调用 `content context`。
- EPUB/PDF 是否可读取决于本地 materialization、DRM 和可读本地 source。不要绕过 DRM，也不要主动 hydration 不可用的 iCloud 内容。

## 写入、恢复与同步

- 只有用户授权修改时才执行 mutation/restore。不要直接写 Apple Books SQLite，也不要围绕 CLI mutation 手工管理 Books.app；guarded rail 自己负责 lifecycle。
- `annotations update-note --note` 会整段替换 note。追加时先读当前 note，再提交完整新文本。`annotations delete` 是 soft-delete 整条批注，不只是清空 note。
- 把完成一个用户请求所需的 Apple Books mutation 视为一个写入批次：
  - 只有一条真实 mutation → 默认给这条加 `--sync`；
  - 多条 mutation → 中间不加 `--sync`，全部本地 commit 后只运行一次 `applebookscli sync --json`；
  - 全部 `changed=false` → 不运行根 `sync`，避免顺带 flush 与本任务无关的旧 pending changes。
- 本批只要有一条 `changed=true`，任务结束前就应尝试 current-Mac CloudKit acknowledgement；除非用户明确要求仅本地修改，不为这个同步收尾再单独询问。
- acknowledgement 无法完成时，明确说明“本地 mutation 已提交，但 iCloud acknowledgement 尚未确认”。post-commit warning 不能触发 mutation 重放。
- `--sync` / 根 `sync` 只证明当前 Mac acknowledgement，不代表另一台设备已经显示。
- restore 前先解析精确 backup handle；applied-but-warning/unverified 不能描述成完整成功。

## 导出 / history / 失败处理

- 遵守 destination/overwrite，默认不覆盖。
- 用 `history list --json` 找近期操作，只对相关候选调用 `history get <id> --json`。History 是证据，不是新的写入授权；`incomplete` 表示 outcome unknown，先只读确认状态。
- 权限、DB discovery、schema 或 capability 问题使用 `doctor --json`；正常 empty result 不需要诊断。
- 没有新证据、输入、权限或环境变化时，不重复同一失败命令。
