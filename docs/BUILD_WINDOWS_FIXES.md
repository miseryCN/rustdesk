# Windows 构建修复说明

本文档记录了在 Windows 环境下构建 RustDesk 时遇到的问题及解决方案。

## 环境信息

- OS: Windows 11 Pro 26200
- Rust: stable-x86_64-pc-windows-msvc (1.96.0)
- Flutter: 3.41.7
- Visual Studio: 2022 Community (MSVC 14.41.34120)
- LLVM: 22.1.8

## 问题 1: libclang.dll 缺失

**现象**: hwcodec 构建时报错 `Unable to find libclang`

**解决**: 安装 LLVM

```powershell
winget install LLVM.LLVM
```

设置环境变量:
```powershell
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
```

## 问题 2: vcpkg 依赖未完整安装

**现象**: `libavutil/pixfmt.h`, `vpx/vp8.h` 等头文件找不到

**解决**: 使用 manifest 模式安装依赖

```powershell
$env:VCPKG_ROOT = 'C:\src\vcpkg'
& "$env:VCPKG_ROOT\vcpkg.exe" install --x-install-root="$env:VCPKG_ROOT\installed" --triplet x64-windows-static
```

注意: ffmpeg 被安装到 `x64-windows` (host triplet) 而非 `x64-windows-static`，需要手动复制头文件和库文件。

## 问题 3: aom 版本不兼容

**现象**: `aom_codec_dec_cfg`, `aom_codec_enc_cfg` 等结构体只有 `_address` 字段

**根因**: aom 3.12.1 的头文件在 MSVC 下导致 bindgen 生成 opaque struct

**解决**: 修改 `res/vcpkg/aom/portfile.cmake`，强制使用 aom 3.9.1

```cmake
# 删除 if(DEFINED ENV{USE_AOM_391}) 条件判断，直接使用 3.9.1
vcpkg_from_git(
    OUT_SOURCE_PATH SOURCE_PATH
    URL "https://aomedia.googlesource.com/aom"
    REF 8ad484f8a18ed1853c094e7d3a4e023b2a92df28 # 3.9.1
    ...
)
```

## 问题 4: bindgen 在 MSVC 下生成 opaque struct

**现象**: 升级 bindgen 到 0.71 后仍然生成只有 `_address` 字段的结构体

**根因**: bindgen 库版本 (0.71.1) 在 MSVC 环境下解析 aom/vpx/yuv 头文件时生成 opaque struct，但 CLI 版本 (0.72.1) 可以正确生成

**解决**:

1. 升级 scrap 的 bindgen 依赖: `bindgen = "0.65"` -> `bindgen = "0.71"`

2. 使用 bindgen CLI 预生成 bindings 文件到 `libs/scrap/generated/` 目录:

```bash
bindgen libs/scrap/src/bindings/aom_ffi.h \
  --allowlist-type "^(aom|AOM|OBU|AV1).*" \
  --rustified-enum "^(aom|AOM|OBU|AV1).*" \
  --no-layout-tests --no-doc-comments \
  -- -I$VCPKG_ROOT/installed/x64-windows-static/include \
  > libs/scrap/generated/aom_ffi.rs

bindgen libs/scrap/src/bindings/vpx_ffi.h \
  --allowlist-type "^[vV].*" --rustified-enum "^[vV].*" \
  --no-layout-tests --no-doc-comments \
  -- -I$VCPKG_ROOT/installed/x64-windows-static/include \
  > libs/scrap/generated/vpx_ffi.rs

bindgen libs/scrap/src/bindings/yuv_ffi.h \
  --allowlist-type ".*" --rustified-enum ".*" \
  --no-layout-tests --no-doc-comments \
  -- -I$VCPKG_ROOT/installed/x64-windows-static/include \
  > libs/scrap/generated/yuv_ffi.rs
```

3. 修改 `libs/scrap/build.rs`，优先使用预生成的 bindings:

```rust
fn gen_vcpkg_package(package: &str, ffi_header: &str, generated: &str, regex: &str) {
    ...
    let exact_file = src_dir.join("generated").join(generated);

    // Use pre-generated bindings if available (for MSVC compatibility)
    if exact_file.exists() {
        fs::copy(&exact_file, &ffi_rs).unwrap();
    } else {
        generate_bindings(&ffi_header, &includes, &ffi_rs, &exact_file, regex);
    }
}
```

## 问题 5: Flutter 3.41.7 Breaking Changes

**现象**:
- `DialogTheme` 类型不匹配
- `TabBarTheme` 类型不匹配
- `extended_text` 14.0.0 缺少方法实现
- `google_fonts` 6.2.1 常量求值错误

**解决**:

1. 修改 `flutter/lib/common.dart`:
   - `DialogTheme(` -> `DialogThemeData(`
   - `TabBarTheme(` -> `TabBarThemeData(`

2. 修改 `flutter/pubspec.yaml`:
   - `extended_text: 14.0.0` -> `extended_text: 15.0.2`
   - `google_fonts: ^6.2.1` -> `google_fonts: ^6.3.3`

## 修改文件清单

| 文件 | 改动说明 |
|------|----------|
| `res/vcpkg/aom/portfile.cmake` | 强制使用 aom 3.9.1 |
| `libs/scrap/Cargo.toml` | bindgen 0.65 -> 0.71 |
| `libs/scrap/build.rs` | 优先使用预生成的 bindings |
| `libs/scrap/generated/*.rs` | 新增预生成的 FFI bindings |
| `flutter/lib/common.dart` | DialogTheme/TabBarTheme 类型修复 |
| `flutter/pubspec.yaml` | 更新 extended_text, google_fonts 版本 |
| `flutter/pubspec.lock` | 依赖锁文件更新 |
| `Cargo.lock` | 依赖锁文件更新 |

## 构建命令

```powershell
# 设置环境变量
$env:LIBCLANG_PATH = 'C:\Program Files\LLVM\bin'
$env:VCPKG_ROOT = 'C:\src\vcpkg'

# 构建 Flutter Windows 应用
cd flutter
flutter build windows --release
```

输出路径: `flutter/build/windows/x64/runner/Release/`
