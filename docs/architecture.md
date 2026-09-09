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
├── JSON operational transport + plain help/version
├── files
└── local operation history
```

下游只消费 CLI 的公开结果或导出产物；不要绕过 Core 重新读写 Apple Books SQLite、复制私有 schema、重做 EPUB/PDF resolver，或直接解析 operation-history 存储文件。

## Store 与 cloud 分层

BKLibrary 与 AEAnnotation 是独立 store，必须分别发现、override 和打开。annotation existence 不依赖 current BKLibrary row；Book metadata 只是 enrichment。

CLI 以命令实际能力声明组合 Core 依赖，而不是先构造“全能力 AppleBooks”：library-only 命令不发现 AEAnnotation、不加载 config、不解析 PDF worker；annotation-only mutation 不发现 BKLibrary；content 只组合 library + config；需要 enrichment/reading-position/context 的命令才组合 library + annotations + config。Export exact selector 先用 library identity 判定 source，再只装配该 source 真正需要的 annotation/config 或 PDF worker。公开 `AppleBooks` 双 DB initializer 继续表示调用方显式请求完整兼容能力；CLI 的 partial composition 只是 package-internal 装配边界，误调用未装配能力必须明确失败，不能通过 dummy path 或静默空结果伪装。

普通读取使用 read-only SQLite。写入 required schema 漂移时 fail closed；读取 optional 字段缺失可以降级。默认 DB discovery 逐目录项流式扫描，不构造完整目录列表；ambiguity 只保留最多 8 个按 UTF-8 byte lexicographic 排序的 witness。

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

## Ordinary semantic projection 与 raw fidelity

普通 Agent read 与 archival/raw Core 是两条不同的数据边界，不能用“先完整读取、最后在 CLI 截断”混在一起：

- ordinary book/collection/annotation query 只把完成当前命令所需的 semantic projection 从 SQLite 带入 Swift。可展示 TEXT 在 SQL 层先证明 storage class 与原始 UTF-8 byte length，只读取 `byteCap + 4` 的 prefix；Core strict-decode 后按完整 Swift `Character` 收敛到 byte cap，并把原始长度造成的截断作为 evidence 传给 CLI。CLI 只再应用 grapheme cap，并与 Core evidence 合并为一个 `truncatedFields`。
- hard SQL semantic budgets：stable identity `2 KiB`；short metadata `2 KiB`；preview `4 KiB`；ordinary metadata `8 KiB`；detail body `32 KiB`。Book language 使用 short-metadata budget；Book title/author/genre、Collection title、annotation chapter hint 使用 metadata budget；Book description/Collection details 与 exact annotation selectedText/note 使用 detail budget；annotation list/search body 使用 preview budget。超限 presentation TEXT 可以截断，但必须留下 `truncatedFields` evidence。
- stable asset ID、annotation UUID、collection ID 等 identity 不是 presentation 文本：只有完整 TEXT 在 SQL 层证明 UTF-8 长度不超过 `2 KiB` 后才 materialize，再交给 stable-token validator。oversize identity 不取 prefix、不猜 identity；annotation source 明确进入 `identityUnavailable` 等有限状态。
- canonical content/PDF filesystem resolution 只消费 `BookResourceTarget` 这类最小 capability view。`Book.path` 只有完整 TEXT 严格 UTF-8、无 NUL 且不超过 `4 KiB` 时才进入 URL/filesystem owner；超过上限或非法 storage/UTF-8 直接视为 path unavailable，绝不把截断 prefix 当路径打开。`BookResourceTarget` 不是新的 raw Book model。
- raw CFI 可完整保留，但任何 derived structural parsing 只接受最多 `64 KiB` UTF-8；oversize CFI 不参与 chapter/fragment 推导，也不能作为 deeplink fragment。
- search、filter、collation、ORDER/keyset 可以继续在 SQLite 内部对完整 source TEXT 运算；cursor 只携带 locator/evidence，不把完整 sort key materialize 到 Swift 或写进 token/history。
- public rich Core compatibility API 与 explicit archival export 继续拥有 full fidelity：raw `SQLiteRow.text()`、rich `Book`/`Collection`/`Annotation` 和 export bundle 不套 ordinary byte budget。新增 ordinary caller 不得为了省事回到 rich decoder；反过来也不得把 ordinary resource gate 偷偷变成 raw/export 截断。

## Configuration 与 content source

配置只扩展 source resolution，不改变 identity：

- `epub_root` 仅在 current Book primary EPUB source 缺失/不可用/不支持时按 exact basename 查找 supplemental packed EPUB；unsafe primary 不允许被 fallback 掩盖。
- `historical_assets` 只按 exact asset ID 提供 historical metadata，不授予 current Book/content identity。

EPUB 的长期边界：

- materialization probe 不主动触发 iCloud hydration；DRM 明确失败；
- directory 与 packed EPUB 共享 package/navigation/content 语义；
- path canonicalization 阻止 root escape，URI decode 不重复执行；
- 结构解析 hard budget 为最大 nesting depth `256`；manifest/spine/navigation/metadata-list/encryption/XHTML-node/ZIP-entry 各最多 `20,000`；packed EPUB retained path index 总计最多 `32 MiB`。超过上限直接 fail closed，不返回部分结构；
- navigation 按 nav → NCX → spine fallback；raw CFI 永久保留；
- annotation context 必须实际命中 anchor，不能返回章节开头冒充成功。

PDF 的长期边界：

- ordinary `pdf list` 是 bounded inventory，不 materialize 全库 rich Book，也不公开绝对 path。唯一可用 Book identity 输出 `bookAssetID`；fallback、无 stable Book identity 或同一文件对应多本 Book 时输出 deterministic opaque `pdfSourceID`。两者都是后续 exact action 的 public selector。
- `pdfSourceID` 表示 validated source slot/path identity，不表示内容版本；fallback slot 由 no-follow 打开的 root directory identity + 单组件 entry name 派生，library opaque slot 由 lexical standardized Book path 派生。public token 不反射 path。
- fallback discovery 由 root directory FD 拥有 trust boundary：拒绝 root symlink/non-directory，随后只通过 `readdir` + `openat(..., O_NOFOLLOW)` + `fstat` 分类 direct regular `.pdf` entry；不递归、不 fuzzy、不用 symlink-resolved target path 建立 ordinary identity。
- library Book path 只有满足 ordinary resource path budget、lexical absolute standardized grammar，并经 no-follow regular-file open/fstat 后才成为 PDF source；同 inode 的 library/fallback source只出现一次，symlink fail closed。
- inventory cursor generation 同时绑定 library SQLite generation 与当前 library/fallback file inventory state；任一 mapping、entry 或 file metadata 变化都会使旧 cursor stale。
- PDFKit 在独立 worker process 中运行；worker 对收到的 path 自己执行 no-follow open，并通过已打开 descriptor 读取，避免验证后重新跟随被替换的 path。timeout/crash/malformed output 都是结构化 failure。
- 无法恢复 text 时仍保留 raw highlight/note/page/geometry；color mapping 只是 presentation approximation。

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

修改 store/source/identity、Core↔CLI ownership、ordinary/raw projection、hard resource budget、EPUB/PDF source model、export ownership 或 cloud layering 时更新本文。当前实现证据来自 `Sources/AppleBooksCore/**`、`Sources/AppleBooksCLI/**` 与对应 executable tests；用户能力变化同时更新 [`capability-matrix.md`](capability-matrix.md)，mutation/restore 变化同时更新 [`write-safety.md`](write-safety.md)。
