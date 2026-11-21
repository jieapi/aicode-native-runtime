# Consuming the prebuilt `libtawcroot.so`

Two supported shapes. Both end with the binary at
`<module>/src/main/jniLibs/<abi>/libtawcroot.so` (or a sourceSet pointing at a
generated dir) and `useLegacyPackaging = true`.

## 1. Download a pinned release at build time (recommended)

Nothing binary is committed to your app repo; the tag pins the exact bytes.

```kotlin
// app/build.gradle.kts
val tawcrootTag = "tawcroot-a49a407"          // bump deliberately
val tawcrootSha = "acd08d2bb44b760caad3faac1850726e9a59f385e8ee1f6203b160b64bc83560" // sha256 of tawcroot-jniLibs.zip

val tawcrootJniLibs = layout.buildDirectory.dir("tawcroot-jniLibs")

val fetchTawcroot by tasks.registering {
    val tag = tawcrootTag
    val want = tawcrootSha
    val dest = tawcrootJniLibs
    outputs.dir(dest)
    doLast {
        val dir = dest.get().asFile
        dir.deleteRecursively(); dir.mkdirs()
        val zip = File(temporaryDir, "tawcroot-jniLibs.zip")
        val url = "https://github.com/jieapi/tawcroot/releases/download/$tag/tawcroot-jniLibs.zip"
        java.net.URI(url).toURL().openStream().use { i ->
            zip.outputStream().use { o -> i.copyTo(o) }
        }
        val actual = java.security.MessageDigest.getInstance("SHA-256")
            .digest(zip.readBytes()).joinToString("") { "%02x".format(it) }
        check(actual == want) { "tawcroot zip checksum mismatch: $actual" }
        copy { from(zipTree(zip)); into(dir) }
    }
}

android {
    sourceSets.getByName("main").jniLibs.srcDir(tawcrootJniLibs)
    packaging {
        jniLibs {
            // Mandatory: the ELF must exist on disk so it can be exec'd out
            // of nativeLibraryDir. Without this it is mmap'd from the APK.
            useLegacyPackaging = true
        }
    }
}

tasks.named("preBuild") { dependsOn(fetchTawcroot) }
```

Gradle caches task outputs, so this is a one-time download per tag (and it
works offline afterwards). Cache the GitHub release download in CI if the
build is otherwise offline.

## 2. Fetch it once, commit the binaries

If you would rather not download during builds (offline CI, F-Droid, etc.):

```bash
curl -fLO https://github.com/jieapi/tawcroot/releases/download/tawcroot-a49a407/tawcroot-jniLibs.zip
unzip -o tawcroot-jniLibs.zip -d app/src/main/jniLibs   # arm64-v8a/, x86_64/
curl -fLO https://github.com/jieapi/tawcroot/releases/download/tawcroot-a49a407/LICENSE.MIT
```

Then commit `app/src/main/jniLibs/**/libtawcroot.so` plus `LICENSE.MIT`, and
note the tag + sha256 in a README or a `TAWCROOT.md` so the provenance is not
lost.

## Using it at runtime

tawcroot is a program, not a JNI library:

```kotlin
val so = File(applicationInfo.nativeLibraryDir, "libtawcroot.so")
// tawcroot -r ROOTFS [-b SRC:DST]... -- CMD
ProcessBuilder(so.absolutePath, "-r", rootfsDir.absolutePath, "--", "/bin/sh", "-l")
    .redirectErrorStream(true)
    .start()
```

Notes that cost people an afternoon:

- `nativeLibraryDir` is per-ABI and the binary name must stay `lib*.so`.
- The process must be spawned from your app's own uid — no root, no SELinux
  `magiskpolicy` tricks (that is chroot/proot's problem, not tawcroot's).
- `--exec-child <fd>` is tawcroot's internal supervisor re-exec entry; you do
  not call it yourself.
- Upstream documents the CLI and internals under
  [`notes/tawcroot/`](https://github.com/wmww/tawc/tree/main/notes/tawcroot).
- Build (rootfs install, bind list, process cleanup) is yours to write —
  tawcroot only translates syscalls.

## Licensing your app

MIT: keep the copyright and permission notice in "all copies or substantial
portions". Practically: ship `LICENSE.MIT` as an asset and add it to your
in-app licenses screen. No copyleft obligation comes from this binary, and
nothing from upstream's GPLv3 `deps/` is included.