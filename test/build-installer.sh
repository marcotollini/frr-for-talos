#!/usr/bin/env bash
# Builds a Talos installer OCI image with the frr-for-talos extension baked
# in, using siderolabs/imager, and pushes a multi-arch manifest.
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

# resolve_official_extensions
# Prints one digest-pinned image ref per line, one per name in
# OFFICIAL_EXTENSIONS.
#
# The refs are read from ghcr.io/siderolabs/extensions:${TALOS_VERSION}, a
# catalogue image whose only real content is an /image-digests file listing
# every official extension built for that exact Talos release, already pinned
# by digest. Reading it here rather than pinning versions in VERSION means the
# extensions can never drift out of step with the kernel they load into --
# which is the one failure mode that produces a node that will not boot.
resolve_official_extensions() {
    [ -n "${OFFICIAL_EXTENSIONS:-}" ] || return 0

    local catalogue="ghcr.io/siderolabs/extensions:${TALOS_VERSION}"
    local probe="frr-for-talos-extensions-$$"
    local digests names name ref

    docker pull -q "$catalogue" >/dev/null
    # The catalogue is FROM scratch with no entrypoint, so it can be created
    # (never started) with a dummy command purely to export its filesystem.
    docker create --name "$probe" "$catalogue" x >/dev/null
    digests="$(docker export "$probe" | tar xO image-digests)"
    docker rm "$probe" >/dev/null

    IFS=',' read -ra names <<< "$OFFICIAL_EXTENSIONS"
    for name in "${names[@]}"; do
        [ -n "$name" ] || continue
        # Anchored, and the ':' is required: an unanchored match for
        # "iscsi-tools" also matches "trident-iscsi-tools", which is a
        # different extension entirely.
        ref="$(printf '%s\n' "$digests" | grep -E "^ghcr\.io/siderolabs/${name}:" || true)"
        if [ -z "$ref" ]; then
            echo "extension '${name}' is not in ${catalogue}" >&2
            echo "available:" >&2
            printf '%s\n' "$digests" | sed -n 's#^ghcr\.io/siderolabs/\([^:]*\):.*#  \1#p' >&2
            exit 1
        fi
        if [ "$(printf '%s\n' "$ref" | wc -l | tr -d ' ')" != "1" ]; then
            echo "extension name '${name}' matched more than one entry in ${catalogue}:" >&2
            printf '%s\n' "$ref" >&2
            exit 1
        fi
        printf '%s\n' "$ref"
    done
}

log "Resolving official extensions for Talos ${TALOS_VERSION}"
OFFICIAL_REFS="$(resolve_official_extensions)"

# The FRR extension first, then any official ones. imager accepts
# --system-extension-image repeatedly; order is not significant.
EXT_ARGS=(--system-extension-image "$EXT_IMAGE_REF")
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    EXT_ARGS+=(--system-extension-image "$ref")
    log "  + $ref"
done <<< "$OFFICIAL_REFS"

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
    "${EXT_ARGS[@]}"

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
