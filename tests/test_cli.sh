#!/usr/bin/env bash
set -euo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export BUILD_ROOT="$scratch/build"
# Tests must never install real system packages, including on a gate regression.
mkdir -p "$scratch/bin"
for installer in apt-get sudo; do
  printf '#!/bin/sh\necho "Unexpected package installation" >&2\nexit 99\n' > "$scratch/bin/$installer"
  chmod +x "$scratch/bin/$installer"
done
export PATH="$scratch/bin:$PATH"
"$project/build.sh" --help > "$scratch/help"
grep -q 'linux|windows|all' "$scratch/help"
"$project/build.sh" > "$scratch/no-args"
cmp "$scratch/help" "$scratch/no-args"
reject() {
  local expected="$1"; shift
  if "$project/build.sh" "$@" > "$scratch/out" 2>&1; then echo "Unexpected success: $*" >&2; exit 1; fi
  grep -q -- "$expected" "$scratch/out"
}
reject 'Expected linux' invalid
reject 'positive integer' linux --jobs 0
reject 'Missing value' windows --jobs
reject 'must be vulkan' linux --whisper cuda
reject 'outside the code' linux --build-root "$project/build"
reject 'without whitespace\|must not contain whitespace' linux --build-root "$scratch/with space"
# Deterministic branch/tag metadata tests; no network or compilation.
mkdir -p "$scratch/bin"
cat > "$scratch/bin/git" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == ls-remote ]] || exit 99
printf '%040d\trefs/heads/stable\n' 1
printf '%040d\trefs/tags/n9.0\n' 2
printf '%040d\trefs/tags/n9.0.1\n' 3
printf '%040d\trefs/tags/n9.0.1^{}\n' 4
printf '%040d\trefs/tags/n10.0-dev\n' 5
printf '%040d\trefs/tags/v1.9.4\n' 6
printf '%040d\trefs/tags/v2.0.0-rc1\n' 7
printf '%040d\trefs/tags/vulkan-sdk-1.4.357.0\n' 8
if [[ "$4" == *Vulkan-Headers* ]]; then printf '%040d\trefs/tags/vulkan-sdk-1.4.999.0\n' 9; fi
MOCK
chmod +x "$scratch/bin/git"
PATH="$scratch/bin:$PATH" "$project/build.sh" all --plan > "$scratch/plan"
grep -q 'FFmpeg: n9.0.1 (0000000000000000000000000000000000000004)' "$scratch/plan"
grep -q 'whisper.cpp: v1.9.4' "$scratch/plan"
grep -q 'Vulkan-Headers: vulkan-sdk-1.4.357.0' "$scratch/plan"
grep -q 'Plan: linux/' "$scratch/plan"
grep -q 'Plan: windows/x86_64' "$scratch/plan"
[[ ! -d "$BUILD_ROOT/sources" && ! -d "$BUILD_ROOT/build" ]]
PATH="$scratch/bin:$PATH" "$project/build.sh" linux --whisper off --no-nvidia --plan > "$scratch/minimal"
if grep -q 'Checking upstream: whisper.cpp\|Checking upstream: nv-codec-headers\|Checking upstream: Vulkan' "$scratch/minimal"; then exit 1; fi
printf 'PASS: CLI validation, no-argument help, stable tags, annotated tags, matching SDK tags, both target plans, optional dependencies\n'
# Exercise installation and publication with mocked compilers/build commands.
# Catch host paths in configure arguments and DESTDIR/output regressions.
(
  source "$project/lib/build.sh"
  PROJECT_DIR="$project"
  BUILD_ROOT="$scratch/private-host/build"
  LOG="$scratch/build.log"
  PLAN=0 NVIDIA=0 WHISPER_BACKEND=off JOBS=1
  SOURCES=()
  declare -A SOURCE=([x264]="$scratch/source/x264" [FFmpeg]="$scratch/source/FFmpeg")
  require_tools() { :; }
  checkout_sources() { :; }
  check_external_dependencies() { :; }
  run() {
    if [[ "$1" == "${SOURCE[FFmpeg]}/configure" ]]; then
      printf '%s\n' "$@" > "$scratch/configure-args"
      [[ "$CFLAGS" == *"-ffile-prefix-map=$BUILD_ROOT=/build"* ]]
      [[ "$LDFLAGS" == *"-L$prefix/lib"* ]]
      local flag
      : > config.h
      for flag in "${FEATURE_FLAGS[@]}"; do
        [[ "$flag" == --enable-* ]] || continue
        flag="${flag#--enable-}"; flag="${flag//-/_}"
        printf '#define CONFIG_%s 1\n' "${flag^^}" >> config.h
      done
      touch config_components.h
    elif [[ "$1" == make && "${2:-}" == DESTDIR=* ]]; then
      [[ "$2" == "DESTDIR=$root/stage" ]]
      mkdir -p "$root/stage/ffmpeg/bin"
      local binary
      for binary in ffmpeg ffprobe ffplay; do
        printf '#!/bin/sh\nexit 0\n' > "$root/stage/ffmpeg/bin/$binary"
        chmod +x "$root/stage/ffmpeg/bin/$binary"
      done
    fi
  }
  build_target linux
  grep -qx -- '--prefix=/ffmpeg' "$scratch/configure-args"
  grep -qx -- '--enable-ffplay' "$scratch/configure-args"
  if grep -F -- "$BUILD_ROOT" "$scratch/configure-args"; then exit 1; fi
  [[ -x "$BUILD_ROOT/output/linux/bin/ffplay" ]]
  [[ ! -f "$BUILD_ROOT/output/linux/config.log" ]]
)
grep -q -- '--enable-libsvtjpegxs' "$scratch/plan"
grep -q -- '--enable-libnpp' "$scratch/plan"
grep -q 'Windows exceptions:' "$scratch/plan"
printf 'PASS: expanded features, ffplay staging/publication, neutral configure prefix, path mapping\n'
# Cleanup is offline, respects the shared lock, and never follows directory links.
cleanup_root="$scratch/cleanup"
mkdir -p "$cleanup_root"/{build,sources,output,logs,tmp,tools,legacy,models} "$scratch/outside"
touch "$cleanup_root/.build.lock" "$cleanup_root/build/object.o" "$scratch/outside/keep"
ln -s "$scratch/outside" "$cleanup_root/build/external"
"$project/build.sh" clean --build-root "$cleanup_root" --plan > "$scratch/clean-plan"
[[ -f "$cleanup_root/build/object.o" ]]
grep -q 'Would remove:' "$scratch/clean-plan"
(
  exec 8<> "$cleanup_root/.build.lock"
  flock -n 8
  reject 'Another build' clean --build-root "$cleanup_root"
)
"$project/build.sh" clean --build-root "$cleanup_root" > "$scratch/clean-result"
for directory in build sources output logs tmp; do [[ ! -e "$cleanup_root/$directory" ]]; done
for directory in tools legacy models; do [[ -d "$cleanup_root/$directory" ]]; done
[[ -f "$scratch/outside/keep" && -f "$cleanup_root/.build.lock" ]]
# A category that itself is a symlink must also leave its target untouched.
ln -s "$scratch/outside" "$cleanup_root/sources"
"$project/build.sh" clean --build-root "$cleanup_root" > /dev/null
[[ ! -L "$cleanup_root/sources" && -f "$scratch/outside/keep" ]]
"$project/build.sh" clean --build-root "$cleanup_root" > /dev/null
reject 'unsafe clean root' clean --build-root /
reject 'unsafe clean root' clean --build-root "$HOME"
reject 'unrecognized build root' clean --build-root "$scratch/outside"
"$project/build.sh" clean --build-root "$scratch/nonexistent" > /dev/null
[[ ! -e "$scratch/nonexistent" ]]
printf 'PASS: cleanup preview, locking, scope, symlinks, repeat cleanup and unsafe roots\n'
# Windows preflight must isolate host pkg-config data and avoid upstream calls.
cat > "$scratch/bin/pkg-config" <<'MOCK'
#!/usr/bin/env bash
[[ -z "${PKG_CONFIG_PATH:-}" && -z "${PKG_CONFIG_SYSROOT_DIR:-}" ]] || exit 99
[[ "${PKG_CONFIG_LIBDIR:-}" == "$EXPECTED_PKG_DIRS" ]] || exit 99
[[ "${DEPS_AVAILABLE:-0}" == 1 ]]
MOCK
cat > "$scratch/bin/git" <<'MOCK'
#!/usr/bin/env bash
printf 'Unexpected upstream request\n' >&2
exit 99
MOCK
chmod +x "$scratch/bin/pkg-config" "$scratch/bin/git"
mkdir -p "$scratch/windows-deps"
export EXPECTED_PKG_DIRS="$scratch/windows-deps/lib/pkgconfig:$scratch/windows-deps/lib64/pkgconfig:$scratch/windows-deps/share/pkgconfig"
PATH="$scratch/bin:$PATH" WINDOWS_DEPS_PREFIX="$scratch/windows-deps" DEPS_AVAILABLE=1 \
  "$project/build.sh" windows --check-deps --build-root "$scratch/check-only" > "$scratch/deps-check"
grep -q 'metadata found' "$scratch/deps-check"
[[ ! -e "$scratch/check-only" ]]
PATH="$scratch/bin:$PATH" WINDOWS_DEPS_PREFIX="$scratch/windows-deps" \
  reject 'must be built for Windows' windows --build-root "$scratch/check-only"
[[ ! -e "$scratch/check-only" ]]
if grep -q 'Unexpected upstream' "$scratch/out"; then exit 1; fi
reject 'cannot be combined' windows --plan --check-deps
reject 'not valid with clean' clean --check-deps
printf 'PASS: offline dependency checks, target isolation, early failure and option validation\n'
