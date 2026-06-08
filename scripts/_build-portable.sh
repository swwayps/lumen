#!/usr/bin/env bash
# Portable build: compile bin/lumen inside Ubuntu 22.04 (glibc 2.34) so it runs
# on any x86_64 distro with glibc >= 2.34. Mirrors SLSsteam-fork/scripts/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

runtime=""
for c in podman docker; do
  if command -v "$c" >/dev/null 2>&1; then runtime="$c"; break; fi
done
if [ -z "$runtime" ]; then
  echo "No container runtime (podman/docker) found. Install one, or run 'make' on the host." >&2
  exit 1
fi

echo "==> portable build (using $runtime, image lumen-builder)"
"$runtime" build -f Dockerfile -t lumen-builder . >&2
"$runtime" run --rm -v "$PWD:/build:Z" -w /build lumen-builder \
  bash -c 'make clean && make'
echo "==> built: bin/lumen"
