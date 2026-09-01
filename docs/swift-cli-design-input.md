# Swift Apple Books CLI 设计输入

> 本文描述已经确认的架构边界与实现输入。**功能范围以 `capability-matrix.md` 为唯一 parity 真源**；本文不再维护一份较小的“MVP 范围”。具体命令名字仍可在实施计划阶段微调，但不能因此删减 parity 能力。

## 已确认目标

先完成：

> **把当前 capability contract 完整实现为一套 Swift CLI；等价能力合并，不复制 MCP 包装层，也不先做未确认的新功能。**

实现可以分 phase 逐步提交，但在 parity gate 通过以前：

- PDF 不是可选后续项。
- export 不是可选后续项。
- 已确认的 collection / annotation writes、backup / restore 不是可选后续项。
- MCP/Obsidian 的实际功能不能因为包装被排除而一起消失。
- 不开始 create-highlight、Notion importer 等尚未进入当前 contract 的新功能。

## 数据流边界

```text
Apple Books
├── BKLibrary SQLite
├── AEAnnotation SQLite
├── local / iCloud EPUB bundles
└── PDF files
          │
          ▼
    Swift applebookscli
          │
          ├── human stdout
          ├── stable JSON
          ├── Markdown / CSV / HTML exports
          └── guarded mutations
                    │
                    └── future consumers such as Notion importer
```

Notion importer 以后不得：

- 自己 query Apple Books SQLite。
- 自己理解 Core Data schema。
- 自己重新发明 CFI parser / EPUB ToC resolver。
- 自己扫描 PDF highlight internals。

它只消费 CLI 的稳定输出。

## 包装层翻译原则

### 不复制

- MCP stdio server / tool registration。
- MCP `TextContent`。
- MCP resources / prompts 对象。
- Obsidian ribbon、modal、settings tab 本身。

### 但必须翻译功能

例如：

```text
Obsidian “Select Books to Import” modal
→ CLI 一个或多个稳定 book selector

Obsidian settings toggles
→ CLI flags / export profile

MCP recent_annotations
→ CLI annotation query/sort/limit

MCP library stats
→ CLI stats
```

只排除宿主/transport，不排除它们承载的用户能力。

## 技术基线

优先：

```text
Swift 6
Swift Package Manager
SDK SQLite3 C API
```

当前 Swift 6.4 已实测可直接 `import SQLite3` 并调用系统 SQLite；P1 不引入第三方 SQLite 包。SQLite online backup、WAL/open-reader 行为必须在后续写安全 fixture 中用 Swift/SQLite3 验证。

第三方依赖只在对应 task 已证明平台/标准库不足时首次引入，并与 license/provenance 同 commit。当前 EPUB XHTML 解析与 packed EPUB 读取已经在各自真实 consumer 出现时落地，长期设计文档只约束行为与安全边界，不重复依赖来源、revision 或 provenance。PDF 已由当前 macOS SDK 的 PDFKit + 独立 worker process 落地并通过可控 fixture 验收；首版不在 PDFKit 前增加 raw-marker negative gate 或 persistent scan cache，避免性能 heuristic 变成 correctness gate。

## 不做小 ORM

Swift CLI 不引入 ORM-style model manager；查询直接落在职责明确的 Swift query owners。

逻辑边界应围绕真实职责形成，例如：

```text
DB discovery / read-only query
books
annotations
collections
EPUB / CFI
PDF highlights
export renderers
write safety / mutations
CLI dispatch
```

文件怎么拆由实际代码规模决定，不提前制造一整棵抽象目录。

## 核心领域对象

### Book

至少保留 raw/source identity 与 parity 所需 metadata：

```swift
struct Book {
    let localPK: Int64            // current local Core Data Z_PK
    let assetID: String?          // Apple Books source identity may be absent
    let title: String?
    let author: String?           // raw value is preserved
    let description: String?
    let epubID: String?
    let genre: String?
    let genresRaw: Data?          // raw ZGENRES BLOB; unknown encoding is never guessed
    let comments: String?
    let language: String?
    let year: Int64?
    let contentType: Int64?
    let pageCount: Int64?
    let path: String?
    let fileSize: Int64?
    let coverURL: String?
    let isFinished: Bool?
    let readingProgressRaw: Double?
    let durationRawMilliseconds: Double?
    let creationDate: Date?
    let modificationDate: Date?
    let finishedDate: Date?
    let lastOpenDate: Date?
    let purchaseDate: Date?
    let releaseDate: Date?
    let isExplicit: Bool?
    let isLocked: Bool?
    let isEphemeral: Bool?
    let isHidden: Bool?
    let isSample: Bool?
    let isStoreAudiobook: Bool?
    let rating: Double?

    var normalizedAuthor: String?       // derived only; never mutates raw author
    var readingProgressPercent: Double?
    var durationSeconds: Double?
}

struct EPUBMetadata {
    let title: String?
    let creator: String?
    let identifiers: [String]
    let isbn: String?
    let language: String?
    let publisher: String?
    let publicationDate: String?
    let rights: String?
    let subjects: [String]
}

struct BookMetadataEnrichment {
    let isbn: String?
    let language: String?
    let publisher: String?
    let publicationDate: String?
    let rights: String?
    let subjects: [String]
}
```

Cover payload 已收敛为原始 `Data`、declared/detected media type 与 source；它不暴露第三方 parser 类型。Optional DB 字段由实时 schema capability 决定。不要以 title 去重；同名不同 asset 是合法情况。`EPUBMetadata` 是独立 content metadata；对 `Book` 的 enrichment 只补明确缺失的 metadata，不覆盖 current-library identity/title/author 等 raw source 字段。

### Annotation

canonical raw object 至少：

```swift
struct Annotation {
    let id: Int64                 // local Z_PK
    let uuid: String
    let assetID: String
    let type: Int?
    let style: Int?
    let isUnderline: Bool
    let selectedText: String
    let representativeText: String
    let note: String
    let cfi: String
    let physicalLocation: Double?
    let rangeStart: Double?
    let rangeEnd: Double?
    let createdAt: Date?
    let modifiedAt: Date?
}
```

Derived enrichment 可以额外给：

```swift
enum AnnotationSourceKind: String {
    case currentLibrary = "current_library"
    case historicalInferred = "historical_inferred"
    case historicalUnmapped = "historical_unmapped"
}

struct AnnotationEnrichment {
    let chapterID: String?
    let chapterTitle: String?
    let book: BookSummary?
    let sourceKind: AnnotationSourceKind?
}
```

规则：

- raw type/style/CFI 永远保留。
- presentation heuristic 不能改变 annotation UUID/row identity。
- export 可额外计算 `presentationKind` 兼容既有展示语义：note 非空→`note`；否则 selected text 为空→`bookmark`；否则→`highlight`。这个字段只服务展示/过滤，不能反写 raw type。
- type=3 reading-position bookmark 和用户 annotation 分轨；它与 `presentationKind='bookmark'` 不是同一个概念。

### Chapter

当前 Chapter contract：

```swift
struct Chapter {
    let id: String
    let title: String
    let href: String
    let fragment: String
    let order: Int
    let depth: Int
}
```

这同时适合未来把完整 EPUB 投影成 Notion 子页面树，但 CLI 本身不包含 Notion 逻辑。

### PDF highlight

PDF 不伪装成 EPUB CFI annotation。P6 已验收的 canonical PDF highlight 保留平台实际可取得的数据与 provenance：

```swift
struct PDFHighlight {
    let page: Int                    // 1-based physical page
    let traversalIndex: Int          // page-local parse/tie-break identity
    let bounds: CGRect
    let quadrilateralPoints: [CGPoint]
    let note: String?
    let pdfKitRGBA: [Double]?
    let presentationColor: PDFColorMatch?
    let modifiedAt: Date?
    let text: String?
    let textSource: PDFHighlightTextSource?
    let textIsApproximate: Bool
    let textUnavailableReason: PDFHighlightTextUnavailableReason?
}
```

`modifiedAt` 直接来自 PDFKit 的 `modificationDate` absolute instant；没有独立来源就不制造 `createdAt`。QuadPoints text 使用 page geometry 恢复并显式标记 approximate；恢复不到 text 时 raw highlight、note/page/geometry 仍保留。颜色同时保留 PDFKit-normalized RGBA 与 approximate presentation mapping，不声称是原始 PDF dictionary `/C`，也不生成虚假的 CFI/annotation UUID/Apple asset identity。

## Selector contract

### Book

首选稳定 selector：

```text
assetId
```

兼容：

- local numeric `Z_PK`。
- search 结果 → assetId。

title 可以作为 search 输入，但多结果时不能静默选第一本。

### Annotation

用户级写操作首选：

```text
ZANNOTATIONUUID
```

numeric PK 只作为明确兼容/诊断 selector。

### Collection

支持：

- Core Data local id。
- `ZCOLLECTIONID`。
- title search。

系统 collection 和用户 collection 必须显式区分。

## CLI 能力分组候选

下面是 capability grouping，不要求最终逐字采用这些 command names；但不能少掉 `capability-matrix.md` 的功能。

```text
apple-books
├── doctor
├── stats
├── books
│   ├── list
│   ├── get <book>
│   ├── search <query>
│   ├── by-genre <genre>
│   ├── in-progress
│   ├── finished
│   ├── unstarted
│   ├── recent
│   ├── current-position <book>
│   ├── chapters <book>
│   └── chapter <book> <chapter>
├── annotations
│   ├── list
│   ├── get <annotation>
│   ├── search <query>
│   ├── search-highlight <query>
│   ├── search-note <query>
│   ├── by-color <color>
│   ├── recent
│   ├── date-range
│   ├── context <annotation>
│   ├── update-note <annotation>
│   └── delete <annotation>
├── collections
│   ├── list
│   ├── get <collection>
│   ├── search <title>
│   ├── books <collection>
│   ├── create
│   ├── rename
│   ├── delete
│   ├── add-book
│   └── remove-book
├── pdf
│   └── highlights [...selectors]
├── export
│   ├── markdown
│   ├── json
│   ├── csv
│   └── html
└── backups
    ├── list              # parity: BKLibrary public backups
    └── restore           # parity: BKLibrary public restore
```

如果一个更小的命令集合能用 flags 无歧义地覆盖同样能力，可以合并；**能力 parity 比 command 名字 parity 更重要**。

## 查询与 JSON 输出 contract

所有查询型命令应有稳定 JSON 输出，例如：

```text
--json
```

约束：

- stdout 只输出结果。
- progress/diagnostic 去 stderr。
- JSON 不混入 human log。
- exit code 表示成功/失败。
- human output 可以 table / compact text。
- list 命令统一定义 limit/offset/order 参数形态，同时保留领域排序：例如按书 annotations 的 ToC chapter reading order，以及全库 annotations 的 creation newest-first grouped view。

Notion 等下游消费 JSON，不解析 Markdown。

## Annotation query scope

CLI 查询层必须显式区分 `user-only` 与 `include-system/raw`：user-only 排除 type=3 reading-position rows；raw scope 可以包含 active type=3。soft-deleted rows 两种 scope 都默认排除；诊断 raw-deleted 数据需要另行显式入口，不能和普通查询混在一起。

## 两种 recent annotation 不能合并错

CLI 必须同时表达 recent-by-creation 与 recent-by-modification。后者还必须能与 raw scope 组合以包含 active type=3 rows。可以合并到一个入口，例如显式 time-field + scope flag，但不能默认选一种语义后删掉另一种。

## Annotation 时间与上下文语义

`date-range` 如果接受 `YYYY-MM-DD`，必须把它定义成用户所在本地时区的完整日历日：`after` 从当天 00:00:00 起，`before` 到当天结束；也可以只接受完整 timestamp，但不能把 `before=YYYY-MM-DD` 偷换成当天 00:00:00 后再做 `<=`。

`annotation context` 只有在 selected/representative anchor 真正在对应 chapter text 中命中时，才能把返回窗口称为该 annotation 的 context。anchor 未命中、CFI chapter 不可解析、书本未下载或 DRM 时，返回结构化 unavailable/degraded reason；不能返回章节开头冒充精确批注上下文。

## EPUB / CFI parity

必须覆盖：

1. 检查 local materialization，检查本身不能触发 iCloud hydration。
2. DRM/FairPlay gate。
3. ToC：正常 parser → NCX fallback → spine fallback。
4. `depth` / `fragment`。
5. 同一 XHTML 多 navPoint 按 fragment scope。
6. ToC 外细粒度 spine entry 可读。
7. chapter plain text。
8. chapter content `offset + max_chars` 分页等价能力；offset 以扩展 grapheme cluster 计数，不按 byte/UTF-16 切开 emoji/CJK 组合字符。
9. CFI raw round-trip。
10. CFI chapter hint 与 leaf text-node char range diagnostics。
11. annotation context：current Book identity + chapter + selected/representative anchor 二次定位；只有 anchor 命中时才返回 context window。
12. context 不可用或 anchor 未命中时返回结构化 degraded reason，不返回章节开头冒充 context；historical metadata 不替代 current content identity。
13. current reading position 三层语义：ToC 可解析 bookmark → raw bookmark hint → 最近用户 annotation inference；后两者不能伪装成精确 ToC bookmark。
14. content source：current Book 的 directory `ZPATH` 优先；primary missing/unavailable/unsupported 时才允许在显式 supplemental root 中按 `ZPATH` basename 查 exact packed `.epub`。unsafe primary 不 fallback，historical/unmapped row 不猜 content。
15. directory 与 packed source 必须共享同一 package/encryption/nav/NCX/chapter/metadata/cover parser；archive entry name 不做第二次 percent decode。
16. 每个 exact resource 有固定 byte budget；packed source同时检查 declared uncompressed size 与 streaming actual output，并限制 archive entry count。

大书完整读取应通过 `chapters` + `chapter` 组合自然流式完成，不需要默认把整本几十万字塞进一个 JSON string。

## PDF parity

PDF 是 parity 必做，并已在 core 层完成 P6 验收。当前产品 contract 是：

1. `ZCONTENTTYPE=3` 提供 current-library PDF metadata；exact canonical `ZPATH` 优先，固定 iCloud Documents root 只枚举直接 regular `.pdf` children，不递归、不 fuzzy。
2. 每个候选 PDF 直接进入 isolated PDFKit worker；首版**没有** raw `/Highlight` marker negative gate，也**没有** mtime/size persistent cache 或 rescan/cache controls。只有 PDFKit 完整成功解析后的 zero highlights 才能表示“无 highlight”。
3. worker 只处理单个 canonical regular PDF；不读 Apple Books DB/config，不扫描 root，不维护 hidden state。
4. PDFKit 枚举 `.highlight` annotations，保留 1-based page、traversal index、bounds、quadrilateral points、contents note、normalized RGBA 与 modification date。
5. QuadPoints 先从 annotation-local 坐标加 `bounds.origin` 转为 page-space，再用 `PDFPage.selection(for:)` 恢复 text；English/CJK、partial/repeated/non-zero-origin fixture 已验证。结果是 geometry-derived approximate，不冒充规范级文本 identity。
6. 无 usable quads 时允许 bounds fallback；text 无法恢复时保留 highlight 并给 unavailable reason。
7. nearest five-color palette 只作 presentation mapping；保留 distance/approximate provenance，不声称能识别原始 `/C` presence。
8. 单 PDF bounded timeout 由 parent process 强制执行：持续 drain stdout/stderr；超时 terminate，短 grace 后仍存活才 SIGKILL，最后 wait/reap。crash、malformed protocol、oversize output、timeout 都是 structured failure，不冒充 empty result。
9. 多 PDF service 对单文件 failure 继续其它 source；相同 inventory 每次都会进入 parser，没有 hidden persistent scan state。
10. exact library Book metadata优先；无 Book source时 title 仅 fallback filename。PDF source identity 始终是 canonical file path，不把 filename/base name 伪造成 Apple asset ID。

PDF 路径不能生成不存在的 EPUB CFI/annotation UUID，也不能把 PDFKit `modificationDate` 改名成虚构的 creation time。

## Export parity

### 通用格式

必须有：

- Markdown。
- JSON。
- CSV。
- HTML。

必须支持：

- 全库 / 单书或选择多书。
- single-file / per-book（适用格式）。
- highlights/bookmarks/notes 类型过滤。
- include-bookmarks。
- color/underline 过滤。
- partial offset/skip。
- export statistics。
- annotation ordering：按 location/CFI 阅读顺序排序或保留来源顺序。
- EPUB/PDF source scope：必须能表达是否包含 PDF highlights。
- custom annotations/library DB paths（用于 export 也可走全局 DB selector）。

### HTML

HTML parity 已在 P6 以 self-contained artifact 验收，不只是“能生成静态 HTML”：

- search 覆盖 book title/author/annotation text/note，并直接读取 DOM `textContent`，不把用户正文嵌入 JS literal。
- per-book collapse/expand 与 collapse all / expand all。
- namespaced localStorage state；collapse/sidebar 只保存生成的 `book-N` token，不保存 raw asset/title/path。
- sidebar navigation / active item 与 mobile sidebar toggle/click-outside。
- responsive layout。
- print styles 隐藏 search/navigation/control 并强制展开正文。
- CSS/JS 全部内嵌；不依赖 CDN、remote font 或 runtime network request。
- 用户 title/author/identity/path/text/note 都作为 escaped text context 输出，不参与 raw DOM id/href/script identity。

### Obsidian-compatible Markdown profile

不复制 Obsidian settings UI，但需要等价表达当前输出 contract：

- output folder。
- selected books。
- smart / always / never overwrite；`smart` hash 必须覆盖真正决定生成文件内容的全部稳定输入，不能只 hash body 而漏掉 frontmatter/renderer settings。
- last-import hash。
- extended frontmatter。
- extended metadata section。
- tags/custom tags。
- cover inline / cover file。
- chapter headings。
- annotation date（EPUB 以 modifiedAt 优先、createdAt fallback；PDF 只保留可核实的 modifiedAt）。
- annotation location/CFI sorting toggle。
- style / underline indicator。
- reading progress。
- citation。
- author pages，保留 Dataview 语义或提供明确等价的 Obsidian-compatible 输出。

consecutive null-location annotation grouping 已收敛为显式 opt-in presentation behavior：canonical 数据层不合并 row；连续无位置 records 只能借用后续 located record 的 chapter presentation，成员自身 identity/text/note/time/style 全部保留，尾部无 location records 也不得丢失。它与 current reading position 没有任何 identity 关系。

### Export file safety / complete note archive

P6 文件输出与完整 note archive 已形成独立于 renderer 的安全边界：

- 普通 file output 统一经过一个 filesystem writer；默认 overwrite policy 是 `never`，`smart/always` 必须显式选择。
- `smart` hash 基于稳定 generated bytes；只忽略首个 Markdown frontmatter或 JSON 顶层的 run-only timestamp/self-hash 字段，正文或 nested 同名稳定字段变化仍必须触发更新。
- title/author/source-derived filename 只能生成受限单 path component；separator/control/`.`/`..`/leading-trailing dot-space、collision、symlink destination/parent 均由同一 confinement owner 处理。
- cover inline 使用真实 media type data URL；cover file 与 author sidecar 复用同一 writer/confinement path。
- 完整 note archive 才启用独立 raw aggregate safety gate；普通 filtered query/export 不受影响。
- aggregate 使用 canonical active predicate（deleted 必须精确为 `0`，NULL 不视作 active），独立计算 raw nonempty note/selected-text totals，不用已经 materialized 的 records 自证。
- raw note 包括 whitespace-only；note-bearing historical-unmapped row、note 无 selected/representative quote、raw count mismatch 都 fail closed。
- 完整 per-book/sidecar archive 的 final directory 必须预先不存在。所有文件先写同 parent 的受控 staging；实际 materialized document count PASS 后才以 exclusive same-filesystem rename 发布。mid-write failure、count mismatch 或 final-target race 都保持 final 不存在/不覆盖竞争者，并只清理本次受控 staging。

## Safe write contract

详细安全不变量见 `write-safety.md`。已确认 UX：

```text
read-only preflight
→ schema/entity validation
→ target preflight
→ online backup
→ backup integrity
→ record wasRunning
→ if wasRunning: clean quit Books
→ writable connection
→ BEGIN IMMEDIATE
→ revalidate target
→ mutation + invariant check
→ COMMIT / ROLLBACK
→ close
→ if wasRunning: relaunch Books
→ read-only read-back
```

Parity writer 必须包括：

- collection create / rename / delete。
- add/remove book membership。
- update existing annotation note。
- soft-delete existing annotation。
- BKLibrary backup list / retention。
- BKLibrary public restore。
- annotation mutation 仍必须内部创建可校验 backup 并返回 backup path；public annotation-backup list/restore 不在当前 contract，留到 parity 后再决定。

COMMIT 后 relaunch 失败：success + warning。

写命令必须保留显式输入边界校验。selector/search/name/note 都要有格式与长度保护；annotation note 当前 contract 上限为 10,000 字符。CLI 可以统一参数校验规则，但不能删除这类保护。

当前 collection write contract 尚未证明写入会通过 iCloud 传播到其他设备。在真实多设备验收前，CLI 必须保留这一 caveat，不能承诺 cross-device sync。

## Historical annotations：本地迁移不回归

这是当前本机迁移已经验证的必要能力，Swift 重构不能退化：

```text
AEAnnotation row
    │
    ├── current BKLibrary metadata found → current_library
    │
    ├── explicit historical mapping       → historical_inferred
    │
    └── neither                           → historical_unmapped
```

`macos-27-schema-baseline.md` 已用当前实机证明 selected-text annotations 中存在不再属于 current BKLibrary 的 asset，因此不能用 inner join current BKLibrary 作为 annotation 存在条件。

当前 `config.json.epub_root` 已由 Swift content resolver保留：current BKLibrary row 必须先提供真实 `ZPATH` identity；directory source不可用时，才按该 `ZPATH` 的 basename 在显式 supplemental root 中查 exact regular packed `.epub`。这条 fallback 不递归、不 fuzzy，也不延伸到 historical title/author/asset-ID 猜测。

## 实现顺序 ≠ 发布范围

为了原子提交、测试与 audit，可以按下面顺序实现：

### Phase A — Read DB / domain queries

- doctor / DB discovery / override。
- books / reading status / stats。
- annotations / recent/date/search/color。
- collections read。
- stable JSON / pagination。
- historical/orphan preservation。

### Phase B — EPUB / CFI

- local/DRM gates。
- ToC / chapter / pagination。
- CFI / context / current position fallback。
- metadata/cover enrichment。

### Phase C — PDF

- prefilter/cache。
- QuadPoints text extraction。
- note/page/color/time。
- timeout / metadata fallback。

### Phase D — Export surfaces

- JSON / Markdown / CSV。
- interactive HTML。
- filters / single-per-book / partial offset。
- Obsidian-compatible renderer profile。

### Phase E — Safe writes

- online backup / restore primitive；public parity 至少覆盖 BKLibrary list/restore，annotation writes 只要求安全 backup primitive。
- schema fail-closed。
- Books.app lifecycle。
- collection mutations。
- annotation update/delete。

### Phase F — Parity audit

逐项对 `capability-matrix.md`：

- 每个“必须复刻”有 executable validation。
- 每个“宿主能力翻译”有明确 CLI 等价入口。
- 每个“包装排除”没有误删底层功能。
- 本地保留能力没有回归。

**只有 Phase F 全部通过，才允许开始新的产品功能。**

## Parity gate 之后

当前明确不进入 parity 实现：

- 创建全新的 Apple Books highlight / annotation。
- 修改 selected-text / CFI range。
- 写 current reading position。
- Notion import / projection。

它们后续需要重新 brainstorming / 逆向 / plan，不能偷渡进 parity 实现。

## 仍可在实施计划阶段决定的非范围问题

这些不会改变 parity 能力：

- 最终可执行文件是否就叫 `apple-books`。
- human table 的列宽/样式。
- 能力相同的 commands 是拆开还是用 flags 合并。
- EPUB/PDF parser 的具体依赖选择，只要行为与测试满足 contract。
