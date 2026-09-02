#!/bin/sh
set -eu

release_metadata_fail() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

[ "$#" -eq 1 ] || release_metadata_fail "usage: release-metadata.sh <git-tag>"

APPLEBOOKSCLI_TAG=$1

if printf '%s\n' "$APPLEBOOKSCLI_TAG" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  RELEASE_CHANNEL=stable
  NPM_DIST_TAG=latest
  GITHUB_PRERELEASE=false
elif printf '%s\n' "$APPLEBOOKSCLI_TAG" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-beta(\.[1-9][0-9]*)?$'; then
  RELEASE_CHANNEL=beta
  NPM_DIST_TAG=beta
  GITHUB_PRERELEASE=true
else
  release_metadata_fail "unsupported release tag: $APPLEBOOKSCLI_TAG"
fi

RELEASE_VERSION=${APPLEBOOKSCLI_TAG#v}
export APPLEBOOKSCLI_TAG RELEASE_VERSION RELEASE_CHANNEL NPM_DIST_TAG GITHUB_PRERELEASE
