#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 0 ] || fail "build-release.sh does not accept arguments."
[ "$(uname -m)" = "arm64" ] || fail "release packages are built only on macOS arm64 hosts."

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
DIST_ROOT="$REPO_ROOT/dist"
BUILD_ROOT="$DIST_ROOT/build/arm64"
PACKAGE_PARENT="$DIST_ROOT/npm"
EXTRACT_ROOT="$DIST_ROOT/extracted/npm"
SKILL_SOURCE="$REPO_ROOT/Skill/applebookscli"
SKILL_SMOKE="$REPO_ROOT/Tests/PackagingTests/skill-smoke.sh"
NPM_SMOKE="$REPO_ROOT/Tests/PackagingTests/npm-smoke.sh"
PACKAGE_TEMPLATE="$REPO_ROOT/packaging/npm/package.json.template"

cd "$REPO_ROOT"
[ -f Package.resolved ] || fail "Package.resolved is required for release builds."
[ -x "$SKILL_SMOKE" ] || fail "Skill packaging smoke is missing or not executable."
[ -x "$NPM_SMOKE" ] || fail "npm install smoke is missing or not executable."
[ -f "$PACKAGE_TEMPLATE" ] || fail "npm package template is missing."
command -v npm >/dev/null 2>&1 || fail "npm is required for release packaging."
command -v node >/dev/null 2>&1 || fail "node is required for release packaging."

"$SKILL_SMOKE" "$SKILL_SOURCE"
mkdir -p "$BUILD_ROOT"

swift build \
  --disable-automatic-resolution \
  --arch arm64 \
  --scratch-path "$BUILD_ROOT" \
  -c release \
  --product applebookscli
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

  [ -x "$binary" ] || fail "$label is missing or not executable: $binary"
  [ "$(xcrun lipo -archs "$binary")" = "arm64" ] || fail "$label must contain only arm64."
  file "$binary" | grep -F 'Mach-O 64-bit executable arm64' >/dev/null || fail "$label is not an arm64 Mach-O executable."
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

VERSION=$("$BUILT_CLI" --version)
case "$VERSION" in
  ""|*[!A-Za-z0-9._-]*) fail "applebookscli --version returned an unsafe package version." ;;
esac

PACKAGE_ROOT="$PACKAGE_PARENT/applebookscli-$VERSION"
PACKAGE_TGZ="$DIST_ROOT/chiimagnus-applebookscli-$VERSION.tgz"
CHECKSUM="$PACKAGE_TGZ.sha256"
rm -rf -- "$PACKAGE_PARENT" "$EXTRACT_ROOT"
rm -f -- "$PACKAGE_TGZ" "$CHECKSUM"
mkdir -p \
  "$PACKAGE_ROOT/bin" \
  "$PACKAGE_ROOT/libexec/applebookscli" \
  "$PACKAGE_ROOT/share/applebookscli/skill/applebookscli" \
  "$EXTRACT_ROOT"

cp "$BUILT_CLI" "$PACKAGE_ROOT/bin/applebookscli"
cp "$BUILT_WORKER" "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
chmod +x "$PACKAGE_ROOT/bin/applebookscli" "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
codesign --force --sign - "$PACKAGE_ROOT/bin/applebookscli"
codesign --force --sign - "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
codesign --verify --strict --verbose=2 "$PACKAGE_ROOT/bin/applebookscli"
codesign --verify --strict --verbose=2 "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"

cp "$SKILL_SOURCE/SKILL.md" "$PACKAGE_ROOT/share/applebookscli/skill/applebookscli/SKILL.md"
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
if (pkg.bin?.applebookscli !== 'bin/applebookscli') throw new Error('npm bin contract mismatch');
if (pkg.scripts) throw new Error('release package must not contain install scripts');
NODE

npm pack "$PACKAGE_ROOT" --pack-destination "$DIST_ROOT" >/dev/null
[ -f "$PACKAGE_TGZ" ] || fail "npm pack did not create the expected package: $PACKAGE_TGZ"
(
  cd "$DIST_ROOT"
  shasum -a 256 "$(basename "$PACKAGE_TGZ")" > "$(basename "$CHECKSUM")"
  shasum -a 256 -c "$(basename "$CHECKSUM")"
)

tar -xzf "$PACKAGE_TGZ" -C "$EXTRACT_ROOT"
EXTRACTED="$EXTRACT_ROOT/package"
EXTRACTED_CLI="$EXTRACTED/bin/applebookscli"
EXTRACTED_WORKER="$EXTRACTED/libexec/applebookscli/applebookscli-pdf-worker"
EXTRACTED_SKILL="$EXTRACTED/share/applebookscli/skill/applebookscli"
[ -x "$EXTRACTED_CLI" ] || fail "extracted npm CLI is missing or not executable."
[ -x "$EXTRACTED_WORKER" ] || fail "extracted npm PDF worker is missing or not executable."
[ "$(xcrun lipo -archs "$EXTRACTED_CLI")" = "arm64" ] || fail "extracted npm CLI is not arm64-only."
[ "$(xcrun lipo -archs "$EXTRACTED_WORKER")" = "arm64" ] || fail "extracted npm worker is not arm64-only."
codesign --verify --strict --verbose=2 "$EXTRACTED_CLI"
codesign --verify --strict --verbose=2 "$EXTRACTED_WORKER"
"$SKILL_SMOKE" "$EXTRACTED_SKILL"
cmp "$SKILL_SOURCE/SKILL.md" "$EXTRACTED_SKILL/SKILL.md"
[ "$(cd / && "$EXTRACTED_CLI" --version)" = "$VERSION" ] || fail "extracted npm CLI version mismatch."
(cd / && "$EXTRACTED_CLI" --help >/dev/null)

ARCHIVE_LIST="$EXTRACT_ROOT/archive-contents.txt"
tar -tzf "$PACKAGE_TGZ" > "$ARCHIVE_LIST"
for required in \
  package/package.json \
  package/bin/applebookscli \
  package/libexec/applebookscli/applebookscli-pdf-worker \
  package/share/applebookscli/skill/applebookscli/SKILL.md \
  package/LICENSE \
  package/THIRD_PARTY_NOTICES.md; do
  grep -Fx "$required" "$ARCHIVE_LIST" >/dev/null || fail "npm package is missing required entry: $required"
done
while IFS= read -r entry; do
  case "$entry" in
    *"/.github/"*|*"/.build/"*|*"/Tests/"*|*"/tests/"*|*"/config.json"|*"/private-"*)
      fail "npm package contains forbidden development or private path: $entry"
      ;;
  esac
done < "$ARCHIVE_LIST"

"$NPM_SMOKE" "$PACKAGE_TGZ" "$VERSION"
git diff --exit-code -- Package.resolved >/dev/null || fail "Package.resolved changed during release packaging."
printf 'npm release package OK: %s (darwin-arm64 only)\n' "$PACKAGE_TGZ"
