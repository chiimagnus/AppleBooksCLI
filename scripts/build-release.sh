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
BUILD_ROOT="$DIST_ROOT/build/arm64-$VERSION"
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
  [ "$(awk '$1 == "minos" && $2 == "15.6" { count += 1 } END { print count + 0 }' "$verify_root/$label.vtool.txt")" -eq 1 ] || \
    fail "$label $arch slice must have minos 15.6."

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
[ "$("$ARM64_BIN_DIR/applebookscli" --version)" = "$VERSION" ] || fail "built CLI version does not match release git tag."

PACKAGE_ROOT="$PACKAGE_PARENT/applebookscli-$VERSION"
PACKAGE_TGZ="$DIST_ROOT/chiimagnus-applebookscli-$VERSION.tgz"
rm -rf -- "$PACKAGE_PARENT"
rm -f -- "$PACKAGE_TGZ"
mkdir -p \
  "$PACKAGE_ROOT/bin" \
  "$PACKAGE_ROOT/libexec/applebookscli"

cp "$ARM64_BIN_DIR/applebookscli" "$PACKAGE_ROOT/bin/applebookscli"
cp "$ARM64_BIN_DIR/applebookscli-pdf-worker" "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
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

validate_thin_binary "$PACKAGE_ROOT/bin/applebookscli" arm64 applebookscli
validate_thin_binary "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker" arm64 applebookscli-pdf-worker
[ "$("$PACKAGE_ROOT/bin/applebookscli" --version)" = "$VERSION" ] || fail "packaged CLI version does not match release git tag."

node - "$PACKAGE_ROOT/package.json" "$VERSION" <<'NODE'
const fs = require('fs');
const [path, expectedVersion] = process.argv.slice(2);
const pkg = JSON.parse(fs.readFileSync(path, 'utf8'));
if (pkg.name !== '@chiimagnus/applebookscli') throw new Error('unexpected npm package name');
if (pkg.version !== expectedVersion) throw new Error('npm package version mismatch');
if (JSON.stringify(pkg.os) !== JSON.stringify(['darwin'])) throw new Error('npm package must allow only darwin');
if (JSON.stringify(pkg.cpu) !== JSON.stringify(['arm64'])) throw new Error('npm package must allow only arm64');
if (pkg.scripts?.postinstall !== 'node libexec/applebookscli/sync-installed-skill.mjs') throw new Error('unexpected npm postinstall contract');
NODE

npm pack "$PACKAGE_ROOT" --pack-destination "$DIST_ROOT" >/dev/null
"$NPM_SMOKE" "$PACKAGE_TGZ" "$VERSION"
printf 'npm release package OK: %s (darwin arm64, macOS 15.6+)\n' "$PACKAGE_TGZ"
