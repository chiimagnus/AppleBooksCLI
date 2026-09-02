#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

usage() {
  printf 'Usage: %s --owner <owner> --version <version> --url <https-url> --sha256 <sha256> --output <file>\n' "$(basename "$0")" >&2
  exit 64
}

OWNER=
VERSION=
URL=
SHA256=
OUTPUT=

while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --owner) OWNER=$2 ;;
    --version) VERSION=$2 ;;
    --url) URL=$2 ;;
    --sha256) SHA256=$2 ;;
    --output) OUTPUT=$2 ;;
    *) usage ;;
  esac
  shift 2
done

case "$OWNER" in
  ""|*[!A-Za-z0-9_.-]*) fail "--owner contains unsupported characters." ;;
esac
case "$VERSION" in
  ""|*[!A-Za-z0-9._-]*) fail "--version contains unsupported characters." ;;
esac
case "$URL" in
  https://*) ;;
  *) fail "--url must use https." ;;
esac
case "$URL" in
  *[[:space:]]*) fail "--url must not contain whitespace." ;;
esac
case "$URL" in
  */applebookscli-"$VERSION"-macos-universal.tar.gz) ;;
  *) fail "--url must match --version release archive." ;;
esac
[ "${#SHA256}" -eq 64 ] || fail "--sha256 must contain exactly 64 hexadecimal characters."
case "$SHA256" in
  *[!0-9A-Fa-f]*) fail "--sha256 must contain exactly 64 hexadecimal characters." ;;
esac
[ -n "$OUTPUT" ] || fail "--output is required."

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
TEMPLATE="$REPO_ROOT/packaging/homebrew/applebookscli.rb.template"
[ -f "$TEMPLATE" ] || fail "Homebrew formula template is missing."

OUTPUT_DIR=$(dirname -- "$OUTPUT")
[ -d "$OUTPUT_DIR" ] || fail "--output parent directory does not exist."
[ ! -d "$OUTPUT" ] || fail "--output must be a file path."

escape_replacement() {
  printf '%s' "$1" | sed 's/[\\&|]/\\&/g'
}

owner=$(escape_replacement "$OWNER")
url=$(escape_replacement "$URL")
sha256=$(escape_replacement "$SHA256")
temporary="$OUTPUT.tmp.$$"
trap 'rm -f -- "$temporary"' EXIT HUP INT TERM

sed \
  -e "s|__OWNER__|$owner|g" \
  -e "s|__URL__|$url|g" \
  -e "s|__SHA256__|$sha256|g" \
  "$TEMPLATE" > "$temporary"
mv -f -- "$temporary" "$OUTPUT"
trap - EXIT HUP INT TERM
