#!/usr/bin/env bash
# Shared helpers for scripts/*. Source it: . "$(dirname "$0")/lib.sh"
#
# The Nix dev shell exports its own Apple SDK, compilers and linker flags
# (SDKROOT, DEVELOPER_DIR, CC, NIX_*), which break Apple's Swift toolchain.
# `apple` runs a command with those removed so Swift, xcrun, clang and cmake
# use the system toolchain (Xcode or the Command Line Tools).

AURE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

apple() {
  env -u SDKROOT -u DEVELOPER_DIR -u NIX_APPLE_SDK_VERSION \
      -u CC -u CXX -u LD -u AR -u NM -u RANLIB -u STRIP -u OBJC -u OBJCXX \
      -u NIX_CFLAGS_COMPILE -u NIX_LDFLAGS -u NIX_CC -u NIX_BINTOOLS \
      -u MACOSX_DEPLOYMENT_TARGET -u CFLAGS -u CXXFLAGS -u LDFLAGS \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(apple_extra_path)" \
      "$@"
}

# Keep non-compiler tools from the dev shell (cmake, node, pnpm, gh) reachable,
# but after /usr/bin so Apple's clang, ld, lipo and swift win.
apple_extra_path() {
  local p out=""
  local IFS=:
  for p in $PATH; do
    case "$p" in
      /nix/store/*clang*|/nix/store/*cctools*|/nix/store/*binutils*|/nix/store/*xcbuild*|/nix/store/*apple-sdk*) ;;
      *) out="${out:+$out:}$p" ;;
    esac
  done
  printf '%s' "$out"
}
