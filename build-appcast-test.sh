#!/bin/bash
# Headless test for build-appcast.sh.
#
# This script writes the one file every installed copy of Oasis polls, so its
# failure modes are unusually unforgiving: a feed that is empty, unparseable,
# or missing a signature does not produce an error anyone sees — it silently
# stops all updates. Each case below is one of those.
#
# Run by the same workflow that publishes the feed, immediately before it does,
# so a broken change cannot reach users even though this repository has no
# separate CI.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/build-appcast.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILURES=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); }

# A fragment shaped exactly like the release pipeline's output.
write_fragment() {
  # ${4-...} and ${5-...}, not ${4:-...}: the colon form also substitutes the
  # default when the argument is present but empty, which would silently turn
  # the empty-signature case below into a well-signed one and test nothing.
  local path="$1" short="$2" build="$3" install_type="${4-package}" signature="${5-c2lnbmF0dXJl}"
  cat > "$path" <<FRAGMENT
    <item>
      <title>Oasis $short</title>
      <pubDate>Wed, 29 Jul 2026 12:00:00 +0000</pubDate>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/danielli223/oasis-releases/releases/download/v$short/Oasis-$short.zip"
                 sparkle:version="$build"
                 sparkle:shortVersionString="$short"
                 sparkle:installationType="$install_type"
                 length="12345"
                 type="application/octet-stream"
                 sparkle:edSignature="$signature"/>
    </item>
FRAGMENT
}

expect_fail() {
  local label="$1"; shift
  if "$@" >"$WORK/out.txt" 2>&1; then
    fail "$label — exited 0 instead of refusing"
    cat "$WORK/out.txt"
  else
    pass "$label"
  fi
}

# ---------------------------------------------------------------------------
# 1. Happy path: two published releases become one feed
# ---------------------------------------------------------------------------
GOOD="$WORK/good"
mkdir -p "$GOOD"
write_fragment "$GOOD/v1.0.1.xml" "1.0.1" "2"
write_fragment "$GOOD/v1.1.0.xml" "1.1.0" "5"

if "$SCRIPT" --items-dir "$GOOD" --out "$WORK/appcast.xml" >"$WORK/out.txt" 2>&1; then
  pass "builds a feed from two fragments"
else
  fail "refused two well-formed fragments"
  cat "$WORK/out.txt"
fi

# Parsed, not grepped: a feed that merely contains the right substrings but does
# not parse is exactly the failure this guards against.
FEED_CHECK="$(python3 - "$WORK/appcast.xml" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

ns = {"sparkle": "http://www.sparkle-project.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
items = root.findall("channel/item")
versions = [i.find("enclosure").get("{http://www.sparkle-project.org/xml-namespaces/sparkle}version") for i in items]
title = root.findtext("channel/title")
print(f"count={len(items)} versions={','.join(versions)} title={title}", end="")
PYEOF
)"

if [ "$FEED_CHECK" = "count=2 versions=5,2 title=Oasis" ]; then
  pass "the feed parses, keeps both entries newest-first, and keeps its channel title"
else
  fail "unexpected feed shape: $FEED_CHECK"
fi

# Byte-for-byte repeatability is what makes re-running the publish workflow safe.
"$SCRIPT" --items-dir "$GOOD" --out "$WORK/appcast-again.xml" >/dev/null 2>&1
if cmp -s "$WORK/appcast.xml" "$WORK/appcast-again.xml"; then
  pass "rebuilding the same releases produces an identical file"
else
  fail "rebuilding the same releases produced a different file"
fi

# The signature must survive assembly untouched — Sparkle refuses to install
# what it cannot verify, and a mangled signature is indistinguishable from an
# attack from the app's point of view.
if grep -q 'sparkle:edSignature="c2lnbmF0dXJl"' "$WORK/appcast.xml"; then
  pass "the signature reaches the feed unmodified"
else
  fail "the signature was altered or dropped during assembly"
fi

# ---------------------------------------------------------------------------
# 2. Refusals
# ---------------------------------------------------------------------------
EMPTY="$WORK/empty"
mkdir -p "$EMPTY"
expect_fail "refuses to write an empty feed, which would switch off updates for everyone" \
  "$SCRIPT" --items-dir "$EMPTY" --out "$WORK/bad.xml"

DUPES="$WORK/dupes"
mkdir -p "$DUPES"
write_fragment "$DUPES/a.xml" "1.0.1" "2"
write_fragment "$DUPES/b.xml" "1.0.2" "2"
expect_fail "refuses two releases claiming the same build number" \
  "$SCRIPT" --items-dir "$DUPES" --out "$WORK/bad.xml"

NO_SIG="$WORK/nosig"
mkdir -p "$NO_SIG"
write_fragment "$NO_SIG/a.xml" "1.0.1" "2" "package" ""
expect_fail "refuses a fragment with an empty signature" \
  "$SCRIPT" --items-dir "$NO_SIG" --out "$WORK/bad.xml"

WRONG_TYPE="$WORK/wrongtype"
mkdir -p "$WRONG_TYPE"
write_fragment "$WRONG_TYPE/a.xml" "1.0.1" "2" "application"
expect_fail "refuses an entry that does not declare a package install, which Sparkle would reject" \
  "$SCRIPT" --items-dir "$WRONG_TYPE" --out "$WORK/bad.xml"

DOTTED="$WORK/dotted"
mkdir -p "$DOTTED"
write_fragment "$DOTTED/a.xml" "1.0.1" "1.0.1"
expect_fail "refuses a non-integer build number" \
  "$SCRIPT" --items-dir "$DOTTED" --out "$WORK/bad.xml"

MALFORMED="$WORK/malformed"
mkdir -p "$MALFORMED"
echo '<item><enclosure' > "$MALFORMED/a.xml"
expect_fail "refuses a fragment that is not parseable XML" \
  "$SCRIPT" --items-dir "$MALFORMED" --out "$WORK/bad.xml"

TWO_ITEMS="$WORK/twoitems"
mkdir -p "$TWO_ITEMS"
{ write_fragment /dev/stdout "1.0.1" "2"; write_fragment /dev/stdout "1.0.2" "3"; } > "$TWO_ITEMS/a.xml"
expect_fail "refuses a fragment holding more than one entry" \
  "$SCRIPT" --items-dir "$TWO_ITEMS" --out "$WORK/bad.xml"

expect_fail "refuses a missing items directory rather than writing an empty feed" \
  "$SCRIPT" --items-dir "$WORK/absent" --out "$WORK/bad.xml"

# An earlier run's output must not be left behind when a later run refuses.
if [ -f "$WORK/bad.xml" ]; then
  fail "a refused run still wrote an output file"
else
  pass "a refused run writes no output file"
fi

exit $FAILURES
