# build_ffmpeg

Build FFmpeg, ffprobe and ffplay on Linux, either for the native Linux architecture or
for Windows 11 x64. The project only builds FFmpeg and its dependencies: it does
not configure services, install web servers, modify drivers, or reboot the host.

## Quick start (Ubuntu)

`./build.sh windows` automatically installs missing Linux host build tools on
Debian/Ubuntu using `apt-get`. Run as your normal user; `sudo` may ask for your
password. Only missing tools trigger package installation. `--plan`,
`--check-deps`, and `clean` never install packages. An explicit
`WINDOWS_DEPS_PREFIX` keeps host setup manual.

For manual setup, or to prepare a machine in advance:

```bash
sudo apt-get update
sudo apt-get install -y build-essential git nasm pkg-config cmake glslc \
  meson ninja-build autoconf automake autopoint libtool libtool-bin gettext \
  bison flex gperf intltool lzip python3-mako python3 python-is-python3 \
  ruby perl wget curl unzip p7zip-full libgdk-pixbuf2.0-bin patch bzip2 xz-utils
```

`./build.sh windows` then builds its own MinGW-w64 toolchain and Windows libraries
under the build root. No Windows development libraries need to be installed
system-wide. The first run requires substantial time and disk space; later runs
reuse completed dependency builds. Run without `sudo`.

For native Linux builds, also install the target development libraries:

```bash
sudo apt-get install -y libvulkan1 libsdl2-dev libaom-dev libass-dev libfdk-aac-dev \
  libfreetype-dev libfontconfig-dev libfribidi-dev libharfbuzz-dev libcaca-dev \
  frei0r-plugins-dev libgmp-dev libmp3lame-dev libopus-dev libvorbis-dev \
  libvpx-dev libx265-dev libsrt-openssl-dev libzvbi-dev libzmq3-dev \
  libssh-dev libopenal-dev ocl-icd-opencl-dev libgl-dev libdrm-dev \
  libssl-dev libsmbclient-dev
```

Run as your normal user:

```bash
./build.sh linux                 # native Linux
./build.sh windows               # Windows x64
./build.sh all --jobs 16          # both, sequentially
./build.sh all --plan            # resolve versions without compiling
./build.sh --help
```

With no arguments, the script displays help. FFmpeg and its built libraries stay
under the build root. The prerequisite step
installs distribution packages system-wide through apt; it does not install
FFmpeg system-wide. A GPU is not needed to compile.
The native target uses the host Linux architecture; Windows always targets x64.
Ubuntu x86-64 is the tested host configuration.

## Generated files

Everything generated is outside the Git checkout, under
`$HOME/build/build_ffmpeg` by default:

```text
$HOME/build/build_ffmpeg/
  sources/<project>/<commit>/      # shared source checkouts
  build/<target>-<arch>/<id>/       # objects, dependency prefix, installed output
  build/windows-deps/<id>/          # automatic MXE toolchain and library cache
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
$HOME/build/build_ffmpeg/output/linux/bin/ffplay
$HOME/build/build_ffmpeg/output/windows/bin/ffmpeg.exe
$HOME/build/build_ffmpeg/output/windows/bin/ffprobe.exe
$HOME/build/build_ffmpeg/output/windows/bin/ffplay.exe
```

Copy all three `.exe` files and any required dependency DLLs to Windows. The
native binaries use system libraries such as glibc, OpenSSL, and the Vulkan loader; they are not fully static Linux binaries.
Build them on the Linux system where they will run, or a compatible distribution.

The original Windows executables, logs, and installer backup were preserved in
`legacy/`. Its old CMake caches contain the previous absolute paths; new builds
use fresh trees under `build/`.

Sources and builds are reused by commit and configuration. Upstream branches are
resolved again on each invocation, so new commits receive separate build trees.
Locally edited source checkouts are rejected rather than overwritten. Only after
a build passes validation is its `output/<target>` symlink updated. Old builds
remain available. A lock prevents concurrent writers to the same build root.

## Build progress and logs

The default job count is `nproc`: the number of logical CPUs available to the
process. Override it with `--jobs N` or `BUILD_JOBS=N`; the command-line option
takes precedence. MXE builds one dependency package at a time, with up to that
many compilation jobs inside each package. This does not reserve CPU cores.

The first Windows run also builds the cross compiler and transitive dependencies,
so it takes longer than subsequent runs. `[download]`, `[build]`, and `[done]`
lines show progress. A quiet main log can mean the current package is still
compiling; inspect its MXE log for more detail. If memory pressure causes swapping,
use fewer jobs on the next invocation.

The terminal prints the main log path. With the default build root:

```bash
# Show the latest build's last 30 lines.
tail -n 30 "$(ls -t "$HOME/build/build_ffmpeg/logs/"*.log | head -1)"

# Follow new output from that build.
tail -f "$(ls -t "$HOME/build/build_ffmpeg/logs/"*.log | head -1)"
```

| Log | Location under the build root |
| --- | --- |
| Main build | `logs/<timestamp>-<pid>.log` |
| MXE package details | `build/windows-deps/<id>/mxe/log/` |
| FFmpeg configure checks | `build/<target>-<arch>/<id>/ffmpeg/ffbuild/config.log` |

Host package installation runs before the main log is created; apt/sudo output
appears directly in the terminal. For a custom `--build-root`, use that path in
the commands above. Rerun the same build command after a failure to reuse completed
dependencies. Do not run `clean` if you want to retain the cache.

## Cleanup

```bash
./build.sh clean --plan        # preview
./build.sh clean               # remove generated build data for BOTH targets
./build.sh clean --build-root "$HOME/build/custom_ffmpeg"
```

Cleanup removes `build/` (including dependency prefixes and staged binaries),
`sources/`, `output/`, `logs/`, and `tmp/` under the selected build root.
It preserves `tools/`, `models/`, `legacy/`, other user files, and `.build.lock`.
External dependency prefixes are unaffected unless placed inside a removed tree.
It needs no network or compiler, refuses an active build, and does not follow
symlinks inside the removed directories. An existing root must have the builder's
regular `.build.lock` file; arbitrary directories are rejected. The command is
idempotent. Rebuilding afterwards downloads sources and compiles from scratch.

## GPU and Whisper support

Both targets include:

- FFmpeg's built-in codecs, formats, filters, and network protocols.
- External codecs and filters, OpenSSL TLS, and SDL2 ffplay.
- NVIDIA NVENC H.264/HEVC/AV1 encoding and NVDEC/CUVID decoding.
- The Whisper audio filter with Vulkan GPU acceleration and a CPU fallback.

For an RTX 5080, install a compatible NVIDIA driver with Vulkan support on the
machine running FFmpeg. NVIDIA header `n13.1.15.0` requires driver **610.0 or
newer** on Windows and Linux. The build log prints the requirements from the
selected headers; future versions may require newer drivers. Compilation does
not upgrade the host driver or CUDA toolkit.

Whisper uses **Vulkan**, not CUDA/cuBLAS. Windows requires the driver-provided
`vulkan-1.dll`; Linux requires `libvulkan.so.1`. FFmpeg, x264, and Whisper are
linked statically. Additional external libraries may require runtime DLLs or
shared libraries; inspect Windows PE import reports before copying the output.
A Whisper model is a separate download. See [GPU tests and transcription](docs/usage.md).

## External libraries and platform limits

The common configuration enables aom, ass, fdk-aac, freetype, fontconfig,
fribidi, harfbuzz, caca, frei0r, GMP, mp3lame, opus, vorbis, vpx, x264,
x265, SRT, SVT-JPEG-XS, zvbi, zmq, ssh, OpenAL, OpenCL, OpenGL, OpenSSL,
VMAF, swresample and SDL2/ffplay, plus GPL, nonfree and version3.
Whisper remains enabled by default, with the existing CPU/off overrides.
Missing dependencies cause a build failure; features are not silently dropped.

For native Linux, the builder compiles x264 and Whisper itself. Install the other
development libraries first. SVT-JPEG-XS (pkg-config `SvtJpegxs >= 0.10.0`) and VMAF
may need separate installation if your distribution does not package them.
Package availability, especially FDK AAC, depends on enabled repositories.
Set `LINUX_DEPS_PREFIX=/absolute/prefix` for additional native libraries.

Linux also enables libdrm, libsmbclient, CUDA NVCC and NPP. Install the CUDA
toolkit including NPP headers/libraries; `CUDA_PATH` defaults to
`/usr/local/cuda` and supplies its `bin`, `include` and `lib64` directories.
`--no-nvidia` disables both NVIDIA video acceleration and NVCC/NPP.

Windows dependencies are built automatically using a pinned revision of
[MXE](https://mxe.cc/) for the compiler and common static libraries, plus pinned
source recipes for AOM, SRT, SVT-JPEG-XS, ZVBI, ZeroMQ, VMAF and OpenCL.
The frei0r API header is installed; effect DLLs are runtime plugins and must be
supplied separately. OpenGL comes from the MinGW Windows SDK/import libraries.
All required common features remain enabled. Whisper and x264 use the same
compiler as the dependency bundle.

MXE verifies its downloaded source archives against its recipe checksums.
Supplementary repositories and MXE itself are fixed to exact Git commits in
`lib/windows-deps.sh`. The libssh recipe uses its official versioned release
archive with a pinned SHA-256, avoiding the mutable Git snapshot archive.
The explicit cache compatibility revision preserves completed libraries across
download-only fixes; compiler, library version, ABI or build-option changes must
bump that revision. Successful
library installs are stamped; failed ones retry on the next invocation.
`--jobs` controls compilation parallelism; dependency packages build sequentially.
Source revisions are recorded in `dependency-build-info.txt` beside the binaries.
MXE's detailed per-package logs remain under the automatic cache's `mxe/log/`.

```bash
./build.sh windows                 # download/build dependencies, then FFmpeg
./build.sh windows --check-deps     # inspect the existing cache, without building
./build.sh clean                    # also removes the automatic dependency cache
```

An explicitly set `WINDOWS_DEPS_PREFIX=/absolute/prefix` opts out of automatic
building. It must already contain Windows x64 headers, libraries and pkg-config
metadata in `include`, `lib` (or `lib64`), and `share/pkgconfig`. This advanced
mode uses the distribution's `gcc-mingw-w64-x86-64-posix`,
`g++-mingw-w64-x86-64-posix` and `binutils-mingw-w64-x86-64` packages. A missing
external dependency fails before downloads; the supplied prefix is never modified.

The Windows build omits libdrm, libsmbclient and CUDA NVCC/NPP:
DRM is Linux-specific, Samba's client library is not provided for this target,
and this Linux-hosted toolchain does not compile/link the Windows CUDA toolkit.
NVENC/NVDEC/CUVID remain enabled. These exceptions are printed by `--plan`.

## Paths in binaries

FFmpeg now reports `--prefix=/ffmpeg` in `-version`/`-buildconf`. Installation
uses `DESTDIR` staging, so it still writes only under the chosen build root.
Include/link paths are passed through the environment rather than embedded
configure arguments. GCC source paths for this builder's compiled sources are
mapped to `/build` and `/src` (and an external dependency prefix to `/deps`).
This reduces host path exposure; prebuilt third-party libraries can still
contain their own paths. Local build/configure logs retain real paths for
troubleshooting and are no longer copied into the output bundle.

## Versions and options

FFmpeg, NVIDIA codec headers, Whisper, and Vulkan SDK source components default
to their latest stable upstream tags. Development and prerelease tags are excluded.
Vulkan uses the newest SDK tag shared by Vulkan-Headers, SPIRV-Headers, and
Vulkan-Loader. x264 uses the current `stable` branch. Git commits are recorded in
`output/<target>/build-info.txt`, alongside the compiler and backend settings.

As checked on 2026-09-18: FFmpeg `n9.0.1`, NVIDIA headers `n13.1.15.0`, Whisper
`v1.9.4`, and Vulkan SDK `vulkan-sdk-1.4.357.0`. These are examples, not fixed defaults.
Native compilers, CMake, and `glslc` are host tools supplied by your Linux
distribution; automatic Windows builds use the separate MXE cross compiler.
Newer shaders may need a newer `glslc`; use `GLSLC=/path/to/glslc` to select a compatible host compiler.

```bash
./build.sh linux --whisper cpu --no-nvidia
./build.sh windows --whisper off --jobs 8
./build.sh all --build-root "$HOME/build/custom_ffmpeg"

# Pin releases for repeatable builds, or explicitly select a branch such as master:
FFMPEG_REF=n9.0.1 NV_CODEC_HEADERS_REF=n13.1.15.0 \
WHISPER_REF=v1.9.4 VULKAN_REF=vulkan-sdk-1.4.357.0 \
./build.sh windows
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `--jobs N` / `BUILD_JOBS` | `nproc` | Parallel compiler jobs |
| `--whisper` / `WHISPER_BACKEND` | `vulkan` | `vulkan`, `cpu`, or `off` |
| `--no-nvidia` | NVIDIA enabled | Omit NVENC/NVDEC/CUVID and CUDA NVCC/NPP; independent of Whisper |
| `--build-root` / `BUILD_ROOT` | `$HOME/build/build_ffmpeg` | Generated files; must be outside the code checkout, without whitespace |
| `FFMPEG_REF` | `latest` | Latest stable release, or explicit branch/tag |
| `NV_CODEC_HEADERS_REF` | `latest` | NVIDIA header branch/tag |
| `WHISPER_REF` | `latest` | Whisper branch/tag |
| `VULKAN_REF` | `latest` | Common Vulkan SDK tag |
| `X264_REF` | `stable` | x264 branch/tag |
| `GLSLC` | `glslc` | Linux shader compiler executable or wrapper |
| `CUDA_PATH` | `/usr/local/cuda` | Native Linux CUDA toolkit root, including NPP |
| `LINUX_DEPS_PREFIX` | unset | Additional native headers, libraries and pkg-config metadata |
| `WINDOWS_DEPS_PREFIX` | automatic build | Use an existing Windows dependency prefix and manual host setup |
| `--check-deps` | off | Check existing target library metadata without building or installing |
| `--plan` | off | Preview build configuration or cleanup; build plans query upstream versions |

If `glslc` is not on PATH, the builder also checks
`$BUILD_ROOT/tools/bin/glslc`. The migration of this workspace preserved its local
shader compiler there. The old `WIN_*` settings and arbitrary function dispatch
are replaced by the target argument and options above.

## Validation and development

```bash
bash -n build.sh lib/*.sh tests/*.sh
bash tests/test_cli.sh
bash tests/test_windows_deps.sh
bash tests/test_host_tools.sh
```

The tests cover CLI validation, release selection, annotated tags, and both build
plans using local mock Git metadata, plus mocked ffplay installation and path
privacy checks. Windows bootstrap tests check caching, failed-step retry and
cleanup. Host-tool installation tests mock apt/sudo; the tests do not install
system packages, download sources, or compile dependencies.

Validation so far includes real MinGW cross-builds and static-link checks for AOM,
SRT/OpenSSL, SVT-JPEG-XS, VMAF, OpenCL, ZVBI and ZeroMQ, plus FFmpeg configure
checks with the supplementary libraries enabled together. A complete build of
the full MXE dependency set and final FFmpeg/ffplay binaries is not yet verified.
Real builds validate Linux execution or Windows x64 PE format. GPU runtime tests
must be run on the intended GPU; successful compilation alone does not test it.

Build diagnostics are in `logs/`; FFmpeg configure diagnostics remain in each
build tree's `ffmpeg/ffbuild/config.log`. Successful outputs also include config
headers, source/compiler provenance, and Windows PE import
reports. Cleanup is explicit through `./build.sh clean`; normal builds retain old outputs.

## Upstream references

- [FFmpeg releases](https://ffmpeg.org/download.html) and [Windows cross-compilation](https://ffmpeg.org/platform.html#Cross-compilation-for-Windows-with-Linux)
- [NVIDIA codec headers and driver requirements](https://github.com/FFmpeg/nv-codec-headers)
- [Whisper Vulkan support](https://github.com/ggml-org/whisper.cpp#vulkan-gpu-support)
- [Khronos Vulkan SDK components](https://github.com/KhronosGroup/Vulkan-Headers)

The requested `--enable-nonfree` combination makes the resulting FFmpeg build
non-redistributable. Use it privately; it is not a distributable GPL build.
