# macOS 27 Apple Books schema baseline

> **Recorded baseline, not product contract.** 本页只记录 2026-08-30 在 macOS 27.0（build `26A5421a`）上通过只读采样得到的 schema / behavior 事实。它不因为 AppleBooksCLI 后续实现变化而自动改写，也不能外推到其它 macOS / Books 版本。当前产品能力见 [`capability-matrix.md`](capability-matrix.md)。

## 证据边界

- 采样只读取本机 Apple Books SQLite schema / counts /必要的类型分布，没有执行 mutation。
- 记录保持净化：不包含真实书名、asset ID、annotation UUID/CFI/正文或用户绝对路径。
- 本页证明的是“这个系统版本当时观测到什么”，不是 Apple 未公开 schema 的稳定承诺。
- 写入、backup/restore、EPUB/PDF parser correctness 由产品实现和 executable tests 单独证明，见 [`write-safety.md`](write-safety.md) 与 [`architecture.md`](architecture.md)。

## 双 store 发现

该环境存在两个独立 Core Data SQLite store：

- BKLibrary：书籍、collection、membership 等 library state。
- AEAnnotation：highlight/note/bookmark 等 annotation state。

因此产品必须把两个 store 分别发现、分别 override、分别打开；annotation existence 不能依赖 current BKLibrary row 一定存在。

## AEAnnotation 观测

`ZAEANNOTATION` 当时可见的产品相关列包括：

- identity / relation：`Z_PK`、`Z_ENT`、`Z_OPT`、`ZANNOTATIONUUID`、`ZANNOTATIONASSETID`；
- lifecycle/type：`ZANNOTATIONDELETED`、`ZANNOTATIONISUNDERLINE`、`ZANNOTATIONSTYLE`、`ZANNOTATIONTYPE`；
- time：`ZANNOTATIONCREATIONDATE`、`ZANNOTATIONMODIFICATIONDATE`；
- text：`ZANNOTATIONSELECTEDTEXT`、`ZANNOTATIONREPRESENTATIVETEXT`、`ZANNOTATIONNOTE`；
- location：`ZANNOTATIONLOCATION`、`ZPLABSOLUTEPHYSICALLOCATION`、`ZPLLOCATIONRANGESTART`、`ZPLLOCATIONRANGEEND`；
- chapter hint：`ZFUTUREPROOFING5`。

另有 creator/storage/user-data 与其它 `ZFUTUREPROOFING*` 列。`Z_PRIMARYKEY` 中观测到 `AEAnnotation` entity。note / soft-delete 所需的 UUID、note、modification date、deleted flag 与 `Z_OPT` 在该 baseline 中存在。

这只证明 schema shape 当时相容；本页本身不证明 write ceremony、Books.app cache 或 iCloud 跨设备行为。

## Type=3 current reading bookmark

只读样本显示 `ZANNOTATIONTYPE = 3` 与 current-reading bookmark 语义相关，因此产品把它与普通 user annotations 分轨：

- 普通 user scope 默认排除 type=3；
- current reading position 走独立 query；
- active-raw scope 可显式观察这类 row。

这个结论来自该系统版本的实机观测与后续 synthetic regressions 共同约束；若未来系统版本改变 type 语义，应建立新的 dated baseline，而不是静默改写本页历史记录。

## BKLibrary / collection 观测

该环境的 library store 提供书籍、collection、membership 以及 Core Data `Z_PRIMARYKEY` bookkeeping。collection write 所需的 collection/member entity、PK、`Z_OPT`、deleted flag、sort/timestamp 等列在当时 schema 中可解析。

entity numeric ID 属于 store 内部事实，不应被写死成跨机器常量；产品写路径应从当前 `Z_PRIMARYKEY` 动态解析并 fail closed。

## EPUB / PDF source 观测

实机 library metadata 同时包含 EPUB 与 PDF 类型，且内容来源形态不同：

- EPUB 可能指向 Books 管理的 content path，并受 materialization/DRM 状态影响；
- PDF 以 `ZCONTENTTYPE = 3` 单独识别，并可能对应 canonical readable PDF file path。

本 baseline 只证明 source shape / metadata 区分存在，不证明任意一本真实资源都可读。当前 directory/packed EPUB resolver、CFI、PDF worker、degraded behavior 由产品 tests 与 [`architecture.md`](architecture.md) 拥有。

## 维护规则

若新的 macOS / Books 版本出现 schema drift：

1. 先做新的净化只读采样；
2. 明确记录系统版本、日期与 evidence scope；
3. 再决定是否需要修改 read capability degradation 或 write fail-closed guard；
4. 不为了让旧 baseline “看起来最新”而覆盖历史观测。
