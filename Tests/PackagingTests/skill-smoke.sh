#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail "usage: skill-smoke.sh <skill-directory>"

SKILL_DIR=${1%/}
[ -n "$SKILL_DIR" ] || fail "skill directory is empty"
[ "$(basename "$SKILL_DIR")" = "applebookscli" ] || fail "skill directory basename must be applebookscli"
[ ! -L "$SKILL_DIR" ] || fail "skill directory must not be a symlink"
[ -d "$SKILL_DIR" ] || fail "skill directory is missing"

SKILL_FILE="$SKILL_DIR/SKILL.md"
[ ! -L "$SKILL_FILE" ] || fail "SKILL.md must not be a symlink"
[ -f "$SKILL_FILE" ] || fail "SKILL.md must be a regular file"
[ -s "$SKILL_FILE" ] || fail "SKILL.md must not be empty"

awk '
  NR == 1 {
    if ($0 != "---") exit 2
    frontmatter = 1
    next
  }
  frontmatter && $0 == "---" {
    frontmatter = 0
    closed = 1
    next
  }
  frontmatter {
    if ($0 ~ /^name:[[:space:]]*applebookscli[[:space:]]*$/) name = 1
    if ($0 ~ /^description:[[:space:]]*[^[:space:]].*$/) description = 1
    next
  }
  closed && $0 ~ /[^[:space:]]/ { body = 1 }
  END {
    if (!(closed && name && description && body)) exit 1
  }
' "$SKILL_FILE" || fail "SKILL.md packaging structure is invalid"

if grep -F '[TODO:' "$SKILL_FILE" >/dev/null 2>&1; then
  fail "SKILL.md contains unfinished scaffold TODO"
fi

printf 'skill packaging smoke OK: %s\n' "$SKILL_DIR"
