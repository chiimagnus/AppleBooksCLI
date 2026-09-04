# AppleBooksCLI 能力与范围矩阵

> 本文是 AppleBooksCLI **当前用户可见能力、明确不支持项与安全边界**的唯一范围 owner。它不记录迁移 phase、历史验收状态或命令 help 快照；参数与命令名以当前 CLI `--help` 为准。

## 范围标记

- **已实现**：当前产品能力；该行必须存在 implementation/test/CLI reachability machine anchor。
- **已实现（强化）**：能力存在，同时带有额外 correctness/safety 边界。
- **已实现（CLI 等价）**：业务语义由 CLI 表达，不复制原宿主 UI/transport。
- **已实现（展示）**：当前 presentation/output 能力，不改变 canonical row identity。
- **当前限制**：当前产品仍存在的已知边界，不作为可调用 capability。


## 数据访问与诊断

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| SQLite DB 自动发现 | 已实现 | 固定目录内按 prefix + `.sqlite` 确定性发现；读取显式 read-only |
| 自定义 annotations/library DB 路径 | 已实现（强化） | 支持显式 DB override，便于 fixture、迁移与诊断；单独 override 一个 store 必须生效或明确报错，不得静默忽略 |
| Full Disk Access / DB 可访问性诊断 | 已实现 | `doctor` 类入口给出清晰权限/路径/schema 错误，不把它混进 stdout 数据 |
| 读取 schema capability detection | 已实现 | optional column 缺失时降级字段，而不是整条读取路径崩溃 |
| 写 schema fail-closed | 已实现 | 写前验证 table/column/entity/NOT NULL invariant；漂移即拒绝写 |
| help / version | 已实现 | 根 CLI 提供可发现的 help 与 version |
| 人类输出与机器输出分离 | 已实现 | stdout 可组合；查询命令提供结构化 JSON；diagnostic 走 stderr |

## Books

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list books | 已实现 | 可分页，也能显式取全量；不能只列“有批注的书” |
| list books with annotations | 已实现 | 提供 annotated-only filter / view，并返回 annotation count |
| get/describe book | 已实现 | asset ID / numeric PK 可定位；详情包含 metadata、reading status/dates、rating、description、annotation count；机器协议保留 raw metadata |
| title search | 已实现 | substring search；多结果不能静默选第一本 |
| title/author/genre 综合搜索 | 已实现 | case-insensitive partial match |
| genre 查询 | 已实现 | genre filter 是独立能力，不只靠通用 search 偶然覆盖 |
| 丰富书籍 metadata | 已实现 | description、EPUB id/path、file size、language、date/year、genre、pageCount、rating、comments、coverUrl、reading progress/duration/dates，以及 purchase/release date、explicit/locked/ephemeral/hidden/sample/store-audiobook 等字段/flags按实时 schema 能力返回；`ZGENRES` 只保留 raw BLOB，未证明编码前不得猜成字符串/数组 |
| EPUB OPF / iTunes metadata enrichment | 已实现 | 可独立读取 canonical OPF metadata；iTunes plist 只补 OPF 缺失的 title/creator/publisher。对当前 Book 的 enrichment 只补 ISBN、缺失 language/release date、publisher、rights、subjects，不覆盖 current-library identity/title/author 等原始字段 |
| cover 提取 | 已实现 | manifest `cover-image` / EPUB2 metadata id 优先，有限 exact common-name fallback；返回原始 bytes + declared/detected media type + source，export 决定内嵌还是保存文件 |
| author sentinel normalization | 已实现 | raw author 永久保留；另提供 derived normalized author，移除 Apple 私用字符并把 Unknown/UnknownAuthor sentinel 归一为 nil，展示/文件命名不得把 sentinel 当真实作者身份 |

## Reading status / stats

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| in-progress books | 已实现 | 按 reading progress 查询 |
| finished books | 已实现 | 保留 finished 语义 |
| unstarted books | 已实现 | 未开始阅读查询 |
| recently read books | 已实现 | 按 last-opened 排序，支持 limit |
| library stats | 已实现 | total/finished/in-progress/unstarted、annotation 总量、orphan 数、top annotated books |
| current reading position | 已实现 | type=3 auto bookmark 单独能力，普通 annotations 默认排除 |
| current reading chapter | 已实现 | CFI chapter hint → ToC chapter |
| current-position fallback | 已实现 | auto bookmark 无可用 CFI 时可回退最近用户 highlight，并明确标记 inferred，不能伪装成真实 bookmark |

## Annotations

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list annotations | 已实现 | soft-deleted 默认排除；CLI 必须明确表达 `user-only` 与 `include-system/raw`。user-only 排除 type=3，raw scope 可包含 active type=3，并支持 limit/order/pagination |
| list all / group by book | 已实现（展示） | 全库 user annotations 按 creation newest-first 取数后按书分组；orphan 与 null-location rows 必须保留。机器 JSON 不复制文本 formatter，也不能因展示分组改变 canonical ordering/identity |
| annotations by book | 已实现 | book asset ID / numeric PK 可筛选；user-only 视图优先按 EPUB ToC chapter order、章内 creation 排序；内容不可读时降级到 creation/local-PK 稳定顺序但不得丢 annotation；raw scope 还必须能包含 active type=3 |
| get/describe annotation | 已实现 | UUID 优先；numeric PK 可兼容；返回 raw 字段和关联书籍信息 |
| Apple Books annotation deep link | 已实现（展示） | Core `Annotation` 从 raw asset ID + optional raw CFI 派生 `appleBooksURL`；annotation CLI 与 EPUB export 复用同一值。HTML/Markdown 有 CFI 时让 `Location` 本身可点击，无 CFI 时退化为书籍级链接；JSON/CSV 分别输出 `appleBooksURL` / `annotation_apple_books_url`。deep link 不替代 asset ID / annotation UUID / raw CFI |
| highlights by color | 已实现 | green/blue/yellow/pink/purple；underline 作为独立原始状态保留 |
| export/filter underline | 已实现 | `--colors ...underline` 的用户可见过滤能力不能丢 |
| search highlighted text | 已实现 | case-insensitive partial search |
| search note text | 已实现 | note-only search |
| full annotation text search | 已实现 | selected + representative + note |
| recent annotations by creation | 已实现 | newest by `creation_date`，支持 limit |
| recent annotations by modification | 已实现 | newest by `ZANNOTATIONMODIFICATIONDATE`；raw scope 可包含 active type=3 system rows；不能和 created-recent/user-only 混成一种语义 |
| annotations by date range | 已实现（强化） | created-after/before + limit；date-only `before` 必须覆盖完整日历日或明确要求 timestamp |
| annotation context window | 已实现（强化） | current Book identity 必须精确；CFI chapter + selected/representative text 二次定位；支持 before/after window；anchor 未命中必须明确失败，不能返回章节开头冒充 context；historical mapping 不能替代 current Book/content identity |
| context 中精确标出 highlight | 已实现（展示） | whitespace-normalized anchor match，canonical 首个命中只标一次；保留原 source whitespace，不能重新搜索后误标重复文本 |
| annotation identity | 已实现 | `ZANNOTATIONUUID` 首选稳定身份，numeric PK 仅本机内部/兼容 |
| 保留 raw annotation 字段 | 已实现 | UUID、asset_id、type/style、underline、selected/note/representative、CFI、physical/range、created/modified |

## EPUB / CFI content

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| 本地 materialization 检查 | 已实现 | 检查本身不得触发 iCloud hydration |
| DRM gate | 已实现 | FairPlay/DRM 明确失败，不返回空正文冒充成功 |
| EPUB ToC | 已实现 | EPUB nav/解析器 → NCX fallback → spine fallback；保留 depth/fragment |
| chapter text | 已实现 | 保留段落结构；同 XHTML 多 fragment 不串 section |
| chapter text pagination | 已实现 | `offset` + `max_chars` 等价能力以扩展 grapheme cluster 计数，不按 byte/UTF-16 切分；明确 continuation/end，不能拆开 emoji/CJK 组合字符 |
| 细粒度 spine entry | 已实现 | ToC 未列出的 spine item 仍可按 id 读取 |
| current-library packed EPUB fallback | 已实现 | current Book 的真实 directory `ZPATH` 优先；仅 primary source missing/unavailable/unsupported 时，才可在显式 `epub_root` 下按 `ZPATH` basename 查找同名 regular non-symlink packed `.epub`。不递归、不 fuzzy；unsafe primary 不得被 fallback 掩盖；historical/unmapped annotation 无 current Book/ZPATH 时永不猜 packed 文件 |
| directory / packed parser 等价 | 已实现 | 两种 content source 共用同一 package/encryption/nav/NCX/chapter/metadata/cover parser；packed entry 只做 archive namespace lexical validation，URI percent decode 只发生在 canonical EPUB href/path 层一次 |
| CFI raw round-trip | 已实现 | 原始 CFI 永久保留 |
| CFI chapter hint | 已实现 | optimistic parse，不冒充完整 CFI validator |
| CFI char range diagnostics | 已实现 | 明确 offset 属于 leaf XHTML text node，不是抽取纯文本 offset |

## Collections

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list collections | 已实现 | deleted collection 默认排除 |
| get/describe collection | 已实现 | detail + books；机器 JSON 保留 collectionId、hidden、sortKey、details、lastModification 等公开 raw metadata |
| search collections by title | 已实现 | substring search |
| list collection books | 已实现 | compact/list JSON 两种呈现可合并 |
| create collection | 已实现 | title + optional details；Core Data bookkeeping + safety rail |
| rename collection | 已实现 | system collection fail closed |
| delete collection | 已实现 | collection soft-delete，membership 按 Books 语义处理 |
| add book | 已实现 | idempotent；维护 member PK/sort/parent timestamps |
| remove book | 已实现 | idempotent；系统 collection guard |

## Export / presentation

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| export output destination | 已实现 | 支持 caller 显式文件/目录输出；所有文件写盘统一经过受限 writer，默认 `.never` 不覆盖现存文件，derived filename/path traversal、symlink destination/parent 均 fail closed |
| Markdown export | 已实现 | 支持 canonical bundle 与单书 renderer；plain/Obsidian-compatible profile 都只消费已选好的 records，不 direct SQL，不因展示分组改写 identity |
| JSON export | 已实现 | 当前 `schemaVersion=2`，确定性 single-file / per-document bytes；保留 EPUB/PDF source-specific raw fields、warnings、statistics，EPUB annotation DTO 包含共享派生的 `appleBooksURL`，PDF 不伪造 annotation UUID/CFI |
| CSV export | 已实现 | 固定 UTF-8 BOM + CRLF schema；EPUB annotation 行包含 `annotation_apple_books_url`；RFC4180 quoting；字符串 cell 在 quoting 前 neutralize spreadsheet formula trigger，typed negative number/date/bool 不误处理 |
| HTML export | 已实现 | self-contained HTML；CSS/JS 均内嵌，无 CDN/font/runtime network dependency；用户内容只进入 escaped text context，不进入 raw DOM identity/JS literal |
| HTML 搜索 | 已实现 | client-side 以 DOM `textContent` 搜索 book title/author/annotation text/note，不把用户正文复制进脚本 |
| HTML 单书折叠 + 全部折叠 | 已实现 | per-book collapse/expand + Collapse All/Expand All；只使用生成的 `book-N` token |
| HTML 状态持久化 | 已实现 | collapse/sidebar 状态使用 namespaced localStorage key；持久化值只含生成 ordinal，不含 asset/title/path |
| HTML sidebar / responsive / print | 已实现 | sidebar navigation/active state、移动端 toggle/click-outside、responsive layout；print 隐藏交互控件并强制展开正文 |
| export 类型过滤 | 已实现（强化） | presentation kind 为纯派生层：trim 后 nonempty note→note、否则 selected text 空→bookmark、否则 highlight；filter 不修改 raw type/style，也不把 presentation bookmark 偷换成 raw `ZANNOTATIONTYPE=3` |
| export 颜色过滤 | 已实现 | green/blue/yellow/pink/purple + 独立 underline filter；unknown raw style 不伪造已知颜色，PDF 使用其 approximate presentation mapping |
| export single/multiple file | 已实现 | canonical renderer 支持 single/per-document 语义；完整 note archive 的 per-book/sidecar 写盘必须先写同 parent 受控 staging，实际 document count 校验通过后才 `RENAME_EXCL` 发布，现存 final directory 永不原地混写 |
| partial export offset | 已实现 | per-book skip 在 kind/color/selector filtering 与最终 ordering 后作用于 annotation rows，不绑定 note 类型 |
| export statistics | 已实现 | final statistics 只统计最终 selection；sourceTotals 独立保留 pre-filter EPUB/PDF attempted/succeeded/failed/highlight totals |
| annotation export ordering | 已实现（CLI 等价） | canonical options 支持 source order 与 reading order；EPUB 使用去 assertions 后的 CFI numeric lexicographic key，invalid/missing CFI 排在有效值后且 tie 保持 source order；PDF 使用 page→top-to-bottom→left→traversal |
| EPUB/PDF source scope | 已实现（CLI 等价） | canonical source scope 明确为 `epub / pdf / all`；current PDF 的 AEAnnotation mirror row 被排除，historical/unmapped row 不因猜测而丢失 |
| 自选有 AEAnnotation highlights 的书 | 已实现（CLI 等价） | 一个或多个 exact stable `assetID` selector；PDF 另有 exact canonical file selector。missing selector 返回 empty，duplicate stable identity fail closed，不按 title/local-PK 猜测 |
| Markdown smart overwrite | 已实现（CLI 等价） | `smart / always / never`；默认 `.never`。smart 只忽略首个 frontmatter/顶层 JSON 的 run-only timestamp 与自引用 hash，稳定 body/frontmatter/profile 内容任一变化都触发更新 |
| extended frontmatter/body metadata | 已实现（CLI 等价） | Obsidian-compatible profile 显式 opt-in；YAML scalar 使用单一安全 serializer，默认 profile 不隐式增加 metadata/content I/O |
| cover inline / cover file | 已实现（CLI 等价） | inline 使用真实 media type 的 data URL；file 模式按已知 JPEG/PNG/GIF media type 写安全 attachment filename，不硬编码 JPEG、不允许同名覆盖 |
| tags | 已实现（CLI 等价） | 支持 source/custom tags，稳定去重；YAML/Markdown context 均转义，不把 tag 当路径或 raw syntax |
| chapter headings / annotation date / style / progress | 已实现（CLI 等价） | profile options 独立控制；连续 null-location grouping 只借用 presentation heading，不合并或丢失 member raw row |
| citation | 已实现（CLI 等价） | author/title/publisher/year + EPUB physical location/CFI 或 PDF physical page；不为 PDF 发明 EPUB location |
| author pages | 已实现（CLI 等价） | 可选生成 `Authors/` sidecar；author filename/path 与 book/cover 共用同一 confinement owner，sidecar failure 返回明确 warning，不回滚已成功 document export |

## PDF

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| PDF library metadata | 已实现 | `ZCONTENTTYPE=3` 单独识别；exact current-library canonical PDF path可附带 Book metadata，fixed iCloud Documents root 只枚举直接 regular `.pdf` child，不递归/fuzzy |
| PDF highlight extraction | 已实现 | PDFKit 成功打开后枚举 `.highlight` annotations；QuadPoints 先从 annotation-local 加 `bounds.origin` 转 page-space，再用 `PDFPage.selection(for:)` 恢复 text；English/CJK/non-zero-origin fixture 已验证，结果明确 `isApproximate=true` |
| PDF highlight note | 已实现 | PDF annotation contents 作为 optional note；text unavailable 时仍保留 raw highlight/note/page，不把空 text 当整条不存在 |
| PDF page/location | 已实现 | page 使用 1-based physical page，并保留 page-local traversal index/bounds/quads；不生成 EPUB CFI |
| PDF color mapping | 已实现 | 保留 PDFKit-normalized RGBA；nearest green/blue/yellow/pink/purple 只作 presentation mapping并保留 distance/approximate provenance；不声称能判断原始 `/C` 是否存在 |
| PDF parse timeout | 已实现（强化） | 每个 PDF 在独立 worker process 内 bounded execution；parent 持续 drain pipes，timeout terminate→必要时 SIGKILL→wait/reap，oversize/crash/malformed protocol 都是结构化 failure |
| PDF metadata fallback | 已实现 | exact Book enrichment优先；无 Book 时 display title 只可 fallback filename，filename/base name 不得冒充 Apple asset identity |

## Safe writes / backup

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| 修改已有 annotation note | 已实现 | UUID/PK 定位；note 非空；更新时间 + `Z_OPT` |
| soft-delete annotation | 已实现 | `ZANNOTATIONDELETED=1`，禁止 hard delete |
| 写事务 | 已实现 | `BEGIN IMMEDIATE` + rollback；domain mutation 不掌握事务边界 |
| 写前 backup | 已实现 | SQLite online backup + integrity；本机已验证 read-only source 可用 |
| backup list/retention | 已实现 | public backup list/restore surface 当前覆盖 BKLibrary；annotation mutation 同样创建内部 safety backup，但不公开第二套 annotation backup catalog |
| restore | 已实现 | public restore 覆盖 BKLibrary：先校验并打开所选 restore source，记录/必要时 clean quit Books，再在 quiet state 对 live DB 创建 fresh safety backup，之后 SQLite-level apply、verify/retention 与条件 relaunch；post-apply failure 不能冒充未恢复。restore 是快照替换，不自动投影成一组 cloud mutation，也不属于 pending-cloud flush contract |
| Books.app lifecycle | 已实现（强化） | 非变异前置检查先完成；若 Books 原先运行则 clean quit，COMMIT 后恢复运行；launch 失败为 success + warning。显式 CloudKit ack/flush 另有受控 lifecycle |
| 批量 CloudKit flush | 已实现（强化） | 普通 collection/annotation mutation 在 commit 后生成 Apple-native dirty cloud representation；多次写入可不逐条 `--sync`，最后用根命令 `sync` 一次触发并等待所有 pending `BCCollectionDetail` / `BCCollectionMember` / `BCAssetAnnotations` acknowledgement。pending=0 时不触发生命周期；restore snapshot 不在此范围 |
| sanitised errors | 已实现 | 默认错误不 dump 用户全文/SQLite row；明确 mutation 是否已 commit、backup 在哪里 |
| 输入边界校验 | 已实现 | selector/search/name/note 等写前校验必须存在；不要求复制同一参数名或完全相同上限，但不能让显式边界保护在 CLI 化时消失 |
| iCloud acknowledgement 边界 | 当前限制 | 单条 mutation 的 `--sync` 或批量 `sync` 成功证明当前 Mac 对相应 cloud representation 获得 Apple Books CloudKit acknowledgement；仍不能单凭该证据声称另一台设备已经 render。annotation soft-delete 尚无用户真实数据 destructive live gate |

## 配置与历史数据边界

这些能力属于当前产品 contract，主要防止 historical/orphan annotation 在 current library 数据变化后被错误丢弃：

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| supplemental EPUB root / 外部 EPUB fallback | 已实现 | content resolver 使用显式 `config.json.epub_root` exact-basename packed EPUB fallback，并维持 current-book identity 边界 |
| historical asset metadata 显式映射 | 已实现 | configuration/annotation enrichment 使用 `config.json.historical_assets` exact asset-ID mapping |
| current / historical / unmapped source 区分 | 已实现 | annotation enrichment 显式区分三种来源；historical metadata 不授予 current content identity |
| orphan annotations 不因 current BKLibrary 缺 row 而消失 | 已实现 | annotation-first 查询保留 orphan row；current library 只做 enrichment |
| 原始 physical/range/type/style/UUID 字段完整 export | 已实现 | canonical Annotation model/query 保留 raw identity/location/style 字段，renderer 不得反写 |
| 导出数量与 raw SQLite count 校验 | 已实现 | 仅完整 note archive 启用独立 active-raw aggregate：raw note/highlight totals 必须与 final EPUB records 一致；普通 filtered export/query 不被此 gate 阻断 |
| note-bearing historical asset 必须可识别 | 已实现 | raw nonempty note（包括 whitespace-only）若仍为 historical-unmapped 则完整 archive fail closed；explicit historical mapping 可通过，note 缺 selected/representative quote 同样拒绝 |

## 当前明确不支持

以下能力不是当前产品 contract；调用方不能根据相似读取/写入能力推定它们存在：

- 从零创建新的 Apple Books highlight / annotation。
- 修改 selected-text / CFI range。
- 任意写 current reading position。
- Notion projection/import（它属于下游消费者，不是 AppleBooksCLI 本体）。
