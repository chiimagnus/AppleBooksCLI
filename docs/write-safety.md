# Apple Books 写入与恢复安全约束

> mutation / backup / restore / Books lifecycle / cloud acknowledgement 的长期安全 owner。能力范围见 [`capability-matrix.md`](capability-matrix.md)，process/history contract 见 [`cli-contract.md`](cli-contract.md)。

## 不可破坏的不变量

- 普通读取 strict read-only，不触发写入 lifecycle。
- production mutation 必须经过 guarded rail；未知 write schema fail closed。
- writable transaction 前创建 fresh SQLite safety backup。
- preflight 之后仍在 transaction 内 revalidate。
- `COMMIT` 是不可逆边界；其后的失败只能成为 committed warning，不能冒充“未写入”或自动重放 mutation。
- local commit、cloud projection、当前 Mac acknowledgement、另一设备已经显示是四层不同证据。

## Mutation 顺序

```text
read-only preflight
→ snapshot Books state (closed / background / frontmost)
→ clean quit when needed
→ quiet-state read-only no-op decision when the mutation has a deterministic target state
→ no-op: restore original Books state and return without backup / RW / COMMIT
→ needs mutation: fresh quiet-state backup
→ short-lived RW connection
→ BEGIN IMMEDIATE
→ transaction revalidation + mutation + invariant
→ COMMIT / rollback
→ close writable handle
→ fresh read-back
→ derive changed / identity / optional annotation deeplink
→ changed=true: Apple-native cloud projection
→ optional explicit acknowledgement (`--sync` only)
→ restore original Books state
```

关键边界：

- invalid selector/schema 必须尽量在退出 Books 前失败；Books quit reject/timeout 时 fail closed，不猜测性 relaunch。
- deterministic no-op 的最终判断必须发生在 Books quiet state；最初 preflight 只能验证输入/schema，不能作为 race-free equality owner。
- quiet-state no-op 返回 `committed=false, changed=false`，不创建 safety backup、不打开 RW、不做 projection/acknowledgement；如果调用者请求了 `--sync`，只保留 acknowledgement intent，不实际等待确认。
- quiet decision 之后到 `BEGIN IMMEDIATE` 之间仍可能有非 Books 外部 writer，因此真实 mutation 继续保留 transaction revalidation；若 transaction 内最终变成 `changed=false`，已创建 backup 是竞态安全代价。
- projection/acknowledgement 发生在 commit 后；失败不回滚本地事务。
- annotation update/delete 的 deeplink 只是 best-effort presentation metadata，不得成为 writer precondition。

## Books lifecycle

`MutationCoordinator` 捕获一次初始 `closed / background / frontmost` 并拥有最终恢复：

- background 恢复不得抢前台；frontmost 必须经过 activation + bounded verification；
- 显式 sync 需要临时启动 Books 时使用 non-activating launch；
- 原 closed 只清理由本次 sync 明确拥有、且没有被用户切到前台的 temporary launch；
- deeplink open 失败或最终状态恢复失败发生在 commit 后，只产生 warning。

CLI 的单侧 DB override 对应 domain 使用 detached Books lifecycle；公开 Core API 仍可显式要求 lifecycle 管理。`backups restore` 保留独立的 running/closed restore contract，不套用 normal mutation 的三态导航语义。

## Schema 与 writable scope

读取可以对 optional schema 降级；写入必须验证 required table/column、Core Data entity/primary-key bookkeeping、未知 NOT NULL 字段和目标 row 状态。

长期 writable boundary：

- annotation 只允许已有 user annotation 的 note update、soft-delete 与 tombstone restore；ordinary note update 只接受 active row，delete/restore 只在同一 existing user row 的 active/tombstone 状态间切换；type=3/system row 不进入该 writable scope；
- collection mutation 必须拒绝 system collection；
- annotation delete 不 hard-delete；restore 不 INSERT 或从历史正文重建，被外部物理移除的 tombstone 必须 fail closed；
- local primary key（PK，即当前 Core Data SQLite 行的 `Z_PK`）只作显式本机 selector；stable identity 优先 UUID / collection ID / asset ID。

具体列与 SQL 由 writer/tests 拥有，不在本文复制。

## Backup 与 restore

Safety backup 使用 SQLite online backup，不裸复制 WAL store；completed backup 必须通过 integrity verification。Backup root 及其已存在祖先组件统一按 no-follow 目录边界验证；create/list/retention/restore 只操作同一已验证 root descriptor 下的 owned regular artifact。Symlink root、entry symlink 或路径 identity 被替换都 fail closed，不能通过 path canonicalization 变成可恢复身份。

BKLibrary restore：

```text
validate/open selected backup
→ quiet Books when needed
→ backup current live library
→ apply SQLite restore
→ checkpoint + verify
→ retention
→ restore original Books state (`closed` / `background` / `frontmost`)
```

restore source 在触碰 Books 前完成校验；随后 snapshot 原始 `closed/background/frontmost` 状态，进入 quiet state，并在 safety-backup failure、apply failure 或成功收尾后 best-effort 恢复原状态。`background` 使用 non-activating launch，只有原本 `frontmost` 才允许激活。restore apply 后同样跨过不可逆边界；后续 verification/retention/Books-state restore 失败必须表达为 applied-but-warning/unverified，不能自动重复 restore。public backup catalog 当前只覆盖 BKLibrary；annotation mutation 的 safety backup 不构成第二套 public restore surface。

## Cloud projection 与 sync

普通 mutation 在 read-back 后只生成 pending Apple-native cloud representation，不等待 acknowledgement。

Cloud projection 有独立的 process/resource ceilings，不等同于 Agent 输入合同：DB-derived stable identity 最多 2 KiB UTF-8；annotation Note 最多 64 KiB；collection title 最多 64 KiB、details 最多 1 MiB；固定 projection metadata 最多 4 KiB；单个 annotation `bookAnnotations` private proto 的 raw/updated data 最多 64 MiB。identity 必须先由 SQLite byte length 证明在界内再 materialize，所有正文/proto 都保持完整值或 fail closed，禁止截断后同步。Collection tombstone projection 不读取 title/details，annotation tombstone projection 不读取 Note。依赖 identity 的 writer 若能在 COMMIT 前发现超限则拒绝写入；COMMIT 后 bridge 才发现的 resource rejection 只能返回现有 `cloud_projection_failed` committed warning，不能 rollback 或重放 mutation。Root sync 只等待已投影 pending generation，不重新读取这些 payload。

两种显式 sync：

- mutation `--sync`：仅等待该 mutation 的 current-Mac acknowledgement；
- root `applebookscli sync`：统计并 flush 已存在的 pending collection/member/annotation records；pending=0 返回 `status=no_pending_changes`、`acknowledged=null`，且不触碰 Books lifecycle。pending>0 时由 root sync 唯一持有 Books lifecycle：先记录原始 `closed/background/frontmost`，完成所需 recycle/launch 与两域 acknowledgement 后 best-effort 恢复原状态；后台态不得被激活，原本关闭时不得残留 Books 进程。

批量写入可以不逐条 `--sync`，最后 root sync 一次。注意 root sync 会处理**所有当前 pending records**，因此不能为了形式上的收尾在一个全 `changed=false` 的任务后无条件执行。mutation 省略 `--sync` 只是不立即等待 acknowledgement；local commit、read-back 与 cloud projection 仍照常发生。

ack criterion 由 synchronizer/tests 拥有。一个 domain 已 ack、另一个失败时不回滚或重放已完成 domain；root sync 可安全重跑。ack 失败仍是 non-zero failure，并在失败路径 best-effort 恢复 Books；若同时恢复失败，不能覆盖原始 sync failure。ack 已成功但仅 Books 状态恢复失败时，结果仍保持 `acknowledged=true`，并返回结构化 `books_state_restore_failed` warning。成功只证明当前 Mac 的 cloud representation 被 CloudKit 接受，不证明第二台设备已经 render；sync failure 不能触发 mutation replay。restore snapshot 也不会自动推导成一组 pending cloud mutations。

## Operation history 交叉边界

CLI 对目标 mutation、restore 与 root sync 必须先持久化 history `started` 才能 dispatch。需要反操作旧值的 mutation（当前为 annotation Note 与 collection title）只能从 guarded transaction 内、COMMIT 前读取真实 prior state，并随 committed mutation result 带回 CLI；CLI 不得在 mutation 前预读再猜。命令在 presentation 前把 committed result/inverse 写入 in-memory completion sink，因此后续 JSON/output 失败也不能抹掉已经发生的 mutation 证据。completion 持久化失败只能追加 warning，绝不能改变或重放已 commit mutation。

可能被 transport 自动重试的调用应为每个**逻辑写请求**设置一次 `APPLEBOOKSCLI_OPERATION_ID=<lowercase UUID>`，并在 transport retry 时原样复用该 UUID。该 UUID 直接作为 history record ID；history root lock 内先原子 claim，再允许 dispatch。同一 UUID + 同一 request 已经存在（无论 `incomplete` 还是已完成）时必须在 dispatch 前阻止 replay；同一 UUID 若对应不同 operation/request 则作为 caller conflict fail closed。没有设置该变量时保持普通本地 CLI 的现有随机 history ID 行为。`incomplete` 仍表示 outcome unknown：看到 replay-block 后只能先 `history get <operation-id>`，不能换新 UUID 猜测性重放。

History inverse 仍受 identity/data-integrity 边界约束：annotation 自动 delete↔restore inverse 只使用 eligible stable UUID；只有 local PK 时不宣称自动可逆。prior Note/title 必须完整保存才可标记 inverse available，超过 history payload 边界时降级为 unavailable，不能截断后伪称可恢复。完整的 history JSON/read/idempotency contract 由 [`cli-contract.md`](cli-contract.md) 拥有。

## Edit trigger / evidence

修改 writable scope、transaction/backup/restore 顺序、Books lifecycle、warning boundary、cloud projection/sync 或 state-changing CLI recorder 时更新本文。验证至少覆盖 happy path、pre/post-COMMIT failure、schema drift、backup/restore、Books states、projection/sync failure、pending=0 与 mixed-domain lifecycle；平台实机行为未跑时必须明确 evidence gap，不能把 fixture pass 写成 live pass。
