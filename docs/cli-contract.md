# AppleBooksCLI process contract

> CLI automation 与维护者的 process-level contract。命令参数和 finite choices 以当前 binary 的 `--help` 为准；用户能力见 [`capability-matrix.md`](capability-matrix.md)。

## Exit status 与输出通道

| Exit | 含义 |
| ---: | --- |
| `0` | success，或 help/version/completion clean exit |
| `64` | usage / validation |
| `66` | requested identity not found |
| `69` | required capability unavailable/degraded |
| `70` | unexpected internal failure |
| `74` | write/backup/output safety failure |
| `77` | permission/path-access failure |

Operational command 成功时 stdout 恰好输出一个 JSON value；没有 public `--json` / `--verbose` presentation switch。Fatal parse/runtime error 只在 stderr 输出一个 JSON envelope，stdout 为空：

```json
{"ok":false,"error":{"code":"usage_invalid","reason":null,"message":"Invalid command-line arguments.","recoveryHint":null}}
```

`code` 的稳定集合是 `usage_invalid`、`not_found`、`unavailable`、`internal`、`write_safety`、`permission`。`reason` 用于更精确的机器分支；`recoveryHint` 只在存在可靠且不泄漏私有数据的恢复动作时提供。当前 reason tokens：

```text
ambiguous_identity            annotation_not_found          annotation_restore_unavailable
backup_not_found              book_not_found                chapter_not_found
collection_not_found          configuration_invalid         content_unavailable
context_unavailable           cursor_stale                  database_unavailable
history_entry_not_found       history_unavailable           operation_id_conflict
operation_id_invalid          operation_replay_blocked      output_exists
pdf_source_not_found          pdf_worker_unavailable        reading_order_requires_book
reading_position_unavailable  schema_unavailable            selector_not_found
sync_ack_failed               sync_unavailable              unsafe_output
```

Unexpected/internal failure 只公开 `Internal error.`；parse failure 不回放 raw argv、selector、search text、path 或 ArgumentParser 原始文本。

命令 outcome 已确定后才发生、且不能改变主结果的诊断使用 stderr JSON Lines：每行形如 `{"diagnostic":{"severity":"warning","code":"...","message":"..."}}`。成功且无 transport diagnostic 时 stderr 为空。Help/version/completion/`help` 是 status `0` 的 plain-text stdout。

## JSON 结果边界

普通 read DTO 可返回 `truncatedFields`；这表示 published presentation text 被 Core byte budget 或 CLI grapheme budget 缩短，但仍是合法 UTF-8 且结束在完整 `Character`。需要 archival fidelity 时使用显式 archival JSON export，而不是把 ordinary result 当 raw dump。

Mutation 结果统一表达 `committed`、`changed`、`acknowledgementRequested`、nullable `acknowledged` 与 `warningCodes`，并使用领域 identity：annotation 为 `annotationUUID` / fallback `annotationLocalPK`；collection 为 `collectionID` / fallback `collectionLocalPK`；membership 另带 `bookAssetID` / fallback `bookLocalPK`。Library-backed collection/membership mutation 可返回 opaque `backupID`；annotation safety backup 不公开。Deterministic no-op 返回 `committed=false`、`changed=false`，不返回 `backupID`，也不实际等待 acknowledgement。

`export` 必须显式 `--output`，默认 Markdown，`--format json` 才是 archival JSON。Artifact 只写入 guarded destination；stdout 只返回 compact write result（destination/disposition/documentCount/warningCount/complete/warnings），不输出完整 artifact 或逐文件路径。Relative output 基于 cwd，结果返回 canonical destination。Existing/unsafe target 分别使用稳定 `output_exists` / `unsafe_output` reason。

## Cursor continuation

返回 `nextCursor` 的查询必须把 token 当 opaque value：用**同一命令、同一 selector/filter/order**，加 `--cursor <nextCursor>` 继续。Record query 默认 20、单页最多 100；`--limit` 可以在合法范围内改变页大小。

Cursor 是 bounded、versioned base64url token，最大 4,096 ASCII bytes，只携带 digest 与 bounded numeric locator，不嵌入 raw query text、title、note、数据库/config/source path。它绑定 query semantics 与影响 selection/order/identity/classification 的 mutable dependency generation；filter mismatch 是 invalid，参与依赖变化是 stale。Owner 在一页查询前后比较 generation；查询期间发生变化时整页 fail closed。Cursor 只证明连续性，不提供跨进程 snapshot isolation，也不能被调用者解码、编辑或猜测。

## Doctor

`doctor` 是 bounded broad diagnostic，overall `status` 只有 `ready`、`partial`、`unavailable`：全部 ordinary prerequisites ready、部分可用、或没有任何 ordinary capability 可证明可用。`components` 报底层 library/annotations/config/backup/cloud/PDF-worker readiness；`capabilities` 报 command-level prerequisite。单个 store 或 worker failure 不应把无关能力判死；per-book EPUB/PDF 是否 materialized/DRM-readable 仍由实际 content command 决定。

## Operation history 与 transport replay

`history` 保存最近 24 小时 recordable mutation/restore/root-sync 的结构化证据。`history list` 默认20/最大100并用 opaque cursor 分页；`history get <id>` 按 exact lowercase UUID 返回 `request`、`result`、`inverse`。History 不保存 raw argv 或 captured stdout/stderr；可用 inverse 只保存执行安全反操作所必需的 prior state。只接受当前 history schema，unsupported schema fail closed。

State-changing dispatch 前必须成功持久化 `started`；失败则不 dispatch。Command outcome 确定后再持久化 completion；completion 写入失败不能改变已确定的 mutation/sync/restore 结果，只追加 sanitized `history_completion_failed` diagnostic。

可能自动 retry 的 transport 应为每个**逻辑写请求**生成一次 fresh lowercase UUID，并设置 `APPLEBOOKSCLI_OPERATION_ID=<uuid>`。该 UUID 就是 history ID，并在 dispatch 前原子 claim：

- 同 UUID + 同 request 已存在 → `operation_replay_blocked`，不再次 dispatch；
- 同 UUID + 不同 operation/request → `operation_id_conflict`；
- malformed UUID → `operation_id_invalid`。

收到 replay-blocked 后先 `history get <uuid>`。`incomplete` 表示 outcome unknown，绝不授权换新 UUID 猜测性重放。

`inverse.available=true` 只表示 history 有 transaction-authentic prior state 与可安全使用的 public identity；调用方仍通过普通 guarded command 执行反操作。只有 local PK、缺失 prior state、超出 history payload budget 或 outcome unknown 时都不得猜 inverse。

## Edit trigger / evidence

修改 exit/error taxonomy、stdout/stderr placement、JSON envelope/result identity、cursor、doctor presentation、history persistence/inverse 或 operation-ID replay contract 时更新本文。Evidence 由 CLI contract/output/history/cursor/doctor tests 与 `scripts/ci-gates.sh` 提供。
