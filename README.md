# build_ffmpeg

Build FFmpeg and ffprobe on Linux, either for the native Linux architecture or
for Windows 11 x64. The project only builds FFmpeg and its dependencies: it does
not configure services, install web servers, modify drivers, or reboot the host.

## Quick start (Ubuntu)

Install the common build tools and native Linux TLS/Vulkan dependencies:

```bash
sudo apt-get update
sudo apt-get install -y build-essential git nasm pkg-config cmake glslc \
  libgnutls28-dev libvulkan1
```

For Windows builds, also install MinGW-w64:

```bash
sudo apt-get install -y gcc-mingw-w64-x86-64-posix \
  g++-mingw-w64-x86-64-posix binutils-mingw-w64-x86-64
```

Run as your normal user:

```bash
./install.sh linux                 # native Linux
./install.sh windows               # Windows x64
./install.sh all --jobs 16          # both, sequentially
./install.sh all --plan            # resolve versions without compiling
./install.sh --help
```

With no arguments, the script displays help. It never installs into `/bin`,
`/usr/local`, or another system location. A GPU is not needed to compile.
The native target uses the host Linux architecture; Windows always targets x64.
Ubuntu x86-64 is the tested host configuration.

## Generated files

Everything generated is outside the Git checkout, under
`$HOME/build/build_ffmpeg` by default:

```text
$HOME/build/build_ffmpeg/
  sources/<project>/<commit>/      # shared source checkouts
  build/<target>-<arch>/<id>/      # objects, dependency prefix, installed output
  output/linux/                   # symlink to last successful native build
  output/windows/                 # symlink to last successful Windows build
  logs/                           # separate log for each invocation
  tmp/                            # temporary compiler/configure files
  tools/                          # optional local host tools
  legacy/                         # preserved files from the original workspace
```

Executables:

```text
$HOME/build/build_ffmpeg/output/linux/bin/ffmpeg
$HOME/build/build_ffmpeg/output/linux/bin/ffprobe
$HOME/build/build_ffmpeg/output/windows/bin/ffmpeg.exe
$HOME/build/build_ffmpeg/output/windows/bin/ffprobe.exe
```

Copy both `.exe` files to Windows. The native binaries use system libraries such
as glibc, GnuTLS, and the Vulkan loader; they are not fully static Linux binaries.
Build them on the Linux system where they will run, or a compatible distribution.

The original Windows executables, logs, and installer backup were preserved in
`legacy/`. Its old CMake caches contain the previous absolute paths; new builds
use fresh trees under `build/`.

Sources and builds are reused by commit and configuration. Upstream branches are
resolved again on each invocation, so new commits receive separate build trees.
Locally edited source checkouts are rejected rather than overwritten. Only after
a build passes validation is its `output/<target>` symlink updated. Old builds
remain available. A lock prevents concurrent writers to the same build root.

## GPU and Whisper support

Both targets include:

- FFmpeg's built-in codecs, formats, filters, and network protocols.
- x264 H.264 encoding and TLS (GnuTLS on Linux, SChannel on Windows).
- NVIDIA NVENC H.264/HEVC/AV1 encoding and NVDEC/CUVID decoding.
- The Whisper audio filter with Vulkan GPU acceleration and a CPU fallback.

For an RTX 5080, install a compatible NVIDIA driver with Vulkan support on the
machine running FFmpeg. NVIDIA header `n13.1.15.0` requires driver **610.0 or
newer** on Windows and Linux. The build log prints the requirements from the
selected headers; future versions may require newer drivers. Compilation does
not upgrade the host driver or CUDA toolkit.

Whisper uses **Vulkan**, not CUDA/cuBLAS. Windows requires the driver-provided
`vulkan-1.dll`; Linux requires `libvulkan.so.1`. FFmpeg, x264, and Whisper are
linked statically, so separate FFmpeg/Whisper or MinGW runtime DLLs are not needed.
A Whisper model is a separate download. See [GPU tests and transcription](docs/usage.md).

The builder does not include ffplay, CUDA NVCC/NPP filters, or optional external
libraries such as x265, libass, SRT, VMAF, and ZeroMQ. This is a focused common
feature set for the two targets, not the old Multiview installer feature set.

## Versions and options

FFmpeg, NVIDIA codec headers, Whisper, and Vulkan SDK source components default
to their latest stable upstream tags. Development and prerelease tags are excluded.
Vulkan uses the newest SDK tag shared by Vulkan-Headers, SPIRV-Headers, and
Vulkan-Loader. x264 uses the current `stable` branch. Git commits are recorded in
`output/<target>/build-info.txt`, alongside the compiler and backend settings.

As checked on 2026-09-18: FFmpeg `n9.0.1`, NVIDIA headers `n13.1.15.0`, Whisper
`v1.9.4`, and Vulkan SDK `vulkan-sdk-1.4.357.0`. These are examples, not fixed defaults.
The compiler, CMake, and `glslc` are host tools supplied by your Linux distribution;
the builder does not automatically replace them. Newer shaders may need a newer
`glslc`; use `GLSLC=/path/to/glslc` to select a compatible host compiler.

```bash
./install.sh linux --whisper cpu --no-nvidia
./install.sh windows --whisper off --jobs 8
./install.sh all --build-root "$HOME/build/custom_ffmpeg"

# Pin releases for repeatable builds, or explicitly select a branch such as master:
FFMPEG_REF=n9.0.1 NV_CODEC_HEADERS_REF=n13.1.15.0 \
WHISPER_REF=v1.9.4 VULKAN_REF=vulkan-sdk-1.4.357.0 \
./install.sh windows
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `--jobs N` / `BUILD_JOBS` | `nproc` | Parallel compiler jobs |
| `--whisper` / `WHISPER_BACKEND` | `vulkan` | `vulkan`, `cpu`, or `off` |
| `--no-nvidia` | NVIDIA enabled | Omit video acceleration; independent of Whisper |
| `--build-root` / `BUILD_ROOT` | `$HOME/build/build_ffmpeg` | Generated files; must be outside the code checkout, without whitespace |
| `FFMPEG_REF` | `latest` | Latest stable release, or explicit branch/tag |
| `NV_CODEC_HEADERS_REF` | `latest` | NVIDIA header branch/tag |
| `WHISPER_REF` | `latest` | Whisper branch/tag |
| `VULKAN_REF` | `latest` | Common Vulkan SDK tag |
| `X264_REF` | `stable` | x264 branch/tag |
| `GLSLC` | `glslc` | Linux shader compiler executable or wrapper |

If `glslc` is not on PATH, the builder also checks
`$BUILD_ROOT/tools/bin/glslc`. The migration of this workspace preserved its local
shader compiler there. The old `WIN_*` settings and arbitrary function dispatch
are replaced by the target argument and options above.

## Validation and development

```bash
bash -n install.sh lib/build.sh tests/test_cli.sh
bash tests/test_cli.sh
```

The tests cover CLI validation, release selection, annotated tags, and both build
plans using local mock Git metadata; they do not download or compile dependencies.
Real builds validate Linux execution or Windows x64 PE format. GPU runtime tests
must be run on the intended GPU; successful compilation alone does not test it.

Build diagnostics are in `logs/`; FFmpeg configure diagnostics remain in each
build tree's `ffmpeg/ffbuild/config.log`. Successful outputs also include config
headers, a copy of that log, source/compiler provenance, and Windows PE import
reports. The project has no cleanup command that deletes user files automatically.

## Upstream references

- [FFmpeg releases](https://ffmpeg.org/download.html) and [Windows cross-compilation](https://ffmpeg.org/platform.html#Cross-compilation-for-Windows-with-Linux)
- [NVIDIA codec headers and driver requirements](https://github.com/FFmpeg/nv-codec-headers)
- [Whisper Vulkan support](https://github.com/ggml-org/whisper.cpp#vulkan-gpu-support)
- [Khronos Vulkan SDK components](https://github.com/KhronosGroup/Vulkan-Headers)

The resulting build enables GPL through x264. Distribution of binaries must
follow the licenses of FFmpeg and its linked dependencies.
