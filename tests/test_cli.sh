#!/usr/bin/env bash
set -euo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
export BUILD_ROOT="$scratch/build"
"$project/install.sh" --help > "$scratch/help"
grep -q 'linux|windows|all' "$scratch/help"
"$project/install.sh" > "$scratch/no-args"
cmp "$scratch/help" "$scratch/no-args"
reject() {
  local expected="$1"; shift
  if "$project/install.sh" "$@" > "$scratch/out" 2>&1; then echo "Unexpected success: $*" >&2; exit 1; fi
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
PATH="$scratch/bin:$PATH" "$project/install.sh" all --plan > "$scratch/plan"
grep -q 'FFmpeg: n9.0.1 (0000000000000000000000000000000000000004)' "$scratch/plan"
grep -q 'whisper.cpp: v1.9.4' "$scratch/plan"
grep -q 'Vulkan-Headers: vulkan-sdk-1.4.357.0' "$scratch/plan"
grep -q 'Plan: linux/' "$scratch/plan"
grep -q 'Plan: windows/x86_64' "$scratch/plan"
[[ ! -d "$BUILD_ROOT/sources" && ! -d "$BUILD_ROOT/build" ]]
PATH="$scratch/bin:$PATH" "$project/install.sh" linux --whisper off --no-nvidia --plan > "$scratch/minimal"
if grep -q 'Checking upstream: whisper.cpp\|Checking upstream: nv-codec-headers\|Checking upstream: Vulkan' "$scratch/minimal"; then exit 1; fi
printf 'PASS: CLI validation, no-argument help, stable tags, annotated tags, matching SDK tags, both target plans, optional dependencies\n'
