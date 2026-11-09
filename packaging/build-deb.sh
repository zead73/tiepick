#!/bin/bash
# Build a .deb for a Debian release inside a container, so the binary is
# linked against that release's libraries.
#
#   packaging/build-deb.sh [release]      default: trixie
#
# Needs docker. The .deb lands in packaging/out/.
set -euo pipefail

release=${1:-trixie}
here=$(cd "$(dirname "$0")" && pwd)
out=$here/out
mkdir -p "$out"

docker run --rm \
  -v "$here/..":/src:ro \
  -v "$out":/out \
  "debian:$release" \
  bash /src/packaging/in-container.sh "$(id -u):$(id -g)"

ls -l "$out"/*.deb
