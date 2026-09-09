# AppleBooksCLI 架构边界

> 维护者文档。本文只拥有跨模块长期不变量：数据 ownership、identity、source 与分层。用户可见能力见 [`capability-matrix.md`](capability-matrix.md)，写入顺序见 [`write-safety.md`](write-safety.md)，命令参数以 `--help` 为准。

## Ownership

```text
Apple Books
├── BKLibrary SQLite                  books / collections / membership
├── AEAnnotation SQLite               highlights / notes / bookmarks
├── BookDataStore cloud records       collection/member/annotation projection
├── Apple-owned CloudKit lifecycle
├── EPUB resources
└── PDF files
        │
        ▼
AppleBooksCore
├── queries + reading state
├── EPUB/CFI + PDF worker protocol
├── export
└── guarded mutation / restore / cloud projection
        │
        ▼
applebookscli
├── human / JSON process contract
├── files
└── local operation history
```

下游只消费 CLI 的公开结果或导出产物；不要绕过 Core 重新读写 Apple Books SQLite、复制私有 schema、重做 EPUB/PDF resolver，或直接解析 operation-history 存储文件。

## Store 与 cloud 分层

BKLibrary 与 AEAnnotation 是独立 store，必须分别发现、override 和打开。annotation existence 不依赖 current BKLibrary row；Book metadata 只是 enrichment。

CLI 以命令实际能力声明组合 Core 依赖，而不是先构造“全能力 AppleBooks”：library-only 命令不发现 AEAnnotation、不加载 config、不解析 PDF worker；annotation-only mutation 不发现 BKLibrary；content 只组合 library + config；需要 enrichment/reading-position/context 的命令才组合 library + annotations + config。Export exact selector 先用 library identity 判定 source，再只装配该 source 真正需要的 annotation/config 或 PDF worker。公开 `AppleBooks` 双 DB initializer 继续表示调用方显式请求完整兼容能力；CLI 的 partial composition 只是 package-internal 装配边界，误调用未装配能力必须明确失败，不能通过 dummy path 或静默空结果伪装。

普通读取使用 read-only SQLite。写入 required schema 漂移时 fail closed；读取 optional 字段缺失可以降级。

本地 SQLite commit、Apple-native cloud projection、当前 Mac CloudKit acknowledgement 是不同层次：

- mutation 在 commit/read-back 后生成对应 dirty cloud representation；
- `--sync` 只决定该 mutation 是否立即等待 acknowledgement；
- 多条 mutation 可最后用根 `sync` 一次 flush pending records；
- AppleBooksCLI 不伪造 Apple identity/entitlement 直接连接 Apple Books CloudKit container。

CLI 的单侧 DB override 只让对应 domain 使用 detached Books lifecycle；公开 `AppleBooksCore` 仍可由调用方显式选择 lifecycle 管理。具体写入/同步顺序只由 [`write-safety.md`](write-safety.md) 拥有。

## Identity 与 source

### Book

- stable identity 优先 Apple Books asset ID；local primary key（PK，Core Data SQLite 行的 `Z_PK`）只属于当前本机 DB。
- title/author/genre 是 search/display，不是唯一 identity。
- raw metadata 与 derived normalization 分开；derived 值不得反写 source identity。

### Annotation

- `ZANNOTATIONUUID` 是首选 stable identity；numeric PK 只用于明确的本机 selector。
- raw type/style/text/CFI/physical range/time 保留为 source data。
- `appleBooksURL` 只由 raw asset ID + optional raw CFI 派生，不替代 UUID/asset ID/CFI。
- user scope 与 raw/system scope 分开；type=3 current-reading bookmark 不等于 presentation bookmark。
- historical/unmapped annotation 不能因 current BKLibrary 缺 row 而消失。

### Collection

stable collection ID 与 local PK 可作精确 selector；title 只用于 search。system collection 与 editable user collection 必须分轨。

### PDF

PDF highlight 不伪装成 EPUB annotation：不用 annotation UUID/CFI，保留 PDF file/page/geometry identity；text/color approximation 必须保留 provenance。

## Configuration 与 content source

配置只扩展 source resolution，不改变 identity：

- `epub_root` 仅在 current Book primary EPUB source 缺失/不可用/不支持时按 exact basename 查找 supplemental packed EPUB；unsafe primary 不允许被 fallback 掩盖。
- `historical_assets` 只按 exact asset ID 提供 historical metadata，不授予 current Book/content identity。

EPUB 的长期边界：

- materialization probe 不主动触发 iCloud hydration；DRM 明确失败；
- directory 与 packed EPUB 共享 package/navigation/content 语义；
- path canonicalization 阻止 root escape，URI decode 不重复执行；
- navigation 按 nav → NCX → spine fallback；raw CFI 永久保留；
- annotation context 必须实际命中 anchor，不能返回章节开头冒充成功。

PDF 的长期边界：

- 只处理 canonical readable `.pdf`；fallback discovery 不递归、不 fuzzy；
- PDFKit 在独立 worker process 中运行，timeout/crash/malformed output 都是结构化 failure；
- 无法恢复 text 时仍保留 raw highlight/note/page/geometry；
- color mapping 只是 presentation approximation。

## Export 分层

```text
query/content/PDF
→ canonical ExportBundle
→ filtering / ordering / grouping
→ renderer
→ confined file writer
```

不变量：renderer 不 direct SQL；machine JSON 有 schema version；用户内容进入 escaped output context；所有文件/附件经过同一 confinement/overwrite 边界。

## CLI 与维护边界

CLI 负责 transport/presentation 与 operation history，AppleBooksCore 不依赖 CLI。process contract 见 [`cli-contract.md`](cli-contract.md)。完整命令树不在文档复制，以 `applebookscli --help` 为准。

新增 transport / UI 集成时继续复用 `AppleBooksCore` 的公开业务路径；不要在下游建立第二套 Apple Books 数据、content、mutation 或 cloud 逻辑，也不要引入第二套 SQLite runtime / ORM-style manager。

## Edit trigger / evidence

修改 store/source/identity、Core↔CLI ownership、EPUB/PDF source model、export ownership 或 cloud layering 时更新本文。当前实现证据来自 `Sources/AppleBooksCore/**`、`Sources/AppleBooksCLI/**` 与对应 executable tests；用户能力变化同时更新 [`capability-matrix.md`](capability-matrix.md)，mutation/restore 变化同时更新 [`write-safety.md`](write-safety.md)。
