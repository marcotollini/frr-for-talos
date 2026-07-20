# syntax=docker/dockerfile:1
# Talos Linux system extension packaging FRRouting (FRR) as an extension
# service, providing zebra, bgpd and bfdd.
#
# A Talos system extension image is just a plain OCI image with:
#   /manifest.yaml
#   /rootfs/<files to overlay onto the Talos root filesystem>
# Talos's `imager` converts /rootfs into a squashfs at boot-asset build time.

ARG FRR_VERSION=10.7.0
ARG EXTENSION_REVISION=2
ARG TALOS_VERSION=v1.13.6

# The upstream FRR image already provides multi-arch (amd64/arm64/...)
# builds with tini as entrypoint and /usr/lib/frr/docker-start as the
# daemon supervisor entrypoint (via watchfrr).
FROM quay.io/frrouting/frr:${FRR_VERSION} AS frr-upstream

# Overlay our defaults on top of the upstream image, preserving frr:frr
# ownership expected by /usr/lib/frr/frrcommon.sh.
FROM frr-upstream AS frr-defaults
COPY --chown=frr:frr rootfs-extra/etc/frr/daemons /etc/frr/daemons
COPY --chown=frr:frr rootfs-extra/etc/frr/frr.conf /etc/frr/frr.conf
COPY --chown=frr:frr rootfs-extra/etc/frr/vtysh.conf /etc/frr/vtysh.conf

# Render manifest.yaml from its template inside the build (keeps the whole
# extension buildable with a single `docker buildx build`, no host-side
# templating step required).
FROM alpine:3.22 AS manifest-builder
ARG FRR_VERSION
ARG EXTENSION_REVISION
ARG TALOS_VERSION
RUN apk add --no-cache gettext
COPY manifest.yaml.tmpl /manifest.yaml.tmpl
RUN FRR_VERSION="${FRR_VERSION}" EXTENSION_REVISION="${EXTENSION_REVISION}" TALOS_VERSION="${TALOS_VERSION}" \
    envsubst '${FRR_VERSION} ${EXTENSION_REVISION} ${TALOS_VERSION}' < /manifest.yaml.tmpl > /manifest.yaml

FROM scratch AS extension
# org.opencontainers.image.source is what makes GitHub auto-link a
# ghcr.io package to this repo's "Packages" sidebar. Without it, a plain
# `docker push` still succeeds and the image genuinely exists on
# ghcr.io - it just shows up disconnected, under the pushing user's own
# account (github.com/<user>?tab=packages), not the repo, and defaults
# to private visibility.
LABEL org.opencontainers.image.source="https://github.com/marcotollini/frr-for-talos"
LABEL org.opencontainers.image.description="FRRouting (FRR) system extension for Talos Linux"
COPY --from=frr-defaults / /rootfs/usr/local/lib/containers/frr/
COPY frr.yaml /rootfs/usr/local/etc/containers/frr.yaml
COPY --from=manifest-builder /manifest.yaml /manifest.yaml
