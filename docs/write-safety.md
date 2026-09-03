# Apple Books 写入与恢复安全约束

> 本文是 AppleBooksCLI mutation / backup / restore 的唯一长期安全 owner。它描述当前已实现的安全 rail，而不是实施计划。用户可见能力范围见 [`capability-matrix.md`](capability-matrix.md)，跨模块架构边界见 [`architecture.md`](architecture.md)。

## 文档职责

- **Audience**：修改 collection / annotation write、backup/restore、Books.app lifecycle 或 CLI write result 的维护者。
- **Job**：固定不可丢失的前置检查、quiet-state backup、事务、不变量、read-back 与不可逆边界。
- **Edit trigger**：mutation/restore 顺序、backup primitive、schema guard、Books.app lifecycle、public write result/warning 或 writable scope 变化。
- **Evidence**：`MutationCoordinator`、`SQLiteBackup`、`CollectionWriter`、`AnnotationWriter`、`BooksAppController` 及其 mutation/restore/lifecycle tests。

## 总原则

Apple Books SQLite 是 Apple / Core Data 拥有的数据文件。SQL 能执行不等于 Core Data cache、optimistic locking 或跨设备状态一定接受这次修改。因此 AppleBooksCLI 的写能力只能经过 guarded mutation rail，不能从 CLI 或新 helper 旁路直接写 live database。

读取和写入必须分轨：

- 普通读取使用 strict read-only SQLite connection，不触发 Books.app lifecycle。
- 写入使用短生命周期 writable connection；schema 不确定时 fail closed。
- 每次 mutation 在进入 writable rail 前都要有 quiet-state safety backup。
- transaction 前的 selector/schema preflight 不能代替 transaction 内 revalidation。
- 已经跨过不可逆边界的结果不能伪装成“未发生”，也不能诱导调用方盲目重试。

## Mutation ceremony

collection 与 annotation mutation 统一经过 `MutationCoordinator.perform`：

```text
1. 以 read-only connection 打开目标 DB
2. read-only schema / selector / target preflight
3. 关闭 preflight connection
4. 记录 Books.app 原运行状态 wasRunning
5. 若 wasRunning=true：clean quit，并等待进程退出
6. quiet state 创建 fresh SQLite online backup，并校验 backup
7. 打开短生命周期 read-write SQLite connection
8. 配置 bounded busy timeout
9. BEGIN IMMEDIATE
10. transaction 内重新校验 schema / target / 前置条件
11. 执行一个 domain mutation
12. 校验 domain / Core Data invariant
13. COMMIT；此前任一步失败则 ROLLBACK
14. 关闭 writable connection
15. 用 fresh read-only connection 做 read-back verification
16. 若 wasRunning=true：恢复 Books.app
```

关键约束：

- 不改变数据的 preflight 应在关闭 Books.app **之前**完成；无效 selector/schema 不应打扰用户应用状态。
- backup 必须在 Books.app 已停止后的 quiet state 创建，才能包含 app 退出时最后落盘的数据。
- Books 在 preflight 与 writable transaction 之间仍可能改变数据，所以 transaction 内必须 revalidate。
- 每个 domain writer 只负责自己的 mutation 与 invariant；事务、backup、lifecycle 由 coordinator 统一拥有。

## Mutation 不可逆边界与结果

`COMMIT` 成功就是 mutation 的 public irreversible boundary。

COMMIT 前失败：

- transaction 已打开则 rollback；
- writable handle 必须关闭；
- 若 CLI 曾关闭 Books.app，要尽力恢复原运行状态；
- 若 safety backup 已创建，failure 可以携带该受控 handle；
- relaunch recovery 失败只能作为 secondary warning，不能覆盖 primary failure。

COMMIT 后：

- writable close、fresh read-back 或 Books.app relaunch 失败都不能把结果改写成“未提交”；
- structured result 保持 `committed=true`、`changed`、backup handle 与可用 stable/local identity；
- post-commit warning 当前包括 `writable_close_failed`、`read_back_failed`、`relaunch_failed`。

调用方看到 committed success + warning 时，应报告 warning 并根据需要重新读取状态；**不能自动重试同一个 mutation**。

## Backup

live SQLite 不使用裸 `.sqlite` 文件复制作为 safety backup。WAL 模式下裸复制可能漏掉未 checkpoint 数据，也可能在 restore 时被旧 reader/WAL 状态重新污染。

当前 backup contract：

- source 由 read-only SQLite connection 驱动；
- 使用 SQLite `sqlite3_backup_*` online backup primitive；
- 完成后的 backup 必须通过 integrity verification 后才可作为有效 restore source；
- backup store 只接受自己的 regular-file handle，不把绝对路径当 public selector；
- retention 不能在当前 restore apply 完成前淘汰被选中的 restore point；
- annotation mutation 也创建内部 safety backup，但 public `backups list/restore` 当前只覆盖 BKLibrary。

## Restore

Restore 比普通 mutation 风险更高。public `backups restore <handle>` 只接受 `backups list` 返回的受控 BKLibrary handle，并通过 SQLite backup API 反向写回 live destination，不做文件系统覆盖。

当前顺序：

```text
1. 校验 handle，并以 strict read-only connection 打开 restore source
2. 记录 Books.app 原运行状态 wasRunning
3. 若 wasRunning=true：clean quit，并等待进程退出
4. quiet state 对当前 live DB 创建 fresh safety backup，同时保护选中的 restore handle
5. 用已打开的 restore source 执行 SQLite-level apply
6. 关闭 restore source
7. checkpoint restored destination，并做 integrity verification
8. verification 成功后恢复正常 retention
9. 若 wasRunning=true：恢复 Books.app
10. 返回 restored-from handle、fresh safety handle、verified 与 warning codes
```

先打开 restore source、再做 safety-backup retention 是正确性的一部分；不能假设“路径仍在”与“已打开 source 能可靠完成 restore”可以互相替代。

`SQLiteBackup.applyRestore` 成功后，restore 已经跨过不可逆边界。Core 以 `restoreApplied=true` 表达这一点；CLI 映射为 `changed=true`，并用 `status=restored_verified` / `restored_unverified` 与 `verified` 区分验证结果。之后：

- checkpoint/integrity 失败 → `restoreApplied=true`、`verified=false`、`verification_failed`；
- retention 失败 → `retention_failed` warning；
- relaunch 失败 → `relaunch_failed` warning。

这些都不能被包装成“restore 没发生”。调用方看到 applied-but-unverified 结果时，应保留 restored-from handle 与 fresh safety handle并先检查状态，**不能自动重复 restore**。

## Books.app lifecycle

Books.app 的运行状态是写协议的一部分：

```text
wasRunning = false
→ mutation/restore 不主动启动 Books

wasRunning = true
→ preflight 通过后 clean quit
→ quiet-state backup + write/restore
→ 完成或可恢复失败后尽力恢复 launch
```

底层 invariant 是：不能在 Books.app 活跃状态下静默直接写 live store。`BKAgentService`、`bookassetd` 等常驻 helper daemon 不等同于 Books.app running gate；SQLite busy/locking 由数据库 rail 处理。

## Schema guard

读取允许 optional capability degradation，写入不允许猜 schema。

写前必须验证：

- target table 存在；
- mutation 所需列全部存在；
- 没有 writer 不知道如何填充的新 required/NOT NULL 列；
- `Z_PRIMARYKEY` 中目标 Core Data entity 存在且唯一；
- entity name → `Z_ENT` 与实际 row/table 一致；
- target row 当前状态满足 mutation 前置条件。

`BKCollection`、`BKCollectionMember`、`AEAnnotation` 的 entity ID 必须从当前 store 解析，不能把一次机器上观察到的数字写死成永久 contract。

## Core Data bookkeeping

Insert 至少维护：

- `Z_PRIMARYKEY.Z_MAX` 与新 `Z_PK`；
- 当前解析出的 `Z_ENT`；
- `Z_OPT = 1`；
- 对应 entity 使用的 modification/local timestamp。

PK allocation 与 insert 必须处于同一 transaction。

Update 需要按 entity 自己的规则 bump `Z_OPT` 并更新其时间字段；annotation note 使用 `ZANNOTATIONNOTE`、`ZANNOTATIONMODIFICATIONDATE`、`Z_OPT`，不能套用 collection timestamp 规则。

Delete 当前都是 soft-delete 语义：

- annotation：`ZANNOTATIONDELETED = 1`；
- collection：`ZDELETEDFLAG = 1`，并按 collection contract 清理 membership。

CLI 不提供对 annotation row 的 hard delete。

## 当前 writable surface

当前 release 的 guarded write surface：

- collection create / rename / soft-delete；
- collection add-book / remove-book，重复 add / missing remove 保持 idempotent `changed=false`；
- existing annotation update-note；
- existing annotation soft-delete；
- BKLibrary backup list / restore。

当前不提供：

- 从零创建 Apple Books highlight / annotation；
- 修改 selected text / CFI range；
- 写 current reading position；
- public annotation-backup catalog/restore surface。

## Identity 与输入边界

优先 stable identity：

```text
annotation → ZANNOTATIONUUID
book       → ZASSETID
collection → collection ID
```

numeric `Z_PK` 只属于当前本机 DB，可用于显式 local selector / 内部 foreign key，不得伪装成跨设备稳定身份。

CLI 边界继续负责 selector/search/name/note 等输入校验；SQL value 使用参数绑定，table/column identifier 只能来自受控内部枚举。annotation note 当前要求非空且最多 10,000 个 Swift `Character`。

## 隐私与错误输出

默认错误/diagnostic 不应 dump 用户书名、annotation 正文、完整 SQLite row 或绝对 backup path。结果需要让调用方知道：

- mutation 是否 `committed`；
- restore 是否 `changed`、当前 `status` 与 `verified`；
- 是否有受控 backup/safety handle；
- 是否有 post-boundary warning。

机器/人类输出协议见 [`cli-contract.md`](cli-contract.md)。

## iCloud caveat

普通 mutation 的 `committed` / read-back 只证明本地结果，不能等同于 iCloud 或 cross-device sync。当前唯一显式 CloudKit acknowledgement rail 是 `collections create --sync`：Stage A projection 成功后，它会受控重建当前用户的 `bookdatastored`、启动 Books，并等待 exact `BCCollectionDetail` 满足 `syncGeneration >= editGeneration` 且 `ckSystemFields` 非空。该生命周期副作用只允许由 `--sync` 显式选择，不能加入默认 create。

`--sync` 成功可以证明当前 Mac 已把该 collection record 上传到 Apple Books 的 iCloud CloudKit private database，但不能单凭这一点声称另一台设备已经显示。若返回 `cloud_sync_failed`，本地 mutation 仍可能已经 `committed=true`，不得自动重试。create 未带 `--sync`、collection rename/delete/membership 以及 annotation mutation 仍没有这个 CloudKit ack contract。

## 维护验证

修改写 rail 时至少要覆盖：

- happy-path mutation + fresh read-back；
- preflight / quit / backup / begin / revalidate / mutation / invariant / commit failure；
- COMMIT 后 close/read-back/relaunch warning；
- schema drift fail closed；
- online backup / WAL / open-reader；
- restore source rejection、fresh safety backup、apply、post-apply verification/retention/relaunch；
- Books.app originally-running 与 originally-closed 两种 lifecycle。

具体命令由 tests/CI 拥有，本文不复制会漂移的执行清单。
