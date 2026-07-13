# RustDesk 桌面端多服务器配置切换实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 在 Windows、Linux、macOS 桌面客户端中加入无需重启即可生效的服务器档案快速切换，并按档案隔离最近设备与连接凭据。

**架构：** `hbb_common` 提供版本化档案存储、旧 peers 迁移和 profile-aware `PeerConfig`；Rust 主仓库用 `ServerProfileManager` 把活动档案映射回现有网络 options，并让每个活动会话捕获自己的 `profile_id`。Flutter 新增响应式模型、主页选择器和管理对话框，切换成功后重新加载当前档案的最近设备。

**技术栈：** Rust 2021、Serde/TOML、现有 RustDesk IPC、Flutter/Dart/GetX、flutter_rust_bridge 1.80、Cargo/Flutter 测试。

---

## 文件结构

### `hbb_common` 子模块

- 修改 `libs/hbb_common/Cargo.toml`：加入仅测试使用的 `tempfile` dev-dependency。
- 创建 `libs/hbb_common/src/config/server_profiles.rs`：档案数据结构、校验、原子保存、首次迁移和可注入根目录的测试实现。
- 修改 `libs/hbb_common/src/config.rs`：导出档案模块；给 `PeerConfig` 增加 profile-aware 路径和 CRUD/枚举 API；维护活动 profile 兼容入口。

### RustDesk 主仓库

- 创建 `src/server_profiles.rs`：`ServerProfileManager`，负责 CRUD、切换、批量 options 应用和 JSON 响应。
- 修改 `src/lib.rs`：注册 `server_profiles` 模块。
- 修改 `src/flutter_ffi.rs`：初始化档案、暴露 Flutter FFI、按活动档案加载/删除 recent peers。
- 修改 `src/client.rs`：`LoginConfigHandler` 捕获 `profile_id`，会话内始终使用显式 profile-aware `PeerConfig`。
- 修改 `src/flutter.rs`：创建会话时读取并传入当前 `profile_id`。
- 修改 `src/ui_interface.rs`：主页直接操作 peer 配置的辅助函数使用活动 profile。
- 修改 `flutter/lib/generated_bridge.dart`：由 flutter_rust_bridge 重新生成新增 FFI 绑定。

### Flutter

- 创建 `flutter/lib/models/server_profile_model.dart`：档案 DTO、响应状态、切换串行化和 recent peers 刷新。
- 创建 `flutter/lib/desktop/widgets/server_profile_selector.dart`：主页快速选择器。
- 创建 `flutter/lib/desktop/widgets/server_profile_dialog.dart`：新增、编辑、删除管理界面。
- 修改 `flutter/lib/models/model.dart`：把 `ServerProfileModel` 加入全局 FFI 模型生命周期。
- 修改 `flutter/lib/desktop/pages/connection_page.dart`：在连接区域右上角挂载选择器。
- 创建 `flutter/test/server_profile_model_test.dart`：DTO、状态替换和错误结果的纯 Dart 测试。
- 创建 `flutter/test/server_profile_selector_test.dart`：选择器和管理对话框的 Widget 测试。

不新增语言 key。界面复用已有的 `Name`、`Add`、`Delete`、`Default`、`ID Server`、`Settings`、`Ready`、`connecting_status` 和 `not_ready_status`，避免为一个私有功能机械修改全部语言文件。

---

### 任务 0：安装仓库 CI 对齐的 Flutter 工具链

**文件：**
- 不修改仓库文件；SDK 安装到 `/root/.cache/flutter-3.24.5`

- [ ] **步骤 1：下载并解压 Flutter 3.24.5**

```bash
mkdir -p /root/.cache/flutter-3.24.5
curl -fL \
  https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.24.5-stable.tar.xz \
  -o /root/.cache/flutter_linux_3.24.5-stable.tar.xz
tar -xf /root/.cache/flutter_linux_3.24.5-stable.tar.xz \
  -C /root/.cache/flutter-3.24.5 --strip-components=1
```

预期：`/root/.cache/flutter-3.24.5/bin/flutter` 存在。该版本来自 `.github/workflows/flutter-build.yml` 的 `FLUTTER_VERSION`。

- [ ] **步骤 2：初始化 Flutter 和项目依赖**

```bash
export PATH="/root/.cache/flutter-3.24.5/bin:$PATH"
flutter config --no-analytics
flutter precache --linux
cd flutter
flutter pub get
cd ..
```

预期：`flutter --version` 显示 `3.24.5`，`flutter pub get` 成功且不改写 `pubspec.yaml`。

- [ ] **步骤 3：安装匹配项目的 bridge 生成器**

```bash
cargo install flutter_rust_bridge_codegen \
  --version 1.80.1 --features uuid --locked
flutter_rust_bridge_codegen --version
```

预期：codegen 版本为 `1.80.1`。

- [ ] **步骤 4：记录 Flutter 基线**

```bash
cd flutter
flutter test
cd ..
```

预期：记录测试总数和结果。如果官方基线已有失败，保存首个失败测试名和错误，在修改功能前明确区分；不得静默跳过。

---

### 任务 1：在 `hbb_common` 建立服务器档案数据模型和持久化

**文件：**
- 修改：`libs/hbb_common/Cargo.toml`
- 创建：`libs/hbb_common/src/config/server_profiles.rs`
- 修改：`libs/hbb_common/src/config.rs:1-40`
- 测试：`libs/hbb_common/src/config/server_profiles.rs` 内联 `tests`

- [ ] **步骤 1：创建子模块功能分支**

```bash
git -C libs/hbb_common switch -c feature/profile-peer-storage
```

预期：子模块从 `7e1c392c...` 创建本地功能分支。

- [ ] **步骤 2：编写失败的档案模型测试**

先在 `libs/hbb_common/Cargo.toml` 的 `[dev-dependencies]` 加入：

```toml
tempfile = "3.10"
```

在 `server_profiles.rs` 先加入测试，覆盖名称规范化、重复名称、当前档案删除和持久化 round trip：

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn rejects_case_insensitive_duplicate_names() {
        let mut config = ServerProfilesConfig::default_with("host", "key");
        let err = config
            .add(ServerProfile::try_new("  default  ", "other", "other-key").unwrap())
            .unwrap_err();
        assert_eq!(err.to_string(), "server profile name already exists");
    }

    #[test]
    fn cannot_delete_active_or_last_profile() {
        let mut config = ServerProfilesConfig::default_with("host", "key");
        assert!(config.remove(DEFAULT_SERVER_PROFILE_ID).is_err());
    }

    #[test]
    fn store_round_trip_preserves_active_profile() {
        let root = tempdir().unwrap();
        let store = ServerProfileStore::with_root(root.path().to_owned());
        let mut config = ServerProfilesConfig::default_with("home", "home-key");
        let office = config
            .add(ServerProfile::try_new("Office", "office", "office-key").unwrap())
            .unwrap();
        config.set_active(&office.id).unwrap();
        store.save(&config).unwrap();
        assert_eq!(store.load().unwrap(), config);
    }

    #[test]
    fn rejects_server_scheme_and_invalid_port() {
        assert!(ServerProfile::try_new("Bad", "https://host", "key").is_err());
        assert!(ServerProfile::try_new("Bad", "host:70000", "key").is_err());
        assert!(ServerProfile::try_new("Public", "", "").is_ok());
    }

    #[test]
    fn corrupt_config_is_preserved_before_load_error() {
        let root = tempdir().unwrap();
        let store = ServerProfileStore::with_root(root.path().to_owned());
        std::fs::write(store.config_path(), b"not = [valid").unwrap();
        assert!(store.load().is_err());
        let backups = std::fs::read_dir(root.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| entry.file_name().to_string_lossy().contains(".corrupt-"))
            .count();
        assert_eq!(backups, 1);
    }
}
```

- [ ] **步骤 3：运行测试验证失败**

运行：

```bash
cargo test -p hbb_common server_profiles::tests -- --nocapture
```

预期：FAIL，原因是 `server_profiles` 模块和类型尚不存在。

- [ ] **步骤 4：实现最小档案类型和校验**

实现下列公开接口；`try_new` 负责 trim 和地址格式校验，名称比较使用 `to_lowercase()`，profile ID 只接受 ASCII 字母、数字、`-`、`_`。ID Server 为空表示公共服务器；非空值拒绝 URL scheme、空白和超出 `u16` 的端口，并使用 `url::Host::parse` 校验主机名、IPv4 或带方括号的 IPv6：

```rust
pub const SERVER_PROFILES_VERSION: u32 = 2;

// v2 separates the stable logical profile ID from peer-data identity namespaces. Previous
// namespaces remain available to already-running sessions, including sessions in other RustDesk
// processes whose liveness cannot be proven locally. They therefore have no count or age cap and
// are removed only when the logical profile is deleted.
pub const DEFAULT_SERVER_PROFILE_ID: &str = "default";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ServerProfile {
    pub id: String,
    pub name: String,
    pub id_server: String,
    pub key: String,
}

impl ServerProfile {
    pub fn try_new(name: &str, id_server: &str, key: &str) -> anyhow::Result<Self> {
        let profile = Self {
            id: uuid::Uuid::new_v4().to_string(),
            name: name.trim().to_owned(),
            id_server: id_server.trim().trim_end_matches('/').to_owned(),
            key: key.trim().to_owned(),
        };
        profile.validate()?;
        Ok(profile)
    }

    pub fn validate(&self) -> anyhow::Result<()>;
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ServerProfilesConfig {
    pub version: u32,
    pub active_profile_id: String,
    pub profiles: Vec<ServerProfile>,
}

impl ServerProfilesConfig {
    pub fn default_with(id_server: &str, key: &str) -> Self;
    pub fn validate(&self) -> anyhow::Result<()>;
    pub fn active(&self) -> anyhow::Result<&ServerProfile>;
    pub fn add(&mut self, profile: ServerProfile) -> anyhow::Result<ServerProfile>;
    pub fn update(&mut self, profile: ServerProfile) -> anyhow::Result<()>;
    pub fn remove(&mut self, id: &str) -> anyhow::Result<()>;
    pub fn set_active(&mut self, id: &str) -> anyhow::Result<()>;
}
```

- [ ] **步骤 5：实现可测试的 crash-safe 保存**

实现 `ServerProfileStore`。生产根目录由 `Config::path("")` 提供；测试使用 `with_root`。保存流程写 `.tmp`、`sync_all`、把旧文件改名为 `.bak`、把 `.tmp` 改为正式文件，第二次改名失败时恢复 `.bak`：

```rust
pub struct ServerProfileStore {
    root: PathBuf,
}

impl ServerProfileStore {
    pub fn production() -> Self;
    pub fn with_root(root: PathBuf) -> Self;
    pub fn load(&self) -> anyhow::Result<ServerProfilesConfig>;
    pub fn save(&self, config: &ServerProfilesConfig) -> anyhow::Result<()>;
    pub fn config_path(&self) -> PathBuf {
        self.root.join("RustDesk_server_profiles.toml")
    }
}
```

`save` 必须先调用 `config.validate()`；任何错误均返回 `Err`，不使用 `unwrap()` 或静默忽略。`load` 遇到 TOML 解析或版本错误时，先把原始字节复制为 `RustDesk_server_profiles.toml.corrupt-<unix_millis>`，再返回错误；不得用默认值覆盖损坏文件。

- [ ] **步骤 6：导出模块并运行测试**

在 `config.rs` 顶部加入：

```rust
mod server_profiles;
pub use server_profiles::{
    ServerProfile, ServerProfileStore, ServerProfilesConfig, DEFAULT_SERVER_PROFILE_ID,
};
```

运行：

```bash
cargo test -p hbb_common server_profiles::tests -- --nocapture
```

预期：上述 3 个测试 PASS。

- [ ] **步骤 7：提交子模块档案存储**

```bash
git -C libs/hbb_common add Cargo.toml src/config.rs src/config/server_profiles.rs
git -C libs/hbb_common commit -m "feat: add server profile storage"
```

---

### 任务 2：给 `PeerConfig` 增加档案命名空间和旧数据迁移

**文件：**
- 修改：`libs/hbb_common/src/config.rs:1725-1930`
- 修改：`libs/hbb_common/src/config/server_profiles.rs`
- 测试：上述两个文件的内联 `tests`

- [ ] **步骤 1：编写失败的路径隔离与迁移测试**

```rust
#[test]
fn same_peer_id_has_different_paths_per_profile() {
    let root = tempdir().unwrap();
    let home = PeerConfig::path_for_root(root.path(), "home", "123").unwrap();
    let office = PeerConfig::path_for_root(root.path(), "office", "123").unwrap();
    assert_ne!(home, office);
    assert!(home.ends_with("peer_profiles/home/peers/123.toml"));
}

#[test]
fn rejects_profile_path_traversal() {
    let root = tempdir().unwrap();
    assert!(PeerConfig::path_for_root(root.path(), "../escape", "123").is_err());
}

#[test]
fn migration_moves_legacy_peers_into_default_profile() {
    let root = tempdir().unwrap();
    let legacy = root.path().join("peers");
    std::fs::create_dir_all(&legacy).unwrap();
    std::fs::write(legacy.join("123.toml"), "[info]\nplatform='Linux'\n").unwrap();
    let store = ServerProfileStore::with_root(root.path().to_owned());
    store.load_or_migrate("home", "key").unwrap();
    assert!(root.path().join("peer_profiles/default/peers/123.toml").exists());
    assert!(!legacy.exists());
}
```

- [ ] **步骤 2：运行测试验证失败**

```bash
cargo test -p hbb_common same_peer_id_has_different_paths_per_profile -- --nocapture
cargo test -p hbb_common migration_moves_legacy_peers_into_default_profile -- --nocapture
```

预期：FAIL，缺少 profile-aware path 和 `load_or_migrate`。

- [ ] **步骤 3：实现活动 profile 上下文和显式 API**

在 `config.rs` 中加入：

```rust
lazy_static::lazy_static! {
    static ref ACTIVE_PEER_PROFILE: RwLock<String> =
        RwLock::new(DEFAULT_SERVER_PROFILE_ID.to_owned());
}

pub fn active_peer_profile() -> String {
    ACTIVE_PEER_PROFILE.read().unwrap().clone()
}

pub fn set_active_peer_profile(id: &str) -> crate::ResultType<()> {
    validate_profile_id(id)?;
    *ACTIVE_PEER_PROFILE.write().unwrap() = id.to_owned();
    Ok(())
}
```

给 `PeerConfig` 增加并实际使用以下方法：

```rust
pub fn load_for(profile_id: &str, id: &str) -> PeerConfig;
pub fn store_for(&self, profile_id: &str, id: &str) -> crate::ResultType<()>;
pub fn remove_for(profile_id: &str, id: &str) -> crate::ResultType<()>;
pub fn peers_for(
    profile_id: &str,
    id_filters: Option<Vec<String>>,
) -> Vec<(String, SystemTime, PeerConfig)>;
pub fn get_vec_id_modified_time_path_for(
    profile_id: &str,
    id_filters: &Option<Vec<String>>,
) -> Vec<(String, SystemTime, PathBuf)>;
pub fn batch_peers_for(
    profile_id: &str,
    all: &[(String, SystemTime, PathBuf)],
    from: usize,
    to: Option<usize>,
) -> (Vec<(String, SystemTime, PeerConfig)>, usize);
```

原 `load/store/remove/peers/get_vec.../batch_peers` 保留签名，内部读取 `active_peer_profile()` 后调用显式方法。显式写入失败必须记录 error；不得回退到其他 profile。

- [ ] **步骤 4：实现幂等迁移**

`ServerProfileStore::load_or_migrate(id_server, key)` 必须按以下确定性顺序处理：

```rust
pub fn load_or_migrate(
    &self,
    id_server: &str,
    key: &str,
) -> anyhow::Result<ServerProfilesConfig> {
    if self.config_path().exists() {
        return self.load();
    }
    self.prepare_default_peer_dir()?;
    let config = ServerProfilesConfig::default_with(id_server, key);
    self.save(&config)?;
    Ok(config)
}
```

`prepare_default_peer_dir` 覆盖源/目标目录的四种状态；两者同时存在时逐文件合并，目标优先，无法移动的文件使迁移返回错误且不删除源目录。

- [ ] **步骤 5：验证隔离、迁移和全量基线**

```bash
cargo test -p hbb_common config::tests -- --nocapture
cargo test -p hbb_common server_profiles::tests -- --nocapture
cargo test -p hbb_common --lib
```

预期：新增测试 PASS，原 94 个基线测试仍全部 PASS。

- [ ] **步骤 6：提交子模块 PeerConfig 改动**

```bash
git -C libs/hbb_common add src/config.rs src/config/server_profiles.rs
git -C libs/hbb_common commit -m "feat: namespace peer config by server profile"
```

---

### 任务 3：实现 Rust 主进程 `ServerProfileManager` 和 FFI

**文件：**
- 创建：`src/server_profiles.rs`
- 修改：`src/lib.rs:1-60`
- 修改：`src/flutter_ffi.rs:950-1100,1740-1830`
- 测试：`src/server_profiles.rs` 内联 `tests`

- [ ] **步骤 1：编写失败的 manager 状态转换测试**

用纯函数把“切换前 options → 切换后 options”隔离出来，使测试不依赖 IPC：

```rust
#[test]
fn selected_profile_replaces_only_server_options() {
    let mut options = HashMap::from([("keep-me".to_owned(), "Y".to_owned())]);
    let profile = ServerProfile {
        id: "office".to_owned(),
        name: "Office".to_owned(),
        id_server: "hbbs.office:21116".to_owned(),
        key: "public-key".to_owned(),
    };
    apply_profile_options(&mut options, &profile);
    assert_eq!(options["custom-rendezvous-server"], "hbbs.office:21116");
    assert_eq!(options["key"], "public-key");
    assert!(!options.contains_key("relay-server"));
    assert!(!options.contains_key("api-server"));
    assert_eq!(options["keep-me"], "Y");
}
```

- [ ] **步骤 2：运行测试验证失败**

```bash
cargo test --lib --features flutter server_profiles::tests::selected_profile_replaces_only_server_options
```

预期：FAIL，模块和函数尚不存在。如果根 crate 因本机缺少 vcpkg/系统库无法链接，记录原始错误，并改用 `cargo check --lib --features flutter` 验证类型；不得把环境失败描述为功能测试通过。

- [ ] **步骤 3：实现 manager 和统一 JSON 响应**

`src/server_profiles.rs` 实现：

```rust
#[derive(Serialize)]
pub struct ServerProfileResponse {
    pub ok: bool,
    pub error: String,
    pub config: Option<ServerProfilesConfig>,
}

pub struct ServerProfileManager {
    store: ServerProfileStore,
    config: ServerProfilesConfig,
}

impl ServerProfileManager {
    pub fn initialize() -> ResultType<()>;
    pub fn snapshot() -> ResultType<ServerProfilesConfig>;
    pub fn add(name: String, id_server: String, key: String) -> ResultType<()>;
    pub fn update(id: String, name: String, id_server: String, key: String) -> ResultType<()>;
    pub fn remove(id: String) -> ResultType<()>;
    pub fn switch(id: String) -> ResultType<()>;
    pub fn active_profile_id() -> String;
}
```

`switch` 在持有 manager mutex 时复制旧 config，保存新 `active_profile_id`，调用 `crate::ipc::set_options` 批量应用 options，成功后调用 `set_active_peer_profile`。IPC 失败时保存旧 config 并恢复旧活动 profile。服务器不可达不由本函数判定。

`update` 保留原 profile ID；如果更新的是活动档案，保存后立即走与 `switch` 相同的 options 应用路径。`remove` 先把 `peer_profiles/<id>` 原子改名为同级 tombstone，再保存移除档案后的配置；配置保存失败时把 tombstone 改回原目录，保存成功后才递归删除 tombstone。改名或删除准备失败时不修改档案配置。

- [ ] **步骤 4：在 `lib.rs` 注册模块并初始化**

```rust
#[cfg(feature = "flutter")]
mod server_profiles;
```

在 `flutter_ffi::main_init` 的现有 `initialize` 完成后调用：

```rust
if let Err(err) = crate::server_profiles::ServerProfileManager::initialize() {
    log::error!("failed to initialize server profiles: {err}");
}
```

- [ ] **步骤 5：暴露 FFI CRUD 和切换接口**

```rust
pub fn main_get_server_profiles() -> String;
pub fn main_add_server_profile(name: String, id_server: String, key: String) -> String;
pub fn main_update_server_profile(
    id: String,
    name: String,
    id_server: String,
    key: String,
) -> String;
pub fn main_delete_server_profile(id: String) -> String;
pub fn main_switch_server_profile(id: String) -> String;
```

五个接口都返回 `ServerProfileResponse` JSON；序列化失败返回 `{"ok":false,"error":"failed to serialize server profile response"}`，不得 `unwrap()`。

- [ ] **步骤 6：验证并提交主仓库 Rust manager**

```bash
cargo fmt --all
cargo check --lib --features flutter
git add libs/hbb_common src/server_profiles.rs src/flutter_ffi.rs src/lib.rs
git commit -m "feat: manage desktop server profiles"
```

提交包含新的 `hbb_common` 子模块指针。

---

### 任务 4：让会话和最近设备始终使用正确 profile

**文件：**
- 修改：`src/client.rs:1734-2240`
- 修改：`src/flutter.rs:1295-1365`
- 修改：`src/flutter_ffi.rs:1380-1545,1790-1820`
- 修改：`src/ui_interface.rs:285-335`
- 测试：`src/client.rs` 内联 `tests` 或可独立的 helper 测试

- [ ] **步骤 1：编写失败的会话 profile 固定测试**

给 `LoginConfigHandler` 增加可测试构造辅助并写测试：

```rust
#[test]
fn login_config_keeps_profile_captured_at_initialize() {
    set_active_peer_profile("home").unwrap();
    let mut handler = LoginConfigHandler::default();
    handler.initialize(
        "123".to_owned(),
        ConnType::DEFAULT_CONN,
        "home".to_owned(),
        None,
        false,
        None,
        None,
        None,
    );
    set_active_peer_profile("office").unwrap();
    assert_eq!(handler.profile_id(), "home");
}
```

- [ ] **步骤 2：实现会话捕获并替换所有 handler 内 PeerConfig 访问**

给 `LoginConfigHandler` 增加：

```rust
profile_id: String,

pub fn profile_id(&self) -> &str {
    &self.profile_id
}
```

`initialize` 新增 `profile_id: String` 参数并在加载配置前保存。`load_config`、`save_config` 以及 `toggle_option` 中的直接 `store` 改成 `PeerConfig::load_for`/`store_for`。写入失败必须记录包含 profile 和 peer ID 的错误，但日志不得包含密码。

- [ ] **步骤 3：创建会话时捕获活动 profile**

在 `flutter::session_add` 调用 `initialize` 前只读取一次：

```rust
let profile_id = crate::server_profiles::ServerProfileManager::active_profile_id();
session.lc.write().unwrap().initialize(
    id.to_owned(),
    conn_type,
    profile_id,
    switch_uuid,
    force_relay,
    get_adapter_luid(),
    shared_password,
    conn_token,
);
```

不要把 profile 参数暴露给 Dart，避免 UI 伪造会话命名空间。

- [ ] **步骤 4：recent peers、删除、收藏读取活动 profile**

在 `flutter_ffi.rs` 的 recent loader 中先读取一次活动 profile，并传给整个批次：

```rust
let profile_id = ServerProfileManager::active_profile_id();
let paths = PeerConfig::get_vec_id_modified_time_path_for(&profile_id, &None);
let peers = PeerConfig::batch_peers_for(&profile_id, &paths, from, to);
```

`main_remove_peer` 使用 `remove_for`；`main_load_recent_peers_for_ab` 和 `main_load_fav_peers` 使用 `peers_for`。`ui_interface.rs` 中主页尚未建立会话的 peer option/alias/password 辅助函数使用活动 profile 显式 API。

- [ ] **步骤 5：运行检查和会话回归测试**

```bash
cargo fmt --all
cargo test --lib --features flutter login_config_keeps_profile_captured_at_initialize
cargo check --lib --features flutter
```

预期：测试 PASS；类型检查无新增错误。

- [ ] **步骤 6：提交会话隔离**

```bash
git add src/client.rs src/flutter.rs src/flutter_ffi.rs src/ui_interface.rs
git commit -m "feat: isolate sessions by server profile"
```

---

### 任务 5：生成 bridge 并实现 Flutter 档案模型

**文件：**
- 修改：`flutter/lib/generated_bridge.dart`
- 创建：`flutter/lib/models/server_profile_model.dart`
- 修改：`flutter/lib/models/model.dart:3680-3740`
- 创建：`flutter/test/server_profile_model_test.dart`

- [ ] **步骤 1：在有 Flutter 环境中重新生成 bridge**

```bash
~/.cargo/bin/flutter_rust_bridge_codegen \
  --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart
dart format flutter/lib/generated_bridge.dart
```

预期：生成 `mainGetServerProfiles`、`mainAddServerProfile`、`mainUpdateServerProfile`、`mainDeleteServerProfile`、`mainSwitchServerProfile`。使用任务 0 安装的 Flutter/Dart CLI 和 codegen 1.80.1；生成失败时保留原错误并修正 Rust FFI 签名，不手写声称等价的完整生成文件。

- [ ] **步骤 2：编写失败的纯 Dart 模型测试**

```dart
test('parses active profile and normalizes response', () {
  final state = ServerProfilesState.fromResponse(jsonEncode({
    'ok': true,
    'error': '',
    'config': {
      'version': 1,
      'active_profile_id': 'home',
      'profiles': [
        {'id': 'home', 'name': 'Home', 'id_server': 'hbbs.home', 'key': 'k'}
      ]
    }
  }));
  expect(state.active.id, 'home');
  expect(state.active.name, 'Home');
});

test('throws response error instead of replacing current state', () {
  expect(
    () => ServerProfilesState.fromResponse(
      '{"ok":false,"error":"disk full","config":null}',
    ),
    throwsA(isA<ServerProfileException>()),
  );
});
```

- [ ] **步骤 3：实现 DTO 和响应式 model**

```dart
class ServerProfile {
  final String id;
  final String name;
  final String idServer;
  final String key;
  const ServerProfile({required this.id, required this.name,
    required this.idServer, required this.key});
  factory ServerProfile.fromJson(Map<String, dynamic> json);
}

abstract class ServerProfileModelBase extends ChangeNotifier {
  List<ServerProfile> get profiles;
  String get activeProfileId;
  bool get switching;
  ServerProfile get active;
  Future<void> add(String name, String idServer, String key);
  Future<void> update(ServerProfile profile);
  Future<void> remove(String id);
  Future<void> switchTo(String id);
}

class ServerProfileModel extends ServerProfileModelBase {
  @override
  List<ServerProfile> profiles = const [];
  @override
  String activeProfileId = '';
  @override
  bool switching = false;

  Future<void> load();
  @override
  Future<void> add(String name, String idServer, String key);
  @override
  Future<void> update(ServerProfile profile);
  @override
  Future<void> remove(String id);
  @override
  Future<void> switchTo(String id);
}
```

`switchTo` 使用 `try/finally` 管理 `switching`，每次状态改变调用 `notifyListeners()`；成功后更新 state、清空 `gFFI.recentPeersModel.peers/restPeerIds` 并调用 `bind.mainLoadRecentPeers()`；失败保持旧 state 并抛出 `ServerProfileException`。

- [ ] **步骤 4：注册全局模型**

在 `FFI` 中加入：

```dart
late final ServerProfileModel serverProfileModel;

serverProfileModel = ServerProfileModel();
```

仅 `desktopType == DesktopType.main` 的主窗口在启动后调用 `load()`；远程子窗口不重复初始化。

- [ ] **步骤 5：运行 Dart 测试并提交**

```bash
cd flutter
flutter test test/server_profile_model_test.dart
dart format lib/models/server_profile_model.dart lib/models/model.dart \
  test/server_profile_model_test.dart
cd ..
git add flutter/lib/generated_bridge.dart flutter/lib/models/server_profile_model.dart \
  flutter/lib/models/model.dart flutter/test/server_profile_model_test.dart
git commit -m "feat: add Flutter server profile model"
```

预期：模型测试 PASS，生成后的 bridge 与 Rust FFI 签名一致。

---

### 任务 6：实现配置管理对话框

**文件：**
- 创建：`flutter/lib/desktop/widgets/server_profile_dialog.dart`
- 创建：`flutter/test/server_profile_selector_test.dart`

- [ ] **步骤 1：编写失败的 Widget 测试**

使用注入的 fake model，不直接依赖 native bridge：

```dart
const homeOnly = [
  ServerProfile(id: 'home', name: 'Home', idServer: 'home', key: 'k'),
];
const twoProfiles = [
  ServerProfile(id: 'home', name: 'Home', idServer: 'home', key: 'k'),
  ServerProfile(id: 'office', name: 'Office', idServer: 'office', key: 'k2'),
];

class FakeServerProfileModel extends ServerProfileModelBase {
  FakeServerProfileModel.withProfiles({
    required String active,
    required this.profiles,
  })  : activeProfileId = active,
        switching = false;

  FakeServerProfileModel.busy({required this.profiles})
      : activeProfileId = profiles.first.id,
        switching = true;

  @override
  List<ServerProfile> profiles;
  @override
  String activeProfileId;
  @override
  bool switching;
  final switchCalls = <String>[];
  @override
  ServerProfile get active =>
      profiles.firstWhere((profile) => profile.id == activeProfileId);
  @override
  Future<void> switchTo(String id) async => switchCalls.add(id);
  @override
  Future<void> add(String name, String idServer, String key) async {}
  @override
  Future<void> update(ServerProfile profile) async {}
  @override
  Future<void> remove(String id) async {}
}

Widget testApp(Widget child) => MaterialApp(home: Scaffold(body: child));

testWidgets('active profile cannot be deleted', (tester) async {
  final model = FakeServerProfileModel.withProfiles(
    active: 'home',
    profiles: const [
      ServerProfile(id: 'home', name: 'Home', idServer: 'home', key: 'k'),
      ServerProfile(id: 'office', name: 'Office', idServer: 'office', key: 'k2'),
    ],
  );
  await tester.pumpWidget(testApp(ServerProfileDialog(model: model)));
  expect(find.byKey(const ValueKey('delete-home')), findsNothing);
  expect(find.byKey(const ValueKey('delete-office')), findsOneWidget);
});

testWidgets('save validates trimmed unique name', (tester) async {
  final model = FakeServerProfileModel.withProfiles(active: 'home', profiles: homeOnly);
  await tester.pumpWidget(testApp(ServerProfileDialog(model: model)));
  await tester.tap(find.byKey(const ValueKey('add-profile')));
  await tester.enterText(find.byKey(const ValueKey('profile-name')), ' HOME ');
  await tester.tap(find.text('OK'));
  await tester.pump();
  expect(find.text('server profile name already exists'), findsOneWidget);
});
```

- [ ] **步骤 2：实现管理列表和编辑表单**

`ServerProfileDialog` 接受 `ServerProfileModelBase model`，生产传真实 model，测试传 fake。列表显示名称和 ID Server；活动项显示 check 图标；非活动项显示删除按钮。新增/编辑表单只包含 `Name`、`ID Server`、`Key`，提交时 trim 并调用 model。ID Server 旁提供测试图标，调用现有 `bind.mainTestIfValidServer(server: value, testWithProxy: true)` 并展示结果；测试失败不禁用保存。

删除流程必须先使用现有 `deleteConfirmDialog`，确认后调用 `model.remove(id)`；错误用现有 `showToast` 或字段错误显示。测试 key 使用计划中固定的 `ValueKey`。

- [ ] **步骤 3：运行 Widget 测试和格式化**

```bash
cd flutter
flutter test test/server_profile_selector_test.dart
dart format lib/desktop/widgets/server_profile_dialog.dart \
  test/server_profile_selector_test.dart
```

预期：测试 PASS。

- [ ] **步骤 4：提交管理对话框**

```bash
git add flutter/lib/desktop/widgets/server_profile_dialog.dart \
  flutter/test/server_profile_selector_test.dart
git commit -m "feat: manage server profiles from desktop UI"
```

---

### 任务 7：在主页接入快速选择器

**文件：**
- 创建：`flutter/lib/desktop/widgets/server_profile_selector.dart`
- 修改：`flutter/lib/desktop/pages/connection_page.dart:260-300`
- 修改：`flutter/test/server_profile_selector_test.dart`

- [ ] **步骤 1：编写失败的快速切换测试**

```dart
testWidgets('selecting another profile switches once', (tester) async {
  final model = FakeServerProfileModel.withProfiles(
    active: 'home',
    profiles: twoProfiles,
  );
  await tester.pumpWidget(testApp(ServerProfileSelector(model: model)));
  await tester.tap(find.byKey(const ValueKey('server-profile-selector')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Office'));
  await tester.pump();
  expect(model.switchCalls, ['office']);
});

testWidgets('selector is disabled while switching', (tester) async {
  final model = FakeServerProfileModel.busy(profiles: twoProfiles);
  await tester.pumpWidget(testApp(ServerProfileSelector(model: model)));
  expect(
    tester.widget<InkWell>(find.byKey(const ValueKey('server-profile-selector'))).onTap,
    isNull,
  );
});
```

- [ ] **步骤 2：实现选择器**

选择器使用 `AnimatedBuilder(animation: model, ...)` 监听 `ChangeNotifier`，从现有 `stateGlobal.svcStatus` 显示就绪、连接中或未就绪状态圆点，并显示活动档案名称和下拉箭头。Popup 菜单列出全部档案，当前项带 check；底部 `Settings` 项打开 `ServerProfileDialog`。`switchTo` 抛错时使用 toast；切换期间显示小型 progress indicator 并禁用 `onTap`。

- [ ] **步骤 3：接入 `ConnectionPage`**

把现有顶部 Row 改为：

```dart
Row(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Flexible(child: _buildRemoteIDTextField(context)),
    const Spacer(),
    ServerProfileSelector(model: gFFI.serverProfileModel),
    const SizedBox(width: 12),
  ],
).marginOnly(top: 22),
```

窄窗口使用 `Wrap` 或 `LayoutBuilder`，保证连接卡和选择器不发生 overflow；断点以下将选择器放到连接卡上方右对齐。

- [ ] **步骤 4：运行 UI 测试与静态分析**

```bash
cd flutter
flutter test test/server_profile_model_test.dart test/server_profile_selector_test.dart
flutter analyze lib/models/server_profile_model.dart \
  lib/desktop/widgets/server_profile_dialog.dart \
  lib/desktop/widgets/server_profile_selector.dart \
  lib/desktop/pages/connection_page.dart
dart format lib/desktop/widgets/server_profile_selector.dart \
  lib/desktop/pages/connection_page.dart test/server_profile_selector_test.dart
```

预期：测试和 analyze 全部成功，无 overflow 相关测试异常。

- [ ] **步骤 5：提交主页入口**

```bash
git add flutter/lib/desktop/widgets/server_profile_selector.dart \
  flutter/lib/desktop/pages/connection_page.dart \
  flutter/test/server_profile_selector_test.dart
git commit -m "feat: switch server profiles from desktop home"
```

---

### 任务 8：完成迁移、错误路径和端到端验证

**文件：**
- 修改：实现过程中涉及的 Rust/Dart 文件，仅限修复验证发现的问题
- 更新：`docs/superpowers/specs/2026-07-11-server-profile-switching-design.md`，仅当实现中的最终接口名称与规格不同

- [ ] **步骤 1：运行完整 Rust 验证**

```bash
cargo fmt --check
cargo test -p hbb_common --lib
cargo check --lib --features flutter
```

预期：`hbb_common` 原 94 个测试加新增测试全部 PASS；fmt/check 无错误。若根 crate 受本机系统库阻塞，记录准确命令和首个错误，并在具备 RustDesk 桌面构建环境的 CI 上运行同一命令。

- [ ] **步骤 2：运行完整 Flutter 验证**

```bash
cd flutter
flutter test test/server_profile_model_test.dart test/server_profile_selector_test.dart
flutter analyze
cd ..
```

预期：测试与 analyze PASS。

- [ ] **步骤 3：进行桌面手工矩阵验证**

在 Windows、Linux、macOS 各验证并记录结果：

```text
1. 旧 peers 自动出现在“默认配置”。
2. 两个档案使用相同设备 ID，各自记住不同密码。
3. 打开远程会话，切换档案，旧会话不断开。
4. 新连接使用新档案服务器。
5. 切回旧档案后列表、别名、密码恢复。
6. 重启应用后保持最后选择的档案。
7. 目标服务器离线时仍完成切换并显示未就绪。
```

- [ ] **步骤 4：检查敏感信息与仓库卫生**

```bash
rg -n "debugPrint|log::(debug|info)|println!" \
  src/server_profiles.rs libs/hbb_common/src/config/server_profiles.rs \
  flutter/lib/models/server_profile_model.dart
git diff --check
git status --short
git log --oneline --decorate -8
```

逐条确认没有打印连接密码或 Key；确认 `.superpowers/` 不在功能 worktree 中，且没有构建产物进入提交。

- [ ] **步骤 5：提交验证阶段的必要修复**

只有存在验证修复时执行：

```bash
git add libs/hbb_common src/server_profiles.rs src/client.rs src/flutter.rs \
  src/flutter_ffi.rs src/ui_interface.rs src/lib.rs \
  flutter/lib/generated_bridge.dart flutter/lib/models/server_profile_model.dart \
  flutter/lib/models/model.dart flutter/lib/desktop/widgets/server_profile_dialog.dart \
  flutter/lib/desktop/widgets/server_profile_selector.dart \
  flutter/lib/desktop/pages/connection_page.dart \
  flutter/test/server_profile_model_test.dart \
  flutter/test/server_profile_selector_test.dart
git commit -m "fix: harden server profile switching"
```

不得为制造提交而修改格式或无关代码。
