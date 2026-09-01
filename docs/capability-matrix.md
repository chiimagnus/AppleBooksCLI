# Apple Books CLI 能力矩阵

> 本文是 AppleBooksCLI 用户可见能力与安全边界的 parity 真源。实现前后都应按本表核对；其他文档只解释设计与风险，不另维护一套范围。

## Parity 范围 contract

已确认目标：

> 把已确认的 Apple Books 用户能力完整实现为 Swift CLI；等价能力合并，不复制宿主包装层，也不先做未确认的新功能。

因此状态分为：

- **必须复刻**：已确认的用户功能语义，CLI 必须提供等价能力。
- **宿主能力翻译**：原能力绑定 MCP / Obsidian UI；不复制包装，但必须提供 CLI 等价入口或输出。
- **包装排除**：纯 transport / UI chrome，不属于 CLI 功能本体。
- **本地保留**：现有 exporter 已有、重构不能回归，但不拿它冒充完整 parity 已完成。
- **Parity 后**：尚未进入已确认范围的能力，parity gate 之前不实现。


## 数据访问与诊断

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| SQLite DB 自动发现 | 必须复刻 | 固定目录内按 prefix + `.sqlite` 确定性发现；读取显式 read-only |
| 自定义 annotations/library DB 路径 | 必须复刻且强化 | 支持显式 DB override，便于 fixture、迁移与诊断；单独 override 一个 store 必须生效或明确报错，不得静默忽略 |
| Full Disk Access / DB 可访问性诊断 | 必须复刻 | `doctor` 类入口给出清晰权限/路径/schema 错误，不把它混进 stdout 数据 |
| 读取 schema capability detection | 必须复刻 | optional column 缺失时降级字段，而不是整条读取路径崩溃 |
| 写 schema fail-closed | 必须复刻 | 写前验证 table/column/entity/NOT NULL invariant；漂移即拒绝写 |
| SQLite runtime | 实现基线 | Swift 6.4 直接使用 SDK `SQLite3` C API；P1 不引入第三方 SQLite 包，online backup 行为在后续写安全 fixture 中验证 |
| help / version | 必须复刻 | 根 CLI 提供可发现的 help 与 version |
| 人类输出与机器输出分离 | 必须复刻/统一 | stdout 可组合；查询命令提供结构化 JSON；diagnostic 走 stderr |

## Books

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| list books | 必须复刻 | 可分页，也能显式取全量；不能只列“有批注的书” |
| list books with annotations | 必须复刻 | 提供 annotated-only filter / view，并返回 annotation count |
| get/describe book | 必须复刻 | asset ID / numeric PK 可定位；详情包含 metadata、reading status/dates、rating、description、annotation count；机器协议保留 raw metadata |
| title search | 必须复刻 | substring search；多结果不能静默选第一本 |
| title/author/genre 综合搜索 | 必须复刻 | case-insensitive partial match |
| genre 查询 | 必须复刻 | genre filter 是独立能力，不只靠通用 search 偶然覆盖 |
| 丰富书籍 metadata | 必须复刻 | description、EPUB id/path、file size、language、date/year、genre、pageCount、rating、comments、coverUrl、reading progress/duration/dates，以及 purchase/release date、explicit/locked/ephemeral/hidden/sample/store-audiobook 等字段/flags按实时 schema 能力返回；`ZGENRES` 只保留 raw BLOB，未证明编码前不得猜成字符串/数组 |
| EPUB OPF / iTunes metadata enrichment | 必须复刻 | 可独立读取 canonical OPF metadata；iTunes plist 只补 OPF 缺失的 title/creator/publisher。对当前 Book 的 enrichment 只补 ISBN、缺失 language/release date、publisher、rights、subjects，不覆盖 current-library identity/title/author 等原始字段 |
| cover 提取 | 必须复刻 | manifest `cover-image` / EPUB2 metadata id 优先，有限 exact common-name fallback；返回原始 bytes + declared/detected media type + source，export 决定内嵌还是保存文件 |
| author sentinel normalization | 必须复刻语义 | raw author 永久保留；另提供 derived normalized author，移除 Apple 私用字符并把 Unknown/UnknownAuthor sentinel 归一为 nil，展示/文件命名不得把 sentinel 当真实作者身份 |

## Reading status / stats

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| in-progress books | 必须复刻 | 按 reading progress 查询 |
| finished books | 必须复刻 | 保留 finished 语义 |
| unstarted books | 必须复刻 | 未开始阅读查询 |
| recently read books | 必须复刻 | 按 last-opened 排序，支持 limit |
| library stats | 必须复刻 | total/finished/in-progress/unstarted、annotation 总量、orphan 数、top annotated books |
| current reading position | 必须复刻 | type=3 auto bookmark 单独能力，普通 annotations 默认排除 |
| current reading chapter | 必须复刻 | CFI chapter hint → ToC chapter |
| current-position fallback | 必须复刻 | auto bookmark 无可用 CFI 时可回退最近用户 highlight，并明确标记 inferred，不能伪装成真实 bookmark |

## Annotations

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| list annotations | 必须复刻两种 scope | soft-deleted 默认排除；CLI 必须明确表达 `user-only` 与 `include-system/raw`。user-only 排除 type=3，raw scope 可包含 active type=3，并支持 limit/order/pagination |
| list all / group by book | 必须复刻展示语义 | 全库 user annotations 按 creation newest-first 取数后按书分组；orphan 单独保留/呈现。CLI 可用 `--all` / `--group-by book` 等价表达，机器 JSON 不必复制文本 formatter |
| annotations by book | 必须复刻两种 scope + 阅读顺序 | book asset ID / numeric PK 可筛选；user-only 视图优先按 EPUB ToC chapter order、章内 creation 排序；内容不可读时降级到 creation/local-PK 稳定顺序但不得丢 annotation；raw scope 还必须能包含 active type=3 |
| get/describe annotation | 必须复刻 | UUID 优先；numeric PK 可兼容；返回 raw 字段和关联书籍信息 |
| highlights by color | 必须复刻 | green/blue/yellow/pink/purple；underline 作为独立原始状态保留 |
| export/filter underline | 必须复刻 | `--colors ...underline` 的用户可见过滤能力不能丢 |
| search highlighted text | 必须复刻 | case-insensitive partial search |
| search note text | 必须复刻 | note-only search |
| full annotation text search | 必须复刻 | selected + representative + note |
| recent annotations by creation | 必须复刻 | newest by `creation_date`，支持 limit |
| recent annotations by modification | 必须复刻 | newest by `ZANNOTATIONMODIFICATIONDATE`；raw scope 可包含 active type=3 system rows；不能和 created-recent/user-only 混成一种语义 |
| annotations by date range | 必须复刻且强化 | created-after/before + limit；date-only `before` 必须覆盖完整日历日或明确要求 timestamp |
| annotation context window | 必须复刻且强化 | current Book identity 必须精确；CFI chapter + selected/representative text 二次定位；支持 before/after window；anchor 未命中必须明确失败，不能返回章节开头冒充 context；historical mapping 不能替代 current Book/content identity |
| context 中精确标出 highlight | 必须复刻展示语义 | whitespace-normalized anchor match，canonical 首个命中只标一次；保留原 source whitespace，不能重新搜索后误标重复文本 |
| annotation identity | 必须复刻/统一 | `ZANNOTATIONUUID` 首选稳定身份，numeric PK 仅本机内部/兼容 |
| 保留 raw annotation 字段 | 必须复刻/统一 | UUID、asset_id、type/style、underline、selected/note/representative、CFI、physical/range、created/modified |
| 前缀 dedupe heuristic | 不复刻缺陷 | 保留 search 能力，但不把 O(n²) prefix heuristic 当 annotation identity |
| 无-location 连续行合并 | 宿主输出兼容，非 canonical | canonical 数据层永不把 null-location row 与相邻 row 合并来制造位置或改变 identity；展示级聚合也不能丢前置 rows 的 note/time/style 等字段，只能在完整保留原 rows 后执行 |

## EPUB / CFI content

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| 本地 materialization 检查 | 必须复刻 | 检查本身不得触发 iCloud hydration |
| DRM gate | 必须复刻 | FairPlay/DRM 明确失败，不返回空正文冒充成功 |
| EPUB ToC | 必须复刻 | EPUB nav/解析器 → NCX fallback → spine fallback；保留 depth/fragment |
| chapter text | 必须复刻 | 保留段落结构；同 XHTML 多 fragment 不串 section |
| chapter text pagination | 必须复刻 | `offset` + `max_chars` 等价能力以扩展 grapheme cluster 计数，不按 byte/UTF-16 切分；明确 continuation/end，不能拆开 emoji/CJK 组合字符 |
| 细粒度 spine entry | 必须复刻 | ToC 未列出的 spine item 仍可按 id 读取 |
| current-library packed EPUB fallback | 本地保留/已固化 | current Book 的真实 directory `ZPATH` 优先；仅 primary source missing/unavailable/unsupported 时，才可在显式 `epub_root` 下按 `ZPATH` basename 查找同名 regular non-symlink packed `.epub`。不递归、不 fuzzy；unsafe primary 不得被 fallback 掩盖；historical/unmapped annotation 无 current Book/ZPATH 时永不猜 packed 文件 |
| directory / packed parser 等价 | 必须复刻 | 两种 content source 共用同一 package/encryption/nav/NCX/chapter/metadata/cover parser；packed entry 只做 archive namespace lexical validation，URI percent decode 只发生在 canonical EPUB href/path 层一次 |
| CFI raw round-trip | 必须复刻 | 原始 CFI 永久保留 |
| CFI chapter hint | 必须复刻 | optimistic parse，不冒充完整 CFI validator |
| CFI char range diagnostics | 必须复刻 | 明确 offset 属于 leaf XHTML text node，不是抽取纯文本 offset |

## Collections

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| list collections | 必须复刻 | deleted collection 默认排除 |
| get/describe collection | 必须复刻 | detail + books；机器 JSON 保留 collectionId、hidden、sortKey、details、lastModification 等公开 raw metadata |
| search collections by title | 必须复刻 | substring search |
| list collection books | 必须复刻 | compact/list JSON 两种呈现可合并 |
| create collection | 必须复刻 | title + optional details；Core Data bookkeeping + safety rail |
| rename collection | 必须复刻 | system collection fail closed |
| delete collection | 必须复刻 | collection soft-delete，membership 按 Books 语义处理 |
| add book | 必须复刻 | idempotent；维护 member PK/sort/parent timestamps |
| remove book | 必须复刻 | idempotent；系统 collection guard |

## Export / presentation

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| export output destination | 必须复刻 | 支持显式文件/目录输出；默认路径只能是 UX 默认值，不能成为唯一去处 |
| Markdown export | 必须复刻 | 支持全库和单书；可文件输出，也保留 stdout 可组合路径 |
| JSON export | 必须复刻 | single-file / per-book；同时查询命令的 `--json` 作为稳定机器协议 |
| CSV export | 必须复刻 | 全库结构化 export |
| HTML export | 必须复刻 | 不只是“能写 HTML”，还要保留当前用户可见交互能力 |
| HTML 搜索 | 必须复刻 | 在导出产物内搜索书名/批注 |
| HTML 单书折叠 + 全部折叠 | 必须复刻 | collapse/expand + all toggle |
| HTML 状态持久化 | 必须复刻 | collapse/sidebar 状态 localStorage |
| HTML sidebar / responsive / print | 必须复刻 | 书籍导航、移动端 sidebar、print-friendly layout |
| export 类型过滤 | 必须复刻且与 raw type 分层 | highlights-only / bookmarks-only / notes-only / include-bookmarks；presentation kind 规则为 note 非空→note、selected text 空→bookmark、否则 highlight，不能把 presentation bookmark 偷换成 raw `ZANNOTATIONTYPE=3` |
| export 颜色过滤 | 必须复刻 | yellow/green/blue/pink/purple/underline |
| export single/multiple file | 必须复刻 | Markdown/JSON 单文件与 per-book |
| partial export offset | 必须复刻 | `skip_first_x_notes` 的等价 offset/skip 能力 |
| export statistics | 必须复刻 | books/annotations/type/orphan 等统计 |
| annotation export ordering | 宿主能力翻译 | 用户可选择按 location/CFI 阅读顺序排序或保留未排序/来源顺序；canonical 数据层不因展示排序改 identity |
| EPUB/PDF source scope | 宿主能力翻译 | 原 `includePdfHighlights` 开关翻译为明确 source scope，例如 `epub / pdf / all` 或等价 include/exclude PDF flag |
| 自选有 AEAnnotation highlights 的书 | 宿主能力翻译 | 原 modal 只覆盖这条 EPUB/AEAnnotation 路径；CLI 用一个或多个稳定 book selector 等价实现。不把“选择 PDF”偷算成当前 parity 要求 |
| Markdown smart overwrite | 宿主能力翻译 | `smart / always / never`；smart hash 必须覆盖实际生成文件的稳定内容与相关 renderer 设置，不能只 hash body 而漏掉 frontmatter |
| extended frontmatter/body metadata | 宿主能力翻译 | CLI Markdown/Obsidian-compatible profile 提供等价选项 |
| cover inline / cover file | 宿主能力翻译 | 可 base64/内嵌或输出独立 cover 文件并引用 |
| tags | 宿主能力翻译 | 可为生成的 Markdown 添加用户指定 tags |
| chapter headings / annotation date / style / progress | 宿主能力翻译 | 对应 renderer 选项不能静默丢失 |
| citation | 宿主能力翻译 | author/title/publisher/year/physical location 等价输出 |
| author pages | 宿主能力翻译 | 不复制 Obsidian UI；需要提供可选的 Obsidian-compatible author-page 生成能力，含原有 Dataview 语义或明确等价输出 |

## PDF

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| PDF library metadata | 必须复刻 | `ZCONTENTTYPE=3` 单独识别 |
| PDF highlight prefilter | 必须复刻 | 低内存扫描 `/Highlight` marker，避免无批注 PDF 全量解析 |
| PDF scan cache | 必须复刻 | mtime + size 判定未变化，删除已不存在文件的 cache 项 |
| PDF highlight extraction | 必须复刻且验证启发式 | `/Subtype /Highlight` + QuadPoints → 文本；首尾行几何比例字符估算必须用英文/CJK fixture 验证，不能把估算当规范真值 |
| PDF highlight note | 必须复刻 | annotation contents 作为 note |
| PDF page/location | 必须复刻 | page 作为 physical location |
| PDF color mapping | 必须复刻 | nearest palette；必须保留其“部分颜色为近似值”的不确定性 |
| PDF parse timeout | 必须复刻且强化 | 单 PDF bounded execution；timeout 必须真正终止/取消底层 work，不能只返回超时结果后让解析继续 |
| PDF metadata fallback | 必须复刻 | 优先 library title/author，缺失时 filename fallback |

## Safe writes / backup

| 能力 | 状态 | 等价能力要求 |
| --- | --- | --- |
| 修改已有 annotation note | 必须复刻 | UUID/PK 定位；note 非空；更新时间 + `Z_OPT` |
| soft-delete annotation | 必须复刻 | `ZANNOTATIONDELETED=1`，禁止 hard delete |
| 写事务 | 必须复刻 | `BEGIN IMMEDIATE` + rollback；domain mutation 不掌握事务边界 |
| 写前 backup | 必须复刻 | SQLite online backup + integrity；本机已验证 read-only source 可用 |
| backup list/retention | 必须复刻 | public list/restore surface 先覆盖 BKLibrary；annotation mutation 同样创建内部 backup。实现基础设施可复用，但额外公开 annotation-backup catalog 属于 parity 后决策 |
| restore | 必须复刻 | public restore 至少覆盖 BKLibrary；先校验 source 并在线备份当前 live DB，之后才 clean quit Books，再做 SQLite-level restore/read-back；是否额外公开 annotation restore 属于 parity 后决策 |
| Books.app lifecycle | 必须复刻且 UX 已定 | 非变异前置检查先完成；若 Books 原先运行则 clean quit，COMMIT 后恢复运行；launch 失败为 success + warning |
| sanitised errors | 必须复刻 | 默认错误不 dump 用户全文/SQLite row；明确 mutation 是否已 commit、backup 在哪里 |
| 输入边界校验 | 必须复刻语义 | selector/search/name/note 等写前校验必须存在；不要求复制同一参数名或完全相同上限，但不能让显式边界保护在 CLI 化时消失 |
| collection iCloud caveat | 必须保留用户提示 | 真实 iCloud collection 行为未完成多设备验收前不得承诺跨设备同步 |

## 包装层：明确排除，但功能不得随之丢失

| 宿主包装 | 状态 | 处理方式 |
| --- | --- | --- |
| MCP stdio server / tool registration | 包装排除 | 不实现 MCP transport；底层工具能力全部映射到 CLI |
| MCP `TextContent` formatter | 包装排除 | 用 human stdout + `--json` 替代 |
| MCP prompts（weekly digest / library snapshot / revisit book） | 包装排除 | 源码只返回提示词，让 LLM 再调用 date-range/stats/search/annotations 后做自然语言综合，没有新增 Apple Books 执行逻辑；不复制 prompt 文本，底层查询能力必须存在 |
| MCP currently-reading resource | 包装排除/组合视图 | 源码只是 `in-progress(limit=1,last-opened)` + current-position/chapter + annotation count 的轻量组合；不复制 resource transport，组成能力必须可由 CLI 表达 |
| Obsidian ribbon icon | 包装排除 | 不复制 UI chrome |
| Obsidian book-selection modal | 宿主能力翻译 | 用 CLI book selectors 等价实现选择性操作 |
| Obsidian settings tab | 宿主能力翻译 | 对实际影响输出/行为的设置提供 CLI flags/profile；纯 UI 本身不复制 |
| Homebrew/npm/MCP 安装包装 | 包装排除 | 分发方式不作为功能 parity 验收项 |

## 本地已有能力：重构必须保留

这些是迁移前本地 exporter 已经具备、且当前 parity contract 明确保留的能力，Swift CLI 迁移不能回归：

| 能力 | 状态 | 当前证据 |
| --- | --- | --- |
| supplemental EPUB root / 外部 EPUB fallback | 本地保留 | 当前 Swift content resolver 已保留显式 `config.json.epub_root` exact-basename packed EPUB fallback，并维持 current-book identity 边界 |
| historical asset metadata 显式映射 | 本地保留 | 当前 Swift configuration/annotation enrichment 保留 `config.json.historical_assets` exact asset-ID mapping |
| current / historical_inferred / historical_unmapped 区分 | 本地保留 | 当前 Swift annotation enrichment 显式保留三种来源；historical metadata 不授予 current content identity |
| orphan annotations 不因 current BKLibrary 缺 row 而消失 | 本地保留 | annotation-first 查询保留 orphan row；current library 只做 enrichment |
| 原始 physical/range/type/style/UUID 字段完整 export | 本地保留 | canonical Annotation model/query 保留 raw identity/location/style 字段，renderer 不得反写 |
| 导出数量与 raw SQLite count 校验 | 本地保留 | export parity 仍需保持 raw-count 可核验，不得因 grouping/filter 静默丢 row |
| note-bearing historical asset 必须可识别 | 本地保留 | historical enrichment 使用 explicit mapping；缺 mapping 保持 unmapped，不 fuzzy 推断 |

## Parity gate 之后才能做

以下能力尚未进入当前 parity contract：

- 从零创建新的 Apple Books highlight / annotation。
- 修改 selected-text / CFI range。
- 任意写 current reading position。
- Notion projection/import（它是 CLI 的下游消费者，不是 Apple Books CLI parity 本体）。

## 两条不同的 schema 策略

读取和写入不能用同一种兼容策略：

```text
读取：缺少 optional column
  → 降级能力 / 返回 null / capability=false

写入：预期列缺失、出现未知必填列、entity 不匹配
  → 直接拒绝写
```

这条边界是自有 CLI 的核心 invariant。
