# frr-for-talos

A [Talos Linux](https://www.talos.dev/) system extension that runs
[FRRouting](https://frrouting.org/) (FRR) as a Talos extension service,
providing:

- **zebra** - installs routes into the Linux kernel routing table
- **bgpd** - BGP (used here for iBGP peering + route exchange)
- **bfdd** - BFD (fast failure detection for the BGP sessions)

`mgmtd` and `staticd` also run (FRR requires them). Everything else is
disabled by default. No routing configuration is baked into the image -
FRR is entirely configured at runtime via Talos's own declarative machine
config (`talosctl patch machineconfig` with an `ExtensionServiceConfig`).

This repo builds a standalone Talos system extension, a fully-built Talos **installer image**
with the extension baked in, and CI that publishes both to `ghcr.io`.

Pinned versions (see [`VERSION`](VERSION)):

| Component | Version |
|---|---|
| FRR       | 10.7.0 (`quay.io/frrouting/frr:10.7.0`, official multi-arch image) |
| Talos     | v1.13.6 |

## How it's put together

A Talos system extension is a plain OCI image with a fixed layout

```
/manifest.yaml                                    # extension metadata
/rootfs/usr/local/etc/containers/frr.yaml         # extension SERVICE definition
/rootfs/usr/local/lib/containers/frr/...          # the extension's own container rootfs
```

[`Dockerfile`](Dockerfile) builds this by taking the official
`quay.io/frrouting/frr` image as-is, overlays
[`rootfs-extra/etc/frr/daemons`](rootfs-extra/etc/frr/daemons) (enables
bgpd + bfdd) and a placeholder [`frr.conf`](rootfs-extra/etc/frr/frr.conf),
and packages it.

[`frr.yaml`](frr.yaml) is the Talos **extension service** definition -
it tells `machined` how to run the extension: entrypoint `tini --
/usr/lib/frr/docker-start`, `writeableRootfs`/`writeableSysfs` (FRR needs
to write PID/socket files and touch `/proc/sys/net`), and
`depends: [configuration: true]`, meaning **the service will not start
until an `ExtensionServiceConfig` has been applied for it**.

## Configuration

Configure a node by applying an `ExtensionServiceConfig`
that mounts a rendered `frr.conf` over `/etc/frr/frr.conf` inside the
extension container:

```
talosctl patch machineconfig -p @my-node-frr-config.yaml -n <node-ip>
```

See [`examples/extensionserviceconfig.yaml`](examples/extensionserviceconfig.yaml)
for a complete, ready-to-adapt example, and
[`examples/frr.conf.example`](examples/frr.conf.example) for the
underlying FRR config template.

Applying a new `ExtensionServiceConfig` restarts the `ext-frr` service.
For live troubleshooting without a restart, use `vtysh` interactively
against the running daemons (see **Troubleshooting** below). This will be read only,
and `ExtensionServiceConfig` applied via `talosctl` is the single source of truth.

## Building

Requires Docker with the `buildx` plugin (on colima: `brew install
docker-buildx` and add `"cliPluginsExtraDirs":
["/opt/homebrew/lib/docker/cli-plugins"]` to `~/.docker/config.json`).

```
make build              # build the extension image, native platform, --load
make build-multiarch    # build+push linux/amd64+linux/arm64 to $REGISTRY
make installer          # build a full Talos installer image (via imager) with
                        # the extension baked in, push to $INSTALLER_IMAGE
```

## Versioning

[`VERSION`](VERSION) is the single source of truth for every pinned
version (`FRR_VERSION`, `TALOS_VERSION`, `IMAGER_VERSION`,
`EXTENSION_REVISION`).

Both the extension image and the installer image are always tagged
`{talos-version}-{frr-version}-{revision}`, e.g. `v1.13.6-10.7.0-1`,
computed from `VERSION` (see the Makefile's `TAG` variable).

To bump a version:

```
scripts/bump-version.sh frr <version>       # e.g. 10.8.0 - resets EXTENSION_REVISION to 1
scripts/bump-version.sh talos <version>     # e.g. v1.14.0 - the Talos version being installed
scripts/bump-version.sh imager <version>    # e.g. v1.14.0 - the imager build tool version,
                                            # independent of `talos` above
scripts/bump-version.sh revision            # bump EXTENSION_REVISION by 1 (packaging-only change)
```

Then `make build-multiarch && make installer` (or push to `main` or `v*`
tag and let CI do it).

[`.github/workflows/version-check.yml`](.github/workflows/version-check.yml)
polls FRR/Talos/imager upstream releases daily and opens a PR (via this
same `scripts/bump-version.sh`) whenever one is newer than what's
pinned.

## Installing

[Image Factory](https://factory.talos.dev) only accepts extensions already
merged into the `siderolabs/extensions` catalog - it has no path for a
custom, unpublished extension like this one. So `make installer` runs
[`siderolabs/imager`](https://github.com/siderolabs/imager) directly
(`ghcr.io/siderolabs/imager`) against the pushed extension image to
produce a real Talos installer OCI image, exactly like `talosctl cluster
create`'s own docs recommend for local extension development. That
installer image is the "fully built image" deliverable - point
`talosctl` at it directly:

```
talosctl gen config mycluster https://<endpoint>:6443 \
  --install-image ghcr.io/marcotollini/frr-for-talos/installer:latest

talosctl apply-config --insecure -n <vm-ip> --file controlplane.yaml

# or, on an already-running node:
talosctl upgrade -n <node-ip> -i ghcr.io/marcotollini/frr-for-talos/installer:latest
```

## Publishing (GitHub Actions)

[`.github/workflows/ci.yml`](.github/workflows/ci.yml):

- **every push and PR**: `smoke-test` (container-level, see below) runs.
- **push to `main` or a `v*` tag**: additionally builds and pushes the
  multi-arch extension image and the multi-arch installer image to
  `ghcr.io/<owner>/frr-for-talos/{extension,installer}`, tagged both with
  the specific version and `:latest`.

## Testing

### `make smoke-test` - container-level, runs anywhere with Docker

Works on colima/macOS (no KVM needed). [`test/smoke-test.sh`](test/smoke-test.sh):

1. Builds the extension image and validates its layout
   (`/manifest.yaml`, `/rootfs/usr/local/etc/containers/frr.yaml`, the
   daemon binaries, `bgpd=yes`/`bfdd=yes` in the default `daemons` file).
2. Boots the daemon set standalone via plain `docker run` and confirms
   zebra, mgmtd, staticd, bgpd and bfdd all come up and are reachable
   over `vtysh`.
3. Syntax-checks `examples/frr.conf.example` with `vtysh -C`.
4. Runs a **real two-node iBGP + BFD test**: two containers, each
   running the daemon image, peer with each other, each advertises a
   `/32` loopback into BGP, and the test asserts the session reaches
   `Established`, BFD reaches `up`, and the peer's loopback route is
   actually installed into the **kernel routing table** by zebra - the
   exact mechanism the topology in `examples/` relies on.

This does not boot Talos - it validates the FRR image is packaged and
behaves correctly. `SMOKE_PLATFORM=linux/amd64` (or `arm64`) overrides
the platform; it defaults to the host's native arch, since zebra's raw
netlink I/O is unreliable under qemu-user cross-arch emulation.

## Troubleshooting

- `talosctl -n <ip> service ext-frr` - service status.
- `talosctl -n <ip> logs ext-frr` - watchfrr/zebra/bgpd/bfdd startup and
  runtime logs (add `log stdout notifications` or similar to `frr.conf`
  for the daemons' own logs to show up here too).
- There's no `talosctl exec` into a node's containers by design. To run
  `vtysh` interactively, deploy a small debug pod on that node with a
  `hostPath` mount of `/var/run/frr`:

  ```
  kubectl run frr-debug --image=quay.io/frrouting/frr:10.7.0 \
    --overrides='{"spec":{"nodeName":"<node-name>","tolerations":[{"operator":"Exists"}]}}' \
    --command -- sleep infinity
  kubectl set volume pod/frr-debug --add --type=hostPath --path=/var/run/frr --mount-path=/var/run/frr
  kubectl exec -it frr-debug -- vtysh
  ```

## Scope

This repo is the FRR Talos extension only, per the project brief - it
does not configure Talos networking (VLANs/bonding on `nic0`/`nic1`),
Cilium's own BGP control plane, or R/S themselves. `examples/` shows how
the extension's configuration surface maps onto the decided topology, but
the actual per-node ASN/IP substitution, R/S-side BGP route-reflector
config, and Talos `machine.network` interface setup are out of scope
here.
