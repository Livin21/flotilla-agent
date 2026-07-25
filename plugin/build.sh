#!/bin/bash
# Builds flotilla-agent-<version>.txz for the .plg. Usage: plugin/build.sh 2026.07.26
set -euo pipefail
VER="${1:?version}"
cd "$(dirname "$0")/.."
STAGE=$(mktemp -d)/flotilla-agent
mkdir -p "$STAGE"
cp -R plugin/src/* "$STAGE/"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o "$STAGE/flotilla-seal" ./cmd/flotilla-seal
chmod +x "$STAGE"/scripts/*.sh "$STAGE/flotilla-seal"
( cd "$(dirname "$STAGE")" && tar -cJf "$OLDPWD/plugin/flotilla-agent-$VER.txz" flotilla-agent )
echo "built plugin/flotilla-agent-$VER.txz"
