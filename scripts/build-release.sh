#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'Usage: %s [--build-only]\n' "$(basename "$0")" >&2
  exit 64
}

BUILD_ONLY=0
case "$#" in
  0) ;;
  1)
    [ "$1" = "--build-only" ] || usage
    BUILD_ONLY=1
    ;;
  *) usage ;;
esac

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
[ "$BUILD_ONLY" -eq 0 ] || exit 0

UNIVERSAL_ROOT="$DIST_ROOT/universal"
VERIFY_ROOT="$UNIVERSAL_ROOT/verify"
UNIVERSAL_CLI="$UNIVERSAL_ROOT/applebookscli"
UNIVERSAL_WORKER="$UNIVERSAL_ROOT/applebookscli-pdf-worker"
STAGING_PARENT="$DIST_ROOT/staging"
EXTRACT_PARENT="$DIST_ROOT/extracted"

rm -rf "$UNIVERSAL_ROOT" "$STAGING_PARENT" "$EXTRACT_PARENT"
mkdir -p "$UNIVERSAL_ROOT" "$VERIFY_ROOT"

xcrun lipo -create \
  "$ARM64_BIN_DIR/applebookscli" \
  "$X86_64_BIN_DIR/applebookscli" \
  -output "$UNIVERSAL_CLI"
xcrun lipo -create \
  "$ARM64_BIN_DIR/applebookscli-pdf-worker" \
  "$X86_64_BIN_DIR/applebookscli-pdf-worker" \
  -output "$UNIVERSAL_WORKER"
chmod +x "$UNIVERSAL_CLI" "$UNIVERSAL_WORKER"

assert_universal_archs() {
  binary=$1
  label=$2
  arch_count=0
  has_arm64=0
  has_x86_64=0
  for arch in $(xcrun lipo -archs "$binary"); do
    arch_count=$((arch_count + 1))
    case "$arch" in
      arm64) has_arm64=1 ;;
      x86_64) has_x86_64=1 ;;
      *) fail "$label contains unexpected architecture: $arch" ;;
    esac
  done
  [ "$arch_count" -eq 2 ] && [ "$has_arm64" -eq 1 ] && [ "$has_x86_64" -eq 1 ] || \
    fail "$label must contain exactly arm64 and x86_64."
}

validate_universal_binary() {
  binary=$1
  label=$2

  [ -x "$binary" ] || fail "$label universal binary is missing or not executable."
  file "$binary" > "$VERIFY_ROOT/$label.file.txt"
  assert_universal_archs "$binary" "$label"

  codesign --force --sign - "$binary"
  codesign --verify --strict --verbose=2 "$binary"

  xcrun vtool -show-build "$binary" > "$VERIFY_ROOT/$label.vtool.txt"
  platform_count=$(awk '$1 == "platform" && $2 == "MACOS" { count += 1 } END { print count + 0 }' "$VERIFY_ROOT/$label.vtool.txt")
  minos_count=$(awk '$1 == "minos" && $2 == "12.0" { count += 1 } END { print count + 0 }' "$VERIFY_ROOT/$label.vtool.txt")
  [ "$platform_count" -eq 2 ] || fail "$label universal binary must contain two MACOS build records."
  [ "$minos_count" -eq 2 ] || fail "$label universal binary must contain two minos 12.0 slices."

  otool -L "$binary" > "$VERIFY_ROOT/$label.otool-L.txt"
  awk '/^[[:space:]]/ { print $1 }' "$VERIFY_ROOT/$label.otool-L.txt" | while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) ;;
      @rpath/*) fail "$label has an unresolved @rpath dependency: $dependency" ;;
      "") ;;
      *) fail "$label has a non-system dynamic dependency: $dependency" ;;
    esac
  done
}

validate_universal_binary "$UNIVERSAL_CLI" applebookscli
validate_universal_binary "$UNIVERSAL_WORKER" applebookscli-pdf-worker

VERSION=$("$UNIVERSAL_CLI" --version)
case "$VERSION" in
  ""|*[!A-Za-z0-9._-]*) fail "applebookscli --version returned an unsafe archive version." ;;
esac

STAGING_NAME="applebookscli-$VERSION-macos-universal"
STAGING_ROOT="$STAGING_PARENT/$STAGING_NAME"
mkdir -p \
  "$STAGING_ROOT/bin" \
  "$STAGING_ROOT/libexec/applebookscli"
cp "$UNIVERSAL_CLI" "$STAGING_ROOT/bin/applebookscli"
cp "$UNIVERSAL_WORKER" "$STAGING_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
cp "$REPO_ROOT/LICENSE" "$STAGING_ROOT/LICENSE"
cp "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$STAGING_ROOT/THIRD_PARTY_NOTICES.md"
cp -R "$REPO_ROOT/ThirdPartyLicenses" "$STAGING_ROOT/ThirdPartyLicenses"

ARCHIVE="$DIST_ROOT/$STAGING_NAME.tar.gz"
CHECKSUM="$ARCHIVE.sha256"
rm -f "$ARCHIVE" "$CHECKSUM"
tar -czf "$ARCHIVE" -C "$STAGING_PARENT" "$STAGING_NAME"
(
  cd "$DIST_ROOT"
  archive_name=$(basename "$ARCHIVE")
  checksum_name=$(basename "$CHECKSUM")
  shasum -a 256 "$archive_name" > "$checksum_name"
  shasum -a 256 -c "$checksum_name"
)

mkdir -p "$EXTRACT_PARENT"
tar -xzf "$ARCHIVE" -C "$EXTRACT_PARENT"
EXTRACTED_ROOT="$EXTRACT_PARENT/$STAGING_NAME"
EXTRACTED_CLI="$EXTRACTED_ROOT/bin/applebookscli"
EXTRACTED_WORKER="$EXTRACTED_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
[ -x "$EXTRACTED_CLI" ] || fail "extracted CLI is missing or not executable."
[ -x "$EXTRACTED_WORKER" ] || fail "extracted PDF worker is missing or not executable."
codesign --verify --strict --verbose=2 "$EXTRACTED_CLI"
codesign --verify --strict --verbose=2 "$EXTRACTED_WORKER"

EXTRACTED_VERSION=$(cd / && "$EXTRACTED_CLI" --version)
[ "$EXTRACTED_VERSION" = "$VERSION" ] || fail "extracted CLI version does not match the archive version."
(cd / && "$EXTRACTED_CLI" --help >/dev/null)

SMOKE_ROOT="$EXTRACT_PARENT/smoke"
SMOKE_HOME="$SMOKE_ROOT/home"
SMOKE_LIBRARY="$SMOKE_ROOT/library.sqlite"
SMOKE_ANNOTATIONS="$SMOKE_ROOT/annotations.sqlite"
SMOKE_PDF_STDOUT="$SMOKE_ROOT/pdf.stdout.json"
SMOKE_PDF_STDERR="$SMOKE_ROOT/pdf.stderr.txt"
SMOKE_WORKER_STDERR="$SMOKE_ROOT/worker.stderr.txt"
PDF_FIXTURE="$REPO_ROOT/Tests/Fixtures/PDF/corrupt.pdf"
mkdir -p "$SMOKE_HOME"
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required for the extracted release smoke."
[ -f "$PDF_FIXTURE" ] || fail "synthetic PDF fixture is missing."
sqlite3 "$SMOKE_LIBRARY" 'CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZCONTENTTYPE INTEGER);'
sqlite3 "$SMOKE_ANNOTATIONS" 'CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY);'

(
  cd /
  HOME="$SMOKE_HOME" CFFIXED_USER_HOME="$SMOKE_HOME" \
    "$EXTRACTED_CLI" pdf highlights \
      --path "$PDF_FIXTURE" \
      --library-db "$SMOKE_LIBRARY" \
      --annotations-db "$SMOKE_ANNOTATIONS" \
      --json
) > "$SMOKE_PDF_STDOUT" 2> "$SMOKE_PDF_STDERR"
[ ! -s "$SMOKE_PDF_STDERR" ] || fail "extracted CLI PDF smoke wrote unexpected diagnostics."
pdf_smoke=$(cat "$SMOKE_PDF_STDOUT")
case "$pdf_smoke" in
  *'"attemptedCount":1'*'"failedCount":1'*'"reason":"unreadableDocument"'*'"provenance":"explicit"'*) ;;
  *) fail "extracted CLI did not reach the relative PDF worker with the synthetic fixture." ;;
esac

worker_smoke=$(cd / && printf '{}' | "$EXTRACTED_WORKER" 2> "$SMOKE_WORKER_STDERR")
case "$worker_smoke" in
  *'"errorCode":"malformedRequest"'*'"status":"failure"'*) ;;
  *) fail "extracted universal worker protocol smoke failed." ;;
esac
[ "$(cat "$SMOKE_WORKER_STDERR")" = "malformedRequest" ] || fail "extracted worker stderr code is unstable."

git diff --exit-code -- Package.resolved >/dev/null || fail "Package.resolved changed during release packaging."
printf 'release archive OK: %s (%s host-native smoke; Intel runtime not asserted here)\n' "$ARCHIVE" "$(uname -m)"
