#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

PACKAGE=$1
EXPECTED_VERSION=$2

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

printf 'npm install smoke OK: %s (%s)\n' "$PACKAGE" "$EXPECTED_VERSION"
