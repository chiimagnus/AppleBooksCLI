# Apple Books 写入与恢复安全约束

> 本文是 mutation / backup / restore / cloud-sync 的长期安全 owner。用户可见能力见 [`capability-matrix.md`](capability-matrix.md)，跨模块分层见 [`architecture.md`](architecture.md)，命令参数以 `--help` 为准。

## 文档职责

- **Audience**：修改 collection / annotation write、backup/restore、Books lifecycle、cloud projection/sync 或 write result 的维护者。
- **Job**：固定不可丢失的顺序、不可逆边界、恢复语义、state-changing CLI recorder 边界与 cloud evidence boundary。
- **Edit trigger**：writable scope、mutation/restore 顺序、backup primitive、schema guard、Books lifecycle、state-changing CLI recorder、cloud rail 或 public result/warning 变化。
- **Evidence**：`MutationCoordinator`、domain writers、`SQLiteBackup`、`BooksAppController`、`CLIEntrypoint`、`OperationHistoryStore`、cloud projector/synchronizer 及对应 tests/live gates。

## 总原则

Apple Books SQLite 与 cloud stores 都由 Apple/Core Data 拥有。SQL 能执行不等于 Core Data、CloudKit 或另一设备已经接受修改，因此：

- 普通读取保持 strict read-only，不触发写入 lifecycle；
- 所有生产 mutation 经过 guarded write rail，schema 不确定即 fail closed；
- 每次 mutation 在 writable transaction 前创建 fresh safety backup；
- selector/schema preflight 不能替代 transaction 内 revalidation；
- `COMMIT` 后的失败不能伪装成“未发生”，调用方也不能因此盲重试；
- local commit、Apple-native cloud projection、当前 Mac CloudKit acknowledgement、second-device rendered 是四层不同证据。

## Mutation ceremony

collection 与 annotation mutation 的固定顺序：

```text
read-only preflight
→ 记录 Books 原运行状态；需要时 clean quit
→ quiet-state fresh SQLite backup
→ short-lived RW connection + bounded busy timeout
→ BEGIN IMMEDIATE
→ transaction 内 revalidate
→ domain mutation + invariant
→ COMMIT / rollback
→ close writable handle
→ fresh read-only read-back
→ Apple-native cloud projection
→ 若 Books 原先运行则恢复
→ optional explicit CloudKit acknowledgement
```

无效 selector/schema 应在关闭 Books 前失败。backup 必须位于 Books quiet state；transaction 内仍要 revalidate，因为 preflight 与 `BEGIN IMMEDIATE` 之间状态可能变化。domain writer 不自行拥有事务边界。

cloud projection 发生在 **COMMIT + read-back 成功之后**。projection 失败是 committed warning，而不是回滚本地事务。

## 不可逆边界与结果

`COMMIT` 是普通 mutation 的 public irreversible boundary。

COMMIT 前失败：rollback、关闭 writable handle，并尽力恢复原 Books 运行状态。COMMIT 后 close/read-back/relaunch/projection/sync 失败都不能把结果改写为“未提交”。structured result 继续保留 `committed=true`、`changed`、backup handle、可用 identity 与 warning。

调用方看到 committed success + warning 时应重新读取需要确认的状态，**不能自动重试同一个 mutation**。`changed=false` 是成功 no-op，不是失败。

## Backup 与 restore

live SQLite safety backup 使用 `sqlite3_backup_*`，不用裸复制 WAL store。completed backup 必须通过 integrity verification；public restore 只接受 backup catalog 的受控 handle，不接受任意路径。

BKLibrary restore 顺序：

```text
验证并打开 restore source
→ 记录/必要时停止 Books
→ 对当前 live library 创建 fresh safety backup
→ SQLite-level apply
→ checkpoint + integrity verification
→ retention
→ 必要时恢复 Books
```

restore apply 成功后也已经跨过不可逆边界。后续 verification/retention/relaunch 失败必须表达为 applied-but-warning/unverified，不能包装成“restore 没发生”，也不能自动重复 restore。

public `backups list/restore` 当前只覆盖 BKLibrary。annotation mutation 也有内部 safety backup，但没有公开 annotation restore catalog。

## Books lifecycle 与 schema guard

Books.app 的运行状态属于 write protocol；`BKAgentService` / `bookassetd` 等 helper daemon 不等同于 Books running gate。safety backup 是 fresh quiet-app snapshot，但不是与所有 Apple helper daemon 写入原子锁定的数学意义 pre-state。

读取允许 optional schema degradation；写入必须验证目标 table/required columns、未知 required/NOT NULL 字段、Core Data entity metadata、`Z_PRIMARYKEY` 与目标 row 状态。Apple 私有 schema 没有公开稳定 contract，因此 guard 只能 fail closed on known drift，不能证明未来语义永久兼容。

Insert/update/delete 的具体字段矩阵由 domain writer 与 tests 拥有，不在本文复制。长期不变量只有：PK/entity bookkeeping 必须与 transaction 同步；update 维护 entity 自己的 optimistic-lock/timestamp 语义；annotation 与 collection delete 都保持当前 soft-delete contract，CLI 不提供 annotation hard delete。

## 当前 writable surface

Guarded mutation 当前覆盖：

- collection create / rename / soft-delete；
- collection add-book / remove-book；
- existing annotation update-note / soft-delete；
- BKLibrary backup list / restore。

不提供 create highlight/annotation、修改 selected text/CFI range、任意写 current reading position。稳定 identity 优先 collection ID / book asset ID / annotation UUID；local PK 只属于本机显式 selector。

这些目标写入命令、`backups restore` 与根 `sync` 还经过 CLI 外层 operation-history recorder：argv parse 成功后必须先持久化 started，之后才进入具体 command dispatch。这个 guard 不改变 Core mutation ceremony；未来新增 Apple Books state-changing / sync CLI surface 时也必须进入同一 recordable contract，不能形成绕过 history 的第二写入口。completion 持久化失败发生在原 command outcome 之后，不能把已 committed/applied 操作改写成未发生，也不能据此自动重试。

## Cloud projection 与 acknowledgement

正常 collection/annotation mutation 在本地 read-back 后通过已验证的 Apple BookDataStore primitive生成 dirty cloud representation；AppleBooksCLI 不手工伪造 Core Data history token，也不伪造 Apple identity/entitlement 直接 attach Apple Books CloudKit container。

两种显式 acknowledgement 模式：

- **单条 `--sync`**：本 mutation projection 成功后立即触发必要 Apple lifecycle，并等待对应 cloud record ack；
- **根 `applebookscli sync`**：先统计已经存在的 pending collection/member/annotation cloud records，再以最少必要 lifecycle flush；pending=0 时 no-op。若 collection 与 annotation 同时 pending，collection lifecycle 复用给 annotation；annotation-only pending 会确保有一次可消费变更的 Books lifecycle。

ack criterion 由当前 cloud synchronizer/tests 拥有，核心语义是 `syncGeneration` 已追上 `editGeneration` 且存在 CloudKit system fields；合法 delete/remove 可表现为 Apple cloud store 的物理移除。

成功 acknowledgement 只证明**当前 Mac** 的 Apple Books cloud representation 已被 CloudKit 接受，不证明另一设备已经 rendered。当前实机 evidence 已覆盖全部 collection mutation 与 annotation update-note；annotation soft-delete只有 disposable clone tombstone/projection evidence，没有拿用户真实 annotation 做 destructive live gate。

`backups restore` 不属于 normal mutation replay：`applebookscli sync` 只 flush 已经存在的 pending cloud representation，不会从任意 restored BKLibrary snapshot 自动推导 collection/member diff。cloud-aware restore 若未来需要，必须单独定义 reconciliation/conflict/deletion contract。

## 隐私与维护验证

错误/diagnostic 默认不 dump 用户正文、完整 SQLite row 或私有绝对路径。显式 `history get` 是本地 tool-history 的有意完整读取面，可能包含此前 argv/stdout/stderr；其 detail/sanitization/process contract 由 [`cli-contract.md`](cli-contract.md) 拥有，普通 mutation output/error 不因此放宽。

修改 write rail 时至少证明：happy path + read-back、pre/post-COMMIT failure boundary、schema drift fail closed、backup/WAL/restore、Books originally-running/closed、cloud projection/sync failure，以及 batch pending=0 / mixed-domain single-lifecycle contract。平台行为不能由 fixture 证明时保留 scoped live evidence；skip 不能写成 live pass。