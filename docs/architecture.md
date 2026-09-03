# AppleBooksCLI 架构与领域边界

> 本文是 AppleBooksCLI 的长期架构 owner：记录跨文件仍需稳定保持的数据流、身份、分层与失败边界。用户可见能力范围由 [`capability-matrix.md`](capability-matrix.md) 拥有；写入/恢复顺序由 [`write-safety.md`](write-safety.md) 单独拥有；命令参数以 CLI `--help` 为准。

## 文档职责

- **Audience**：修改 AppleBooksCore、CLI、EPUB/PDF、export、mutation 或下游集成的维护者。
- **Job**：解释哪些数据由谁拥有、不同 source 如何分轨、哪些 identity/derived value 不能互换。
- **Edit trigger**：数据源、领域 identity、query/content/export owner、CLI/core 分层、配置语义或下游消费边界变化。
- **Evidence**：`Sources/AppleBooksCore/**`、`Sources/AppleBooksCLI/**`、`Tests/AppleBooksCoreTests/**`、`Tests/AppleBooksCLITests/**` 与 capability parity tests。

## 数据流与 ownership

```text
Apple Books
├── BKLibrary SQLite
├── AEAnnotation SQLite
├── local / iCloud EPUB resources
└── PDF files
          │
          ▼
    AppleBooksCore
    ├── read/query
    ├── EPUB / CFI
    ├── PDF worker protocol
    ├── export
    └── guarded mutation / restore
          │
          ▼
    applebookscli
    ├── human stdout
    ├── stable JSON
    ├── exported files
    └── explicit mutation commands
          │
          ▼
    downstream consumers
```

下游消费者只消费 CLI 的稳定输出或产物，不应重新 query Apple Books SQLite、复制 Core Data schema、重新实现 CFI/EPUB resolver、扫描 PDF internals，或绕过 guarded mutation rail。

## Runtime 与依赖边界

- Swift 6 / SwiftPM，deployment target 为 macOS 12。
- SQLite 直接使用 SDK `SQLite3` C API，不引入第二套 SQLite runtime。
- `swift-argument-parser` 只负责 CLI parsing；SwiftSoup 用于 XHTML/HTML parsing；ZIPFoundation 用于 packed EPUB。版本与许可证真源在 `Package.swift` / `Package.resolved` / `THIRD_PARTY_NOTICES.md`。
- PDFKit 只运行在独立 `applebookscli-pdf-worker` process 内；worker 不读取 Apple Books DB/config，也不扫描 root。
- 不引入 ORM-style manager。query、content、export、mutation 各自直接拥有自己的 domain logic。

## 两个 SQLite store 必须分开

BKLibrary 与 AEAnnotation 是两个独立 store：

- 分别发现、分别允许 override、分别打开连接；
- 普通读取使用 strict read-only SQLite connection；
- annotation 生命周期不依赖 current BKLibrary row 存在；
- current Book metadata 只是 annotation enrichment，不是 annotation existence 条件。

读取与写入使用不同 schema 策略：

```text
读取 optional column 缺失
→ capability degradation / nil

写入 required table/column/entity 漂移
→ fail closed
```

具体写入与 restore ceremony 不在本文复制，唯一 owner 是 [`write-safety.md`](write-safety.md)。

## Identity 与 raw semantics

### Book

- current stable source identity 优先使用 Apple Books asset ID；local `Z_PK` 只属于当前本机 DB。
- title/author/genre 可以作为 search 输入，但同名结果不能静默选第一条。
- raw author、raw schema metadata 与 derived normalization 分层；derived display value不能反写 source identity。

### Annotation

- `ZANNOTATIONUUID` 是首选稳定 annotation identity；numeric PK 只用于明确的本机/诊断兼容路径。
- raw type/style/underline/selected/note/representative/CFI/physical range/time 必须保留。
- `appleBooksURL` 只从 raw asset ID + optional raw CFI 派生，供 CLI/export presentation 共享；它不是 source identity，也不能反向覆盖 raw CFI。
- user annotation scope 与 raw/system scope 分开；type=3 current-reading bookmark 不能与展示层 `presentationKind=bookmark` 混为同一语义。
- soft-deleted row 默认不进入普通读取。

### Collection

- stable collection ID 与 local PK 都可作为精确 selector；title 属于 search，不是唯一 identity。
- system collection 与 editable user collection 分开，写入必须 fail closed。

### PDF

PDF highlight 不伪装成 EPUB annotation：

- identity 由 canonical PDF file source + page/traversal geometry 表达；
- 不制造 annotation UUID 或 EPUB CFI；
- PDFKit `modificationDate` 不改名成不存在的 creation time；
- approximate text/color mapping 必须保留 provenance。

## Configuration 与 historical annotation

默认配置文件为 `~/.config/applebookscli/config.json`；调用方也可通过 CLI `--config` 指定其它配置文件。当前配置只拥有两类长期语义：

- `epub_root`：current Book 的 directory source missing/unavailable/unsupported 时，按 current `ZPATH` basename 在显式 supplemental root 查找 exact packed `.epub`；不递归、不 fuzzy，unsafe primary 不被 fallback 掩盖。
- `historical_assets`：按 exact asset ID 提供 historical metadata enrichment；它不能授予 current Book/content identity。

annotation source 的领域类别分为 current library、explicit historical mapping 与 unmapped。CLI JSON 的 `source.kind` 当前分别为 `currentLibrary`、`historicalInferred`、`unmapped`；这些 machine values 若变化必须同步 CLI contract/tests，不能沿用旧设计稿名称。

historical/unmapped annotation 必须保留；不能用 inner join current BKLibrary 过滤掉。完整 note archive 对 unmapped note-bearing rows 另有 fail-closed materialization gate。

## EPUB / CFI

EPUB source resolver 的长期边界：

1. current Book 的真实 `ZPATH` 优先；materialization 检查本身不能触发 iCloud hydration。
2. unsafe primary source 直接失败，不允许 supplemental fallback 掩盖安全问题。
3. directory 与 packed EPUB 共享同一 package/encryption/navigation/chapter/metadata/cover parser 语义。
4. navigation 顺序为 EPUB nav → NCX fallback → spine fallback，并保留 depth/fragment。
5. href/path canonicalization 负责阻止 root escape；packed archive namespace 与 EPUB URI decode 分层，不能重复 percent-decode。
6. chapter plain text 保留段落结构；fragment-scoped chapter 不能串到同 XHTML 的其它 section。
7. chapter pagination 按 Swift Character / extended grapheme cluster 计数，不按 byte 或 UTF-16 切开组合字符。
8. raw CFI 永久保留；chapter hint 是 optimistic interpretation，不冒充完整 CFI validator。
9. annotation context 只有 anchor 真正在对应 chapter 命中时才称为 context；anchor miss 返回结构化 degraded/unavailable，不返回章节开头冒充结果。

## PDF worker

PDF 读取保持独立 process 边界：

- source 必须是 canonical readable regular `.pdf`；默认 fallback root 只枚举直接 child，不递归、不 fuzzy。
- 每个候选都进入 PDFKit worker；没有 raw `/Highlight` negative gate，也没有 persistent scan cache。
- parent 对每个 worker 做 bounded timeout，并持续 drain pipes；timeout/crash/malformed/oversize 都是结构化 failure。
- QuadPoints 先从 annotation-local 坐标转换到 page-space，再尝试恢复 text；无 usable quads 时允许 bounds fallback。
- text 无法恢复时仍保留 raw highlight/note/page/geometry，并给 unavailable reason。
- nearest five-color mapping 只是 presentation approximation；保留 normalized RGBA、distance 与 `isApproximate`。

## Export 分层

Export pipeline 必须保持：

```text
query/content/PDF source
→ canonical ExportBundle / records
→ filters + ordering + grouping
→ renderer
→ confined filesystem writer
```

长期边界：

- renderer 不 direct SQL，不反写 canonical identity。
- JSON 是 schema-versioned machine artifact；CSV 保持 RFC4180 escaping 并对字符串 formula trigger 做 neutralization；HTML self-contained 且用户内容只进入 escaped text context。
- Markdown plain 与 Obsidian-compatible profile 都消费同一 canonical records。
- `smart / always / never` overwrite 属于 writer contract；默认不覆盖现存文件。
- filename、attachment、author page 与 complete archive 共用 confinement owner；symlink/path traversal/target race fail closed。
- complete note archive 才启用独立 raw aggregate count/materialization gate；普通 filtered export 不被该 gate 阻断。
- multi-file complete archive 先写同 parent staging，materialized document count 通过后才用 exclusive rename 发布，不原地混写现有 final directory。

## CLI 与下游边界

CLI root 当前拥有 `doctor`、`books`、`reading`、`stats`、`content`、`annotations`、`collections`、`pdf`、`export`、`backups`、`skill`。完整参数不在文档手抄，使用：

```sh
applebookscli <group> --help
```

machine/human process contract 由 [`cli-contract.md`](cli-contract.md) 拥有。Notion、MCP 或其它消费者不得要求 AppleBooksCore 为特定 transport/UI 复制一套业务逻辑。

## 架构非目标

产品层“已实现 / 当前限制 / 明确不支持”的清单只在 [`capability-matrix.md`](capability-matrix.md) 维护，本文不复制。架构层长期保持：

- 不为 MCP、Notion 或其它 transport/UI 建第二套 Apple Books 业务实现；
- 不引入 ORM-style manager 或第二套 SQLite runtime；
- PDF raw-marker prefilter / persistent cache 不能成为 correctness gate，除非未来有独立需求、可证明无 false-negative 的 invalidation 与对应测试。

新增产品能力必须先更新 capability owner；涉及 write safety 的能力还必须同步 [`write-safety.md`](write-safety.md)。

## 维护验证

修改本页涉及的架构边界时，至少应让现有对应 tests 与 capability gates 证明行为仍成立；release version、channel 与 publication pipeline 由 [`release.md`](release.md) 拥有，本文不复制。用户可见范围变化必须同步 [`capability-matrix.md`](capability-matrix.md)；mutation/restore 语义变化必须同步 [`write-safety.md`](write-safety.md)。
