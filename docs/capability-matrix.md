# AppleBooksCLI 能力矩阵

> 当前用户可见能力与明确不支持项的唯一 owner。命令参数以 `applebookscli --help` 为准；写安全细节见 [`write-safety.md`](write-safety.md)。

范围标记：**已实现**=当前用户能力；**已实现（强化）**=同一能力带额外 correctness/safety 边界；**已实现（展示）**=presentation 能力。每个“已实现”行都必须有 implementation/test/CLI reachability anchor。

## 数据访问与诊断

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| SQLite DB 自动发现 | 已实现（强化） | 自动发现 library/annotation store；ordinary read 保持只读；缺失或歧义时 fail closed |
| Full Disk Access / DB 可访问性诊断 | 已实现（强化） | `doctor` 返回固定 `components` + command-level `capabilities` 与 `ready/partial/unavailable`；单个 store/config/worker 失败不会把无关能力判死 |
| 读取 schema capability detection | 已实现 | optional column 缺失按能力降级 |
| 写 schema fail-closed | 已实现 | required write schema/entity 漂移即拒绝写 |
| help / version | 已实现 | 根 CLI 提供 help/version |
| operational JSON output | 已实现（强化） | operational success固定stdout单个JSON；fatal error固定stderr JSON；help/version保持plain text；无public `--json`/`--verbose`双轨 |
| operation history | 已实现（强化） | 最近 24h 保存结构化 request/result/inverse；list 默认20/最大100并用 opaque cursor 续页；get 按 exact lowercase UUID 取 detail；不保存 raw argv/stdout/stderr；retrying transport 可用 caller UUID 阻止同一逻辑写请求重放 |

## Books

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list books | 已实现 | 整个 BKLibrary universe；opaque cursor 分页，默认 20、单页最多 100；summary 只返回下一步所需字段 |
| list books with annotations | 已实现 | `books list --annotated`；library + annotations 双源 cursor，按≤100本一批做聚合计数，不构造全库 annotation map；附 user annotation count |
| get/describe book | 已实现 | stable asset ID 优先、显式 local PK fallback；返回 bounded semantic detail，不暴露数据库路径/raw blob/internal flags |
| title/author/genre 综合搜索 | 已实现 | `books search --field all|title|author|genre`；case-insensitive literal partial match |
| 书籍 semantic metadata | 已实现 | title/author/description/genre/language/year/pageCount/reading state 等 Agent 可理解字段；超限文本有 `truncatedFields` |
| EPUB OPF / iTunes metadata enrichment | 已实现（强化） | `content metadata` 返回 stable identity/fallback PK + 单层 bounded resolved metadata；DB title/author/language/releaseDate 优先，OPF/plist 补缺，不返回 raw identifiers/重复来源结构 |
| cover 提取 | 已实现（强化） | `content cover --output <path>` 写文件并返回 canonical destination/disposition；相对路径按 cwd 解析，JSON 不内联图片或 private source path |
| author sentinel normalization | 已实现 | ordinary book summary/detail 只返回 canonical author；Apple sentinel/private-use 标记归一化为清理值或 null |

## Reading status / stats

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| in-progress books | 已实现 | 按 reading progress 查询；cursor 分页，默认 20、最大 100 |
| finished books | 已实现 | finished 状态查询；cursor 分页，默认 20、最大 100 |
| unstarted books | 已实现 | 未开始阅读查询；cursor 分页，默认 20、最大 100 |
| recently read books | 已实现 | 按 last-opened 排序；cursor 分页，默认 20、最大 100 |
| library stats | 已实现 | SQL aggregate + bounded cross-store classifier；分别报告 historical / unmapped / ambiguous / identity-unavailable annotation counts；top-5 只返回可消费书籍 identity + count |
| current reading position | 已实现（强化） | `reading position` 只读取 type=3 current bookmark；仅当 raw hint 能映射当前 ToC 时返回 `chapterOrder`、bounded title 与 totalChapters，不暴露 raw chapter ID/source |

## Annotations

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list annotations | 已实现 | user annotations 的组合查询；默认20、max100、opaque cursor；支持 book/text/created/modified/color/underline/presence 过滤与 created/modified/reading order |
| annotations by book | 已实现 | `--book` / `--book-pk` 精确 selector；reading order 只允许 exact book，并使用确定性的阅读位置排序 |
| get/describe annotation | 已实现 | UUID 优先、UUID 不可公开时 local PK fallback；selected text/Note 为 bounded detail，raw type/style/CFI/range 不进入 canonical detail |
| Apple Books annotation deep link | 已实现（展示） | archival export 可保留 annotation-level CFI deeplink；ordinary `annotations get` 只返回由完整合法 book asset ID 构造的无 fragment `bookURL`；mutation result 不返回 deeplink |
| highlights by color | 已实现 | green/blue/yellow/pink/purple；underline 独立保留 |
| export/filter underline | 已实现 | underline 可独立过滤 |
| search highlighted text | 已实现 | `annotations list --text <query> --text-field highlight`；case-insensitive partial search |
| search note text | 已实现 | `annotations list --text <query> --text-field note`；note-only search |
| full annotation text search | 已实现 | `annotations list --text <query>`；selected + representative + note |
| recent annotations by creation | 已实现 | `annotations list --order created`；user annotations creation newest-first |
| recent annotations by modification | 已实现 | `annotations list --order modified`；user annotations modification newest-first（默认 order） |
| annotations by date range | 已实现（强化） | `annotations list --created-after/--created-before` 或 modified 对应 flags；只接受带时区 RFC3339 instant |
| annotation context window | 已实现（强化） | `annotations context`；minimal annotation/book projection + bounded before/matched/after，oversize anchor/location/path fail closed，raw CFI 不进入 ordinary JSON |
| context 中精确标出 highlight | 已实现（强化） | `annotations context` 的 `matched` 返回 normalized anchor 首次精确命中的 source span，并保留原 source whitespace |
| annotation identity | 已实现 | UUID 为 stable identity；缺失/非法/超限 UUID 不截断，canonical list/get 才返回 positive local PK fallback |
| 保留 raw annotation 字段 | 已实现（强化） | ordinary list/get 只输出 semantic summary/detail；archival JSON export 保留 source type/style/CFI/range fidelity |

## EPUB / CFI content

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| DRM gate | 已实现 | DRM 明确不可读，不用空正文冒充成功 |
| EPUB ToC | 已实现（强化） | `content chapters --book|--book-pk`；nav → NCX → spine fallback；默认 20 / 最大 100 的 opaque cursor，只公开 `chapterOrder`、bounded title、depth |
| chapter text | 已实现（强化） | `content chapter --book <assetID> --chapter <order>`；按 ToC order 精确选择，ordinary JSON 不公开 raw chapter id/href/fragment |
| chapter text pagination | 已实现（强化） | bounded normalized traversal + opaque cursor；默认 4,000 graphemes/32 KiB，`--max-chars` 最大 16,000，单页 hard cap 128 KiB；无 `--offset` |
| current-library packed EPUB fallback | 已实现 | primary 不可用时只在显式 root 做 exact-basename fallback；unsafe primary 不掩盖 |
| directory / packed parser 等价 | 已实现（强化） | directory 与 packed EPUB 使用同一内容语义与 path safety；结构复杂度超出固定预算时 fail closed |
| CFI raw round-trip | 已实现（强化） | archival JSON export 保留 source CFI；ordinary derived parsing 有固定预算，超限不伪造 chapter/fragment |

## Collections

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| list collections | 已实现（强化） | 默认排除 deleted；opaque cursor 分页，默认 20、最大 100；summary 返回 stable identity/fallback PK、title 与 collection/membership 可编辑能力 |
| get/describe collection | 已实现（强化） | stable collection ID 优先、显式 local PK fallback；返回 bounded semantic detail 与 collection/membership 可编辑能力，超限 title/details 带 `truncatedFields`；不暴露 persistence 排序/视图字段 |
| search collections by title | 已实现（强化） | case-insensitive literal substring；opaque cursor 分页，默认 20、最大 100 |
| list collection books | 已实现（强化） | relation owner 在分页前跳过 stale membership 并按 canonical membership order 去重；opaque cursor 分页，默认 20、最大 100 |
| create collection | 已实现 | public CLI 只接收 title，并使用统一 guarded write path |
| rename collection | 已实现 | system collection fail closed |
| delete collection | 已实现（强化） | soft-delete；对已完成且无残留 membership 的普通 UUID collection 重试返回 deterministic no-op；异常 tombstone/system collection 仍 fail closed |
| add book | 已实现（强化） | idempotent membership add；固定 named selectors：`--collection|--collection-pk` + `--book|--book-pk` |
| remove book | 已实现（强化） | idempotent membership remove；固定 named selectors：`--collection|--collection-pk` + `--book|--book-pk`；system collection guard |

## Export / presentation

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| export output destination | 已实现（强化） | 完整artifact只写显式confined file/dir；stdout仅compact JSON write result；默认不覆盖 unsafe/existing target |
| Markdown export | 已实现 | human-readable notes；title/author、quote/Note、semantic location/PDF page、dates/presentation；不含 raw asset ID/CFI/absolute PDF path |
| JSON export | 已实现 | schemaVersion=10；保留 source-specific raw fields/warnings/statistics；Book non-finite raw numerics 主字段为 null，并用固定 `numericAnomalies` 标记 ±Infinity；presence 属性独立编码，PDF selector 使用 opaque source ID |
| export 属性过滤 | 已实现（强化） | `--has-highlight / --has-note / --underline true\|false` 独立 AND 过滤；省略不筛；仅导出有正文的 user annotations 与 PDF highlights |
| export 颜色过滤 | 已实现 | canonical EPUB colors；PDF approximate presentation color 不参与 hard filter |
| export single/multiple file | 已实现（强化） | single 原子写文件；per-document 原子发布 managed directory；`--overwrite always` 只替换可验证的既有 AppleBooksCLI managed output |
| export statistics | 已实现 | final selection stats 与 sourceTotals 分开；highlightCount/noteCount 独立且可重叠，无 bookmarkCount |
| annotation export ordering | 已实现（强化） | 默认 reading；EPUB 与 PDF 都使用稳定的阅读位置顺序和确定性 fallback；没有额外 order flag |
| EPUB/PDF source scope | 已实现（强化） | bulk 默认 all，可用 `--source epub / pdf / all` 收窄；exact `--book / --book-pk / --pdf` 可重复、自动路由并去重，missing/ambiguous fail closed；有效空书允许零记录，bulk PDF 失败显式标为 incomplete |

## PDF

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| PDF inventory | 已实现（强化） | `pdf list` 默认20、最大100，opaque cursor；summary 不暴露绝对 path，每项提供唯一可消费的 `bookAssetID` 或 `pdfSourceID` |
| PDF highlight extraction | 已实现（强化） | `--book / --pdf` exact selector；默认20、最大100的 opaque cursor；PDFKit 隔离在 worker 中，ordinary JSON 只返回 bounded semantic summary |
| PDF highlight note | 已实现 | ordinary read 返回 bounded optional Note/text preview；archive/export 保留 raw highlight fidelity |
| PDF page/location | 已实现 | ordinary read只公开1-based page；raw geometry仅由archive/export保留，不生成 EPUB CFI |
| PDF color mapping | 已实现 | ordinary read只公开 approximate 五色 presentation；archive/export 保留 normalized RGBA |
| PDF parse timeout | 已实现（强化） | 独立 worker 使用内部 bounded timeout；普通 CLI 不暴露 timeout tuning；timeout/crash/malformed/oversize 都结构化失败 |
| PDF metadata fallback | 已实现 | exact Book enrichment；无 Book 时 title 最多 fallback filename，不伪造 asset identity |

## Safe writes / backup

| 能力 | 范围 | 当前 contract |
| --- | --- | --- |
| 修改已有 annotation note | 已实现 | UUID/PK 定位；stdin 提供完整替换正文，`--clear` 显式清空为 NULL；只写 user annotation note |
| soft-delete / restore annotation | 已实现（强化） | `delete` 只做 soft-delete；`restore` 只恢复仍存在的 user-annotation tombstone；两者幂等，禁止 hard delete/system bookmark write |
| 写事务 | 已实现（强化） | mutation 使用 guarded transaction；pre-COMMIT failure rollback，transaction revalidation 防止 quiet-state stale decision |
| 写前 backup | 已实现 | SQLite online backup + integrity verification |
| backup list/retention | 已实现（强化） | `backups list` 固定只返回 newest 10 valid library recovery backups，不分页；ordinary CLI 只暴露 opaque `backupID`，annotation safety backup 不作为 public restore surface |
| restore | 已实现 | restore 前 safety backup；apply 后 verification/Books state restore failure 不能冒充未发生 |
| Books.app lifecycle | 已实现（强化） | normal mutation 保留 closed/background/frontmost；explicit sync temporary launch 不夺取最终状态 ownership |
| 批量 CloudKit flush | 已实现（强化） | 多条 mutation 可最后 root `sync` 一次 flush pending records；pending=0 no-op |
| sanitised errors | 已实现 | 默认 error 不回显用户正文、private path 或底层数据库 payload |
| 输入边界校验 | 已实现 | selector/search/name/note 等在副作用前校验 |
| iCloud acknowledgement 边界 | 已实现（当前 Mac acknowledgement） | mutation 始终 local commit/read-back + projection，`--sync` 只额外等待当前 Mac ack；root `sync` pending=0 不触碰 Books，有 pending 时恢复原 closed/background/frontmost 状态；ack 不证明第二设备已显示 |

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

## Edit trigger / evidence

用户可见 capability、selector/output 语义、分页/limit、写入能力或明确不支持项变化时更新本文，并同步 `Tests/Fixtures/Parity/capability-anchors.json`。当前事实以 CLI `--help`、对应 Core/CLI executable tests 与 `CapabilityParityTests` 为证据。
