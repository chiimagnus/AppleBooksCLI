#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 2 ] || fail "usage: npm-smoke.sh <package.tgz> <expected-version>"
PACKAGE=$1
EXPECTED_VERSION=$2
[ -f "$PACKAGE" ] || fail "npm package is missing: $PACKAGE"
command -v npm >/dev/null 2>&1 || fail "npm is required for the npm install smoke."
command -v node >/dev/null 2>&1 || fail "node is required for the npm platform smoke."
command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 is required for the npm install smoke."

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
SKILL_SMOKE="$SCRIPT_DIR/skill-smoke.sh"
PDF_FIXTURE="$REPO_ROOT/Tests/Fixtures/PDF/corrupt.pdf"
[ -x "$SKILL_SMOKE" ] || fail "Skill smoke is missing or not executable."
[ -f "$PDF_FIXTURE" ] || fail "synthetic PDF fixture is missing."

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
CODEX_HOME_ROOT="$SMOKE_ROOT/codex-home"
LIBRARY_DB="$SMOKE_ROOT/library.sqlite"
ANNOTATIONS_DB="$SMOKE_ROOT/annotations.sqlite"
mkdir -p "$PREFIX" "$HOME_ROOT"

NPM_REAL=$(node -e 'const fs=require("fs"); console.log(fs.realpathSync(process.argv[1]))' "$(command -v npm)")
NPM_ROOT=$(dirname "$(dirname "$NPM_REAL")")
PLATFORM_CHECKS="$NPM_ROOT/node_modules/npm-install-checks/lib/index.js"
[ -f "$PLATFORM_CHECKS" ] || fail "npm-install-checks is unavailable from the active npm installation."
node - "$PLATFORM_CHECKS" "$PACKAGE" <<'NODE'
const cp = require("child_process")
const checks = require(process.argv[2])
const manifest = JSON.parse(cp.execFileSync("tar", ["-xOf", process.argv[3], "package/package.json"], { encoding: "utf8" }))

function expectAllowed(os, cpu) {
  checks.checkPlatform(manifest, false, { os, cpu, libc: null })
}

function expectBlocked(os, cpu) {
  try {
    checks.checkPlatform(manifest, false, { os, cpu, libc: null })
  } catch (error) {
    if (error?.code === "EBADPLATFORM") return
    throw error
  }
  throw new Error(`expected EBADPLATFORM for ${os}/${cpu}`)
}

expectAllowed("darwin", "arm64")
expectBlocked("darwin", "x64")
expectBlocked("linux", "arm64")
NODE

npm install --global --prefix "$PREFIX" --ignore-scripts "$PACKAGE" >/dev/null
CLI="$PREFIX/bin/applebookscli"
[ -x "$CLI" ] || fail "npm global bin is missing or not executable."
[ "$(cd / && "$CLI" --version)" = "$EXPECTED_VERSION" ] || fail "npm-installed CLI version mismatch."
(cd / && "$CLI" --help >/dev/null)

PACKAGE_ROOT="$PREFIX/lib/node_modules/@chiimagnus/applebookscli"
WORKER="$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
SKILL="$PACKAGE_ROOT/share/applebookscli/skill/applebookscli"
[ -x "$WORKER" ] || fail "npm-installed PDF worker is missing or not executable."
"$SKILL_SMOKE" "$SKILL"

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
grep -F '"failedCount":1' "$SMOKE_ROOT/pdf.stdout.json" >/dev/null || fail "npm-installed CLI returned an unexpected PDF result."
grep -F '"reason":"unreadableDocument"' "$SMOKE_ROOT/pdf.stdout.json" >/dev/null || fail "npm-installed worker error contract drifted."

HOME="$HOME_ROOT" CFFIXED_USER_HOME="$HOME_ROOT" CODEX_HOME="$CODEX_HOME_ROOT" \
  "$CLI" skill install --json > "$SMOKE_ROOT/skill.stdout.json" 2> "$SMOKE_ROOT/skill.stderr.txt"
[ ! -s "$SMOKE_ROOT/skill.stderr.txt" ] || fail "npm-installed Skill install wrote unexpected diagnostics."
grep -F '"installed":true' "$SMOKE_ROOT/skill.stdout.json" >/dev/null || fail "npm-installed CLI did not install the packaged Skill."
"$SKILL_SMOKE" "$CODEX_HOME_ROOT/skills/applebookscli"

printf 'npm install smoke OK: %s (%s)\n' "$PACKAGE" "$EXPECTED_VERSION"
