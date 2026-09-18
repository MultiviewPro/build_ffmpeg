# shellcheck shell=bash
# build_whisper intentionally uses build_target locals in the same subshell.
# shellcheck disable=SC2030,SC2031
# Shared source resolution and build steps. Sourced by install.sh.
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require_tools() {
  local tool
  for tool in "$@"; do command -v "$tool" >/dev/null || die "Missing $tool; see README.md prerequisites"; done
}
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
run() { "$@" >> "$LOG" 2>&1; }

# Match complete numeric release tags, excluding rc/dev/prerelease suffixes.
latest_tag() { sed -n 's@.*refs/tags/@@p' | grep -E "$1" | sort -V | tail -n 1; }
resolve_sources() {
  declare -gA URL REF COMMIT REMOTE
  URL[x264]=https://code.videolan.org/videolan/x264.git
  URL[FFmpeg]=https://github.com/FFmpeg/FFmpeg.git
  URL[nv-codec-headers]=https://github.com/FFmpeg/nv-codec-headers.git
  URL[whisper.cpp]=https://github.com/ggml-org/whisper.cpp.git
  local name
  SOURCES=(x264 FFmpeg)
  (( NVIDIA == 0 )) || SOURCES+=(nv-codec-headers)
  [[ "$WHISPER_BACKEND" == off ]] || SOURCES+=(whisper.cpp)
  if [[ "$WHISPER_BACKEND" == vulkan ]]; then
    for name in Vulkan-Headers SPIRV-Headers Vulkan-Loader; do
      URL[$name]="https://github.com/KhronosGroup/$name.git"
      SOURCES+=("$name")
    done
  fi
  REF[x264]="${X264_REF:-stable}"
  REF[FFmpeg]="${FFMPEG_REF:-latest}"
  REF[nv-codec-headers]="${NV_CODEC_HEADERS_REF:-latest}"
  REF[whisper.cpp]="${WHISPER_REF:-latest}"
  for name in "${SOURCES[@]}"; do
    log "Checking upstream: $name"
    REMOTE[$name]="$(git ls-remote --heads --tags "${URL[$name]}")"
  done
  if [[ "$WHISPER_BACKEND" == vulkan ]]; then
    local sdk="${VULKAN_REF:-latest}" candidates tag
    if [[ "$sdk" == latest ]]; then
      candidates="$(printf '%s\n' "${REMOTE[Vulkan-Headers]}" | sed -n 's@.*refs/tags/@@p' | grep -E '^vulkan-sdk-[0-9]+(\.[0-9]+)+$' | sort -Vr)"
      sdk=
      while IFS= read -r tag; do
        if ref_commit "${REMOTE[SPIRV-Headers]}" "$tag" >/dev/null && ref_commit "${REMOTE[Vulkan-Loader]}" "$tag" >/dev/null; then sdk="$tag"; break; fi
      done <<< "$candidates"
      [[ -n "$sdk" ]] || die 'No matching Vulkan SDK release across all three repositories'
    fi
    for name in Vulkan-Headers SPIRV-Headers Vulkan-Loader; do REF[$name]="$sdk"; done
  fi
  for name in "${SOURCES[@]}"; do
    if [[ "${REF[$name]}" == latest ]]; then
      local pattern='^n[0-9]+(\.[0-9]+)+$'
      [[ "$name" != whisper.cpp ]] || pattern='^v[0-9]+(\.[0-9]+)+$'
      REF[$name]="$(printf '%s\n' "${REMOTE[$name]}" | latest_tag "$pattern")"
    fi
    COMMIT[$name]="$(ref_commit "${REMOTE[$name]}" "${REF[$name]}")" || die "Unknown branch/tag ${REF[$name]} for $name"
    log "$name: ${REF[$name]} (${COMMIT[$name]})"
  done
}

ref_commit() {
  # Prefer an annotated tag's peeled commit over its tag object or a branch.
  local refs="$1" ref="$2" candidate value
  for candidate in "refs/tags/$ref^{}" "refs/tags/$ref" "refs/heads/$ref"; do
    value="$(awk -v ref="$candidate" '$2 == ref {print $1}' <<< "$refs")"
    if [[ -n "$value" ]]; then printf '%s\n' "$value"; return 0; fi
  done
  return 1
}

checkout_sources() {
  declare -gA SOURCE
  local name destination
  for name in "${SOURCES[@]}"; do
    destination="$BUILD_ROOT/sources/$name/${COMMIT[$name]}"
    if [[ ! -d "$destination/.git" ]]; then
      [[ ! -e "$destination" ]] || die "Source directory already exists: $destination"
      mkdir -p "$destination"
      run git init -q "$destination"
      run git -C "$destination" remote add origin "${URL[$name]}"
    fi
    if ! git -C "$destination" rev-parse --verify HEAD >/dev/null 2>&1; then
      run git -C "$destination" fetch --depth 1 origin "${COMMIT[$name]}"
      run git -C "$destination" checkout --detach FETCH_HEAD
    fi
    [[ "$(git -C "$destination" rev-parse HEAD)" == "${COMMIT[$name]}" ]] || die "Source commit changed: $destination"
    [[ -z "$(git -C "$destination" status --porcelain)" ]] || die "Source has local edits: $destination"
    SOURCE[$name]="$destination"
  done
}

build_target() (
  local target="$1" cc=gcc cxx=g++ ar=ar ranlib=ranlib cross='' suffix='' arch
  arch="$(uname -m)"
  local target_flags=(--enable-pthreads --enable-gnutls)
  local ldflags='' runtime_libs='-lstdc++ -lpthread -ldl -lm'
  if [[ "$target" == windows ]]; then
    arch=x86_64; suffix=.exe; cross=x86_64-w64-mingw32-
    cc="${cross}gcc-posix"; cxx="${cross}g++-posix"; ar="${cross}ar"; ranlib="${cross}ranlib"
    target_flags=(--arch=x86_64 --target-os=mingw32 --enable-cross-compile
      "--cross-prefix=$cross" "--cc=$cc" --host-cc=gcc
      --enable-schannel --enable-w32threads --disable-pthreads)
    ldflags='-static -static-libgcc'
    runtime_libs='-lstdc++ -lwinpthread'
  fi
  local glslc="${GLSLC:-glslc}"
  # An optional workspace-local host compiler is useful on machines without glslc installed.
  if ! command -v "$glslc" >/dev/null && [[ -z "${GLSLC:-}" && -x "$BUILD_ROOT/tools/bin/glslc" ]]; then glslc="$BUILD_ROOT/tools/bin/glslc"; fi
  if (( PLAN )); then
    log "Plan: $target/$arch, Whisper=$WHISPER_BACKEND, NVIDIA=$NVIDIA, root=$BUILD_ROOT"
    return
  fi
  require_tools "$cc" "$ar" "$ranlib"
  [[ "$target" != windows ]] || require_tools "${cross}strip" "${cross}windres" "${cross}objdump"
  [[ "$WHISPER_BACKEND" == off ]] || require_tools cmake "$cxx"
  if [[ "$WHISPER_BACKEND" == vulkan ]]; then
    require_tools "$glslc"
    glslc="$(command -v "$glslc")"
    [[ "$target" != windows ]] || require_tools "${cross}dlltool"
  fi
  if [[ "$target" == linux ]]; then pkg-config --exists gnutls || die 'Missing native GnuTLS development package (libgnutls28-dev)'; fi
  checkout_sources
  local key root prefix output name
  key="$( { printf '%s\n' "$target" "$arch" "$WHISPER_BACKEND" "$NVIDIA" "$glslc"; for name in "${SOURCES[@]}"; do printf '%s:%s\n' "$name" "${COMMIT[$name]}"; done; "$cc" --version; } | sha256sum)"
  root="$BUILD_ROOT/build/$target-${arch}/${key:0:16}"
  prefix="$root/prefix"; output="$root/output"
  mkdir -p "$root/x264" "$root/ffmpeg" "$prefix/lib/pkgconfig" "$output" "$BUILD_ROOT/output"
  log "Building $target in $root; log: $LOG"
  unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH CFLAGS CXXFLAGS CPPFLAGS LDFLAGS
  export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
  unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR
  if [[ "$target" == windows ]]; then export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH" PKG_CONFIG_PATH=; fi
  local x264_flags=(--enable-static --enable-pic --disable-cli --disable-opencl)
  [[ "$target" != windows ]] || x264_flags+=(--host=x86_64-w64-mingw32 "--cross-prefix=$cross")
  log 'Building x264'
  cd "$root/x264" || return 1
  run env CC="$cc" AR="$ar" RANLIB="$ranlib" "${SOURCE[x264]}/configure" "--prefix=$prefix" "${x264_flags[@]}"
  run make -j"$JOBS"
  run make install
  local gpu_flags=(--disable-ffnvcodec --disable-cuda --disable-cuvid --disable-nvdec --disable-nvenc)
  if (( NVIDIA )); then
    mkdir -p "$prefix/include/ffnvcodec"
    cp "${SOURCE[nv-codec-headers]}"/include/ffnvcodec/*.h "$prefix/include/ffnvcodec/"
    sed "s|@@PREFIX@@|$prefix|g" "${SOURCE[nv-codec-headers]}/ffnvcodec.pc.in" > "$prefix/lib/pkgconfig/ffnvcodec.pc"
    gpu_flags=(--enable-ffnvcodec --enable-cuda --enable-cuvid --enable-nvdec --enable-nvenc)
    log "NVIDIA driver requirements (${REF[nv-codec-headers]}):"
    tee -a "$LOG" < "${SOURCE[nv-codec-headers]}/README"
    printf '\n'
  fi
  local whisper_flags=(--disable-whisper)
  if [[ "$WHISPER_BACKEND" != off ]]; then
    build_whisper
    whisper_flags=(--enable-whisper)
  fi
  log 'Building FFmpeg and ffprobe'
  cd "$root/ffmpeg" || return 1
  run "${SOURCE[FFmpeg]}/configure" "--prefix=$output" "--bindir=$output/bin" \
    "--extra-cflags=-I$prefix/include" "--extra-ldflags=-L$prefix/lib $ldflags" \
    --pkg-config=pkg-config --pkg-config-flags=--static \
    --disable-autodetect --enable-static --disable-shared --enable-gpl \
    --enable-libx264 --disable-ffplay --disable-doc --disable-debug \
    "${target_flags[@]}" "${gpu_flags[@]}" "${whisper_flags[@]}"
  run make -j"$JOBS"
  run make install
  local binary
  for binary in ffmpeg ffprobe; do
    if [[ "$target" == windows ]]; then
      "${cross}objdump" -f "$output/bin/$binary.exe" | grep 'file format pei-x86-64' >> "$LOG"
      "${cross}objdump" -p "$output/bin/$binary.exe" > "$output/$binary-pe.txt"
    else
      run "$output/bin/$binary" -version
    fi
  done
  cp config.h config_components.h "$output/"
  cp ffbuild/config.log "$output/config.log"
  {
    printf 'Target: %s/%s\nWhisper: %s\nNVIDIA: %s\nBuild directory: %s\n' "$target" "$arch" "$WHISPER_BACKEND" "$NVIDIA" "$root"
    for name in "${SOURCES[@]}"; do printf '%s: %s %s\n' "$name" "${REF[$name]}" "${COMMIT[$name]}"; done
    "$cc" --version
  } > "$output/build-info.txt"
  # Publish a pointer only after build and validation have both succeeded.
  ln -s "$output" "$BUILD_ROOT/output/.$target-$$"
  mv -Tf "$BUILD_ROOT/output/.$target-$$" "$BUILD_ROOT/output/$target"
  log "Ready: $BUILD_ROOT/output/$target/bin/ffmpeg$suffix"
)

build_whisper() {
  log "Building Whisper ($WHISPER_BACKEND)"
  local cmake_flags=() vulkan_flags=(-DGGML_VULKAN=OFF) vulkan_libs='' archive_libs
  if [[ "$target" == windows ]]; then
    cat > "$root/mingw.cmake" <<CMAKE
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER $cc)
set(CMAKE_CXX_COMPILER $cxx)
set(CMAKE_RC_COMPILER ${cross}windres)
set(CMAKE_FIND_ROOT_PATH "$prefix" /usr/x86_64-w64-mingw32)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
CMAKE
    cmake_flags+=("-DCMAKE_TOOLCHAIN_FILE=$root/mingw.cmake")
    archive_libs='-lwhisper -l:ggml.a -l:ggml-base.a -l:ggml-cpu.a'
  else
    archive_libs='-lwhisper -lggml -lggml-base -lggml-cpu'
  fi
  if [[ "$WHISPER_BACKEND" == vulkan ]]; then
    local dependency vulkan_library
    for dependency in Vulkan-Headers SPIRV-Headers; do
      run cmake -S "${SOURCE[$dependency]}" -B "$root/$dependency" -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib
      run cmake --install "$root/$dependency"
    done
    if [[ "$target" == windows ]]; then
      "${cross}dlltool" -d "${SOURCE[Vulkan-Loader]}/loader/vulkan-1.def" -D vulkan-1.dll -l "$prefix/lib/libvulkan-1.a"
      vulkan_library="$prefix/lib/libvulkan-1.a"
      vulkan_libs='-l:ggml-vulkan.a -lvulkan-1'
    else
      vulkan_library="$(gcc -print-file-name=libvulkan.so.1)"
      [[ -f "$vulkan_library" ]] || die 'Missing Linux Vulkan loader; install libvulkan1'
      vulkan_libs='-lggml-vulkan -l:libvulkan.so.1'
    fi
    vulkan_flags=(-DGGML_VULKAN=ON "-DVulkan_INCLUDE_DIR=$prefix/include" "-DVulkan_LIBRARY=$vulkan_library" "-DVulkan_GLSLC_EXECUTABLE=$glslc")
  fi
  run cmake -S "${SOURCE[whisper.cpp]}" -B "$root/whisper" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$prefix" -DBUILD_SHARED_LIBS=OFF -DWHISPER_BUILD_IS_DEV=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_BACKEND_DL=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_CUDA=OFF \
    -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF \
    -DGGML_BMI2=OFF -DGGML_SSE42=OFF -DGGML_CCACHE=OFF \
    "${cmake_flags[@]}" "${vulkan_flags[@]}"
  run cmake --build "$root/whisper" -j"$JOBS"
  run cmake --install "$root/whisper"
  # Upstream metadata omits static backend dependencies and their link order.
  local version
  version="$(pkg-config --modversion whisper)"
  cat > "$prefix/lib/pkgconfig/whisper.pc" <<PC
prefix=$prefix
libdir=$prefix/lib
includedir=$prefix/include
Name: whisper
Description: Whisper for $target with $WHISPER_BACKEND backend
Version: $version
Libs: -L$prefix/lib -Wl,--start-group $archive_libs $vulkan_libs -Wl,--end-group $runtime_libs
Cflags: -I$prefix/include
PC
}
