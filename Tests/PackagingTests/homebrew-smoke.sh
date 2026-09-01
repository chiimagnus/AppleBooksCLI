#!/bin/sh
set -eu

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
RENDERER="$REPO_ROOT/scripts/render-homebrew-formula.sh"
TEMPLATE="$REPO_ROOT/packaging/homebrew/applebookscli.rb.template"

[ -x "$RENDERER" ] || fail "Homebrew renderer is missing or not executable."
[ -f "$TEMPLATE" ] || fail "Homebrew formula template is missing."
command -v ruby >/dev/null 2>&1 || fail "ruby is required for the Homebrew smoke test."
command -v brew >/dev/null 2>&1 || fail "brew is required for the Homebrew smoke test."

base=${TMPDIR:-/tmp}
tmp=$(mktemp -d "$base/applebookscli-homebrew-smoke.XXXXXX")
cleanup() {
  case "$tmp" in
    "$base"/applebookscli-homebrew-smoke.*) rm -rf -- "$tmp" ;;
    *) fail "refusing to remove unexpected smoke directory." ;;
  esac
}
trap cleanup EXIT HUP INT TERM

formula="$tmp/applebookscli.rb"
"$RENDERER" \
  --owner example-org \
  --version 0.0.0-test \
  --url https://example.invalid/applebookscli-0.0.0-test-macos-universal.tar.gz \
  --sha256 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
  --output "$formula"

ruby -c "$formula" >/dev/null
HOMEBREW_NO_AUTO_UPDATE=1 brew style "$formula"

assert_contains() {
  expected=$1
  grep -Fq -- "$expected" "$formula" || fail "rendered formula is missing required contract: $expected"
}

assert_contains 'homepage "https://github.com/example-org/AppleBooksCLI"'
assert_contains 'version "0.0.0-test"'
assert_contains 'license "AGPL-3.0-only"'
assert_contains 'bin.install "bin/applebookscli"'
assert_contains '(libexec/"applebookscli").install "libexec/applebookscli/applebookscli-pdf-worker"'
assert_contains 'share.install "share/applebookscli"'
assert_contains 'prefix.install "LICENSE", "THIRD_PARTY_NOTICES.md", "ThirdPartyLicenses"'
assert_contains 'codex_home = testpath/"codex-home"'
assert_contains 'ENV["CODEX_HOME"] = codex_home.to_s'
assert_contains 'system bin/"applebookscli", "skill", "install"'
assert_contains 'assert_path_exists codex_home/"skills/applebookscli/SKILL.md"'
assert_contains 'assert_predicate share/"applebookscli/skill/applebookscli/SKILL.md", :file?'
assert_contains 'assert_predicate libexec/"applebookscli/applebookscli-pdf-worker", :executable?'
assert_contains 'assert_predicate prefix/"LICENSE", :file?'
assert_contains 'assert_predicate prefix/"THIRD_PARTY_NOTICES.md", :file?'
assert_contains 'assert_predicate prefix/"ThirdPartyLicenses", :directory?'
assert_contains 'shell_output("#{bin}/applebookscli --version")'
assert_contains 'shell_output("#{bin}/applebookscli --help")'

if grep -Eq '__[A-Z0-9_]+__|swift build|depends_on' "$formula"; then
  fail "rendered formula contains an unresolved token or source-build dependency."
fi
if grep -Eq '^[[:space:]]*rtk([[:space:]]|$)|gh[[:space:]]+api|brew[[:space:]]+audit' "$RENDERER" "$TEMPLATE" "$0"; then
  fail "packaging scripts must stay independent of local wrappers, remote release APIs, and online audit."
fi

printf 'homebrew offline smoke OK\n'
