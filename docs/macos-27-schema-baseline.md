# macOS 27 Apple Books schema baseline

> **Recorded observation, not product contract.** 2026-08-30，macOS 27.0 (`26A5421a`) 的净化只读采样。当前产品行为见 [`capability-matrix.md`](capability-matrix.md)。

## Evidence scope

- 只读 SQLite schema/count/type sampling；未执行 mutation。
- 不记录真实书名、asset ID、annotation UUID/CFI/正文或用户绝对路径。
- 只证明该系统版本当时的观测，不承诺 Apple 私有 schema 跨版本稳定。

## Store observations

观测到两个独立 Core Data SQLite store：

- BKLibrary：books / collections / membership 等 library state。
- AEAnnotation：highlight / note / bookmark 等 annotation state。

### AEAnnotation

`ZAEANNOTATION` 的产品相关列当时包括：

- identity/relation：`Z_PK`、`Z_ENT`、`Z_OPT`、`ZANNOTATIONUUID`、`ZANNOTATIONASSETID`
- lifecycle/type：`ZANNOTATIONDELETED`、`ZANNOTATIONISUNDERLINE`、`ZANNOTATIONSTYLE`、`ZANNOTATIONTYPE`
- time：`ZANNOTATIONCREATIONDATE`、`ZANNOTATIONMODIFICATIONDATE`
- text：`ZANNOTATIONSELECTEDTEXT`、`ZANNOTATIONREPRESENTATIVETEXT`、`ZANNOTATIONNOTE`
- location：`ZANNOTATIONLOCATION`、`ZPLABSOLUTEPHYSICALLOCATION`、`ZPLLOCATIONRANGESTART`、`ZPLLOCATIONRANGEEND`
- chapter hint：`ZFUTUREPROOFING5`

`Z_PRIMARYKEY` 中观测到 `AEAnnotation` entity。该 shape 当时足以支持当前 note/soft-delete guard 所需字段，但不单独证明写入安全或 CloudKit 行为。

### Type=3 bookmark

样本中 `ZANNOTATIONTYPE = 3` 与 current-reading bookmark 相关。当前产品的 user-annotation/type=3 分轨由源码/tests约束；若未来 Books 版本改变该语义，应建立新的 dated baseline，不覆盖本记录。

### BKLibrary / collection

观测到 book、collection、membership 与 Core Data `Z_PRIMARYKEY` bookkeeping；collection write 所需 entity/PK/`Z_OPT`/deleted/sort/timestamp 类字段可解析。entity numeric ID 是 store-local observation，不是跨机器常量。

## Content source observations

样本同时包含 EPUB 与 PDF metadata：EPUB source 受 content path/materialization/DRM 影响；PDF 可由 `ZCONTENTTYPE = 3` 区分并可能指向 readable file path。本记录不证明任意真实资源都可读。

## Maintenance rule

遇到新 macOS/Books schema drift 时：先做新的净化只读采样并记录日期/build/evidence scope，再决定产品 guard 是否需要变化。不要为了“更新”而改写旧 baseline。
