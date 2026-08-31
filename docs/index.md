# Apple Books CLI 文档索引

> 更新时间：2026-08-31。这里记录 AppleBooksCLI 的长期产品 contract、本机只读验证与安全边界；实施来源和迁移证据属于 `.github/features/`，不进入长期 tracked 文档。

## 目标与 contract

AppleBooksCLI 把 Apple Books 作为独立数据源提供稳定 Swift CLI。Notion 等下游只消费稳定输出契约，不直接理解 Apple Books SQLite / EPUB / PDF 内部结构。

`capability-matrix.md` 是用户可见能力与安全边界的唯一范围真源。当前范围包括：

- books / collections / annotations / reading status / stats。
- EPUB、ToC、CFI、chapter content 与 annotation context。
- PDF highlight extraction 与增量 scan cache。
- JSON / Markdown / CSV / self-contained HTML export。
- annotation / collection 写能力、backup / restore 与 Books.app lifecycle。
- 宿主特定交互转译成 CLI 等价 flags/profile；不复制 transport 或 UI chrome。

当前不包含：

- 从零创建新的 Apple Books highlight / annotation。
- 修改 selected-text / CFI range。
- 任意写 current reading position。
- Notion projection/import；它是 CLI 的下游消费者。

真实 Apple Books 数据库写验收必须在 fixture、schema、backup/restore 与 lifecycle gates 全部通过后，再经用户明确批准执行。

## 文档

- `capability-matrix.md`：用户可见能力、安全边界与 parity contract。
- `macos-27-schema-baseline.md`：当前机器 Apple Books 数据库的净化只读实测基线。
- `write-safety.md`：写入顺序、backup/restore、Books.app lifecycle 与失败语义。
- `swift-cli-design-input.md`：Swift CLI 的领域模型、selector、query、content、export 与 mutation 设计输入。

## 当前设计结论

1. **Swift 6 + SwiftPM + SDK SQLite3**：读取和 SQLite-level backup/restore 不依赖第二套运行时。
2. **双数据库独立 read-only**：BKLibrary 与 AEAnnotation 分别发现、分别 override、分别以只读 handle 打开。
3. **annotation-first**：annotation 生命周期独立于当前 BKLibrary；current metadata 只是 enrichment，historical/unmapped annotation 不能消失。
4. **raw semantics 优先**：raw type/style/UUID/CFI/reading progress 不被展示 heuristic 覆盖；用户 scope 与 raw/system scope 显式分离。
5. **EPUB / PDF 分轨**：EPUB content/CFI 与 PDF file annotations 使用不同 adapter；不可读或 DRM 状态结构化降级。
6. **写入单轨**：read-only preflight → 必要时停止 Books → fresh online backup + integrity → short-lived transaction → invariant check → read-back → 恢复原 Books.app 状态。
7. **输出分层**：机器 JSON 与 human diagnostics 分离；export renderer 不反向改变 canonical identity。
8. **隐私默认关闭**：tracked docs、tests、logs 和 release evidence 不记录真实 title、asset ID、UUID、CFI、note/highlight 正文或用户绝对路径。
