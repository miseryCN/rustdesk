# RustDesk 多服务器档案：AI 执行与三端构建手册

本文档用于把本分支交给另一个 AI 或开发者继续执行、验证和维护。不要在命令、日志、提交信息或文档中记录 GitHub Token、服务器 Key、密码或真实服务器地址。

## 仓库与分支

本功能使用两个 GitHub fork，必须递归克隆：

- 主仓库：`https://github.com/miseryCN/rustdesk`
- 子模块：`https://github.com/miseryCN/hbb_common`
- 主分支：`feature/server-profiles`
- 子模块分支：`feature/profile-peer-storage`

```sh
git clone --recurse-submodules --branch feature/server-profiles \
  https://github.com/miseryCN/rustdesk.git rustdesk
cd rustdesk
git submodule status
```

`libs/hbb_common` 必须指向子模块提交 `5197a17a43e3b218d9c7cd28d47ed0f5dd3ff6ad`。如果子模块为空或不一致，先执行：

```sh
git submodule sync --recursive
git submodule update --init --recursive
```

## 功能边界

仅桌面端（Windows、Linux、macOS）有多服务器档案 UI。移动端不会自动加载档案；Android/iOS FFI 返回安全的不可用响应。

- 主页右上角可快速切换 ID Server 与 Key，不重启客户端。
- 已建立的远程会话不会被主动断开；它继续使用切换前捕获的凭据命名空间。
- 最近连接、别名、密码和 RDP/OS 凭据按服务器身份隔离。
- 编辑档案名称不会清空设备；编辑 ID Server 或 Key 会建立新的凭据命名空间，旧会话仅能写历史命名空间，不能污染新服务器。
- 最近连接使用带 profile/epoch 的 snapshot 读取；旧异步结果不得覆盖当前档案。

关键代码位置：

| 目标 | 文件 |
| --- | --- |
| 档案持久化、迁移、跨进程锁 | `libs/hbb_common/src/config/server_profiles.rs` |
| PeerConfig 命名空间 | `libs/hbb_common/src/config.rs` |
| 档案事务与运行时 options | `src/server_profiles.rs` |
| Flutter FFI 与 recent snapshot | `src/flutter_ffi.rs` |
| Flutter 档案状态 | `flutter/lib/models/server_profile_model.dart` |
| 最近连接协调器 | `flutter/lib/models/peer_model.dart` |
| 管理对话框与选择器 | `flutter/lib/desktop/widgets/server_profile_*.dart` |

## 固定工具版本

当前 CI 使用下列版本，继续开发或复现构建时优先保持一致：

- Rust：Windows/Linux `1.75`；macOS `1.81`
- Flutter：桌面 x64 `3.24.5`
- Windows ARM64 Flutter：`3.44.0`（仅 ARM64 需要）
- vcpkg commit：`120deac3062162151622ca4860575a33844ba10b`

生成 Flutter/Rust 桥接时必须使用官方 FRB 命令，不能手写生成文件：

```sh
flutter_rust_bridge_codegen \
  --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart
```

生成后要检查四个生成文件均被跟踪且没有意外 diff：

- `src/bridge_generated.rs`
- `src/bridge_generated.io.rs`
- `flutter/lib/generated_bridge.dart`
- `flutter/lib/generated_bridge.freezed.dart`

## Windows x64 构建

### 前置条件

安装以下组件：

1. Visual Studio 2022 Build Tools，勾选 **Desktop development with C++**、MSVC v143、Windows 10/11 SDK。
2. Git、Python 3、Flutter `3.24.5`。
3. Rust 的 `x86_64-pc-windows-msvc` 工具链。

PowerShell：

```powershell
cd C:\src\rustdesk

rustup toolchain install 1.75.0-x86_64-pc-windows-msvc
rustup override set 1.75.0

flutter config --enable-windows-desktop
flutter doctor
```

安装 vcpkg 与依赖：

```powershell
git clone https://github.com/microsoft/vcpkg C:\src\vcpkg
cd C:\src\vcpkg
git checkout 120deac3062162151622ca4860575a33844ba10b
.\bootstrap-vcpkg.bat -disableMetrics

$env:VCPKG_ROOT = 'C:\src\vcpkg'
[Environment]::SetEnvironmentVariable('VCPKG_ROOT', $env:VCPKG_ROOT, 'User')

cd C:\src\rustdesk
& "$env:VCPKG_ROOT\vcpkg.exe" install `
  --triplet x64-windows-static `
  --x-install-root="$env:VCPKG_ROOT\installed"
```

构建未打包的 Release 目录：

```powershell
cd C:\src\rustdesk
flutter pub get
py -3 build.py --portable --flutter --skip-portable-pack --hwcodec --vram
```

运行或复制整个输出目录：

```text
flutter\build\windows\x64\runner\Release\
```

其中的 `rustdesk.exe` 是主程序。不要只复制 exe；同目录 DLL、`data` 与资源也必须一起带走。

## Linux x64 构建（Ubuntu/Debian）

安装系统依赖：

```sh
sudo apt update
sudo apt install -y \
  zip g++ gcc git curl wget nasm yasm cmake make pkg-config clang \
  libgtk-3-dev libxcb-randr0-dev libxdo-dev libxfixes-dev \
  libxcb-shape0-dev libxcb-xfixes0-dev libasound2-dev libpulse-dev \
  libclang-dev ninja-build libgstreamer1.0-dev \
  libgstreamer-plugins-base1.0-dev libpam0g-dev
```

安装 Rust、Flutter 与 vcpkg：

```sh
cd rustdesk
rustup toolchain install 1.75.0
rustup override set 1.75.0

flutter config --enable-linux-desktop
flutter doctor

git clone https://github.com/microsoft/vcpkg "$HOME/vcpkg"
cd "$HOME/vcpkg"
git checkout 120deac3062162151622ca4860575a33844ba10b
./bootstrap-vcpkg.sh -disableMetrics

export VCPKG_ROOT="$HOME/vcpkg"
cd -
"$VCPKG_ROOT/vcpkg" install \
  --triplet x64-linux \
  --x-install-root="$VCPKG_ROOT/installed"
```

构建：

```sh
flutter pub get
python3 build.py --flutter --hwcodec --unix-file-copy-paste
```

未打包的 Release bundle 位于：

```text
flutter/build/linux/x64/release/bundle/
```

可直接执行：

```sh
./flutter/build/linux/x64/release/bundle/rustdesk
```

## macOS 构建

先安装 Xcode（含 Command Line Tools）、Git、Python 3、Flutter `3.24.5` 和 Homebrew。然后安装工具：

```sh
xcode-select --install
brew install cmake ninja nasm yasm pkg-config autoconf automake libtool
```

Apple Silicon 使用 `arm64-osx`；Intel 使用 `x64-osx`。以下以 Apple Silicon 为例：

```sh
cd rustdesk
rustup toolchain install 1.81.0
rustup override set 1.81.0

flutter config --enable-macos-desktop
flutter doctor

git clone https://github.com/microsoft/vcpkg "$HOME/vcpkg"
cd "$HOME/vcpkg"
git checkout 120deac3062162151622ca4860575a33844ba10b
./bootstrap-vcpkg.sh -disableMetrics

export VCPKG_ROOT="$HOME/vcpkg"
cd -
"$VCPKG_ROOT/vcpkg" install \
  --triplet arm64-osx \
  --x-install-root="$VCPKG_ROOT/installed"
```

构建：

```sh
flutter pub get
python3 build.py --flutter --hwcodec
```

构建产物通常位于：

```text
flutter/build/macos/Build/Products/Release/RustDesk.app
```

Intel Mac 只需将 vcpkg triplet 改成 `x64-osx`。首次在本机运行未签名应用时，macOS 可能需要在“隐私与安全性”中手动允许。

## 验证命令

代码修改后按比例执行；不要只跑 Flutter：

```sh
# hbb_common
cd libs/hbb_common
cargo test --lib

# 主 Rust crate（Linux）
cd ../..
PKG_CONFIG_PATH=/tmp/rustdesk-pkgconfig \
  cargo check --lib --features flutter,linux-pkg-config

# Flutter
cd flutter
flutter test
flutter analyze
```

本功能至少应覆盖：档案切换后旧会话不断线、地址/Key 编辑后的凭据隔离、最近连接在慢请求逆序下不串档案、损坏配置 v1→v2 迁移、跨进程 tombstone 锁，以及 Windows/Linux/macOS 的真实 UI 冒烟测试。

## 后续跟官方更新

两个 fork 都保留官方父仓库关系。更新时不要只合并主仓库；主仓和 `hbb_common` 要一起处理：

```sh
# 主仓库中
git remote add upstream https://github.com/rustdesk/rustdesk.git
git fetch upstream
git checkout feature/server-profiles
git merge upstream/master

# 子模块中
git -C libs/hbb_common remote add upstream https://github.com/rustdesk/hbb_common.git
git -C libs/hbb_common fetch upstream
git -C libs/hbb_common checkout feature/profile-peer-storage
git -C libs/hbb_common merge upstream/main
```

处理冲突、测试通过后，先推送子模块分支，再提交主仓新的 gitlink 与 `.gitmodules`。不要把子模块 URL 改回官方地址，否则干净克隆无法取得本功能的子模块提交。
