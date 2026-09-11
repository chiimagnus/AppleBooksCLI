# Apple Books 写入与恢复安全约束

> mutation / backup / restore / Books lifecycle / cloud acknowledgement 的长期安全 owner。Process/history JSON 见 [`cli-contract.md`](cli-contract.md)，用户能力范围见 [`capability-matrix.md`](capability-matrix.md)。

## 不可破坏的不变量

- 普通读取始终 read-only，不触发写 lifecycle。
- production mutation 只能走 guarded write rail；未知 required write schema/entity fail closed。
- 真实 mutation 在 writable transaction 前创建 fresh SQLite safety backup。
- quiet-state no-op 与 transaction revalidation 都必须保留：前者避免无变化写入，后者覆盖 quiet check 后的外部 writer race。
- `COMMIT` 是不可逆边界；commit 后 read-back/projection/acknowledgement/Books-state failure 只能成为 committed warning，绝不能自动重放 mutation。
- local commit、Apple-native cloud projection、当前 Mac acknowledgement、另一设备已经显示，是四层不同证据。

## Mutation rail

```text
read-only preflight
→ snapshot Books state (closed / background / frontmost)
→ quiet Books when needed
→ deterministic quiet-state no-op decision
   ├─ no-op → restore Books state; no backup / RW / COMMIT / projection / ack
   └─ needs mutation → fresh safety backup
→ short-lived RW connection
→ BEGIN IMMEDIATE
→ transaction revalidation
→ mutation + invariant
→ changed=false → ROLLBACK + close; restore Books state
→ changed=true  → COMMIT
→ close RW handle
→ fresh read-back
→ Apple-native cloud projection
→ optional `--sync` acknowledgement
→ restore original Books state
```

Invalid selector/schema 应尽量在退出 Books 前失败。Quiet decision 只拥有确定性 target-state no-op；它不能替代 transaction revalidation。若外部 writer 在 quiet decision 与 `BEGIN IMMEDIATE` 之间改变状态，transaction 内最终 `changed=false` 必须 rollback，不跨 COMMIT；此时前面已经创建的 backup 是竞态安全成本。

Writer/transaction failure 在 COMMIT 前 rollback。COMMIT 后本地事实不可撤销：close/read-back/projection/ack/deeplink/state-restore failure 都不能把结果伪装成“未写入”。

## Writable scope

- annotation：只允许已有 user annotation 的 note replacement/clear、soft-delete、以及仍存在 tombstone 的 restore；不 hard-delete，不创建新 highlight，不修改 selected text/CFI range；type-3/system row 不可写。
- collection：只允许 editable user collection 的 create/rename/soft-delete/membership mutation；system collection fail closed。
- local PK 仅作显式本机 selector；stable UUID/collection ID/book asset ID 优先。
- note/title 的 inverse prior state 只能在 guarded transaction 内、COMMIT 前读取；CLI 不得在 mutation 前预读再猜。

具体 SQL/column 集合由 writer/tests 拥有，不在本文复制。

## Books lifecycle

`MutationCoordinator` 捕获一次初始 `closed / background / frontmost`，并拥有 normal mutation 的最终恢复：background 不得被激活；frontmost 需要 bounded activation verification；原 closed 不得因为一次 mutation/sync 永久留下 Books 进程。Quit/launch/recovery 无法证明完成时 fail closed 或返回 post-COMMIT warning，不能用一次 `isRunning` 猜 ownership。

显式 root sync 需要临时启动 Books 时使用 non-activating launch。`backups restore` 使用独立 restore lifecycle，但同样记录并 best-effort 恢复原始三态。

## Backup 与 restore

Safety backup 使用 SQLite online backup，并对完成产物做 integrity verification；不能裸复制 active WAL store。Backup root 与祖先组件使用 no-follow directory boundary；create/list/retention/restore 只操作同一 held root descriptor 下的 owned regular artifact。Root/entry symlink、path identity replacement 或 malformed artifact 都 fail closed。

Public library backup catalog 只展示 newest 10 valid recovery artifacts；`backupID` 是 public recovery identity，文件名/path 不是。Annotation safety backups 仍是内部 mutation recovery evidence，不形成第二套 public restore surface。

BKLibrary restore：

```text
validate/open selected backup
→ snapshot + quiet Books
→ safety-backup current live library
→ apply SQLite restore
→ checkpoint / verify
→ retention
→ restore original Books state
```

Restore source 在触碰 Books 前完成验证。Apply 成功后同样跨过不可逆边界：verification、retention 或 Books-state restore 失败必须表达为 applied-but-warning/unverified，不能自动执行第二次 restore。

## Cloud projection 与 acknowledgement

Changed mutation 在 commit/read-back 后写入 Apple-native pending cloud representation；省略 `--sync` 只是不立即等待 acknowledgement。单条 mutation 的 `--sync` 等待该 mutation 的 current-Mac acknowledgement；root `applebookscli sync` 统计并 flush 当前全部 pending collection/member/annotation records。

Root sync 的 `pending=0` 返回 `status=no_pending_changes`、`acknowledged=null`，不触碰 Books lifecycle。有 pending 时 root sync 负责 temporary lifecycle 与最终状态恢复。一个 domain 已 ack 而另一个失败时，不回滚已完成 domain；root sync 可重新执行。Acknowledgement 只证明当前 Mac client-side cloud representation 已被接受，不证明第二台设备已经 render。

Cloud projection 读取 DB/private proto 时仍有 hard resource ceilings：stable identity 2 KiB UTF-8、annotation Note 64 KiB、collection title 64 KiB、details 1 MiB、固定 projection metadata 4 KiB、annotation private proto raw/updated data 64 MiB。需要 identity 的 writer 应尽量在 COMMIT 前拒绝超限；COMMIT 后 bridge 才发现的 resource failure 只能成为 `cloud_projection_failed` warning。正文/proto 不允许截断后同步。

## Operation history / transport retry 交叉边界

Recordable mutation、restore、root sync 必须在业务 dispatch 前成功写入 history `started`；否则不执行副作用。COMMIT 后的 structured result/inverse 在 presentation 前交给 CLI completion sink；history completion persistence 失败只能追加 diagnostic，不能改变或重放已确定 outcome。

可能自动 retry 的 transport 应为同一个逻辑写请求复用同一个 `APPLEBOOKSCLI_OPERATION_ID` UUID；history root lock 会在 dispatch 前 claim，并阻止同 UUID replay。`incomplete` 始终表示 outcome unknown，只能先查询 history，不能换 UUID 猜测性重试。完整 persistence/JSON/inverse/replay contract 由 [`cli-contract.md`](cli-contract.md) 拥有。

## Edit trigger / evidence

修改 writable scope、transaction/no-op/COMMIT 边界、backup/restore、Books lifecycle、cloud projection/acknowledgement 或 state-changing recorder/replay 语义时更新本文。验证必须覆盖 pre/post-COMMIT failure、schema drift、backup/restore、三种 Books state、projection/sync failure、pending=0 与 replay；真实 Apple Books/CloudKit/UI 未实测时必须明确 evidence gap。
