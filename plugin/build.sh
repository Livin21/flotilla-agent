#!/bin/bash
# Builds the release artifacts for a flotilla-agent release AND syncs the .plg's <MD5> to the
# package it just built, so the release asset and the .plg can never drift apart.
#
#   plugin/build.sh              # builds the version the .plg already declares
#   plugin/build.sh 2026.08.10   # same, but refuses unless the .plg declares that version too
#
# Produces, under plugin/ and bin/:
#   plugin/flotilla-agent-<version>.txz   the Unraid plugin package (the .plg's <FILE> download)
#   bin/flotilla-beacon-linux-amd64       the Proxmox beacon (beacon-install.sh downloads this)
#   bin/flotilla-beacon-linux-arm64
#
# ...and rewrites <MD5> in plugin/flotilla-agent.plg in place. That rewrite is the whole point:
# the plugin manager verifies the downloaded package against that MD5 and refuses to install on
# a mismatch, so the value committed to the repo must be the MD5 of the exact file uploaded as
# the release asset. Never hand-edit it -- run this script.
#
# Nothing here is committed except the .plg change: /plugin/*.txz and /bin are .gitignore'd,
# they ship as GitHub release assets. See the release instructions this script prints at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

PLG=plugin/flotilla-agent.plg
SETTINGS=plugin/src/include/settings.php

md5_of() {
  # md5sum on Linux, md5 -q on macOS/BSD. Both print the same 32 hex digits.
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
  else md5 -q "$1"; fi
}

# --- version consistency -----------------------------------------------------------------
# Three places carry the version and all three must agree, or a user gets a mismatched
# install: the .plg's <!ENTITY version> (drives both the download URL and the on-flash package
# name, via the nested &pkg; entity), and FLOTILLA_AGENT_VERSION in settings.php (the
# "installed" side of the relay's X-Min-Agent comparison, which would otherwise nag or fail to
# nag against the wrong number).
PLG_VER=$(sed -n 's/.*<!ENTITY[[:space:]]*version[[:space:]]*"\([^"]*\)".*/\1/p' "$PLG" | head -1)
PHP_VER=$(sed -n "s/.*define('FLOTILLA_AGENT_VERSION',[[:space:]]*'\([^']*\)').*/\1/p" "$SETTINGS" | head -1)
VER="${1:-$PLG_VER}"

[ -n "$PLG_VER" ] || { echo "build: could not read <!ENTITY version> from $PLG" >&2; exit 1; }
if [ "$VER" != "$PLG_VER" ]; then
  echo "build: refusing -- you asked for $VER but $PLG declares $PLG_VER." >&2
  echo "build: bump <!ENTITY version> in $PLG and FLOTILLA_AGENT_VERSION in $SETTINGS first." >&2
  exit 1
fi
if [ "$PHP_VER" != "$PLG_VER" ]; then
  echo "build: version drift -- $PLG says $PLG_VER but $SETTINGS says ${PHP_VER:-<unreadable>}." >&2
  exit 1
fi

TXZ="plugin/flotilla-agent-$VER.txz"

# --- package -----------------------------------------------------------------------------
STAGE_ROOT=$(mktemp -d)
trap 'rm -rf "$STAGE_ROOT"' EXIT
STAGE="$STAGE_ROOT/flotilla-agent"
mkdir -p "$STAGE"
cp -R plugin/src/* "$STAGE/"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o "$STAGE/flotilla-seal" ./cmd/flotilla-seal
chmod +x "$STAGE"/scripts/*.sh "$STAGE/flotilla-seal"
rm -f "$TXZ"
( cd "$STAGE_ROOT" && tar -cJf "$OLDPWD/$TXZ" flotilla-agent )

# The .plg install block hard-depends on exactly these two paths existing after extraction (it
# aborts the install before touching Unraid's notification path if either is missing), so prove
# they are actually in the archive rather than discovering it on a user's box.
for want in flotilla-agent/scripts/agent.sh flotilla-agent/flotilla-seal; do
  tar -tJf "$TXZ" | grep -qx "$want" || { echo "build: $TXZ is missing $want" >&2; exit 1; }
done

MD5=$(md5_of "$TXZ")

# --- sync the .plg's <MD5> ---------------------------------------------------------------
TMP_PLG=$(mktemp)
sed "s#<MD5>[0-9a-fA-F]*</MD5>#<MD5>$MD5</MD5>#" "$PLG" > "$TMP_PLG"
grep -q "<MD5>$MD5</MD5>" "$TMP_PLG" || { rm -f "$TMP_PLG"; echo "build: failed to rewrite <MD5> in $PLG" >&2; exit 1; }
mv -f "$TMP_PLG" "$PLG"

# --- beacon binaries (the other half of the same release) ---------------------------------
# beacon-install.sh fetches these from releases/latest/download/, so they have to live in the
# same (or a newer) release as the .txz or a Proxmox install 404s.
mkdir -p bin
for A in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$A" go build -ldflags "-s -w" -o "bin/flotilla-beacon-linux-$A" ./cmd/flotilla-beacon
done

cat <<EOF

built $TXZ
  md5: $MD5   ($PLG <MD5> updated in place to match)
  bin/flotilla-beacon-linux-amd64
  bin/flotilla-beacon-linux-arm64

To cut release $VER:
  1. git add $PLG && git commit -m "release $VER"     # the MD5 above MUST be committed
  2. git push && gh release create "$VER" \\
       "$TXZ" \\
       bin/flotilla-beacon-linux-amd64 \\
       bin/flotilla-beacon-linux-arm64 \\
       --title "$VER"
  3. Verify the asset URL the .plg points at resolves:
       curl -fsSLI https://github.com/Livin21/flotilla-agent/releases/download/$VER/flotilla-agent-$VER.txz

The asset filename must stay exactly flotilla-agent-$VER.txz -- the .plg's <URL> is built from
<!ENTITY name> and <!ENTITY version>, and the plugin manager will not find it under any other name.
EOF
