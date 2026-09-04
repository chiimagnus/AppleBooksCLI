#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

SKILL_DIR=${1%/}
SKILL_FILE="$SKILL_DIR/SKILL.md"

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
