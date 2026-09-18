# shellcheck shell=bash
# Pinned MXE supplies a consistent compiler and the common static libraries.
# Supplementary sources are pinned to commits, not moving branches/tags.
MXE_COMMIT=215428bf6f9c4e634f2fb827849a9c027dfe950a
MXE_TARGET=x86_64-w64-mingw32.static
MXE_PACKAGES=(cc cmake libass fdk-aac freetype fontconfig fribidi harfbuzz
  libcaca gmp lame opus vorbis libvpx x265 libssh openal openssl sdl2 libpng libiconv)
WINDOWS_EXTRA_NAMES=(aom srt svtjpegxs zvbi frei0r vmaf opencl-headers opencl-loader zmq)
declare -A WINDOWS_EXTRA_URL=(
  [aom]=https://aomedia.googlesource.com/aom
  [srt]=https://github.com/Haivision/srt.git
  [svtjpegxs]=https://github.com/OpenVisualCloud/SVT-JPEG-XS.git
  [zvbi]=https://github.com/zapping-vbi/zvbi.git
  [frei0r]=https://github.com/dyne/frei0r.git
  [vmaf]=https://github.com/Netflix/vmaf.git
  [opencl-headers]=https://github.com/KhronosGroup/OpenCL-Headers.git
  [opencl-loader]=https://github.com/KhronosGroup/OpenCL-ICD-Loader.git
  [zmq]=https://github.com/zeromq/libzmq.git
)
declare -A WINDOWS_EXTRA_COMMIT=(
  [aom]=10aece4157eb79315da205f39e19bf6ab3ee30d0
  [srt]=a8c6b65520f814c5bd8f801be48c33ceece7c4a6
  [svtjpegxs]=f9c82c12beed453980ef1888a5e72923b7265ed4
  [zvbi]=5169a428d51c3ae8ff7b0897e8a687d8e05e37b5
  [frei0r]=cdeddc7553bbfdc446c61d1bfa6a51bcc029b4a8
  [vmaf]=17a67b238ce0539bdeafdc95961abac64fa16ea8
  [opencl-headers]=4ea6df132107e3b4b9407f903204b5522fdffcd6
  [opencl-loader]=5907ac1114079de4383cecddf1c8640e3f52f92b
  [zmq]=622fc6dde99ee172ebaa9c8628d85a7a1995a21d
)

windows_dependency_root() {
  local digest
  digest="$(sha256sum "$PROJECT_DIR/lib/windows-deps.sh")"
  printf '%s/build/windows-deps/%s\n' "$BUILD_ROOT" "${digest:0:16}"
}

windows_dependency_tools() {
  local tool missing=()
  for tool in git gcc g++ make cmake meson ninja nasm pkg-config \
    autoconf automake autoreconf autopoint libtool libtoolize gettextize \
    bison flex gperf intltoolize lzip mako-render ruby perl python python3 \
    wget curl unzip 7za gdk-pixbuf-csource patch bzip2 xz; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  (( ${#missing[@]} == 0 )) || die "Missing Windows dependency build tools: ${missing[*]}. Install the Windows host prerequisites in README.md"
}

fetch_dependency() {
  local name="$1" url="$2" commit="$3" destination="$4"
  if [[ ! -d "$destination/.git" ]]; then
    [[ ! -e "$destination" ]] || die "Source directory already exists: $destination"
    mkdir -p "$destination"
    run git init -q "$destination"
    run git -C "$destination" remote add origin "$url"
  fi
  if ! git -C "$destination" rev-parse --verify HEAD >/dev/null 2>&1; then
    log "Downloading Windows dependency: $name"
    run git -C "$destination" fetch --depth 1 origin "$commit"
    run git -C "$destination" checkout --detach FETCH_HEAD
  fi
  [[ "$(git -C "$destination" rev-parse HEAD)" == "$commit" ]] || die "Unexpected $name commit in $destination"
  git -C "$destination" diff --quiet HEAD -- || die "Source has edits: $destination"
}

build_windows_dependencies() (
  windows_dependency_tools
  local dep_root mxe dep_prefix dep_cross name source work
  dep_root="$(windows_dependency_root)"
  mxe="$dep_root/mxe"
  dep_prefix="$mxe/usr/$MXE_TARGET"
  dep_cross="$MXE_TARGET-"
  mkdir -p "$dep_root/stamps"
  fetch_dependency MXE https://github.com/mxe/mxe.git "$MXE_COMMIT" "$mxe"
  # Do not allow native compiler/pkg-config environment to contaminate MXE.
  unset CC CXX AR RANLIB CFLAGS CXXFLAGS CPPFLAGS LDFLAGS CPATH C_INCLUDE_PATH \
    CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
  log "Building Windows toolchain and libraries with MXE (cached in $dep_root)"
  run make -C "$mxe" "MXE_TARGETS=$MXE_TARGET" "JOBS=$JOBS" check-requirements
  run make -C "$mxe" -j1 "MXE_TARGETS=$MXE_TARGET" "JOBS=$JOBS" "${MXE_PACKAGES[@]}"
  export PATH="$mxe/usr/bin:$PATH"
  export PKG_CONFIG_LIBDIR="$dep_prefix/lib/pkgconfig:$dep_prefix/share/pkgconfig" PKG_CONFIG_PATH=
  export CC="${dep_cross}gcc" CXX="${dep_cross}g++" AR="${dep_cross}ar" RANLIB="${dep_cross}ranlib"
  export CFLAGS="-O2 -ffile-prefix-map=$BUILD_ROOT=/build"
  export CXXFLAGS="$CFLAGS"
  export CPPFLAGS="-I$dep_prefix/include" LDFLAGS="-L$dep_prefix/lib"
  cat > "$dep_root/toolchain.cmake" <<CMAKE
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_VERSION 10.0)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $CC)
set(CMAKE_CXX_COMPILER $CXX)
set(CMAKE_RC_COMPILER ${dep_cross}windres)
set(CMAKE_FIND_ROOT_PATH "$dep_prefix")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
CMAKE
  cat > "$dep_root/cross.meson" <<MESON
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '${dep_cross}strip'
windres = '${dep_cross}windres'
pkg-config = 'pkg-config'
[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[properties]
needs_exe_wrapper = true
MESON
  for name in "${WINDOWS_EXTRA_NAMES[@]}"; do
    [[ ! -f "$dep_root/stamps/$name" ]] || continue
    source="$BUILD_ROOT/sources/windows-deps/$name/${WINDOWS_EXTRA_COMMIT[$name]}"
    fetch_dependency "$name" "${WINDOWS_EXTRA_URL[$name]}" "${WINDOWS_EXTRA_COMMIT[$name]}" "$source"
    work="$dep_root/work/$name"
    mkdir -p "$work"
    log "Building Windows library: $name"
    build_windows_extra "$name"
    # A failed configure, compile, or install never marks a library complete.
    touch "$dep_root/stamps/$name"
  done
  {
    printf 'MXE: %s\nTarget: %s\n' "$MXE_COMMIT" "$MXE_TARGET"
    for name in "${WINDOWS_EXTRA_NAMES[@]}"; do printf '%s: %s\n' "$name" "${WINDOWS_EXTRA_COMMIT[$name]}"; done
  } > "$dep_prefix/dependency-build-info.txt"
)

windows_cmake_library() {
  run cmake -S "$source" -B "$work/build" -G Ninja \
    "-DCMAKE_TOOLCHAIN_FILE=$dep_root/toolchain.cmake" \
    "-DCMAKE_INSTALL_PREFIX=$dep_prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 "$@"
  run cmake --build "$work/build" -j "$JOBS"
  run cmake --install "$work/build"
}

build_windows_extra() {
  case "$1" in
    aom) windows_cmake_library -DENABLE_TESTS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TOOLS=OFF -DENABLE_DOCS=OFF ;;
    srt) windows_cmake_library -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF -DUSE_ENCLIB=openssl ;;
    svtjpegxs) windows_cmake_library -DBUILD_APPS=OFF -DENABLE_NASM=ON -DJPEGXS_LTO=OFF "-DCMAKE_OUTPUT_DIRECTORY=$work/bin" ;;
    zmq)
      windows_cmake_library -DZMQ_WIN32_WINNT=0x0A00 -DZMQ_HAVE_IPC=OFF -DENABLE_DRAFTS=OFF \
        -DBUILD_SHARED=OFF -DBUILD_STATIC=ON -DBUILD_TESTS=OFF -DWITH_PERF_TOOL=OFF \
        -DWITH_DOCS=OFF -DWITH_LIBSODIUM=OFF
      # Upstream's static .pc omits the Windows system libraries and import switch.
      sed -i -e '/^Cflags:/s/$/ -DZMQ_STATIC/' \
        -e '/^Libs.private:/s/$/ -lws2_32 -lrpcrt4 -liphlpapi/' \
        "$dep_prefix/lib/pkgconfig/libzmq.pc"
      ;;
    opencl-headers) windows_cmake_library -DOPENCL_HEADERS_BUILD_TESTING=OFF ;;
    opencl-loader)
      windows_cmake_library -DOPENCL_ICD_LOADER_BUILD_SHARED_LIBS=OFF \
        -DENABLE_OPENCL_LAYERS=OFF "-DOPENCL_ICD_LOADER_HEADERS_DIR=$dep_prefix/include"
      # Upstream uses OpenCL.a (without lib) for the MinGW static archive.
      if [[ -f "$dep_prefix/lib/OpenCL.a" ]]; then
        sed -i 's/-lOpenCL/-l:OpenCL.a/g' "$dep_prefix/lib/pkgconfig/OpenCL.pc"
      fi
      # Static loader references Windows configuration-manager APIs.
      sed -i '/^Libs.private:/d' "$dep_prefix/lib/pkgconfig/OpenCL.pc"
      printf '\nLibs.private: -lcfgmgr32 -lole32\n' >> "$dep_prefix/lib/pkgconfig/OpenCL.pc"
      ;;
    frei0r)
      # FFmpeg loads effect DLLs at runtime and only needs the frei0r API header.
      install -Dm644 "$source/include/frei0r.h" "$dep_prefix/include/frei0r.h"
      sed -e "s|@prefix@|$dep_prefix|g" -e "s|@exec_prefix@|$dep_prefix|g" \
        -e "s|@libdir@|$dep_prefix/lib|g" -e "s|@includedir@|$dep_prefix/include|g" \
        -e 's|@VERSION@|2.3.3|g' "$source/frei0r.pc.in" > "$dep_prefix/lib/pkgconfig/frei0r.pc"
      ;;
    vmaf)
      if [[ ! -f "$work/build/meson-private/coredata.dat" ]]; then
        run meson setup "$work/build" "$source/libvmaf" --cross-file "$dep_root/cross.meson" \
          --prefix "$dep_prefix" --libdir lib --default-library static --buildtype release \
          -Denable_tests=false -Denable_docs=false
      fi
      run meson compile -C "$work/build" -j "$JOBS"
      run meson install -C "$work/build"
      ;;
    zvbi)
      # Autoreconf modifies the tree; keep the pinned checkout untouched.
      if [[ ! -f "$work/source/configure" ]]; then
        mkdir -p "$work/source"
        cp -a "$source/." "$work/source/"
        (cd "$work/source" && run autoreconf -fiv)
      fi
      mkdir -p "$work/build"
      (cd "$work/build" && run "$work/source/configure" --host=x86_64-w64-mingw32 \
        "--prefix=$dep_prefix" --enable-static --disable-shared --disable-nls \
        --disable-dvb --disable-bktr --disable-proxy --disable-v4l --without-x \
        --disable-tests --disable-examples --without-doxygen --without-libiconv-prefix)
      run make -C "$work/build" -j "$JOBS"
      run make -C "$work/build" install
      ;;
    *) die "Unknown Windows dependency recipe: $1" ;;
  esac
}
