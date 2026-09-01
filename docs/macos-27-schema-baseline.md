# macOS 27 Apple Books Schema 基线

> 采样时间：2026-08-30，macOS 27.0（Build `26A5421a`）。这是净化后的研究基线：只保留 schema、行为不变量与运行时验证；真实书库规模、asset ID、书名、CFI、UUID 和用户绝对路径不进入本仓库。

## 数据库发现

Apple Books 当前使用 BKLibrary 与 AEAnnotation 两个独立 SQLite store。文件名带版本样式后缀，因此实现不得写死完整文件名；应在固定 Apple Books 容器目录按已知 prefix + `.sqlite` 确定性发现，并允许两个 store 独立 override。

## 已核实的数据寿命不变量

本机只读检查证明 active annotations 可以在当前 BKLibrary 已无对应 row 后继续存在：

```text
Book library lifetime != Annotation lifetime
```

因此 annotation 必须以自身 `asset_id` / UUID 独立存在；当前 BKLibrary metadata 只是 enrichment。找不到 current library row 时仍返回 annotation；历史 metadata 可由显式用户配置补充。真实数量与具体 identities 已从迁移副本删除。

## Annotation schema

macOS 27 的 `ZAEANNOTATION` 已核实包含写/读路径依赖的核心列：

```text
Z_PK Z_ENT Z_OPT
ZANNOTATIONDELETED ZANNOTATIONISUNDERLINE ZANNOTATIONSTYLE ZANNOTATIONTYPE
ZANNOTATIONCREATIONDATE ZANNOTATIONMODIFICATIONDATE
ZANNOTATIONASSETID ZANNOTATIONLOCATION ZANNOTATIONNOTE
ZANNOTATIONREPRESENTATIVETEXT ZANNOTATIONSELECTEDTEXT ZANNOTATIONUUID
ZPLABSOLUTEPHYSICALLOCATION ZPLLOCATIONRANGESTART ZPLLOCATIONRANGEEND
```

另有 creator/storage/user-data 与 `ZFUTUREPROOFING*` 列。`Z_PRIMARYKEY` 中存在 `AEAnnotation` entity。note / soft-delete 所需的 UUID、note、modification date、deleted flag 与 `Z_OPT` 当前均存在。这只证明 schema shape 当前相容，不证明真实写入的 Books.app / iCloud 行为已验收。

## Collection schema

`ZBKCOLLECTION` 当前包含 PK/entity/version、deleted/hidden/placeholder、sort/view、modification、collection ID/details/title 等列；`ZBKCOLLECTIONMEMBER` 当前包含 PK/entity/version、sort、asset/collection foreign keys、local modification 与 asset IDs。

当前 entity mapping 与 `BKCollection` / `BKCollectionMember` 关系一致，但 writer 不得只靠固定数字：写前必须从 `Z_PRIMARYKEY` 按 entity name 解析并验证 `Z_ENT`、目标表、必填列；漂移即 fail closed。

## Annotation type 证据边界

本机只读验证支持把 `ZANNOTATIONTYPE=3` 作为 current-reading bookmark 查询依据，但 raw `type` 必须永久保留。type=1/type=2 的样本不足以建立跨 macOS 版本的永久语义，不能把当前样本标签当 Apple 官方规范。

## EPUB / PDF 分轨

当前数据来源表明 EPUB content/CFI 与 PDF highlights 是两条不同路径：PDF highlight 来自 PDF 文件的 `/Subtype /Highlight + QuadPoints`，而不是 AEAnnotation selected-text row。因此两者必须分 adapter；PDF parity 仍需 synthetic/可控 fixture 验证 text、note、page、color、cache 与 timeout。

## 当前 Swift runtime 基线

Swift 6.4 已在本机实测可直接 `import SQLite3` 并读取系统 SQLite 版本；AppleBooksCLI 使用 SwiftPM、Swift 6 language mode 与 macOS 12 deployment target。P1 当时尚未需要第三方 SwiftPM dependency；后续 parser/content source dependency 属于产品实现事实，不属于本 schema 采样基线。SQLite online backup、WAL/open-reader 与 restore correctness 已在后续 synthetic safety gate 中验证；本文仍只记录实机 schema/行为证据，不把 synthetic implementation evidence 冒充 macOS 27 schema 事实。
