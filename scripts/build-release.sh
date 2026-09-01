#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'Usage: %s --build-only\n' "$(basename "$0")" >&2
  exit 64
}

[ "$#" -eq 1 ] || usage
[ "$1" = "--build-only" ] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DIST_ROOT="$REPO_ROOT/dist"
BUILD_ROOT="$DIST_ROOT/build"

cd "$REPO_ROOT"
[ -f Package.resolved ] || fail "Package.resolved is required for release builds."
mkdir -p "$BUILD_ROOT/arm64" "$BUILD_ROOT/x86_64"

validate_thin_binary() {
  binary=$1
  expected_arch=$2
  label=$3
  verify_root="$BUILD_ROOT/verify/$expected_arch"
  mkdir -p "$verify_root"

  [ -x "$binary" ] || fail "$label is missing or not executable: $binary"

  file_output=$(file "$binary")
  case "$file_output" in
    *"Mach-O 64-bit executable $expected_arch"*) ;;
    *) fail "$label is not a $expected_arch Mach-O executable: $file_output" ;;
  esac

  lipo_output=$(lipo -info "$binary")
  case "$lipo_output" in
    *"architecture: $expected_arch") ;;
    *) fail "$label is not a thin $expected_arch binary: $lipo_output" ;;
  esac

  otool -hv "$binary" > "$verify_root/$label.otool.txt"
  xcrun vtool -show-build "$binary" > "$verify_root/$label.vtool.txt"

  platform_count=$(awk '$1 == "platform" && $2 == "MACOS" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")
  minos_count=$(awk '$1 == "minos" && $2 == "12.0" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")
  [ "$platform_count" -eq 1 ] || fail "$label $expected_arch slice must target platform MACOS."
  [ "$minos_count" -eq 1 ] || fail "$label $expected_arch slice must have minos 12.0."
}

build_arch() {
  build_arch_name=$1
  scratch="$BUILD_ROOT/$build_arch_name"

  swift build \
    --disable-automatic-resolution \
    --arch "$build_arch_name" \
    --scratch-path "$scratch" \
    -c release \
    --product applebookscli

  swift build \
    --disable-automatic-resolution \
    --arch "$build_arch_name" \
    --scratch-path "$scratch" \
    -c release \
    --product applebookscli-pdf-worker

  BUILT_BIN_DIR=$(swift build \
    --disable-automatic-resolution \
    --arch "$build_arch_name" \
    --scratch-path "$scratch" \
    -c release \
    --show-bin-path)

  validate_thin_binary "$BUILT_BIN_DIR/applebookscli" "$build_arch_name" applebookscli
  validate_thin_binary "$BUILT_BIN_DIR/applebookscli-pdf-worker" "$build_arch_name" applebookscli-pdf-worker
}

build_arch arm64
ARM64_BIN_DIR=$BUILT_BIN_DIR
build_arch x86_64
X86_64_BIN_DIR=$BUILT_BIN_DIR

smoke_native_slice() {
  native_arch=$1
  native_bin_dir=$2
  smoke_root="$BUILD_ROOT/smoke/$native_arch"
  mkdir -p "$smoke_root"

  version_output=$("$native_bin_dir/applebookscli" --version)
  [ -n "$version_output" ] || fail "native $native_arch applebookscli --version returned empty output."

  printf '{}' | "$native_bin_dir/applebookscli-pdf-worker" \
    > "$smoke_root/worker.stdout.json" \
    2> "$smoke_root/worker.stderr.txt"

  worker_stdout=$(cat "$smoke_root/worker.stdout.json")
  worker_stderr=$(cat "$smoke_root/worker.stderr.txt")
  case "$worker_stdout" in
    *'"errorCode":"malformedRequest"'*) ;;
    *) fail "native $native_arch worker did not return malformedRequest protocol envelope." ;;
  esac
  [ "$worker_stderr" = "malformedRequest" ] || fail "native $native_arch worker stderr code is unstable."
}

case "$(uname -m)" in
  arm64) smoke_native_slice arm64 "$ARM64_BIN_DIR" ;;
  x86_64) smoke_native_slice x86_64 "$X86_64_BIN_DIR" ;;
  *) fail "unsupported build host architecture: $(uname -m)" ;;
esac

git diff --exit-code -- Package.resolved >/dev/null || fail "Package.resolved changed during release build."

printf 'release thin build OK: arm64=%s x86_64=%s\n' "$ARM64_BIN_DIR" "$X86_64_BIN_DIR"
