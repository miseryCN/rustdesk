# Windows 构建排障说明

本项目保持 RustDesk 当前跨平台基线：Flutter `3.24.5`、Rust `1.75`、LLVM `15.0.6`、项目锁定的 vcpkg baseline 和默认 AOM `3.12.1`。不要为了某一台 Windows 机器的本地构建而升级 Flutter/Dart、修改 AOM/FFmpeg overlay、手工复制不同 triplet 的库，或提交 Windows 生成的 C FFI bindings；这些做法会影响 Linux、macOS、移动端和 CI。

完整的 Windows、Linux、macOS 构建步骤见 [AI_AGENT_SERVER_PROFILES.md](AI_AGENT_SERVER_PROFILES.md)。

## Windows 常见问题

### 找不到 `libclang.dll`

安装 LLVM `15.0.6`，并在当前 PowerShell 设置：

```powershell
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
```

该变量只影响本机 bindgen；不要因此提交预生成 bindings。

### vcpkg 头文件或库找不到

使用仓库根目录的 manifest 和固定 triplet 安装依赖：

```powershell
$env:VCPKG_ROOT = 'C:\src\vcpkg'
$env:VCPKG_DEFAULT_HOST_TRIPLET = 'x64-windows-static'
& "$env:VCPKG_ROOT\vcpkg.exe" install `
  --triplet x64-windows-static `
  --x-install-root="$env:VCPKG_ROOT\installed"
```

不要手动把 `x64-windows` 的 FFmpeg 文件复制到 `x64-windows-static`。如果 manifest 安装结果不完整，应检查 vcpkg 的构建日志并停止；不要修改仓库 portfile 或 manifest 来绕过错误。

### 可复现的构建命令

`flutter build windows` 只负责 Flutter runner；干净仓库还需要先构建 Rust 动态库。使用项目根目录的构建脚本：

完整命令（包括 Flutter SDK 补丁、自定义引擎与锁文件恢复）见 [AI_AGENT_SERVER_PROFILES.md](AI_AGENT_SERVER_PROFILES.md) 的“Windows x64 构建”。`flutter pub get` 必须在 `flutter\` 目录运行；若它仅更新 `flutter/pubspec.lock`，允许其作为本机临时构建文件，构建后用 `git restore flutter/pubspec.lock` 恢复。

输出目录为：

```text
flutter\build\windows\x64\runner\Release\
```

## 本地排障记录

### 从零开始的 Windows x64 构建记录

以下记录对应一次按 Windows CI 基线完成的本机构建准备。开始前先在仓库根目录执行 `git status --short`，工作树必须干净；然后 `git pull` 并确认 `libs/hbb_common` 指向文档指定的 gitlink。不要用旧的、版本不明的 Flutter 或 LLVM 安装继续构建。

1. 准备独立的 Flutter `3.24.5` SDK，并确认其 Dart 为 `3.5.4`；准备 LLVM `15.0.6`，设置 `LIBCLANG_PATH=C:\Program Files\LLVM\bin`，同时把 Flutter 与 LLVM 的 `bin` 放到当前 PowerShell 的 `Path` 最前面。
2. 安装并在仓库根目录启用 `1.75.0-x86_64-pc-windows-msvc`；执行 `flutter config --enable-windows-desktop`、`flutter doctor`、`flutter --version` 和 `rustc --version`。Android Studio 缺失不影响 Windows desktop 构建，但 Visual Studio 的 Windows C++ 工作负载必须可用。
3. 在独立 Flutter SDK 中只应用仓库的 `flutter_3.24.4_dropdown_menu_enableFilter.diff`，执行 `flutter precache --windows`，并按主文档下载和覆盖 RustDesk 的 Windows x64 引擎。补丁和引擎只能改 Flutter SDK，不能改 RustDesk 源码。
4. 使用提交 `120deac3062162151622ca4860575a33844ba10b` 的 vcpkg，设置 `VCPKG_DEFAULT_HOST_TRIPLET=x64-windows-static`，在 RustDesk 根目录执行完整 manifest 安装。不要传单独包名、不要加 `--classic`，也不要修改 `vcpkg.json`、portfile 或手工复制 `.lib`/`.dll`/`.pc` 文件。
5. 在 `flutter\` 目录执行 `flutter pub get`。Flutter `3.24.5` 会临时重解 `flutter/pubspec.lock`；继续前必须确认 `git diff --name-only` 仅显示这个文件。它是本机构建产物，最终必须恢复，绝不提交。
6. 从根目录执行 `cargo clean`，再执行唯一的最终命令：`py -3 build.py --portable --flutter --skip-portable-pack --hwcodec --vram`。不要省略硬件编码和显存参数，也不要改用单独的 `flutter build windows`。

本次排障还发现，完整 manifest vcpkg 安装能够自动移除早先错误 triplet 的依赖并重建 `x64-windows-static` 依赖；这是预期行为，不能用手工复制静态库替代。

实际遇到的问题与结论：

- 在仓库根目录对 manifest vcpkg 使用“指定单个包名”的安装命令会被拒绝；正确做法是上面的无包名完整 manifest 命令，而不是通过 `--classic` 绕过它。
- 机器上原有 LLVM 16 或 LLVM 22 都不符合本基线；应安装 LLVM 15.0.6 并显式设置当前 PowerShell 的路径，避免依赖系统默认 `clang`。
- 前台构建工具的固定超时不是编译失败证据。若需要长时间执行，应把同一最终命令放入后台、记录 stdout/stderr 并轮询退出码；不要因外层超时杀掉仍在工作的 Rust/C++ 编译。
- 本次有一次 `flutter build windows` 在 `flutter_assemble` 阶段卡死。它在 Rust Release 完成后不再消耗 CPU，也不再写入日志；这需要按下一节保留日志、终止卡死进程和报告，而不是改项目依赖或伪造构建产物。

### Flutter Windows 构建长时间无输出

`py -3 build.py --portable --flutter --skip-portable-pack --hwcodec --vram`
会在最后调用 `flutter build windows --release`。首次 Rust 构建可能耗时较长，因此不要把前台命令的固定超时直接当作编译失败；应保留 stdout/stderr 日志并轮询进程状态。

如果进程树停在 `cmd -> dart -> cmake -> MSBuild`，持续数分钟没有新的日志，且 CMake/MSBuild/Dart 的累计 CPU 时间几乎不增长，则它已卡在 Flutter 的 `tool_backend.bat` / `flutter_assemble` 自定义目标，而不是 RustDesk Rust/C++ 编译。此时停止进程、保留日志并报告；不要通过更换 Flutter、修改 `vcpkg.json`、portfile 或手工复制库来掩盖问题。

构建命令异常退出后，先恢复临时锁文件：

```powershell
git restore flutter/pubspec.lock
git status --short
```

只有同时存在 `rustdesk.exe`、`librustdesk.dll`、`flutter_windows.dll` 和 `data\flutter_assets\fonts\MaterialIcons-Regular.otf` 时，`flutter\build\windows\x64\runner\Release\` 才可作为完整产物交付。文件时间戳只能说明产物何时写入，不能代替构建命令的成功退出码。

曾有一次本机使用 Flutter `3.41.7` 构建成功，但它要求升级 `google_fonts` 等依赖，已与项目 Flutter `3.24.5` 基线冲突，因此不作为本分支的解决方案。若未来决定正式升级 Flutter，必须同时更新 CI、FRB 生成环境、Windows/Linux/macOS 测试与全部构建文档。
