#!/usr/bin/env bash
set -Eeuo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
source "$project/lib/build.sh"
PROJECT_DIR="$project"
BUILD_ROOT="$scratch/root"
LOG="$scratch/run.log"
JOBS=2
# Stub expensive commands only; exercise real orchestration and cache handling.
windows_dependency_tools() { :; }
fetch_dependency() { mkdir -p "$4"; }
run() { printf '%s\n' "$*" >> "$scratch/commands"; }
build_windows_extra() {
  printf '%s\n' "$1" >> "$scratch/recipes"
  mkdir -p "$dep_prefix/lib/pkgconfig"
}
build_windows_dependencies
[[ "$(wc -l < "$scratch/recipes")" == "${#WINDOWS_EXTRA_NAMES[@]}" ]]
dep_cache="$(windows_dependency_root)"
[[ "$dep_cache" == "$BUILD_ROOT/build/windows-deps/852ea558f59f195b" ]]
grep -q 'libssh_FILE=libssh-0.12.2.tar.xz' "$scratch/commands"
grep -q 'libssh_URL=https://www.libssh.org/files/0.12/libssh-0.12.2.tar.xz' "$scratch/commands"
grep -q 'libssh_CHECKSUM=49560f677d96e3706a904ac2de1116e25f3680937d51e5c92198fcba4a1c1e9f' "$scratch/commands"
[[ -f "$dep_cache/mxe/usr/$MXE_TARGET/dependency-build-info.txt" ]]
grep -q 'MXE_TARGETS=x86_64-w64-mingw32.static' "$scratch/commands"
grep -q 'JOBS=2' "$scratch/commands"
build_windows_dependencies
[[ "$(wc -l < "$scratch/recipes")" == "${#WINDOWS_EXTRA_NAMES[@]}" ]]
# A failed library must be retried; no success marker or manifest may be written.
BUILD_ROOT="$scratch/failed"
build_windows_extra() { return 23; }
set +e
(set -e; build_windows_dependencies) > "$scratch/failure.log" 2>&1
result=$?
set -e
[[ "$result" == 23 ]]
failed_cache="$(windows_dependency_root)"
[[ ! -e "$failed_cache/stamps/aom" ]]
[[ ! -e "$failed_cache/mxe/usr/$MXE_TARGET/dependency-build-info.txt" ]]
# Automatic mode checks host tools, not unbuilt target libraries.
CHECK_DEPS=0
unset WINDOWS_DEPS_PREFIX
check_external_dependencies() { echo 'unexpected external preflight' >&2; return 99; }
preflight_target windows > "$scratch/preflight"
grep -q 'built automatically' "$scratch/preflight"
# Cleanup includes the automatic cache because it lives within build/.
touch "$BUILD_ROOT/.build.lock"
PLAN=0
clean_build > "$scratch/clean"
[[ ! -e "$failed_cache" ]]
printf 'PASS: automatic Windows bootstrap, resume cache, failed-step retry, preflight and cleanup\n'
# The FFmpeg build must adopt MXE's compiler, dependency paths and provenance.
(
  BUILD_ROOT="$scratch/integration"
  LOG="$scratch/integration.log"
  PLAN=0 NVIDIA=0 WHISPER_BACKEND=off JOBS=1
  SOURCES=()
  declare -A SOURCE=([x264]="$scratch/source/x264" [FFmpeg]="$scratch/source/FFmpeg")
  require_tools() { :; }
  checkout_sources() { :; }
  check_external_dependencies() { :; }
  build_windows_dependencies() {
    local cache
    cache="$(windows_dependency_root)/mxe/usr"
    mkdir -p "$cache/bin" "$cache/$MXE_TARGET"
    printf 'MXE: test\n' > "$cache/$MXE_TARGET/dependency-build-info.txt"
    printf '#!/bin/sh\nprintf "test compiler\\n"\n' > "$cache/bin/$MXE_TARGET-gcc"
    printf '#!/bin/sh\nprintf "file format pei-x86-64\\n"\n' > "$cache/bin/$MXE_TARGET-objdump"
    chmod +x "$cache/bin/"*
  }
  run() {
    if [[ "$1" == "${SOURCE[FFmpeg]}/configure" ]]; then
      [[ "$cc" == "$MXE_TARGET-gcc" ]]
      [[ "$PKG_CONFIG_LIBDIR" == *"$deps/lib/pkgconfig"* && -z "$PKG_CONFIG_PATH" ]]
      [[ "$LDFLAGS" == *"-L$deps/lib"* ]]
      printf '%s\n' "$@" > "$scratch/windows-configure"
      local flag
      : > config.h
      for flag in "${FEATURE_FLAGS[@]}"; do
        [[ "$flag" == --enable-* ]] || continue
        flag="${flag#--enable-}"; flag="${flag//-/_}"
        printf '#define CONFIG_%s 1\n' "${flag^^}" >> config.h
      done
      touch config_components.h
    elif [[ "$1" == make && "${2:-}" == DESTDIR=* ]]; then
      mkdir -p "$root/stage/ffmpeg/bin"
      touch "$root/stage/ffmpeg/bin/"{ffmpeg,ffprobe,ffplay}.exe
    fi
  }
  build_target windows
  grep -qx -- "--cross-prefix=$MXE_TARGET-" "$scratch/windows-configure"
  grep -qx -- '--prefix=/ffmpeg' "$scratch/windows-configure"
  [[ -f "$BUILD_ROOT/output/windows/bin/ffplay.exe" ]]
  grep -qx 'MXE: test' "$BUILD_ROOT/output/windows/dependency-build-info.txt"
)
printf 'PASS: managed compiler selection, isolated target search paths and Windows publication\n'
