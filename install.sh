#!/usr/bin/env bash
# build_ffmpeg: native Linux and Windows x64 FFmpeg builds from Linux.
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/build.sh
source "$PROJECT_DIR/lib/build.sh"

usage() {
  cat <<'HELP'
Usage: ./install.sh {linux|windows|all} [options]

  linux                  Build for the native Linux architecture
  windows                Cross-compile for Windows x64 with MinGW-w64
  all                    Build both targets, sequentially
  --jobs N               Parallel jobs (default: nproc)
  --whisper BACKEND      vulkan (default), cpu, or off
  --no-nvidia            Omit NVENC/NVDEC; independent of Whisper
  --build-root PATH      All generated files (default: $HOME/build/build_ffmpeg)
  --plan                 Resolve versions and show configuration without building
  -h, --help             Show this help

Source overrides: FFMPEG_REF, NV_CODEC_HEADERS_REF, WHISPER_REF, VULKAN_REF
(default: latest stable); X264_REF (default: stable branch).
GLSLC selects the Linux shader compiler. See README.md for prerequisites.
HELP
}

main() {
  [[ $# -gt 0 ]] || { usage; return 0; }
  case "$1" in
    -h|--help) usage; return 0 ;;
    linux|windows|all) TARGET="$1"; shift ;;
    *) die "Expected linux, windows, or all; use --help" ;;
  esac
  JOBS="${BUILD_JOBS:-$(nproc)}"
  BUILD_ROOT="${BUILD_ROOT:-$HOME/build/build_ffmpeg}"
  WHISPER_BACKEND="${WHISPER_BACKEND:-vulkan}"
  NVIDIA=1
  PLAN=0
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
  require_tools git gcc make nasm pkg-config flock
  mkdir -p "$BUILD_ROOT/logs" "$BUILD_ROOT/tmp"
  # One lock covers shared sources and output pointers for both targets.
  exec 9> "$BUILD_ROOT/.build.lock"
  flock -n 9 || die "Another build is using $BUILD_ROOT"
  LOG="$BUILD_ROOT/logs/$(date +%Y%m%d-%H%M%S)-$$.log"
  export TMPDIR="$BUILD_ROOT/tmp"
  trap 'printf "Build failed at line %s. Log: %s\n" "$LINENO" "$LOG" >&2' ERR
  resolve_sources
  local target
  local targets=("$TARGET")
  [[ "$TARGET" != all ]] || targets=(linux windows)
  for target in "${targets[@]}"; do
    build_target "$target"
  done
}

main "$@"
