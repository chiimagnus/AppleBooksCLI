#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

PACKAGE=$1
EXPECTED_VERSION=$2

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
PDF_FIXTURE="$REPO_ROOT/Tests/Fixtures/PDF/corrupt.pdf"

SMOKE_ROOT=$(mktemp -d /private/tmp/applebookscli-npm-smoke.XXXXXX)
cleanup() {
  case "$SMOKE_ROOT" in
    /private/tmp/applebookscli-npm-smoke.*) rm -rf -- "$SMOKE_ROOT" ;;
    *) fail "refusing to clean unexpected npm smoke root: $SMOKE_ROOT" ;;
  esac
}
trap cleanup EXIT HUP INT TERM

PREFIX="$SMOKE_ROOT/prefix"
HOME_ROOT="$SMOKE_ROOT/home"
FAKE_BIN="$SMOKE_ROOT/fake-bin"
LIBRARY_DB="$SMOKE_ROOT/library.sqlite"
ANNOTATIONS_DB="$SMOKE_ROOT/annotations.sqlite"
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
[ "$(node -e 'const value=require(process.argv[1]); process.stdout.write(value.skills.applebookscli.ref)' "$SKILL_LOCK")" = "v$EXPECTED_VERSION" ] || \
  fail "npm postinstall did not align the managed Skill ref with the CLI version."
grep -Fx -- "-y skills@1.5.23 update applebookscli -g -y" "$NPX_CALL" >/dev/null || \
  fail "npm postinstall did not delegate the managed Skill update to Agent Skills CLI."
CLI="$PREFIX/bin/applebookscli"
[ "$(cd / && "$CLI" --version)" = "$EXPECTED_VERSION" ] || fail "npm-installed CLI version mismatch."
(cd / && "$CLI" --help >/dev/null)

PACKAGE_ROOT="$PREFIX/lib/node_modules/@chiimagnus/applebookscli"
WORKER="$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
rm -f "$NPX_CALL"
EMPTY_HOME="$SMOKE_ROOT/empty-home"
mkdir -p "$EMPTY_HOME"
HOME="$EMPTY_HOME" CFFIXED_USER_HOME="$EMPTY_HOME" PATH="$FAKE_BIN:$PATH" \
  node "$PACKAGE_ROOT/libexec/applebookscli/sync-installed-skill.mjs"
[ ! -e "$NPX_CALL" ] || fail "Skill sync must be a no-op when no managed Skill is installed."
sqlite3 "$LIBRARY_DB" 'CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZCONTENTTYPE INTEGER);'
sqlite3 "$ANNOTATIONS_DB" 'CREATE TABLE ZAEANNOTATION(Z_PK INTEGER PRIMARY KEY);'
HOME="$HOME_ROOT" CFFIXED_USER_HOME="$HOME_ROOT" \
  "$CLI" pdf highlights \
    --path "$PDF_FIXTURE" \
    --library-db "$LIBRARY_DB" \
    --annotations-db "$ANNOTATIONS_DB" \
    --json \
  > "$SMOKE_ROOT/pdf.stdout.json" \
  2> "$SMOKE_ROOT/pdf.stderr.txt"
[ ! -s "$SMOKE_ROOT/pdf.stderr.txt" ] || fail "npm-installed PDF smoke wrote unexpected diagnostics."
grep -F '"attemptedCount":1' "$SMOKE_ROOT/pdf.stdout.json" >/dev/null || fail "npm-installed CLI did not invoke the PDF worker."
grep -F '"reason":"unreadableDocument"' "$SMOKE_ROOT/pdf.stdout.json" >/dev/null || fail "npm-installed worker error contract drifted."

printf 'npm install smoke OK: %s (%s)\n' "$PACKAGE" "$EXPECTED_VERSION"
