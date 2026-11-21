# Android native runtime builder

本仓库构建 AiCode 使用的 Android 原生运行时，不提交任何生成的 `.so`。

## 组件

| 组件 | 来源 | 产物 | 加载方式 |
|---|---|---|---|
| tawcroot | `wmww/tawc` | `libtawcroot.so` | `ProcessBuilder` 执行 |
| PRoot | `termux/proot` | `libproot.so`、`libproot-loader.so`、`libproot-loader32.so` | `ProcessBuilder` 执行 |
| Termux JNI | `termux/termux-app` | `libtermux.so` | `System.loadLibrary("termux")` |
| talloc | Samba talloc | 静态链接进 PRoot | PRoot 内部 |
| libandroid-shmem | `termux/libandroid-shmem` | 静态链接进 PRoot | PRoot 内部 |

所有上游 commit、版本、SHA256 和 NDK 版本固定在 [`PINS`](PINS)。

## 构建

构建机需要 Linux x86_64、JDK 17 以外的基础 shell 工具、`curl`、`git`、`make`、`python3`、`unzip` 和两个 Android NDK：

- tawcroot：NDK r27c `27.2.12479018`
- PRoot / Termux JNI：NDK r28c `28.2.13676358`

```bash
export ANDROID_NDK_TAWC="$HOME/Android/Sdk/ndk/27.2.12479018"
export ANDROID_NDK_NATIVE="$HOME/Android/Sdk/ndk/28.2.13676358"
./build-all.sh
```

默认输出到 `dist/native-runtime/`：

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

`jniLibs` 中的 PRoot/tawcroot 可执行文件使用 `lib*.so` 命名，是为了让 Android 安装器把它们解压到 `nativeLibraryDir`。它们不是 JNI 库，不能调用 `System.loadLibrary()`。

## 校验

构建过程会对最终输出检查：

- `arm64-v8a` / `x86_64` 每个 `PT_LOAD` 至少按 `0x4000` 对齐；
- PRoot/tawcroot 不含 `PT_INTERP`；
- 所有 ELF 不含可执行栈；
- 所有最终文件生成 SHA256 清单。

App 仍必须使用：

```kotlin
android {
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}
```

## 许可证

发布产物必须同时携带 `LICENSE.*` 文件。PRoot、talloc、libandroid-shmem、Termux 和 tawcroot 的许可证分别以各自上游源码和本仓库构建时复制的许可证文件为准。
