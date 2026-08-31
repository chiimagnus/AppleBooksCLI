# Apple Books 写安全约束

> 本文是写路径的安全 contract，不代表当前已经允许对真实 Apple Books 数据库执行写操作。当前阶段没有对真实库做任何 mutation。

## 总原则

Apple Books SQLite 是 Apple / Core Data 拥有的数据文件，不是普通业务数据库。一个 SQL 能执行成功，不代表 Books.app、Core Data optimistic locking 或 iCloud sync 会接受这次修改。

因此：

```text
看懂 schema
!=
可以安全写
```

任何真实写能力都必须先通过 fixture / 副本验证，再单独做真实库验收。

## 读取与写入必须完全分轨

读取：

- SQLite 强制 read-only。
- optional column 缺失时可以 capability degradation。
- 不触发 Books.app 生命周期管理。
- 不触发 iCloud book hydration，仅为了“检查是否可读”时尤其如此。

写入：

- 使用独立、短生命周期 writable connection。
- schema 不确定时 fail closed。
- 写前必须有可恢复 backup。
- transaction 之外不能留下 Core Data bookkeeping 半状态。
- Books.app 内存 cache 必须纳入协议。

不要让一个 `Database` helper 隐式地从 read-only 升级成 writable。

## 已确认 mutation ceremony

AppleBooksCLI 写一次 mutation 的顺序固定为：

```text
1. 定位目标 DB
2. 只读读取并验证实时 schema / Core Data entity
3. 只读解析目标 selector / mutation 前置条件
4. 创建 SQLite online backup
5. 验证 backup integrity
6. 记录 Books.app 是否原先运行（wasRunning）
7. 若 wasRunning=true，clean quit Books.app，并确认进程退出
8. 打开短生命周期 writable connection
9. BEGIN IMMEDIATE
10. 在 transaction 内重新校验目标 row / 前置条件
11. 执行一个 domain mutation
12. 校验受影响行 / Core Data invariant
13. COMMIT；异常则 ROLLBACK
14. 关闭 writable connection
15. 若 wasRunning=true，重新打开 Books.app
16. 用新的 read-only connection 做 mutation read-back
```

关键约束：**所有不会改变 Apple Books 状态的前置检查都应在关闭 Books.app 之前完成**。用户不应因为 schema drift、selector 错误或 backup 失败而无故看到 Books 被退出。

Books.app 关闭前做的 target preflight 不是最终并发保证；因为 app 在这期间仍可能改变 row，所以 writable transaction 内必须再次验证目标状态。

任一 COMMIT 前 mutation/transaction 步骤失败：ROLLBACK，返回 backup path，不做部分成功。若失败发生在 Books 已被 CLI 关闭之后，应尽力恢复原先运行状态。

COMMIT 后仅 Books.app relaunch 失败：数据 mutation 已成功，不能把它谎报成 rollback 成功；应返回 success + warning。

## Backup：采用 SQLite online backup，不复制 live `.sqlite`

WAL 模式下裸文件复制可能漏掉未 checkpoint 数据；restore 时仍存活的 helper/read connection 也可能把旧 WAL 页重新覆盖回来。

AppleBooksCLI 已实测 Swift 6.4 可直接使用 SDK `SQLite3`。Swift 实现 contract 是：

- source 以 read-only SQLite connection 打开。
- 使用 SQLite3 C API 的 online backup primitive（`sqlite3_backup_*`）；具体 WAL/open-reader 行为必须在后续 fixture gate 实测后才能宣称完成。
- 先写临时 `.part`/临时路径；成功后再作为有效 backup 暴露。
- backup 本身运行 `PRAGMA integrity_check`。
- 做 retention，但 batch mutation 期间要保住 batch 开始前的 restore point。

禁止用 `wal_checkpoint(TRUNCATE) +` 文件复制替代 SQLite online backup；backup 必须由 SQLite3 的一致性机制拥有。

## Restore

Restore 比普通 write 更危险。

Restore 把已验证 backup 作为 SQLite source，通过 SQLite backup API 反向写回 live destination，而不是文件系统覆盖。

顺序：

```text
1. 校验 restore handle 只能指向自己的 backup store
2. backup 文件存在
3. restore source integrity_check = ok
4. 记录 Books.app 是否原先运行（wasRunning）
5. 对当前 live DB 创建 pre-restore SQLite online safety backup
6. pre-restore backup integrity_check = ok
7. 若 wasRunning=true，clean quit Books.app，并确认进程退出
8. SQLite-level restore
9. live DB integrity/read-back
10. 若 wasRunning=true，恢复 Books.app
```

pre-restore safety backup 是只读 snapshot，应在关闭 Books 前完成；这样 backup/handle/integrity 任何一步失败都不会无故退出应用。真正改变 live DB 的 restore 必须发生在 Books 已确认退出之后。

需要额外 fixture 测试：restore 时存在只读连接 / WAL reader，恢复后的旧状态不能被重新 replay。

## Books.app 生命周期

Books.app 本身运行时直接写不安全。

原因：

- Books.app 会 cache Core Data rows。
- optimistic locking 依赖 `Z_OPT`。
- app 内存状态可能覆盖外部 SQLite 修改。

AppleBooksCLI 采用自动 clean quit / 条件恢复，同时精确保存原始运行状态：

```text
wasRunning = false
  → 不需要为了写入而启动 Books；写完仍保持关闭

wasRunning = true
  → 前置检查通过后 clean quit
  → mutation 完成后恢复 launch
```

底层 invariant：**不能在 Books.app 活跃状态下静默直接写。**

COMMIT 成功但 relaunch 失败时，mutation 仍然是成功；返回 success + warning，提示用户手动打开 Books。不能把 post-commit launch failure 谎报成写入失败或已回滚。

不要把 `BKAgentService` / `bookassetd` 等 helper daemon 当成永久禁止写的条件；它们常驻。SQLite lock / busy timeout 与 online backup 用来处理数据库层并发。

## Schema guard：写路径必须 fail closed

读取 optional metadata 可以这样：

```text
字段不存在 → 不返回这项能力
```

写入不能这样。

写前至少验证：

- target table 存在。
- mutation 所需列全部存在。
- 没有 writer 不知道如何填充的新 NOT NULL 列。
- `Z_PRIMARYKEY` 中目标 Core Data entity 名存在。
- entity name → `Z_ENT` 与实际目标 row / table 一致。
- 目标 row 当前状态符合 mutation 前置条件。

因此 collection 不应只写死：

```text
Collection = 2
CollectionMember = 3
```

虽然 macOS 27 当前实机就是 2/3，但 writer 应解析：

```text
BKCollection       → 当前 Z_ENT
BKCollectionMember → 当前 Z_ENT
AEAnnotation       → 当前 Z_ENT
```

并在异常时拒绝写。

## Core Data bookkeeping

### Insert

Core Data insert 至少要维护：

- `Z_PRIMARYKEY.Z_MAX`
- `Z_PK`
- `Z_ENT`
- `Z_OPT = 1`
- 对应 local / modification timestamp

分配 PK 必须和 domain insert 在同一 transaction。

### Update

常规 row update 需要 bump：

```text
Z_OPT = Z_OPT + 1
```

并刷新该 entity 实际使用的 modification timestamp。

Annotation note mutation 使用：

```text
ZANNOTATIONNOTE
ZANNOTATIONMODIFICATIONDATE
Z_OPT
```

不要误用 collection 的 `ZLOCALMODDATE` 规则套 annotation。

### Delete

Apple Books 多处采用 sync tombstone / soft-delete 语义。

当前 schema 与 fixture contract 要求：

- annotation：`ZANNOTATIONDELETED = 1`。
- collection：`ZDELETEDFLAG = 1`，membership rows 另有删除语义。

禁止把 CLI `delete annotation` 实现成 `DELETE FROM ZAEANNOTATION`。

## Identity

优先身份：

```text
annotation → ZANNOTATIONUUID
book       → ZASSETID
```

`Z_PK` 是当前本机数据库内部主键，只作为：

- 查询/诊断显示。
- 必要的内部 foreign key。
- 明确兼容场景 fallback。

用户级 CLI 不应把 numeric PK 伪装成跨设备稳定身份。

## Parity writer 范围

这些不是“以后可选的第一批写功能”，而是当前 write parity contract 必须覆盖的 writer 能力：

- collection create / rename / delete。
- collection add-book / remove-book。
- existing annotation update-note。
- existing annotation soft-delete。

没有成熟证据：

- 从零创建新的 highlight / annotation。
- 修改 selected-text / CFI range。
- 任意改变 reading position。

后者属于 parity 后的单独逆向研究；在 parity gate 完成前不实现。

## 测试阶梯

任何写能力必须依次经过：

```text
1. 纯 mapper / schema tests
2. synthetic SQLite fixture
3. 由当前 macOS 27 schema 生成的 fixture
4. transaction failure / rollback
5. schema drift fail-closed
6. backup / restore + open reader / WAL tests
7. Books.app lifecycle fake / integration seam
8. 仅在明确允许后，真实库最小 mutation + Apple Books UI/read-back 验收
```

真实库测试之前不得跳级。

## 输入边界与 iCloud caveat

安全 rail 不只包括 transaction。CLI 边界必须验证 selector/search/name/note 等输入；annotation note 当前限制为非空且最多 10,000 字符。写命令至少必须：

- selector 格式/长度可控。
- collection title/details、note 等文本在进 DB 之前验证。
- SQL value 始终参数化；table/column identifier 只能来自受控内部枚举。
- 拒绝明显异常的大输入，而不是把 Core Data 当通用 blob store。

当前尚未完成真实多设备 iCloud collection 验收，所以 CLI 文档/成功结果不得承诺跨设备同步。

## 错误输出

错误需要同时满足：

- 用户知道 mutation 是否发生。
- 用户知道 backup 在哪里。
- COMMIT 后失败不能误导成“没写入”。
- 系统异常不要把完整用户书名 / note / SQL row dump 泄进默认日志。

调试模式可以提供结构化诊断，但仍不要无必要地打印完整批注正文。
