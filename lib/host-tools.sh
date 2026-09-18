# shellcheck shell=bash
# Called only for a real automatic Windows build, never for preview/check/clean.
host_tool_available() { command -v "$1" >/dev/null 2>&1; }
install_windows_host_tools() {
  local specs=(git:git gcc:build-essential g++:build-essential make:build-essential
    cmake:cmake meson:meson ninja:ninja-build nasm:nasm pkg-config:pkg-config
    autoconf:autoconf automake:automake autoreconf:autoconf autopoint:autopoint
    libtool:libtool-bin libtoolize:libtool gettextize:gettext bison:bison flex:flex
    gperf:gperf intltoolize:intltool lzip:lzip mako-render:python3-mako ruby:ruby
    perl:perl python:python-is-python3 python3:python3 wget:wget curl:curl
    unzip:unzip 7za:p7zip-full gdk-pixbuf-csource:libgdk-pixbuf2.0-bin
    patch:patch bzip2:bzip2 xz:xz-utils flock:util-linux)
  if [[ "$WHISPER_BACKEND" == vulkan && -z "${GLSLC:-}" && ! -x "$BUILD_ROOT/tools/bin/glslc" ]]; then
    specs+=(glslc:glslc)
  fi
  local spec tool package missing=() packages=() privilege=()
  local -A seen=()
  for spec in "${specs[@]}"; do
    tool="${spec%%:*}"; package="${spec#*:}"
    if ! host_tool_available "$tool"; then
      missing+=("$tool")
      if [[ -z "${seen[$package]:-}" ]]; then
        packages+=("$package")
        seen[$package]=1
      fi
    fi
  done
  (( ${#packages[@]} )) || return 0
  host_tool_available apt-get || die "Missing host tools: ${missing[*]}. Automatic installation requires apt-get; install them with your distribution's package manager (see README.md)"
  if [[ "$(id -u)" != 0 ]]; then
    host_tool_available sudo || die "Missing host tools: ${missing[*]}. Install packages as administrator: ${packages[*]} (sudo is unavailable)"
    privilege=(sudo)
  fi
  printf 'Installing missing Windows build prerequisites: %s\n' "${packages[*]}"
  "${privilege[@]}" apt-get update || die 'Could not refresh apt package lists; fix the apt/sudo error and rerun the build'
  "${privilege[@]}" apt-get install -y --no-install-recommends "${packages[@]}" || die 'Could not install host prerequisites; fix the apt/sudo error and rerun the build'
  hash -r
  for tool in "${missing[@]}"; do
    host_tool_available "$tool" || die "Package installation finished but $tool is still unavailable on PATH"
  done
}
