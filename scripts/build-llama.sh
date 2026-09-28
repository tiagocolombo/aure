#!/usr/bin/env bash
# Build a self-contained universal llama-server for Aure.
#
#   scripts/build-llama.sh            # arm64 (Metal) + x86_64 (CPU), lipo'd
#   AURE_ARCHS=native scripts/build-llama.sh   # this machine only (faster)
#
# Output: build/llama/llama-server  (static: no dylibs, no Homebrew, no curl)
# Source: vendor/llama.cpp, a shallow checkout of the tag in scripts/llama.version,
# verified against the commit pinned next to it (a tag can be moved upstream).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
root="$AURE_ROOT"
read -r tag commit < "$root/scripts/llama.version"
[ -n "${commit:-}" ] || { echo "error: scripts/llama.version must be '<tag> <commit sha>'"; exit 1; }
src="$root/vendor/llama.cpp"
out="$root/build/llama"
jobs="$(sysctl -n hw.ncpu)"

command -v cmake >/dev/null || { echo "cmake not found: run inside the dev shell (dev llama) or brew install cmake"; exit 1; }
cmake_bin="$(command -v cmake)"

if [ ! -d "$src/.git" ] || [ "$(git -C "$src" rev-parse HEAD 2>/dev/null)" != "$commit" ]; then
  echo "==> fetching llama.cpp $tag"
  rm -rf "$src"
  git clone --quiet --depth 1 --branch "$tag" https://github.com/ggml-org/llama.cpp "$src"
fi
actual="$(git -C "$src" rev-parse HEAD)"
if [ "$actual" != "$commit" ]; then
  echo "error: llama.cpp $tag is commit $actual, expected $commit (pinned in scripts/llama.version)"
  exit 1
fi

build_slice() {
  local arch="$1" dir="$root/build/llama-$1"
  local metal=OFF native=OFF
  [ "$arch" = arm64 ] && metal=ON
  # A native x86_64 build on this Mac may use AVX-512 etc. that other Intel
  # Macs lack, so pin a portable baseline (AVX2/FMA/F16C: Haswell, 2013+).
  local cpu_flags=()
  if [ "$arch" = x86_64 ]; then
    cpu_flags=(-DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON)
  else
    cpu_flags=(-DGGML_NATIVE=$native)
  fi
  echo "==> configuring llama.cpp for $arch (metal=$metal)"
  apple "$cmake_bin" -S "$src" -B "$dir" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=$metal -DGGML_METAL_EMBED_LIBRARY=$metal \
    -DGGML_BLAS=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON \
    "${cpu_flags[@]}" > "$dir.configure.log"
  echo "==> building llama-server for $arch"
  apple "$cmake_bin" --build "$dir" --config Release --target llama-server -j "$jobs" > "$dir.build.log"
  echo "$dir/bin/llama-server"
}

if [ "${AURE_ARCHS:-universal}" = universal ]; then
  archs=(arm64 x86_64)
else
  archs=("$(uname -m)")
fi

slices=()
for a in "${archs[@]}"; do
  mkdir -p "$root/build"
  slices+=("$(build_slice "$a" | tail -1)")
done

mkdir -p "$out"
apple lipo -create "${slices[@]}" -output "$out/llama-server"
chmod +x "$out/llama-server"
echo "$tag" > "$out/VERSION"

echo "==> $(apple lipo -archs "$out/llama-server") -> $out/llama-server"
# Check every slice. otool prints a "<file> (architecture X):" header per slice
# (on Apple Silicon hosts even without -arch all), so only inspect the indented
# library lines, never the headers.
if apple otool -arch all -L "$out/llama-server" | grep -E '^[[:space:]]' | grep -vE '^[[:space:]]*(/usr/lib/|/System/Library/)'; then
  echo "error: llama-server links non-system libraries (see above)"; exit 1
fi
"$out/llama-server" --version 2>&1 | head -2 || true
