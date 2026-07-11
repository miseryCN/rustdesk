# Windows 构建排障说明

本项目保持 RustDesk 当前跨平台基线：Flutter `3.24.5`、Dart `3.5.x`、项目锁定的依赖和默认 AOM `3.12.1`。不要为了某一台 Windows 机器的本地构建而升级 Flutter/Dart、全局降级 AOM，或提交 Windows 生成的 C FFI bindings；这些做法会影响 Linux、macOS、移动端和 CI。

完整的 Windows、Linux、macOS 构建步骤见 [AI_AGENT_SERVER_PROFILES.md](AI_AGENT_SERVER_PROFILES.md)。

## Windows 常见问题

### 找不到 `libclang.dll`

安装 LLVM，并在当前 PowerShell 设置：

```powershell
winget install LLVM.LLVM
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
```

该变量只影响本机 bindgen；不要因此提交预生成 bindings。

### vcpkg 头文件或库找不到

使用仓库根目录的 manifest 和固定 triplet 安装依赖：

```powershell
$env:VCPKG_ROOT = 'C:\src\vcpkg'
& "$env:VCPKG_ROOT\vcpkg.exe" install `
  --triplet x64-windows-static `
  --x-install-root="$env:VCPKG_ROOT\installed"
```

不要手动把 `x64-windows` 的 FFmpeg 文件复制到 `x64-windows-static`。如果 manifest 安装结果不完整，应检查 vcpkg 的构建日志并修复 manifest/triplet 配置。

### 可复现的构建命令

`flutter build windows` 只负责 Flutter runner；干净仓库还需要先构建 Rust 动态库。使用项目根目录的构建脚本：

```powershell
flutter pub get
py -3 build.py --portable --flutter --skip-portable-pack --hwcodec --vram
```

输出目录为：

```text
flutter\build\windows\x64\runner\Release\
```

## 本地排障记录

曾有一次本机使用 Flutter `3.41.7` 构建成功，但它要求升级 `google_fonts` 等依赖，已与项目 Flutter `3.24.5` 基线冲突，因此不作为本分支的解决方案。若未来决定正式升级 Flutter，必须同时更新 CI、FRB 生成环境、Windows/Linux/macOS 测试与全部构建文档。
