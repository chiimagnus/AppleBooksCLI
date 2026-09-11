# AppleBooksCLI 架构边界

> 维护者文档。本文只拥有跨模块长期不变量：数据 ownership、identity、source/trust boundary、Core↔CLI 分层与 hard resource budget。用户能力见 [`capability-matrix.md`](capability-matrix.md)，写入顺序见 [`write-safety.md`](write-safety.md)，process contract 见 [`cli-contract.md`](cli-contract.md)。

## Ownership / 分层

```text
Apple Books
├── BKLibrary SQLite            books / collections / membership
├── AEAnnotation SQLite         highlights / notes / bookmarks
├── Apple-owned cloud stores
├── EPUB resources
└── PDF files
        │
        ▼
AppleBooksCore
├── queries / semantic projections / reading state
├── EPUB/CFI + PDF worker protocol
├── export bundle / renderers
└── guarded mutation / backup / restore / cloud projection
        │
        ▼
applebookscli
├── argument composition
├── JSON process presentation
├── confined artifact writes
└── local operation history
```

业务语义归 `AppleBooksCore`；CLI 不重新实现 SQLite 查询/写入、EPUB/PDF 解析或 cloud projection。`AppleBooksCloudBridge` 是唯一允许的非 Swift production runtime，只桥接 Apple Books 自有 cloud representation，不实现独立 CloudKit client。

## Store 与依赖组合

BKLibrary 与 AEAnnotation 是独立 store，必须分别发现、打开和管理 lifecycle。annotation existence 不依赖当前 BKLibrary row；library metadata 只是 enrichment。

CLI 按命令需要组合最小 Core dependencies：library-only 命令不应强制发现 annotation store/config/PDF worker；annotation-only mutation 不应要求 library store；content 只组合 library + config；跨域 context/reading/export 再按真实需要增加依赖。公开 `AppleBooks` 双 DB initializer 表示调用方显式请求完整 Core composition；CLI 的 partial composition 是 package 内部边界，未装配能力必须明确失败。

普通 SQLite 查询保持 read-only。required write schema 漂移 fail closed；optional read column 可以降级。默认数据库发现流式扫描目录，ambiguity 只保留有限 witness，不 materialize 全目录。

## Identity

| Domain | Stable/public identity | Local fallback / non-identity |
| --- | --- | --- |
| Book | Apple Books asset ID | local `Z_PK`; title/author/genre 仅 search/display |
| Annotation | `ZANNOTATIONUUID` | local `Z_PK`; raw CFI/range 是 source data，不是 annotation identity |
| Collection | stable collection ID | local `Z_PK`; title 仅 search |
| PDF | unique Book asset ID，或 deterministic opaque `pdfSourceID` | absolute path 不是 ordinary public selector |
| Backup | opaque `backupID` | backup filename/path 不是 public recovery identity |

数字形式的 stable ID 不能猜成 local PK；多候选 exact identity 必须 fail closed。Derived display/normalization 不得反写 source identity。

## Ordinary projection 与 archival fidelity

普通 Agent read 只从 SQLite/materialized source 读取当前命令所需的 bounded semantic projection；不要“完整 materialize 后再在 CLI 截断”。CLI 侧只有明确的 archival JSON export 承担 source fidelity。

长期 hard budgets：

| Boundary | Budget |
| --- | ---: |
| stable identity | 2 KiB UTF-8 |
| short metadata | 2 KiB UTF-8 |
| list/search preview | 4 KiB UTF-8 |
| ordinary metadata | 8 KiB UTF-8 |
| ordinary detail body | 32 KiB UTF-8 |
| filesystem resource path | 4 KiB UTF-8 |
| derived CFI structural parsing | 64 KiB UTF-8 |

展示文本只能在完整 UTF-8 / Swift `Character` 边界缩短，并必须返回 truncation evidence。Identity/path 不属于展示文本：超限、非法 UTF-8、NUL 或错误 storage class 都使该值不可用，不能拿 prefix 冒充完整值。

Search/filter/order 可以直接在 SQLite 内对完整 source value 运算，不必把完整值 materialize 到 Swift 或 cursor；cursor 只携带 bounded locator/evidence。

## Configuration 与 EPUB

Configuration 只扩展 source resolution，不创造 identity。`epub_root` 仅在当前 primary EPUB 缺失/不可用时按 exact basename fallback；`historical_assets` 只补充 exact historical asset ID 的 metadata。

Configuration hard limit：regular file 最大 1 MiB；historical entry 最多 10,000；asset ID 走 stable-token 规则；historical title/author 走 metadata budget；`epub_root` 输入最多 4 KiB UTF-8。

EPUB 不变量：

- 不主动触发 iCloud hydration；DRM/不可读内容明确失败；
- packed 与 directory EPUB 共用 package/navigation/content 语义；
- path resolution 不能逃逸 package root，URI 不重复 decode；
- navigation fallback 固定为 nav → NCX → spine；
- structure depth 最多 256；manifest/spine/navigation/metadata/encryption/XHTML/ZIP-entry 集合各最多 20,000；packed EPUB retained path index 最多 32 MiB；
- annotation context 只有真实 anchor 命中才成功。

## PDF

PDF inventory 优先公开唯一 `bookAssetID`，否则公开 opaque `pdfSourceID`；ordinary selector 不暴露 absolute path。Library/fallback source 必须解析为 no-follow 打开的 regular file；同 inode source 合并为一个 inventory item。

PDFKit 只运行在独立 `applebookscli-pdf-worker` 进程。Worker 以 no-follow 语义重新打开/验证 source，并通过 held descriptor 读取；timeout、crash、malformed protocol、generation mismatch、oversized protocol data 都结构化失败。Ordinary highlight read 返回 bounded semantic page；archival export 走独立 archive path 保留 raw page/geometry/color fidelity。

## Export ownership

```text
query / content / PDF
→ ExportSourceResolver
→ ExportBundle
→ JSON or Markdown renderer
→ ExportFileWriter
```

`ExportSourceResolver` 统一拥有 stable document source identity；filesystem path 永不成为 artifact identity。Renderer 不访问 DB，只向 sink 增量写 bytes。Canonical CLI writer 负责 destination confinement、no-follow parent identity、single-file atomic publish 与 managed per-document directory publish。Per-document replacement 只能替换已经验证的 AppleBooksCLI managed tree；unexpected entry 或 identity race 必须在 publish 前 fail closed。

`AppleBooks.exportBundle(options:)` 是 public archival Core surface。Canonical CLI 的 renderer/file-writer plumbing 保持 package-internal，不再形成第二套 public persistence API。

## Edit trigger / evidence

store/source/identity ownership、Core↔CLI layering、ordinary-vs-archival projection、hard budget、EPUB/PDF trust boundary、export ownership 或 cloud bridge boundary 变化时更新本文。证据来自 `Sources/AppleBooksCore/**`、`Sources/AppleBooksCLI/**`、`Sources/AppleBooksCloudBridge/**` 与对应 contract/parity tests；用户可见能力变化同时更新 [`capability-matrix.md`](capability-matrix.md)。
