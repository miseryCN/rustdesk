已完成并确认当前分支的合并提交：

- 合并提交：`3250848df` `chore: 同步 RustDesk 上游 5f015c9da13c`
- 上游提交：`5f015c9da13c`，已是当前 `HEAD` 的父提交。
- 未推送，未切换或修改 `master`；工作区干净，无未解决冲突。

处理的冲突/重叠：

- 双侧改动文件：`Cargo.lock`、`src/common.rs`、`src/flutter.rs`。
- `src/common.rs` 同时保留上游的禁用安装判断与定制版的软件更新策略/测试。
- `src/flutter.rs` 保留服务器配置档的最近连接命名空间隔离，同时纳入上游 Windows 安装禁用状态 FFI。
- 服务器配置档持久化、Rust/Flutter FFI、生成桥接、设置页、最近连接逻辑及现有测试均未被覆盖。

完成的验证：

- `git diff --check`
- 合并提交与两侧父提交的差异检查
- 无未解决冲突、无冲突标记、工作区干净
- Git 对象完整性检查
- 六个服务器配置档 FFI 端点在 Rust、C ABI、Dart 生成桥接与调用层逐一对应

未完成的验证：

- Rust 编译/测试、FFI 编译、Flutter 测试与分析未运行：容器未安装 `rustc`、`cargo`、`dart`、`flutter`，且 `libs/hbb_common` 子模块未初始化。

风险：

- 仅剩工具链与子模块缺失导致的运行时验证空缺；未发现配置迁移语义不明确项，无 `NEEDS-HUMAN`。