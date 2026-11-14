#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

PACKAGE=$1
EXPECTED_VERSION=$2

SMOKE_PARENT=$(getconf DARWIN_USER_TEMP_DIR)
SMOKE_ROOT=$(mktemp -d "${SMOKE_PARENT%/}/applebookscli-npm-smoke.XXXXXX")
cleanup() {
  case "$SMOKE_ROOT" in
    "${SMOKE_PARENT%/}"/applebookscli-npm-smoke.*) rm -rf -- "$SMOKE_ROOT" ;;
    *) fail "refusing to clean unexpected npm smoke root: $SMOKE_ROOT" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

PREFIX="$SMOKE_ROOT/prefix"
HOME_ROOT="$SMOKE_ROOT/home"
FAKE_BIN="$SMOKE_ROOT/fake-bin"
SKILL_LOCK="$HOME_ROOT/.agents/.skill-lock.json"
NPX_CALL="$SMOKE_ROOT/npx-call.txt"
mkdir -p "$PREFIX" "$HOME_ROOT/.agents" "$FAKE_BIN"
cat > "$SKILL_LOCK" <<'JSON'
{
  "version": 3,
  "skills": {
    "applebookscli": {
      "source": "chiimagnus/AppleBooksCLI",
      "sourceUrl": "https://github.com/chiimagnus/AppleBooksCLI.git",
      "sourceType": "github",
      "ref": "v0.0.0",
      "skillPath": "skills/applebookscli",
      "skillFolderHash": "fixture"
    },
    "applebookscli-zh": {
      "source": "chiimagnus/AppleBooksCLI",
      "sourceUrl": "https://github.com/chiimagnus/AppleBooksCLI.git",
      "sourceType": "github",
      "ref": "v0.0.0",
      "skillPath": "skills/applebookscli-zh",
      "skillFolderHash": "fixture"
    }
  }
}
JSON
cat > "$FAKE_BIN/npx" <<EOF
#!/bin/sh
printf '%s\\n' "\$*" > "$NPX_CALL"
EOF
chmod +x "$FAKE_BIN/npx"

HOME="$HOME_ROOT" CFFIXED_USER_HOME="$HOME_ROOT" PATH="$FAKE_BIN:$PATH" \
  npm install --global --prefix "$PREFIX" "$PACKAGE" >/dev/null
node - "$SKILL_LOCK" "v$EXPECTED_VERSION" <<'NODE' || fail "npm postinstall did not align managed Skill refs with the CLI version."
const [path, expected] = process.argv.slice(2);
const value = require(path);
for (const name of ["applebookscli", "applebookscli-zh"]) {
  if (value.skills[name].ref !== expected) process.exit(1);
}
NODE
grep -Fx -- "-y skills@1.5.23 update applebookscli applebookscli-zh -g -y" "$NPX_CALL" >/dev/null || \
  fail "npm postinstall did not delegate managed Skill updates to Agent Skills CLI."
CLI="$PREFIX/bin/applebookscli"
[ "$(cd / && "$CLI" --version)" = "$EXPECTED_VERSION" ] || fail "npm-installed CLI version mismatch."
(cd / && "$CLI" --help >/dev/null)

PACKAGE_ROOT="$PREFIX/lib/node_modules/@chiimagnus/applebookscli"
[ "$(xcrun lipo -archs "$CLI")" = arm64 ] || \
  fail "npm-installed binary must contain only arm64: $CLI"
xcrun vtool -show-build "$CLI" | grep -Eq 'minos[[:space:]]+15\.6' || \
  fail "npm-installed binary must target macOS 15.6: $CLI"
# Reject an unstripped release, and ensure stripping did not break signing or the native version.
BINARY_BYTES=$(stat -f %z "$PACKAGE_ROOT/bin/applebookscli")
[ "$BINARY_BYTES" -lt 8000000 ] || \
  fail "npm-installed release binary retains excess symbols ($BINARY_BYTES bytes)."
EXPORTED_SYMBOLS=$(xcrun otool -l "$PACKAGE_ROOT/bin/applebookscli" | \
  awk '/cmd LC_DYSYMTAB/ { in_table = 1 } in_table && $1 == "nextdefsym" { print $2; exit }')
[ "${EXPORTED_SYMBOLS:-999999}" -le 2 ] || \
  fail "npm-installed release binary retains unstripped exported symbols."
codesign --verify --strict "$CLI" || fail "npm-installed release signature is invalid."
strings "$CLI" | grep -Fq "<string>$EXPECTED_VERSION</string>" || \
  fail "release executable lost its native application version metadata."
rm -f "$NPX_CALL"
EMPTY_HOME="$SMOKE_ROOT/empty-home"
mkdir -p "$EMPTY_HOME"
HOME="$EMPTY_HOME" CFFIXED_USER_HOME="$EMPTY_HOME" PATH="$FAKE_BIN:$PATH" \
  node "$PACKAGE_ROOT/libexec/applebookscli/sync-installed-skill.mjs"
[ ! -e "$NPX_CALL" ] || fail "Skill sync must be a no-op when no managed Skill is installed."
[ ! -e "$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker" ] || \
  fail "PDF worker must not be installed by v0.5.0 or later."
"$CLI" --help > "$SMOKE_ROOT/help.stdout"
if grep -Eq '^[[:space:]]+pdf[[:space:]]' "$SMOKE_ROOT/help.stdout"; then
  fail "PDF command remains visible in root help."
fi
if "$CLI" pdf list > "$SMOKE_ROOT/pdf.stdout" 2> "$SMOKE_ROOT/pdf.stderr"; then
  fail "PDF command must not exist in v0.5.0 or later."
fi
[ ! -s "$SMOKE_ROOT/pdf.stdout" ] || fail "removed PDF command emitted primary output."
for removed_option in --pdf --source; do
  if "$CLI" export "$removed_option" pdf --output "$SMOKE_ROOT/export.md" \
    > "$SMOKE_ROOT/export.stdout" 2> "$SMOKE_ROOT/export.stderr"; then
    fail "removed export option unexpectedly accepted: $removed_option"
  fi
  [ ! -e "$SMOKE_ROOT/export.md" ] || fail "unsupported export option wrote an artifact."
done

# Exercise the installed Mach-O in a separate process using synthetic override data.
# Never read or write the user's Apple Books library during package acceptance.
LIBRARY_DB="$SMOKE_ROOT/library.sqlite"
ANNOTATIONS_DB="$SMOKE_ROOT/annotations.sqlite"
CONFIG="$SMOKE_ROOT/config.json"
printf '%s\n' '{"historical_assets":{}}' > "$CONFIG"
/usr/bin/sqlite3 "$LIBRARY_DB" <<'SQL'
CREATE TABLE ZBKLIBRARYASSET(
  Z_PK INTEGER PRIMARY KEY,
  ZASSETID TEXT,
  ZTITLE TEXT,
  ZAUTHOR TEXT,
  ZCONTENTTYPE INTEGER
);
INSERT INTO ZBKLIBRARYASSET VALUES (1,'asset-a','Synthetic EPUB','Fixture',1);
SQL
/usr/bin/sqlite3 "$ANNOTATIONS_DB" <<'SQL'
CREATE TABLE ZAEANNOTATION(
  Z_PK INTEGER PRIMARY KEY,
  ZANNOTATIONUUID TEXT,
  ZANNOTATIONASSETID TEXT,
  ZANNOTATIONDELETED INTEGER,
  ZANNOTATIONISUNDERLINE INTEGER,
  ZANNOTATIONSTYLE INTEGER,
  ZANNOTATIONTYPE INTEGER,
  ZANNOTATIONCREATIONDATE REAL,
  ZANNOTATIONMODIFICATIONDATE REAL,
  ZANNOTATIONSELECTEDTEXT TEXT,
  ZANNOTATIONREPRESENTATIVETEXT TEXT,
  ZANNOTATIONNOTE TEXT,
  ZANNOTATIONLOCATION TEXT,
  ZPLABSOLUTEPHYSICALLOCATION INTEGER,
  ZPLLOCATIONRANGESTART INTEGER,
  ZPLLOCATIONRANGEEND INTEGER,
  ZFUTUREPROOFING5 TEXT
);
INSERT INTO ZAEANNOTATION VALUES
  (1,'uuid-a','asset-a',0,0,1,1,10,20,'Synthetic quote','Synthetic excerpt','Synthetic note','epubcfi(/6/2[a]!/4/2,:1,:2)',1,2,3,'Chapter');
SQL
HOME="$HOME_ROOT" CFFIXED_USER_HOME="$HOME_ROOT" "$CLI" export \
  --format json --book asset-a --output "$SMOKE_ROOT/synthetic.json" \
  --library-db "$LIBRARY_DB" --annotations-db "$ANNOTATIONS_DB" --config "$CONFIG" \
  > "$SMOKE_ROOT/export-result.json"
node - "$SMOKE_ROOT/synthetic.json" "$SMOKE_ROOT/export-result.json" <<'NODE' || \
  fail "installed release binary could not export a synthetic EPUB annotation."
const fs = require('node:fs');
const [exportPath, resultPath] = process.argv.slice(2);
const bundle = JSON.parse(fs.readFileSync(exportPath, 'utf8'));
const result = JSON.parse(fs.readFileSync(resultPath, 'utf8'));
if (bundle.schemaVersion !== 11 || bundle.groups?.length !== 1 ||
    bundle.groups[0].records?.length !== 1 ||
    bundle.groups[0].records[0].annotation?.selectedText !== 'Synthetic quote' ||
    result.documentCount !== 1 || result.warningCount !== 0) process.exit(1);
NODE

printf 'npm install smoke OK: %s (%s)\n' "$PACKAGE" "$EXPECTED_VERSION"
