#!/usr/bin/env bash
# Single entry point for bumping any of this repo's pinned versions.
# VERSION is the only source of truth; this script updates it plus the
# handful of places that mention a version in prose (README.md, and the
# Dockerfile's ARG fallback defaults) so nothing needs hunting through
# files by hand. Image tags, manifest.yaml, and every build/test/CI
# script all derive from VERSION at build time and never need touching.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

usage() {
  cat <<'EOF'
Usage:
  scripts/bump-version.sh frr <new-version>      e.g. 10.8.0 - resets the
                                                  extension revision to 1
  scripts/bump-version.sh talos <new-version>    e.g. v1.14.0 (must start
                                                  with 'v') - the Talos
                                                  version being installed
                                                  onto/upgraded to
  scripts/bump-version.sh imager <new-version>   e.g. v1.14.0 - the
                                                  ghcr.io/siderolabs/imager
                                                  build tool version used
                                                  to produce the installer
                                                  image. Independent of
                                                  `talos` above - imager
                                                  is a separate tool, you
                                                  may want to pin it apart
                                                  from the Talos version
                                                  you're targeting.
  scripts/bump-version.sh revision               bump the extension
                                                  packaging revision by 1
                                                  (use for packaging-only
                                                  changes: daemons file,
                                                  frr.yaml, etc - no FRR
                                                  or Talos version change)

Image tags (extension and installer) are always
{talos-version}-{frr-version}-{revision}, computed from VERSION - see
the Makefile's TAG variable and README.md "Versioning".
EOF
  exit 1
}

set -a; source VERSION; set +a

case "${1:-}" in
  frr)
    NEW_FRR="${2:?usage: scripts/bump-version.sh frr <new-frr-version>}"
    sed -i.bak -E "s/^FRR_VERSION=.*/FRR_VERSION=${NEW_FRR}/" VERSION
    sed -i.bak -E "s/^EXTENSION_REVISION=.*/EXTENSION_REVISION=1/" VERSION
    ;;
  talos)
    NEW_TALOS="${2:?usage: scripts/bump-version.sh talos <new-talos-version>}"
    [[ "$NEW_TALOS" == v* ]] || { echo "talos version must start with 'v', e.g. v1.14.0" >&2; exit 1; }
    sed -i.bak -E "s/^TALOS_VERSION=.*/TALOS_VERSION=${NEW_TALOS}/" VERSION
    ;;
  imager)
    NEW_IMAGER="${2:?usage: scripts/bump-version.sh imager <new-imager-version>}"
    [[ "$NEW_IMAGER" == v* ]] || { echo "imager version must start with 'v', e.g. v1.14.0" >&2; exit 1; }
    sed -i.bak -E "s/^IMAGER_VERSION=.*/IMAGER_VERSION=${NEW_IMAGER}/" VERSION
    ;;
  revision)
    NEW_REV=$((EXTENSION_REVISION + 1))
    sed -i.bak -E "s/^EXTENSION_REVISION=.*/EXTENSION_REVISION=${NEW_REV}/" VERSION
    ;;
  *)
    usage
    ;;
esac
rm -f VERSION.bak

# Reload the now-updated values and propagate them to the few places
# that mention a version in prose or as a Dockerfile fallback default.
set -a; source VERSION; set +a

sed -i.bak -E "s/^ARG FRR_VERSION=.*/ARG FRR_VERSION=${FRR_VERSION}/" Dockerfile
sed -i.bak -E "s/^ARG EXTENSION_REVISION=.*/ARG EXTENSION_REVISION=${EXTENSION_REVISION}/" Dockerfile
rm -f Dockerfile.bak

sed -i.bak -E "s#\| FRR       \| [0-9.]+ \(\`quay\.io/frrouting/frr:[0-9.]+\`#| FRR       | ${FRR_VERSION} (\`quay.io/frrouting/frr:${FRR_VERSION}\`#" README.md
sed -i.bak -E "s#\| Talos     \| v[0-9.]+ \|#| Talos     | ${TALOS_VERSION} |#" README.md
sed -i.bak -E "s#quay\.io/frrouting/frr:[0-9.]+#quay.io/frrouting/frr:${FRR_VERSION}#g" README.md
rm -f README.md.bak

TAG="${TALOS_VERSION}-${FRR_VERSION}-${EXTENSION_REVISION}"
echo "VERSION now: FRR_VERSION=${FRR_VERSION} TALOS_VERSION=${TALOS_VERSION} IMAGER_VERSION=${IMAGER_VERSION} EXTENSION_REVISION=${EXTENSION_REVISION}"
echo "New image tag: ${TAG}"
echo
echo "Next: make build-multiarch && make installer   (or push a v* tag / to main for CI to do it)"
