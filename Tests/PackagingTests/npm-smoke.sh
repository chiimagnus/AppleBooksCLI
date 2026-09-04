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
LIBRARY_DB="$SMOKE_ROOT/library.sqlite"
ANNOTATIONS_DB="$SMOKE_ROOT/annotations.sqlite"
mkdir -p "$PREFIX" "$HOME_ROOT"

npm install --global --prefix "$PREFIX" "$PACKAGE" >/dev/null
CLI="$PREFIX/bin/applebookscli"
[ "$(cd / && "$CLI" --version)" = "$EXPECTED_VERSION" ] || fail "npm-installed CLI version mismatch."
(cd / && "$CLI" --help >/dev/null)

PACKAGE_ROOT="$PREFIX/lib/node_modules/@chiimagnus/applebookscli"
WORKER="$PACKAGE_ROOT/libexec/applebookscli/applebookscli-pdf-worker"
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
