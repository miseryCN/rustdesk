已完成同步并提交，当前分支为 `7f644a188 merge: 保留服务器配置档功能`，工作区干净，未推送、未切换或修改 `master`。

- 上游提交：`94a2a2bb4 fix #15566`，已是当前 `HEAD` 的祖先。
- 配置档保留：已合入 `origin/feature/server-profiles`，Rust 持久化、Rust/Flutter FFI、生成桥接、设置页、最近连接隔离及其测试均保留。
- 冲突：无手动冲突。`server_page.dart` 的上游文案更新保留；配置档实现与定制功能分支一致。
- 已验证：
  - `git diff --check`、`git diff --check upstream/master..HEAD`
  - `git diff-tree --check -r HEAD`
  - 无未解决冲突、无冲突标记
  - `git fsck --no-reflogs --no-progress`
  - 六个配置档 FFI 端点在 Rust、C ABI、Rust 桥接、Dart 生成桥接中逐一对应
  - 配置档及最近连接三组 Flutter 测试文件仍存在，且相关实现/测试与定制功能分支一致
- 未完成验证：容器未安装 `cargo`、`rustc`、`rustfmt`、`dart`、`flutter`，且 `libs/hbb_common` 子模块未初始化，因此无法运行 Rust 编译/测试、FFI 编译或 Flutter 测试/分析。
- 风险：主要是上述工具链与子模块缺失导致未执行运行时验证；未发现配置迁移语义不确定项，无 `NEEDS-HUMAN`。