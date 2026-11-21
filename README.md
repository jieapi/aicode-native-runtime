# AiCode native runtime

AiCode Android 原生运行时的可复现构建仓库。

本仓库不提交生成的 `.so` 文件，而是固定上游源码、构建工具链和校验规则，统一生成 Android `jniLibs` 产物。

## 构建内容

| 组件 | 上游来源 | 产物 | 运行方式 |
|---|---|---|---|
| tawcroot | [wmww/tawc](https://github.com/wmww/tawc) | `libtawcroot.so` | `ProcessBuilder` 执行 |
| PRoot | [termux/proot](https://github.com/termux/proot) | `libproot.so`、`libproot-loader.so`、`libproot-loader32.so` | `ProcessBuilder` 执行 |
| Termux JNI | [termux/termux-app](https://github.com/termux/termux-app) | `libtermux.so` | `System.loadLibrary("termux")` |
| talloc | Samba talloc | 静态链接进 PRoot | PRoot 内部 |
| libandroid-shmem | [termux/libandroid-shmem](https://github.com/termux/libandroid-shmem) | 静态链接进 PRoot | PRoot 内部 |

所有源码 commit、版本、SHA256 和 NDK 版本固定在 [`PINS`](PINS)。

## 构建环境

当前构建目标是 Linux x86_64 主机。需要 Bash、Git、Make、Python 3、curl、unzip，以及两个 Android NDK：

- tawcroot：NDK r27c `27.2.12479018`
- PRoot / Termux JNI：NDK r28c `28.2.13676358`

```bash
export ANDROID_NDK_TAWC="$HOME/Android/Sdk/ndk/27.2.12479018"
export ANDROID_NDK_NATIVE="$HOME/Android/Sdk/ndk/28.2.13676358"
./build-all.sh
```

GitHub Actions 会自动安装固定 NDK 并执行同一套构建流程，见 [`.github/workflows/build-native.yml`](.github/workflows/build-native.yml)。

## 输出

```text
dist/native-runtime/
├── jniLibs/
│   ├── arm64-v8a/
│   └── x86_64/
├── native-runtime-jniLibs.zip
├── SHA256SUMS
├── BUILD-INFO.txt
├── PINS
└── LICENSE.*
```

`native-runtime-jniLibs.zip` 可以直接解压到 Android 模块的 `src/main/jniLibs/`。

## Android 接入要求

由于 PRoot 和 tawcroot 是需要直接执行的 ELF 文件，它们使用 `lib*.so` 文件名让 Android 将其解压到 `nativeLibraryDir`。它们不是 JNI 库，不能调用 `System.loadLibrary()`。

```kotlin
android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}
```

应用运行时：

```kotlin
val proot = File(applicationInfo.nativeLibraryDir, "libproot.so")
val tawcroot = File(applicationInfo.nativeLibraryDir, "libtawcroot.so")
```

`libtermux.so` 是真正的 JNI 共享库，由终端模块通过 `System.loadLibrary("termux")` 加载。

## 16 KB 页面兼容

最终构建会对所有 `arm64-v8a` 和 `x86_64` ELF 执行检查：

- 每个 `PT_LOAD` 至少按 `0x4000` 对齐；
- 不包含可执行栈；
- PRoot/tawcroot 执行文件不包含 `PT_INTERP`；
- 生成最终文件的 SHA256 清单。

Termux JNI 使用 16 KB 链接参数重新构建，避免继续使用历史来源不明的 4 KB 预编译库。

## 许可证

发布产物必须同时携带构建生成的 `LICENSE.*` 文件。各组件许可证以对应上游源码和发布目录中的许可证文件为准。
