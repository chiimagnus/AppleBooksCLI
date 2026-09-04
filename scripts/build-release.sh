#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ "$(uname -m)" = "arm64" ] || fail "release packages are built only on macOS arm64 hosts."

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
RELEASE_METADATA="$SCRIPT_DIR/release-metadata.sh"
[ -n "${APPLEBOOKSCLI_TAG:-}" ] || fail "APPLEBOOKSCLI_TAG is required and must be the release git tag."
. "$RELEASE_METADATA" "$APPLEBOOKSCLI_TAG"
VERSION=$RELEASE_VERSION
DIST_ROOT="$REPO_ROOT/dist"
BUILD_ROOT="$DIST_ROOT/build/arm64-$VERSION"
BUILD_INFO_PLIST="$BUILD_ROOT/applebookscli-Info.plist"
PACKAGE_PARENT="$DIST_ROOT/npm"
NPM_SMOKE="$REPO_ROOT/Tests/PackagingTests/npm-smoke.sh"
PACKAGE_TEMPLATE="$REPO_ROOT/packaging/npm/package.json.template"

cd "$REPO_ROOT"

mkdir -p "$BUILD_ROOT"
cat > "$BUILD_INFO_PLIST" <<EOF
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
EOF
swift build \
  --disable-automatic-resolution \
  --arch arm64 \
  --scratch-path "$BUILD_ROOT" \
  -c release \
  --product applebookscli \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "$BUILD_INFO_PLIST"
swift build \
  --disable-automatic-resolution \
  --arch arm64 \
  --scratch-path "$BUILD_ROOT" \
  -c release \
  --product applebookscli-pdf-worker

BIN_DIR=$(swift build \
  --disable-automatic-resolution \
  --arch arm64 \
  --scratch-path "$BUILD_ROOT" \
  -c release \
  --show-bin-path)
BUILT_CLI="$BIN_DIR/applebookscli"
BUILT_WORKER="$BIN_DIR/applebookscli-pdf-worker"

validate_arm64_binary() {
  binary=$1
  label=$2
  verify_root="$BUILD_ROOT/verify"
  mkdir -p "$verify_root"

  [ "$(xcrun lipo -archs "$binary")" = "arm64" ] || fail "$label must contain only arm64."
  xcrun vtool -show-build "$binary" > "$verify_root/$label.vtool.txt"
  [ "$(awk '$1 == "platform" && $2 == "MACOS" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")" -eq 1 ] || \
    fail "$label must contain one MACOS build record."
  [ "$(awk '$1 == "minos" && $2 == "12.0" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")" -eq 1 ] || \
    fail "$label must have minos 12.0."

  otool -L "$binary" > "$verify_root/$label.otool-L.txt"
  awk '/^[[:space:]]/ { print $1 }' "$verify_root/$label.otool-L.txt" | while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*|"") ;;
      *) fail "$label has a non-system dynamic dependency: $dependency" ;;
    esac
  done
}

validate_arm64_binary "$BUILT_CLI" applebookscli
validate_arm64_binary "$BUILT_WORKER" applebookscli-pdf-worker
[ "$("$BUILT_CLI" --version)" = "$VERSION" ] || fail "built CLI version does not match release git tag."

PACKAGE_ROOT="$PACKAGE_PARENT/applebookscli-$VERSION"
PACKAGE_TGZ="$DIST_ROOT/chiimagnus-applebookscli-$VERSION.tgz"
rm -rf -- "$PACKAGE_PARENT"
rm -f -- "$PACKAGE_TGZ"
mkdir -p \
  "$PACKAGE_ROOT/bin" \
  "$PACKAGE_ROOT/libexec/applebookscli"

cp "$BUILT_CLI" "$PACKAGE_ROOT/bin/applebookscli"
cp "$BUILT_WORKER" "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
codesign --force --sign - "$PACKAGE_ROOT/bin/applebookscli"
codesign --force --sign - "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
cp "$REPO_ROOT/README.md" "$PACKAGE_ROOT/README.md"
cp "$REPO_ROOT/LICENSE" "$PACKAGE_ROOT/LICENSE"
cp "$REPO_ROOT/THIRD_PARTY_NOTICES.md" "$PACKAGE_ROOT/THIRD_PARTY_NOTICES.md"
cp -R "$REPO_ROOT/ThirdPartyLicenses" "$PACKAGE_ROOT/ThirdPartyLicenses"
sed "s/__VERSION__/$VERSION/g" "$PACKAGE_TEMPLATE" > "$PACKAGE_ROOT/package.json"

node - "$PACKAGE_ROOT/package.json" "$VERSION" <<'NODE'
const fs = require('fs');
const [path, expectedVersion] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
if (pkg.name !== '@chiimagnus/applebookscli') throw new Error('unexpected npm package name');
if (pkg.version !== expectedVersion) throw new Error('npm package version mismatch');
if (JSON.stringify(pkg.os) !== JSON.stringify(['darwin'])) throw new Error('npm package must allow only darwin');
if (JSON.stringify(pkg.cpu) !== JSON.stringify(['arm64'])) throw new Error('npm package must allow only arm64');
if (pkg.scripts) throw new Error('release package must not contain install scripts');
NODE

npm pack "$PACKAGE_ROOT" --pack-destination "$DIST_ROOT" >/dev/null
"$NPM_SMOKE" "$PACKAGE_TGZ" "$VERSION"
printf 'npm release package OK: %s (darwin-arm64 only)\n' "$PACKAGE_TGZ"
