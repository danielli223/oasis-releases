#!/bin/bash
# Rebuild appcast.xml — the file every installed Oasis polls to learn that a
# newer version exists — from the update-feed fragments attached to the
# published releases in this repository.
#
# The feed is rebuilt from scratch every time rather than appended to, so it is
# a pure function of what is actually published. Three things fall out of that:
#
#   - Publishing is the only trigger. A draft release carries no weight,
#     because drafts are filtered out below and the workflow that calls this
#     only fires on a real publish.
#   - Pulling a bad release needs no XML editing. Delete the release (or just
#     its Oasis-appcast-item.xml asset), re-run the workflow, and the entry is
#     gone. See the workflow's own header for the full procedure.
#   - Re-running is always safe. The same set of releases produces the same
#     file, byte for byte.
#
# The fragments are produced and signed by the release pipeline in the
# danielli223/oasis-focus repository (build/make-sparkle-item.sh), which is the
# only place the update-signing private key exists. Nothing here signs
# anything, so nothing here needs that key.
#
# Usage:
#   build-appcast.sh --items-dir <dir of *.xml fragments> --out appcast.xml
set -euo pipefail

ITEMS_DIR=""
OUT_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --items-dir) ITEMS_DIR="$2"; shift 2 ;;
    --out) OUT_PATH="$2"; shift 2 ;;
    *) echo "build-appcast: unknown argument: $1" >&2; exit 1 ;;
  esac
done

for req_name in ITEMS_DIR OUT_PATH; do
  if [ -z "${!req_name}" ]; then
    echo "build-appcast: missing required argument for $req_name" >&2
    exit 1
  fi
done

[ -d "$ITEMS_DIR" ] || { echo "build-appcast: items directory not found: $ITEMS_DIR" >&2; exit 1; }

python3 - "$ITEMS_DIR" "$OUT_PATH" <<'PYEOF'
import glob
import os
import sys
import xml.etree.ElementTree as ET

items_dir, out_path = sys.argv[1], sys.argv[2]

SPARKLE_URI = "http://www.sparkle-project.org/xml-namespaces/sparkle"
SPARKLE_NS = "{" + SPARKLE_URI + "}"

entries = []
for fragment_path in sorted(glob.glob(os.path.join(items_dir, "*.xml"))):
    with open(fragment_path) as handle:
        fragment = handle.read()

    # Each fragment is a bare <item>, so it needs the namespace declaration
    # wrapped back around it before it can be parsed.
    wrapped = f'<channel xmlns:sparkle="{SPARKLE_URI}">{fragment}</channel>'
    try:
        channel = ET.fromstring(wrapped)
    except ET.ParseError as error:
        sys.exit(f"::error::{fragment_path} is not parseable XML: {error}")

    items = channel.findall("item")
    if len(items) != 1:
        sys.exit(
            f"::error::{fragment_path} holds {len(items)} <item> elements; "
            "each fragment must hold exactly one."
        )
    item = items[0]

    enclosure = item.find("enclosure")
    if enclosure is None:
        sys.exit(f"::error::{fragment_path} has no <enclosure>, so there is nothing to download.")

    # Re-check the three things that decide whether an update installs at all.
    # They were already checked when the fragment was built, but this is the
    # last point before the file every user polls, and a hand-edited or
    # truncated asset must not reach it.
    raw_version = enclosure.get(SPARKLE_NS + "version")
    if raw_version is None:
        sys.exit(f"::error::{fragment_path} has no sparkle:version, so Sparkle cannot order it.")
    try:
        build = int(raw_version)
    except ValueError:
        sys.exit(
            f"::error::{fragment_path} has a non-integer sparkle:version "
            f"('{raw_version}'), which cannot be ordered."
        )

    install_type = enclosure.get(SPARKLE_NS + "installationType")
    if install_type != "package":
        sys.exit(
            f"::error::{fragment_path} declares sparkle:installationType="
            f"'{install_type}' — Oasis ships a .pkg, and Sparkle refuses the "
            "install unless this says 'package'."
        )

    if not enclosure.get(SPARKLE_NS + "edSignature"):
        sys.exit(
            f"::error::{fragment_path} carries no sparkle:edSignature. Sparkle "
            "refuses to install what it cannot verify, so this entry would be dead."
        )

    # Keep the fragment's original text, not a re-serialization of the parsed
    # tree: re-serializing would restate the sparkle namespace on every <item>
    # and reflow the attributes, so the published feed would stop matching what
    # the release pipeline actually produced and reviewed.
    entries.append((build, fragment_path, fragment.strip("\n")))

if not entries:
    sys.exit(
        "::error::No update-feed fragments were found. Refusing to write an empty "
        "feed over a populated one — that would silently switch off updates for "
        "everyone. If this is genuinely the first release, check that the release "
        "pipeline attached its Oasis-appcast-item.xml asset."
    )

seen = {}
for build, fragment_path, _ in entries:
    if build in seen:
        sys.exit(
            f"::error::Two releases both claim build number {build}: "
            f"{seen[build]} and {fragment_path}. Sparkle cannot choose between them."
        )
    seen[build] = fragment_path

# Newest first, for whoever reads the file by hand. Sparkle itself picks the
# best entry regardless of order.
entries.sort(key=lambda entry: entry[0], reverse=True)

body = "\n".join(fragment for _, _, fragment in entries)

feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_URI}">
  <channel>
    <title>Oasis</title>
    <description>Updates for the Oasis macOS app.</description>
    <language>en</language>
{body}
  </channel>
</rss>
"""

with open(out_path, "w") as handle:
    handle.write(feed)

print(f"Wrote {out_path} with {len(entries)} entries (newest build {entries[0][0]}).")
PYEOF
