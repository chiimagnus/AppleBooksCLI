# AppleBooksCLI 能力矩阵

> 当前用户可见能力与明确不支持项的唯一 owner。命令参数以 `applebookscli --help` 为准；写安全细节见 [`write-safety.md`](write-safety.md)。

范围标记：**已实现**=当前能力；**已实现（强化）**=带额外 correctness/safety 边界；**已实现（CLI 等价）**=由 CLI 表达同等业务语义；**已实现（展示）**=presentation 能力。所有“已实现”行必须有 implementation/test/CLI reachability anchor。

## 数据访问与诊断

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| SQLite DB 自动发现 | 已实现（强化） | 固定 Apple Books 目录内流式确定性发现；读取连接只读；ambiguity 只保留有限 witness，不构造全目录列表 |
| 自定义 annotations/library DB 路径 | 已实现（强化） | 两个 store 可独立 override；无效 override 明确失败 |
| Full Disk Access / DB 可访问性诊断 | 已实现（强化） | `doctor` 返回固定 `components` + command-level `capabilities`，overall 仅为 `ready/partial/unavailable`；写能力同时要求 write schema + backup root 可用，`syncPrerequisites` 直接探测两侧 live client-side CloudKit pending-state；单个 store/config/worker 失败不会把无关能力判死 |
| 读取 schema capability detection | 已实现 | optional column 缺失按能力降级 |
| 写 schema fail-closed | 已实现 | required write schema/entity 漂移即拒绝写 |
| help / version | 已实现 | 根 CLI 提供 help/version |
| operational JSON output | 已实现（强化） | operational success固定stdout单个JSON；fatal error固定stderr JSON；help/version保持plain text；无public `--json`/`--verbose`双轨 |
| operation history | 已实现（强化） | 最近 24h 记录目标写入/sync；list 摘要、get 完整本地记录；不是 undo |

## Books

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list books | 已实现 | 整个 BKLibrary universe；opaque cursor 分页，默认 20、单页最多 100；summary 只返回下一步所需字段 |
| list books with annotations | 已实现 | `books list --annotated`；library + annotations 双源 cursor，按≤100本一批做聚合计数，不构造全库 annotation map；附 user annotation count |
| get/describe book | 已实现 | stable asset ID 优先、显式 local PK fallback；返回 bounded semantic detail，不暴露数据库路径/raw blob/internal flags |
| title search | 已实现 | `books search --field title` literal substring；多结果不猜第一项，使用 opaque cursor |
| title/author/genre 综合搜索 | 已实现 | `books search --field all|title|author|genre`；case-insensitive literal partial match |
| 书籍 semantic metadata | 已实现 | title/author/description/genre/language/year/pageCount/reading state 等 Agent 可理解字段；超限文本有 `truncatedFields` |
| EPUB OPF / iTunes metadata enrichment | 已实现 | OPF 为主，plist 只补缺失 enrichment，不覆盖 current-library identity |
| cover 提取 | 已实现 | EPUB 声明优先，有限 exact fallback；保留 bytes/media type/source |
| author sentinel normalization | 已实现 | ordinary book summary/detail 只返回 canonical author；Apple sentinel/private-use 标记归一化为清理值或 null |

## Reading status / stats

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| in-progress books | 已实现 | 按 reading progress 查询；cursor 分页，默认 20、最大 100 |
| finished books | 已实现 | finished 状态查询；cursor 分页，默认 20、最大 100 |
| unstarted books | 已实现 | 未开始阅读查询；cursor 分页，默认 20、最大 100 |
| recently read books | 已实现 | 按 last-opened 排序；cursor 分页，默认 20、最大 100 |
| library stats | 已实现 | SQL aggregate + bounded cross-store classifier；分别报告 historical / unmapped / ambiguous / identity-unavailable annotation counts；top-5 只返回可消费书籍 identity + count |
| current reading position | 已实现 | type=3 current-reading bookmark 单独读取 |
| current reading chapter | 已实现 | current position 的 CFI hint 映射 ToC chapter |
| current-position fallback | 已实现 | 无可用 auto bookmark 时可用最近 user highlight，并明确 inferred |

## Annotations

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list annotations | 已实现 | 默认 active user rows；可显式 raw/system scope；ordinary body 使用 bounded preview，超限字段返回 `truncatedFields` evidence |
| list all / group by book | 已实现（展示） | 分组不改变 canonical ordering/identity，orphan/null-location 不丢 |
| annotations by book | 已实现 | 精确 book selector；可读内容时按阅读顺序，否则稳定降级 |
| get/describe annotation | 已实现 | UUID 优先，local PK 可显式使用 |
| Apple Books annotation deep link | 已实现（展示） | `appleBooksURL` 由 asset ID + optional CFI 派生，并复用于 read/export/mutation output |
| highlights by color | 已实现 | green/blue/yellow/pink/purple；underline 独立保留 |
| export/filter underline | 已实现 | underline 可独立过滤 |
| search highlighted text | 已实现 | case-insensitive partial search |
| search note text | 已实现 | note-only search |
| full annotation text search | 已实现 | selected + representative + note |
| recent annotations by creation | 已实现 | creation newest-first |
| recent annotations by modification | 已实现 | modification newest-first；可显式 raw/system scope |
| annotations by date range | 已实现（强化） | created range + limit；date-only 上界覆盖完整日历日 |
| annotation context window | 已实现（强化） | current content + CFI/anchor 精确定位；anchor miss 不伪造 context |
| context 中精确标出 highlight | 已实现（展示） | normalized anchor 首次命中，保留原 source whitespace |
| annotation identity | 已实现 | UUID 为 stable identity；PK 仅本机 selector |
| 保留 raw annotation 字段 | 已实现（强化） | ordinary read 保留需要的 raw identity/type/style/location 语义但 TEXT 受 semantic budget；archival export/raw Core 保持 source text/CFI full fidelity |

## EPUB / CFI content

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| 本地 materialization 检查 | 已实现 | probe 不主动触发 iCloud hydration |
| DRM gate | 已实现 | DRM 明确不可读，不用空正文冒充成功 |
| EPUB ToC | 已实现 | nav → NCX → spine fallback |
| chapter text | 已实现 | 保留段落与 fragment scope |
| chapter text pagination | 已实现 | 按 Swift Character 分页，不拆 grapheme cluster |
| 细粒度 spine entry | 已实现 | ToC 外 spine item 仍可读取 |
| current-library packed EPUB fallback | 已实现 | primary 不可用时只在显式 root 做 exact-basename fallback；unsafe primary 不掩盖 |
| directory / packed parser 等价 | 已实现（强化） | 两种 source 共用 package/content 语义与 path safety；结构深度/节点/ZIP inventory 有固定 hard budget，超限 fail closed |
| CFI raw round-trip | 已实现（强化） | archival/raw Core 永久保留 source CFI；ordinary derived parsing 最多处理 64 KiB，超限不伪造 chapter/fragment |
| CFI chapter hint | 已实现 | optimistic hint，不冒充完整 validator |
| CFI char range diagnostics | 已实现 | offset 明确属于 leaf XHTML text node |

## Collections

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list collections | 已实现 | 默认排除 deleted |
| get/describe collection | 已实现（强化） | stable collection ID 优先、显式 local PK fallback；返回 bounded semantic detail，超限 title/details 带 `truncatedFields` |
| search collections by title | 已实现 | substring search |
| list collection books | 已实现 | collection membership 查询 |
| create collection | 已实现 | title + optional details，走 guarded write rail |
| rename collection | 已实现 | system collection fail closed |
| delete collection | 已实现 | soft-delete |
| add book | 已实现 | idempotent membership add |
| remove book | 已实现 | idempotent membership remove；system collection guard |

## Export / presentation

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| export output destination | 已实现（强化） | 完整artifact只写显式confined file/dir；stdout仅compact JSON write result；默认不覆盖 unsafe/existing target |
| Markdown export | 已实现 | plain Markdown；使用 canonical records |
| JSON export | 已实现 | schemaVersion=2；保留 source-specific raw fields/warnings/statistics |
| export 类型过滤 | 已实现（强化） | presentation kind 纯派生，不改 raw annotation type/style |
| export 颜色过滤 | 已实现 | known colors + underline；unknown 不伪造已知颜色 |
| export single/multiple file | 已实现 | single/per-document；统一经过 confinement/overwrite file writer |
| partial export offset | 已实现 | 在最终 selection/order 后按 book skip |
| export statistics | 已实现 | final selection stats 与 sourceTotals 分开 |
| annotation export ordering | 已实现（CLI 等价） | EPUB CFI reading order / PDF page geometry order，稳定 fallback |
| EPUB/PDF source scope | 已实现（CLI 等价） | `epub / pdf / all` 明确分轨，不猜 historical/unmapped source |
| 自选有 AEAnnotation highlights 的书 | 已实现（CLI 等价） | exact stable asset ID / canonical PDF selector；missing 返回 empty，duplicate fail closed |
| Markdown smart overwrite | 已实现（CLI 等价） | `smart / always / never`；默认 never，plain Markdown 按稳定正文判定 unchanged |
| cover inline / cover file | 已实现（CLI 等价） | 使用真实 media type；安全 filename、不覆盖 |

## PDF

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| PDF library metadata | 已实现 | `ZCONTENTTYPE=3` 独立识别；exact canonical file 才关联 Book metadata |
| PDF highlight extraction | 已实现 | PDFKit highlight + geometry/text recovery；结果标记 approximation |
| PDF highlight note | 已实现 | contents 作为 optional note；text unavailable 不丢 raw highlight |
| PDF page/location | 已实现 | 1-based page + raw geometry，不生成 EPUB CFI |
| PDF color mapping | 已实现 | 保留 normalized RGBA；五色映射只作 approximate presentation |
| PDF parse timeout | 已实现（强化） | 独立 worker bounded timeout；timeout/crash/malformed/oversize 都结构化失败 |
| PDF metadata fallback | 已实现 | exact Book enrichment；无 Book 时 title 最多 fallback filename，不伪造 asset identity |

## Safe writes / backup

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| 修改已有 annotation note | 已实现 | UUID/PK 定位；只写 user annotation note |
| soft-delete annotation | 已实现 | soft-delete，禁止 hard delete/system bookmark write |
| 写事务 | 已实现 | `BEGIN IMMEDIATE` + rollback + transaction revalidation |
| 写前 backup | 已实现 | SQLite online backup + integrity verification |
| backup list/retention | 已实现 | public catalog/restore 当前覆盖 BKLibrary；annotation backup 仅内部 safety use |
| restore | 已实现 | restore 前 safety backup；apply 后 verification/relaunch failure 不能冒充未发生 |
| Books.app lifecycle | 已实现（强化） | normal mutation 保留 closed/background/frontmost；explicit sync temporary launch 不夺取最终状态 ownership |
| 批量 CloudKit flush | 已实现（强化） | 多条 mutation 可最后 root `sync` 一次 flush pending records；pending=0 no-op |
| sanitised errors | 已实现 | 默认 error 不回显用户正文/SQLite payload |
| 输入边界校验 | 已实现 | selector/search/name/note 等在副作用前校验 |
| iCloud acknowledgement 边界 | 已实现（当前 Mac acknowledgement） | mutation `--sync` 或 root `sync` 等待当前 Mac ack；普通 mutation 只 projection，ack 不证明第二设备已显示 |

## 配置与历史数据边界

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| supplemental EPUB root / 外部 EPUB fallback | 已实现 | explicit `epub_root` 只作 exact-basename packed EPUB fallback |
| historical asset metadata 显式映射 | 已实现 | `historical_assets` 只按 exact asset ID enrichment |
| current / historical / unmapped source 区分 | 已实现 | historical metadata 不授予 current content identity |
| orphan annotations 不因 current BKLibrary 缺 row 而消失 | 已实现 | annotation-first query；library 只 enrichment |
| 原始 physical/range/type/style/UUID 字段完整 export | 已实现 | canonical raw identity/location/style 不被 renderer 改写 |

## 当前明确不支持

- 创建新的 Apple Books highlight / annotation。
- 修改 selected text / CFI range。
- 任意写 current reading position。
