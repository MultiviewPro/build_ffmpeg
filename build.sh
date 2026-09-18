#!/usr/bin/env bash
# build_ffmpeg: native Linux and Windows x64 FFmpeg builds from Linux.
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/build.sh
source "$PROJECT_DIR/lib/build.sh"
# shellcheck source=lib/host-tools.sh
source "$PROJECT_DIR/lib/host-tools.sh"

usage() {
  cat <<'HELP'
Usage: ./build.sh {linux|windows|all|clean} [options]

  linux                  Build for the native Linux architecture
  windows                Cross-compile for Windows x64 with MinGW-w64
  all                    Build both targets, sequentially
  clean                  Remove build trees, sources, outputs, logs and temporary files
  --jobs N               Parallel jobs (default: nproc)
  --whisper BACKEND      vulkan (default), cpu, or off
  --no-nvidia            Omit NVIDIA video acceleration and CUDA NVCC/NPP
  --build-root PATH      All generated files (default: $HOME/build/build_ffmpeg)
  --plan                 Preview a build or cleanup without executing it
  --check-deps           Check installed/cached libraries without building them
  -h, --help             Show this help

Source overrides: FFMPEG_REF, NV_CODEC_HEADERS_REF, WHISPER_REF, VULKAN_REF
(default: latest stable); X264_REF (default: stable branch).
GLSLC selects the Linux shader compiler; CUDA_PATH selects the CUDA toolkit.
Windows dependencies build automatically unless WINDOWS_DEPS_PREFIX is set.
Missing host tools are installed with apt-get (sudo may prompt for a password).
LINUX_DEPS_PREFIX selects additional native libraries.
See README.md for prerequisites and Windows feature exceptions.
HELP
}

main() {
  [[ $# -gt 0 ]] || { usage; return 0; }
  case "$1" in
    -h|--help) usage; return 0 ;;
    linux|windows|all|clean) TARGET="$1"; shift ;;
    *) die "Expected linux, windows, all, or clean; use --help" ;;
  esac
  JOBS="${BUILD_JOBS:-$(nproc)}"
  BUILD_ROOT="${BUILD_ROOT:-$HOME/build/build_ffmpeg}"
  WHISPER_BACKEND="${WHISPER_BACKEND:-vulkan}"
  NVIDIA=1
  PLAN=0
  CHECK_DEPS=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jobs|--whisper|--build-root)
        [[ $# -ge 2 && -n "$2" ]] || die "Missing value for $1"
        case "$1" in
          --jobs) JOBS="$2" ;;
          --whisper) WHISPER_BACKEND="$2" ;;
          --build-root) BUILD_ROOT="$2" ;;
        esac
        shift 2 ;;
      --no-nvidia) NVIDIA=0; shift ;;
      --plan) PLAN=1; shift ;;
      --check-deps) CHECK_DEPS=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
  [[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer'
  case "$WHISPER_BACKEND" in vulkan|cpu|off) ;; *) die '--whisper must be vulkan, cpu, or off' ;; esac
  [[ "$(uname -s)" == Linux ]] || die 'Run this builder on Linux'
  BUILD_ROOT="$(realpath -m -- "$BUILD_ROOT")"
  [[ "$BUILD_ROOT" != *[[:space:]]* ]] || die 'Build paths must not contain whitespace'
  [[ "$BUILD_ROOT" != "$PROJECT_DIR" && "$BUILD_ROOT" != "$PROJECT_DIR/"* ]] || die 'Choose a build root outside the code directory'
  if [[ "$TARGET" == clean ]]; then
    (( CHECK_DEPS == 0 )) || die "--check-deps is not valid with clean"
    clean_build
    return
  fi
  (( PLAN == 0 || CHECK_DEPS == 0 )) || die '--plan and --check-deps cannot be combined'
  local target
  local targets=("$TARGET")
  [[ "$TARGET" != all ]] || targets=(linux windows)
  if (( PLAN == 0 && CHECK_DEPS == 0 )) && [[ -z "${WINDOWS_DEPS_PREFIX:-}" && ( "$TARGET" == windows || "$TARGET" == all ) ]]; then
    install_windows_host_tools
  fi
  # Check host tools for automatic Windows builds, or the supplied target libraries.
  if (( PLAN == 0 )); then
    require_tools pkg-config
    for target in "${targets[@]}"; do preflight_target "$target"; done
    (( CHECK_DEPS == 0 )) || return 0
  fi
  require_tools git gcc make nasm pkg-config flock
  mkdir -p "$BUILD_ROOT/logs" "$BUILD_ROOT/tmp"
  # One lock covers shared sources and output pointers for both targets.
  exec 9> "$BUILD_ROOT/.build.lock"
  flock -n 9 || die "Another build is using $BUILD_ROOT"
  LOG="$BUILD_ROOT/logs/$(date +%Y%m%d-%H%M%S)-$$.log"
  export TMPDIR="$BUILD_ROOT/tmp"
  trap 'printf "Build failed at line %s. Log: %s\n" "$LINENO" "$LOG" >&2' ERR
  resolve_sources
  for target in "${targets[@]}"; do
    build_target "$target"
  done
}

main "$@"
