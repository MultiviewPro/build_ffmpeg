#!/usr/bin/env bash
set -euo pipefail
project="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
source "$project/lib/build.sh"
source "$project/lib/host-tools.sh"
BUILD_ROOT="$scratch/build"
WHISPER_BACKEND=off
host_tool_available() {
  case "$1" in
    libtool|intltoolize|lzip|mako-render) [[ -f "$scratch/installed" ]] ;;
    *) return 0 ;;
  esac
}
id() { printf '1000\n'; }
sudo() { printf 'sudo\n' >> "$scratch/privilege"; "$@"; }
apt-get() {
  printf '%s\n' "$*" >> "$scratch/apt"
  [[ "$1" != install ]] || touch "$scratch/installed"
}
install_windows_host_tools > "$scratch/output"
grep -qx update "$scratch/apt"
grep -qx 'install -y --no-install-recommends libtool-bin intltool lzip python3-mako' "$scratch/apt"
[[ "$(wc -l < "$scratch/privilege")" == 2 ]]
install_windows_host_tools > "$scratch/output"
[[ "$(wc -l < "$scratch/apt")" == 2 ]]
# Root invokes apt directly; a failed update must not proceed to installation.
rm "$scratch/installed" "$scratch/privilege"
id() { printf '0\n'; }
install_windows_host_tools > "$scratch/output"
[[ ! -e "$scratch/privilege" ]]
rm "$scratch/installed"
apt-get() { printf '%s\n' "$*" >> "$scratch/failed-apt"; return 42; }
if (install_windows_host_tools) > "$scratch/error" 2>&1; then exit 1; fi
grep -q 'Could not refresh' "$scratch/error"
[[ "$(cat "$scratch/failed-apt")" == update ]]
# Unsupported package managers fail with manual instructions, without invoking apt.
host_tool_available() { [[ "$1" != libtool && "$1" != apt-get ]]; }
if (install_windows_host_tools) > "$scratch/error" 2>&1; then exit 1; fi
grep -q 'Automatic installation requires apt-get' "$scratch/error"
printf 'PASS: missing-package selection, sudo/root, no-op reuse and install failure handling\n'
