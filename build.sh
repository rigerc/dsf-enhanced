#!/usr/bin/env bash
# Linux build: the same plugin, DLSS 5 helper, tests and release package as build.ps1, made with
# clang-cl and lld-link against Microsoft's C runtime and Windows SDK, which xwin downloads.
# The tests are 32-bit Windows programs, as in build.ps1, and run under Wine in a prefix of their
# own (~/.cache/dsf-enhanced/wineprefix, or DSF_TEST_WINEPREFIX).
#
#   ./build.sh                 everything into dist/
#   ./build.sh --skip-dlss5    without the DLSS 5 / DLAA helper
#   ./build.sh --skip-tests    build only
#
# Needs clang-cl and lld-link from LLVM 19 or later (Microsoft's C++ library needs Clang 19), bsdtar,
# curl, sha256sum, and Wine for the tests.
# The Microsoft files come from xwin (cargo install xwin), once:
#   xwin --accept-license --arch x86,x86_64 splat --use-winsysroot-style --preserve-ms-arch-notation --output ~/.xwin
# --accept-license accepts Microsoft's license for those files. XWIN points elsewhere if needed.
# DSF_GAME_DIR, if set, makes the FOV site test check its table against that Driver.exe (read only).
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
build="$root/build"
dist="$root/dist"
xwin="${XWIN:-$HOME/.xwin}"
skip_dlss5=0
skip_tests=0
for arg in "$@"; do
  case "$arg" in
    --skip-dlss5) skip_dlss5=1 ;;
    --skip-tests) skip_tests=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

need() { command -v "$1" >/dev/null || { echo "$1 is missing: $2" >&2; exit 1; }; }
need clang-cl "install clang (LLVM 19 or later)"
need lld-link "install lld (LLVM 19 or later)"
clang_major="$(clang-cl --version | sed -n 's/.*clang version \([0-9]*\).*/\1/p' | head -1)"
if [ "${clang_major:-0}" -lt 19 ]; then
  echo "clang-cl $clang_major is too old: Microsoft's C++ library needs Clang 19 or later" >&2
  exit 1
fi
need bsdtar "install libarchive"
need curl "install curl"
need sha256sum "install coreutils"
[ "$skip_tests" = 1 ] || need wine "install Wine, or pass --skip-tests"
# clang-cl's /winsysroot wants Microsoft's arch folder names (x86, x64): --preserve-ms-arch-notation.
if [ ! -d "$xwin/VC/Tools/MSVC" ] || [ ! -d "$xwin/Windows Kits/10" ] || ! ls -d "$xwin"/VC/Tools/MSVC/*/lib/x64 >/dev/null 2>&1; then
  echo "No Microsoft CRT and Windows SDK at $xwin. Get them once with:" >&2
  echo "  xwin --accept-license --arch x86,x86_64 splat --use-winsysroot-style --preserve-ms-arch-notation --output $xwin" >&2
  exit 1
fi

rm -rf "$build" "$dist"
mkdir -p "$build" "$dist"

# clang-cl in MSVC mode against xwin's files; the rest of each command line is build.ps1's.
cl32() { clang-cl --target=i686-pc-windows-msvc /winsysroot "$xwin" -fuse-ld=lld "$@"; }
cl64() { clang-cl --target=x86_64-pc-windows-msvc /winsysroot "$xwin" -fuse-ld=lld "$@"; }

# The tests run under Wine in a prefix of their own, never the game's. It stays outside the
# repository and is reused between builds: thousands of small files, which also filled the file
# table of an NTFS (ntfs-3g) volume the repository was on.
export WINEPREFIX="${DSF_TEST_WINEPREFIX:-${XDG_CACHE_HOME:-$HOME/.cache}/dsf-enhanced/wineprefix}"
mkdir -p "$(dirname "$WINEPREFIX")"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree,mshtml=}"
run_test() {
  echo "== $(basename "$1")"
  wine "$@"
}

asi="$build/dsf_enhanced.asi"
cl32 /nologo /std:c++17 /EHsc /O2 /MT /LD /Fo"$build/" /Fe"$asi" "$root/src/dsf_enhanced.cpp" \
  user32.lib d3d9.lib dxguid.lib /link /MACHINE:X86 /MAP:"$build/dsf_enhanced.map"

if [ "$skip_tests" = 0 ]; then
  wineboot -i >/dev/null 2>&1 || true
  cl32 /nologo /std:c++17 /EHsc /O2 /Fo"$build/" /Fe"$build/cinematic_fit_test.exe" "$root/tests/cinematic_fit_test.cpp"
  run_test "$build/cinematic_fit_test.exe"
  # FOVScaling's sites (src/fov_sites.h): the reads of the degrees-to-radians constant that make a FOV.
  cl32 /nologo /std:c++17 /EHsc /O2 /Fo"$build/" /Fe"$build/fov_sites_test.exe" "$root/tests/fov_sites_test.cpp"
  if [ -n "${DSF_GAME_DIR:-}" ] && [ -f "$DSF_GAME_DIR/Driver.exe" ]; then
    run_test "$build/fov_sites_test.exe" "$(winepath -w "$DSF_GAME_DIR/Driver.exe")"
  else
    run_test "$build/fov_sites_test.exe"
  fi
  # DLAA jitter's vertex shader patch: the self-test. It compiles and disassembles its shaders with
  # d3dcompiler_47, and needs Microsoft's: Wine's own allocates registers differently and writes
  # other disassembly, so the test fails with it. The redistributable 32-bit DLL comes from
  # Mozilla's fxc2 (where winetricks gets it too), pinned by commit and SHA-256, cached outside build/.
  d3dc_cache="${XDG_CACHE_HOME:-$HOME/.cache}/dsf-enhanced"
  d3dc="$d3dc_cache/d3dcompiler_47_32.dll"
  d3dc_sha=2ad0d4987fc4624566b190e747c9d95038443956ed816abfd1e2d389b5ec0851
  if ! { [ -f "$d3dc" ] && echo "$d3dc_sha  $d3dc" | sha256sum -c --quiet - 2>/dev/null; }; then
    mkdir -p "$d3dc_cache"
    curl -fsSL -o "$d3dc" \
      "https://raw.githubusercontent.com/mozilla/fxc2/807d26f4e4e9e9d0d0d6c1e05493b28eafb20e91/dll/d3dcompiler_47_32.dll"
    echo "$d3dc_sha  $d3dc" | sha256sum -c --quiet - || { rm -f "$d3dc"; echo "d3dcompiler_47_32.dll: SHA-256 mismatch" >&2; exit 1; }
  fi
  cl32 /nologo /std:c++17 /EHsc /O2 /D_CRT_SECURE_NO_WARNINGS /Fo"$build/" /Fe"$build/vs_jitter_test.exe" \
    "$root/tests/vs_jitter_test.cpp" d3d9.lib user32.lib
  cp "$d3dc" "$build/d3dcompiler_47.dll"
  WINEDLLOVERRIDES="d3dcompiler_47=n;$WINEDLLOVERRIDES" run_test "$build/vs_jitter_test.exe"
  # [Files] Redirect: loads the plugin just built into a stand-in exe (tests/file_redirect_test.cpp),
  # which writes a game folder layout beside itself.
  mkdir -p "$build/redirect_test"
  cl32 /nologo /std:c++17 /EHsc /O2 /MT /Fo"$build/redirect_test/" /Fe"$build/redirect_test/file_redirect_test.exe" \
    "$root/tests/file_redirect_test.cpp" /link /MACHINE:X86
  run_test "$build/redirect_test/file_redirect_test.exe" "$(winepath -w "$asi")"
  # Optional: checks src/vk_min.h against the Khronos Vulkan headers (a Vulkan-Headers include folder).
  if [ -n "${VULKAN_HEADERS_INCLUDE:-}" ]; then
    cl32 /nologo /std:c++17 /EHsc /I"$VULKAN_HEADERS_INCLUDE" /Fo"$build/" /Fe"$build/vk_min_check.exe" "$root/tests/vk_min_check.cpp"
    run_test "$build/vk_min_check.exe"
  fi
fi

cp "$asi" "$dist/"
cp "$root/src/dsf_enhanced.ini" "$root/third_party/winmm.dll" "$root/README.md" "$root/LICENSE" "$dist/"
entries=(winmm.dll dsf_enhanced.asi dsf_enhanced.ini README.md LICENSE)

# DLSS 5 (experimental): dist/dlss5 holds the helper, NVIDIA's license for the static NGX loader
# linked into it (fetched with the SDK, never committed) and a readme. No NVIDIA DLL and no DXVK.
if [ "$skip_dlss5" = 0 ]; then
  # dlss5/fetch-sdk.ps1: NVIDIA's public DLSS SDK at a fixed commit, each file checked by SHA-256.
  sdk="$root/dlss5/external/dlss-sdk"
  commit=9981c6350dc58c0ce21f024fd65e31e851c31689
  while read -r source target hash; do
    file="$sdk/$target"
    if [ -f "$file" ] && echo "$hash  $file" | sha256sum -c --quiet - 2>/dev/null; then
      continue
    fi
    mkdir -p "$(dirname "$file")"
    curl -fsSL -o "$file" "https://raw.githubusercontent.com/NVIDIA/DLSS/$commit/$source"
    if ! echo "$hash  $file" | sha256sum -c --quiet - 2>/dev/null; then
      rm -f "$file"
      echo "SHA-256 of $source from NVIDIA/DLSS@$commit does not match the pinned value; refusing to use it." >&2
      exit 1
    fi
  done <<'EOF'
include/nvsdk_ngx.h include/nvsdk_ngx.h dc38e7467cf415379c9d12ae1b6e4a494c453ed92720fb53e92aecb523e7b848
include/nvsdk_ngx_defs.h include/nvsdk_ngx_defs.h ea23f33497cd274860d1c25a97644fce807dcb0037c594547203343103fad03e
include/nvsdk_ngx_params.h include/nvsdk_ngx_params.h 943bc8cc5cdae03b6303016fbad3183636f2335ae27a2d18776798c3b4efabbc
include/nvsdk_ngx_helpers_d3d.h include/nvsdk_ngx_helpers_d3d.h ec75224f36ed6580baaf250fa83620405ad81a1d98c2c436654a0c9cf6a6b8ba
lib/Windows_x86_64/x64/nvsdk_ngx_s.lib lib/nvsdk_ngx_s.lib 7b9a5239c1145af5f645ab472aa066f9ea79db36ac819562312aae69d65f3765
LICENSE.txt LICENSE.txt d4216e39ebef5f9b50a6712ebb37beeb5379862a67733a9999c651f21592aaf0
EOF
  echo "$commit" > "$sdk/COMMIT"

  # dlss5/build.ps1: the x64 helper and its tests, the x86 protocol test client.
  # /DEPENDENTLOADFLAG:0x800 (LOAD_LIBRARY_SEARCH_SYSTEM32) makes the loader resolve the
  # executables' DLL imports (d3d12, dxgi, wintrust, ...) from System32 only.
  d5="$root/dlss5"
  d5build="$d5/build"
  mkdir -p "$d5build/x64" "$d5build/x86"
  common=(/nologo /std:c++17 /EHsc /O2 /MT /W3 /DUNICODE /D_UNICODE /DNOMINMAX /DWIN32_LEAN_AND_MEAN
    /D_CRT_SECURE_NO_WARNINGS /I"$d5/include")
  shared=("$d5/src/nr_d3d12.cpp" "$d5/src/sr_d3d12.cpp" "$d5/src/ngx_d3d12.cpp" "$d5/src/ngx_trust.cpp" "$d5/src/d3d12_util.cpp")
  ngx_libs=("$sdk/lib/nvsdk_ngx_s.lib" d3d12.lib dxgi.lib advapi32.lib user32.lib ole32.lib)
  helper64() {
    local name="$1"; shift
    cl64 "${common[@]}" "$@" /Fo"$d5build/x64/" /Fe"$d5build/x64/$name.exe" /link /MACHINE:X64 /DEPENDENTLOADFLAG:0x800
  }
  helper64 dsf-dlss5-offscreen /I"$sdk/include" "$d5/tests/offscreen_test.cpp" "$d5/tests/synthetic_scene.cpp" \
    "$d5/src/image_io.cpp" "${shared[@]}" "${ngx_libs[@]}"
  helper64 dsf-dlss5-helper /I"$sdk/include" "$d5/src/helper_main.cpp" "${shared[@]}" "${ngx_libs[@]}"
  helper64 dsf-dlss5-gpu-wait-test "$d5/tests/gpu_wait_test.cpp" "$d5/src/d3d12_util.cpp" d3d12.lib dxgi.lib
  cl32 "${common[@]}" "$d5/tests/client_test.cpp" "$d5/tests/synthetic_scene.cpp" "$d5/src/image_io.cpp" \
    d3d11.lib dxgi.lib user32.lib ole32.lib /Fo"$d5build/x86/" /Fe"$d5build/x86/dsf-dlss5-client-test.exe" \
    /link /MACHINE:X86 /DEPENDENTLOADFLAG:0x800

  mkdir -p "$dist/dlss5"
  cp "$d5build/x64/dsf-dlss5-helper.exe" "$dist/dlss5/"
  cp "$sdk/LICENSE.txt" "$dist/dlss5/NVIDIA-RTX-SDKs-LICENSE.txt"
  cp "$root/src/dlss5-folder-README.txt" "$dist/dlss5/README.txt"
  entries+=(dlss5)
fi

bsdtar -a -c -f "$dist/DSF-Enhanced.zip" -C "$dist" "${entries[@]}"

# worldlod/release/package.ps1: install.cmd, the pipeline and this build of the plugin.
wl="$root/worldlod"
stage="$dist/worldlod"
mkdir -p "$stage/app" "$stage/plugin" "$stage/licenses"
cp "$wl/pyproject.toml" "$wl/uv.lock" "$wl/README.md" "$stage/app/"
cp -r "$wl/src" "$stage/app/"
find "$stage/app/src" -type d -name __pycache__ -prune -exec rm -rf {} +
cp "$wl/release/launcher.ps1" "$stage/app/"
cp "$wl/release/install.cmd" "$wl/README.md" "$stage/"
cp "$dist/dsf_enhanced.asi" "$dist/dsf_enhanced.ini" "$dist/winmm.dll" "$dist/LICENSE" "$stage/plugin/"
cp "$wl/native/meshoptimizer/LICENSE.md" "$stage/licenses/meshoptimizer.txt"
cp "$root/third_party/Ultimate-ASI-Loader.LICENSE.txt" "$stage/licenses/Ultimate-ASI-Loader.txt"
bsdtar -a -c -f "$dist/worldlod.zip" -C "$stage" install.cmd README.md app plugin licenses
rm -rf "$stage"

echo "Built release package in $dist"
