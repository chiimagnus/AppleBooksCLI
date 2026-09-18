#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ "$(uname -m)" = "arm64" ] || fail "release packages are built on macOS arm64 hosts."

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RELEASE_METADATA="$SCRIPT_DIR/release-metadata.sh"
[ -n "${APPLEBOOKSCLI_TAG:-}" ] || fail "APPLEBOOKSCLI_TAG is required and must be the release git tag."
. "$RELEASE_METADATA" "$APPLEBOOKSCLI_TAG"
VERSION=$RELEASE_VERSION
DIST_ROOT="$REPO_ROOT/dist"
BUILD_ROOT="$DIST_ROOT/build/universal-$VERSION"
BUILD_INFO_PLIST="$BUILD_ROOT/applebookscli-Info.plist"
PACKAGE_PARENT="$DIST_ROOT/npm"
NPM_SMOKE="$REPO_ROOT/Tests/PackagingTests/npm-smoke.sh"
PACKAGE_TEMPLATE="$REPO_ROOT/packaging/npm/package.json.template"
SKILL_SYNC="$REPO_ROOT/packaging/npm/sync-installed-skill.mjs"

cd "$REPO_ROOT"

for skill_dir in skills/applebookscli skills/applebookscli-zh; do
  SKILL_VERSION=$(sed -n 's/^  cli_version: "\([^"]*\)"$/\1/p' "$skill_dir/SKILL.md")
  [ "$SKILL_VERSION" = "$VERSION" ] || fail "$skill_dir/SKILL.md cli_version must match the release tag."
done

mkdir -p "$BUILD_ROOT"
cat > "$BUILD_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>dev.chiimagnus.applebookscli</string>
  <key>CFBundleName</key>
  <string>applebookscli</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
</dict>
</plist>
PLIST

validate_thin_binary() {
  binary=$1
  arch=$2
  label=$3
  verify_root="$BUILD_ROOT/verify/$arch"
  mkdir -p "$verify_root"

  [ "$(xcrun lipo -archs "$binary")" = "$arch" ] || fail "$label must contain only $arch."
  xcrun vtool -show-build "$binary" > "$verify_root/$label.vtool.txt"
  [ "$(awk '$1 == "platform" && $2 == "MACOS" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")" -eq 1 ] || \
    fail "$label $arch slice must contain one MACOS build record."
  [ "$(awk '$1 == "minos" && $2 == "12.0" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")" -eq 1 ] || \
    fail "$label $arch slice must have minos 12.0."

  otool -L "$binary" > "$verify_root/$label.otool-L.txt"
  awk '/^[[:space:]]/ { print $1 }' "$verify_root/$label.otool-L.txt" | while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*|"") ;;
      *) fail "$label $arch slice has a non-system dynamic dependency: $dependency" ;;
    esac
  done
}

build_arch() {
  arch=$1
  scratch="$BUILD_ROOT/$arch"

  swift build \
    --disable-automatic-resolution \
    --arch "$arch" \
    --scratch-path "$scratch" \
    -c release \
    --product applebookscli \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker "$BUILD_INFO_PLIST" \
    1>&2
  swift build \
    --disable-automatic-resolution \
    --arch "$arch" \
    --scratch-path "$scratch" \
    -c release \
    --product applebookscli-pdf-worker \
    1>&2

  bin_dir=$(swift build \
    --disable-automatic-resolution \
    --arch "$arch" \
    --scratch-path "$scratch" \
    -c release \
    --show-bin-path)

  validate_thin_binary "$bin_dir/applebookscli" "$arch" applebookscli
  validate_thin_binary "$bin_dir/applebookscli-pdf-worker" "$arch" applebookscli-pdf-worker
  printf '%s\n' "$bin_dir"
}

ARM64_BIN_DIR=$(build_arch arm64)
X86_64_BIN_DIR=$(build_arch x86_64)
[ "$("$ARM64_BIN_DIR/applebookscli" --version)" = "$VERSION" ] || fail "built CLI version does not match release git tag."

PACKAGE_ROOT="$PACKAGE_PARENT/applebookscli-$VERSION"
PACKAGE_TGZ="$DIST_ROOT/chiimagnus-applebookscli-$VERSION.tgz"
rm -rf -- "$PACKAGE_PARENT"
rm -f -- "$PACKAGE_TGZ"
mkdir -p \
  "$PACKAGE_ROOT/bin" \
  "$PACKAGE_ROOT/libexec/applebookscli"

xcrun lipo -create \
  "$ARM64_BIN_DIR/applebookscli" \
  "$X86_64_BIN_DIR/applebookscli" \
  -output "$PACKAGE_ROOT/bin/applebookscli"
xcrun lipo -create \
  "$ARM64_BIN_DIR/applebookscli-pdf-worker" \
  "$X86_64_BIN_DIR/applebookscli-pdf-worker" \
  -output "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
chmod +x \
  "$PACKAGE_ROOT/bin/applebookscli" \
  "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"

cp "$SKILL_SYNC" "$PACKAGE_ROOT/libexec/applebookscli/sync-installed-skill.mjs"
codesign --force --sign - "$PACKAGE_ROOT/bin/applebookscli"
codesign --force --sign - "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
cp "$REPO_ROOT/README.md" "$PACKAGE_ROOT/README.md"
cp "$REPO_ROOT/README.zh.md" "$PACKAGE_ROOT/README.zh.md"
cp "$REPO_ROOT/LICENSE" "$PACKAGE_ROOT/LICENSE"
cp "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$PACKAGE_ROOT/THIRD_PARTY_NOTICES.md"
cp -R "$REPO_ROOT/ThirdPartyLicenses" "$PACKAGE_ROOT/ThirdPartyLicenses"
sed "s/__VERSION__/$VERSION/g" "$PACKAGE_TEMPLATE" > "$PACKAGE_ROOT/package.json"

validate_universal_binary() {
  binary=$1
  label=$2
  verify_root="$BUILD_ROOT/verify/universal"
  mkdir -p "$verify_root"

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
    fail "$label must contain exactly arm64 and x86_64 slices."

  codesign --verify --strict --verbose=2 "$binary"
  xcrun vtool -show-build "$binary" > "$verify_root/$label.vtool.txt"
  [ "$(awk '$1 == "platform" && $2 == "MACOS" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")" -eq 2 ] || \
    fail "$label universal binary must contain two MACOS build records."
  [ "$(awk '$1 == "minos" && $2 == "12.0" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")" -eq 2 ] || \
    fail "$label universal binary must contain two minos 12.0 slices."

  otool -L "$binary" > "$verify_root/$label.otool-L.txt"
  awk '/^[[:space:]]/ { print $1 }' "$verify_root/$label.otool-L.txt" | while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*|"") ;;
      *) fail "$label universal binary has a non-system dynamic dependency: $dependency" ;;
    esac
  done
}

validate_universal_binary "$PACKAGE_ROOT/bin/applebookscli" applebookscli
validate_universal_binary "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker" applebookscli-pdf-worker
[ "$("$PACKAGE_ROOT/bin/applebookscli" --version)" = "$VERSION" ] || fail "universal CLI version does not match release git tag."

node - "$PACKAGE_ROOT/package.json" "$VERSION" <<'NODE'
const fs = require('fs');
const [path, expectedVersion] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
if (pkg.name !== '@chiimagnus/applebookscli') throw new Error('unexpected npm package name');
if (pkg.version !== expectedVersion) throw new Error('npm package version mismatch');
if (JSON.stringify(pkg.os) !== JSON.stringify(['darwin'])) throw new Error('npm package must allow only darwin');
if (JSON.stringify(pkg.cpu) !== JSON.stringify(['arm64', 'x64'])) throw new Error('npm package must allow arm64 and x64');
if (pkg.scripts?.postinstall !== 'node libexec/applebookscli/sync-installed-skill.mjs') throw new Error('unexpected npm postinstall contract');
NODE

npm pack "$PACKAGE_ROOT" --pack-destination "$DIST_ROOT" >/dev/null
"$NPM_SMOKE" "$PACKAGE_TGZ" "$VERSION"
printf 'npm release package OK: %s (darwin universal: arm64 + x86_64)\n' "$PACKAGE_TGZ"
