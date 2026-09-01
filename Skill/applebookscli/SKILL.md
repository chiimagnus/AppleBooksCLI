---
name: applebookscli
description: 在 macOS 且已安装 applebookscli 时，用于读取、搜索和检查本机 Apple Books 的书籍、阅读状态、EPUB/PDF 内容与批注，导出数据，管理 collection/annotation 写入，以及列出或恢复安全备份。
---

# AppleBooksCLI

## 工作流

1. 先运行 `applebookscli doctor --json`，确认当前数据库、内容和安装能力。permission、schema、DRM、not-downloaded 或其它 degraded 状态应原样报告，不绕过保护。
2. 读取、搜索和结构化检查优先使用 `--json`。只有用户确实需要正文、PDF 划线或导出产物时，才调用 content、PDF 或 export 路径；不要为了预检读取不必要的正文。
3. 需要具体参数时运行 `applebookscli <group> --help` 或更深一层的子命令 help；不要凭记忆复制或猜测完整命令表。
4. collection/annotation mutation、backup restore 等写操作只能在用户明确要求该写入时执行。不要直接操作 Apple Books SQLite，也不要自行复制事务、备份、EPUB 或 PDF 解析逻辑。
5. 写入由 CLI 的 guarded mutation rail 负责：先建立安全备份，再提交事务。成功结果中的 post-commit/read-back/relaunch warning 表示提交后恢复或验证阶段出现警告，不能把它误判为“未提交”后盲目重试；应根据返回状态向用户说明结果。
6. 导出使用 CLI 自身的 selection、renderer 和安全 writer。完整 note archive 的冲突、计数或 no-clobber 校验失败时停止，不降低为普通导出或覆盖已有目标。

以 CLI 的结构化结果和稳定错误为事实来源；权限不足、内容未下载、DRM 不支持、schema 不兼容或 worker 不可用时，保持 fail-closed，并说明需要用户或环境解决的条件。
