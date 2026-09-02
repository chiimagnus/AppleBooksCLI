#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
METADATA="$REPO_ROOT/scripts/release-metadata.sh"
[ -f "$METADATA" ] || fail "release metadata parser is missing."

expect() {
  tag=$1
  version=$2
  channel=$3
  npm_tag=$4
  prerelease=$5
  actual=$(sh -c '. "$1" "$2"; printf "%s|%s|%s|%s" "$RELEASE_VERSION" "$RELEASE_CHANNEL" "$NPM_DIST_TAG" "$GITHUB_PRERELEASE"' sh "$METADATA" "$tag")
  expected="$version|$channel|$npm_tag|$prerelease"
  [ "$actual" = "$expected" ] || fail "$tag resolved to $actual, expected $expected"
}

reject() {
  tag=$1
  if sh -c '. "$1" "$2"' sh "$METADATA" "$tag" >/dev/null 2>&1; then
    fail "invalid release tag was accepted: $tag"
  fi
}

expect v1.2.1 1.2.1 stable latest false
expect v1.2.2-beta 1.2.2-beta beta beta true
expect v1.2.2-beta.1 1.2.2-beta.1 beta beta true
expect v0.0.0 0.0.0 stable latest false
reject 1.2.1
reject v1.2
reject v01.2.3
reject v1.02.3
reject v1.2.03
reject v1.2.3-rc
reject v1.2.3-beta.0
reject v1.2.3+build

printf 'release metadata smoke OK\n'
