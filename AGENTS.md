# AppleBooksCLI Repository Rules

- 在本仓库源码 checkout 中执行、测试或调用 AppleBooksCLI 时，先运行 `swift build`，再用 `$(swift build --show-bin-path)/applebookscli` 解析并调用当前 checkout 的最新编译产物。不要混用 PATH 中可能更旧的全局安装版本。
