#!/usr/bin/env bash
# Builds a Talos installer OCI image with the frr-for-talos extension baked
# in, using siderolabs/imager, and pushes a multi-arch manifest.
#
#
# Usage: build-installer.sh <extension-image-ref> <installer-image-ref> <platforms>
#   extension-image-ref: e.g. ghcr.io/marcotollini/frr-for-talos/extension:v1.13.6-10.7.0-1
#   installer-image-ref: e.g. ghcr.io/marcotollini/frr-for-talos/installer:v1.13.6-10.7.0-1
#   platforms:            comma-separated, e.g. linux/amd64,linux/arm64
#
# Requires: docker, the extension image already pushed to a registry
# reachable from inside the imager container (a local registry started
# with `make registry-up` works fine for this, including from CI).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

set -a; source VERSION; set +a

EXT_IMAGE_REF="${1:?usage: build-installer.sh <extension-image-ref> <installer-image-ref> <platforms>}"
INSTALLER_IMAGE_REF="${2:?usage: build-installer.sh <extension-image-ref> <installer-image-ref> <platforms>}"
PLATFORMS="${3:-linux/amd64,linux/arm64}"

OUT="$(pwd)/_out"
rm -rf "$OUT"
mkdir -p "$OUT"

log() { printf '\n==> %s\n' "$*"; }

IFS=',' read -ra PLATFORM_LIST <<< "$PLATFORMS"
PUSHED_REFS=()

for platform in "${PLATFORM_LIST[@]}"; do
  arch="${platform#linux/}"
  log "Running imager for $arch"
  # --network host so imager (talking to a registry at 127.0.0.1:PORT, as
  # started by `make registry-up`) can resolve it the same way the host does.
  docker run --rm --network host \
    -v "$OUT:/out" \
    "ghcr.io/siderolabs/imager:${IMAGER_VERSION}" installer \
    --arch "$arch" \
    --system-extension-image "$EXT_IMAGE_REF"

  tarball="$OUT/installer-${arch}.tar"
  [ -f "$tarball" ] || { echo "expected $tarball to exist after imager run" >&2; exit 1; }

  log "Loading and tagging $arch installer image"
  LOADED_REF="$(docker load -i "$tarball" | sed -n 's/^Loaded image: //p' | tail -n1)"
  [ -n "$LOADED_REF" ] || { echo "could not determine loaded image ref from docker load output" >&2; exit 1; }

  arch_ref="${INSTALLER_IMAGE_REF}-${arch}"
  docker tag "$LOADED_REF" "$arch_ref"
  docker push "$arch_ref"
  PUSHED_REFS+=("$arch_ref")
done

log "Creating multi-arch manifest $INSTALLER_IMAGE_REF"
# --insecure is required for plain-HTTP registries (e.g. the local
# registry started by `make registry-up`); harmless against real ghcr.io.
docker manifest rm "$INSTALLER_IMAGE_REF" >/dev/null 2>&1 || true
docker manifest create --insecure "$INSTALLER_IMAGE_REF" "${PUSHED_REFS[@]}"
docker manifest push --insecure "$INSTALLER_IMAGE_REF"

log "Installer image published: $INSTALLER_IMAGE_REF"
printf '%s\n' "${PUSHED_REFS[@]}"
