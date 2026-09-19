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
install_linux_host_tools() {
  local packages=(
    libvulkan1 libsdl2-dev libaom-dev libass-dev libfdk-aac-dev
    libfreetype-dev libfontconfig-dev libfribidi-dev libharfbuzz-dev libcaca-dev
    frei0r-plugins-dev libgmp-dev libmp3lame-dev libopus-dev libvorbis-dev
    libvpx-dev libx265-dev libsrt-openssl-dev libzvbi-dev libzmq3-dev
    libssh-dev libopenal-dev ocl-icd-opencl-dev libgl-dev libdrm-dev
    libssl-dev libsmbclient-dev nvidia-cuda-toolkit
  )

  local privilege=()
  host_tool_available apt-get || die "Automatic installation requires apt-get; install missing packages using your distribution's package manager (see README.md)"

  if [[ "$(id -u)" != 0 ]]; then
    host_tool_available sudo || die "Install required packages as administrator: ${packages[*]} (sudo is unavailable)"
    privilege=(sudo)
  fi

  printf 'Installing Linux host build dependencies and CUDA toolkit...\n'
  "${privilege[@]}" apt-get update || die 'Could not refresh apt package lists; fix the apt/sudo error and rerun the build'
  "${privilege[@]}" apt-get install -y --no-install-recommends "${packages[@]}" || die 'Could not install Linux host dependencies; fix the apt/sudo error and rerun the build'

  # Standardize CUDA directory layout for Ubuntu/Debian system paths
  if [[ ! -d /usr/local/cuda ]]; then
    printf 'Creating standard /usr/local/cuda symlinks for CUDA headers and libraries...\n'
    "${privilege[@]}" mkdir -p /usr/local/cuda
    "${privilege[@]}" ln -s /usr/include /usr/local/cuda/include
    "${privilege[@]}" ln -s /usr/lib/x86_64-linux-gnu /usr/local/cuda/lib64
  fi

  hash -r
}