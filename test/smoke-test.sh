#!/usr/bin/env bash
# Container-level smoke test for the frr-for-talos extension.
#
# This does NOT boot Talos - it validates, using plain Docker (works on
# colima/macOS with no KVM):
#
#   1. The built extension image has the exact layout Talos requires
#      (/manifest.yaml, /rootfs/usr/local/etc/containers/frr.yaml,
#      /rootfs/usr/local/lib/containers/frr/...).
#   2. The FRR daemon set the extension enables by default (zebra, mgmtd,
#      staticd, bgpd, bfdd) actually starts and is reachable over vtysh.
#   3. The example frr.conf shipped in examples/ parses cleanly.
#   4. A real two-node iBGP session with BFD comes up between two
#      containers running the extension's daemon image, and a loopback
#      route learned over BGP gets installed into the kernel routing
#      table by zebra - i.e. the exact mechanism the target topology in
#      README.md relies on.
#
# Requires: docker (with buildx), jq.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# shellcheck disable=SC1091
set -a; source VERSION; set +a

# Default to the host's native platform: FRR's zebra daemon does raw
# netlink I/O, which is unreliable under qemu-user cross-arch emulation
# (observed: "recvmsg overrun" / zebra crash-looping when e.g. running
# linux/amd64 under emulation on an arm64 host). Override with
# SMOKE_PLATFORM=linux/amd64 to force a specific arch if you have native
# support for it (e.g. in CI on an amd64 runner).
case "$(uname -m)" in
  arm64|aarch64) DEFAULT_PLATFORM="linux/arm64" ;;
  *) DEFAULT_PLATFORM="linux/amd64" ;;
esac
PLATFORM="${SMOKE_PLATFORM:-$DEFAULT_PLATFORM}"
EXT_TAG="frr-for-talos/extension:smoke"
DAEMON_TAG="frr-for-talos/daemons:smoke"
NETWORK="frr-smoke-net-$$"
SUBNET="172.30.30.0/24"
NODE1_IP="172.30.30.11"
NODE2_IP="172.30.30.12"
NODE1_LOOPBACK="10.10.0.1"
NODE2_LOOPBACK="10.10.0.2"
ASN=65000
WORKDIR=""

log() { printf '\n==> %s\n' "$*"; }
ok() { printf 'OK: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
  [ -n "${SMOKE_KEEP:-}" ] && { echo "SMOKE_KEEP set, leaving containers/network up for inspection"; return; }
  docker rm -f frr-smoke-1 frr-smoke-2 >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
  [ -n "$WORKDIR" ] && rm -rf "$WORKDIR"
}
trap cleanup EXIT

log "Building extension image ($EXT_TAG, platform=$PLATFORM)"
docker buildx build --platform "$PLATFORM" \
  --build-arg "FRR_VERSION=${FRR_VERSION}" \
  --build-arg "EXTENSION_REVISION=${EXTENSION_REVISION}" \
  --build-arg "TALOS_VERSION=${TALOS_VERSION}" \
  -t "$EXT_TAG" --load .

log "Validating extension image layout"
# Use a workdir under the repo, not the system TMPDIR: on colima/macOS the
# default TMPDIR (/var/folders/...) is not mounted into the docker VM, so
# bind-mounting files from there into containers silently fails.
WORKDIR="$(pwd)/.smoke-test-tmp-$$"
mkdir -p "$WORKDIR"
CID="$(docker create --platform "$PLATFORM" "$EXT_TAG" noop)"
docker export "$CID" | tar -x -C "$WORKDIR"
docker rm "$CID" >/dev/null

[ -f "$WORKDIR/manifest.yaml" ] || fail "missing /manifest.yaml"
grep -q '^version: v1alpha1' "$WORKDIR/manifest.yaml" || fail "manifest.yaml missing version: v1alpha1"
grep -q "name: frr" "$WORKDIR/manifest.yaml" || fail "manifest.yaml missing metadata.name: frr"
# Canonical {talos}-{frr}-{revision} version string - see VERSION and
# scripts/bump-version.sh. Asserted on content, not just presence, since
# a missing build-arg here would otherwise render "-1" silently.
EXPECTED_MANIFEST_VERSION="${TALOS_VERSION}-${FRR_VERSION}-${EXTENSION_REVISION}"
grep -qF "version: \"${EXPECTED_MANIFEST_VERSION}\"" "$WORKDIR/manifest.yaml" \
  || fail "manifest.yaml version is not '${EXPECTED_MANIFEST_VERSION}' (got: $(grep 'version:' "$WORKDIR/manifest.yaml" | head -1))"

SVC_DEF="$WORKDIR/rootfs/usr/local/etc/containers/frr.yaml"
[ -f "$SVC_DEF" ] || fail "missing extension service definition at usr/local/etc/containers/frr.yaml"
grep -q '^name: frr' "$SVC_DEF" || fail "frr.yaml missing name: frr"

FRR_ROOT="$WORKDIR/rootfs/usr/local/lib/containers/frr"
[ -x "$FRR_ROOT/sbin/tini" ] || fail "missing tini entrypoint in extension container rootfs"
[ -x "$FRR_ROOT/usr/lib/frr/docker-start" ] || fail "missing docker-start in extension container rootfs"
grep -q '^bgpd=yes' "$FRR_ROOT/etc/frr/daemons" || fail "bgpd not enabled by default"
grep -q '^bfdd=yes' "$FRR_ROOT/etc/frr/daemons" || fail "bfdd not enabled by default"
ok "extension image layout is valid"

log "Building runnable daemon image for functional tests ($DAEMON_TAG)"
docker buildx build --platform "$PLATFORM" \
  --build-arg "FRR_VERSION=${FRR_VERSION}" \
  --target frr-defaults -t "$DAEMON_TAG" --load .

log "Checking example frr.conf syntax (vtysh -C)"
# examples/frr.conf.example is a template with <PLACEHOLDER> tokens for
# values that depend on the user's own R/S addressing; substitute dummy
# valid values before syntax-checking it.
sed -e 's/<ASN>/65000/g' \
    -e 's/<NODE_LOOPBACK>/10.10.0.1/g' \
    -e 's/<IFACE_TO_R>/eth0.1011/g' \
    -e 's/<R_IP>/10.10.11.254/g' \
    -e 's/<S_IP>/10.10.12.254/g' \
    examples/frr.conf.example > "$WORKDIR/example-rendered.conf"
docker run --rm --platform "$PLATFORM" \
  -v "$WORKDIR/example-rendered.conf:/etc/frr/frr.conf:ro" \
  --entrypoint vtysh "$DAEMON_TAG" -C -f /etc/frr/frr.conf \
  || fail "examples/frr.conf.example failed vtysh syntax check (after placeholder substitution)"
ok "examples/frr.conf.example parses cleanly"

log "Starting default daemon set standalone and checking it comes up healthy"
docker rm -f frr-smoke-1 >/dev/null 2>&1 || true
docker run -d --name frr-smoke-1 --platform "$PLATFORM" \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BIND_SERVICE --cap-add SYS_ADMIN \
  "$DAEMON_TAG" >/dev/null

for i in $(seq 1 20); do
  RUNNING="$(docker exec frr-smoke-1 vtysh -c 'show daemons' 2>/dev/null || true)"
  echo "$RUNNING" | grep -q zebra && echo "$RUNNING" | grep -q bgpd && echo "$RUNNING" | grep -q bfdd && break
  sleep 1
done
echo "$RUNNING" | grep -q zebra || fail "zebra did not come up"
echo "$RUNNING" | grep -q mgmtd || fail "mgmtd did not come up"
echo "$RUNNING" | grep -q staticd || fail "staticd did not come up"
echo "$RUNNING" | grep -q bgpd || fail "bgpd did not come up"
echo "$RUNNING" | grep -q bfdd || fail "bfdd did not come up"
ok "zebra, mgmtd, staticd, bgpd, bfdd all running and reachable over vtysh"
docker rm -f frr-smoke-1 >/dev/null 2>&1 || true

log "Starting two-node iBGP + BFD peering test (mirrors the loopback-advertisement design in README.md)"
docker network create --subnet "$SUBNET" "$NETWORK" >/dev/null

render_conf() {
  local router_id="$1" peer="$2"
  cat <<EOF
frr defaults traditional
hostname smoke-${router_id}
log stdout notifications
service integrated-vtysh-config
!
router bgp ${ASN}
 bgp router-id ${router_id}
 no bgp ebgp-requires-policy
 no bgp network import-check
 neighbor ${peer} remote-as ${ASN}
 neighbor ${peer} bfd
 redistribute connected
!
bfd
 peer ${peer}
  no shutdown
 !
!
line vty
!
EOF
}

render_conf "$NODE1_LOOPBACK" "$NODE2_IP" > "$WORKDIR/node1-frr.conf"
render_conf "$NODE2_LOOPBACK" "$NODE1_IP" > "$WORKDIR/node2-frr.conf"

docker run -d --name frr-smoke-1 --platform "$PLATFORM" \
  --network "$NETWORK" --ip "$NODE1_IP" \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BIND_SERVICE --cap-add SYS_ADMIN \
  -v "$WORKDIR/node1-frr.conf:/etc/frr/frr.conf:ro" \
  "$DAEMON_TAG" >/dev/null

docker run -d --name frr-smoke-2 --platform "$PLATFORM" \
  --network "$NETWORK" --ip "$NODE2_IP" \
  --cap-add NET_ADMIN --cap-add NET_RAW --cap-add NET_BIND_SERVICE --cap-add SYS_ADMIN \
  -v "$WORKDIR/node2-frr.conf:/etc/frr/frr.conf:ro" \
  "$DAEMON_TAG" >/dev/null

sleep 3
# Simulate each node's "Lo 10.10.0.x/24 node identifier" from the target
# topology by adding a /32 on loopback; redistribute connected picks it up.
docker exec frr-smoke-1 ip addr add "${NODE1_LOOPBACK}/32" dev lo
docker exec frr-smoke-2 ip addr add "${NODE2_LOOPBACK}/32" dev lo

log "Waiting for BGP session to reach Established"
BGP_STATE=""
for i in $(seq 1 30); do
  BGP_STATE="$(docker exec frr-smoke-1 vtysh -c 'show bgp summary json' 2>/dev/null \
    | jq -r --arg peer "$NODE2_IP" '.ipv4Unicast.peers[$peer].state // empty' 2>/dev/null || true)"
  [ "$BGP_STATE" = "Established" ] && break
  sleep 1
done
if [ "$BGP_STATE" != "Established" ]; then
  docker exec frr-smoke-1 vtysh -c "show bgp summary" || true
  docker logs frr-smoke-1 || true
  fail "BGP session to $NODE2_IP did not reach Established"
fi
ok "iBGP session Established (AS $ASN, node1 <-> node2)"

log "Waiting for BFD session to come up"
BFD_STATE=""
for i in $(seq 1 30); do
  BFD_STATE="$(docker exec frr-smoke-1 vtysh -c 'show bfd peers json' 2>/dev/null \
    | jq -r --arg peer "$NODE2_IP" '.[] | select(.peer==$peer) | .status // empty' 2>/dev/null || true)"
  [ "$BFD_STATE" = "up" ] && break
  sleep 1
done
if [ "$BFD_STATE" != "up" ]; then
  docker exec frr-smoke-1 vtysh -c "show bfd peers" || true
  fail "BFD session to $NODE2_IP did not come up"
fi
ok "BFD session up"

log "Verifying node2's loopback was learned over BGP and installed into the kernel FIB by zebra"
# BGP reaching Established doesn't guarantee redistribution has already
# propagated the loopback route, so poll rather than check once.
ROUTE_LEARNED=""
for i in $(seq 1 30); do
  ROUTE_DETAIL="$(docker exec frr-smoke-1 vtysh -c "show ip route ${NODE2_LOOPBACK}/32" 2>/dev/null || true)"
  if echo "$ROUTE_DETAIL" | grep -q 'Known via "bgp"' && echo "$ROUTE_DETAIL" | grep -q 'Status: Installed'; then
    ROUTE_LEARNED=1
    break
  fi
  sleep 1
done
[ -n "$ROUTE_LEARNED" ] || { echo "$ROUTE_DETAIL"; fail "${NODE2_LOOPBACK}/32 was not learned via bgp and Installed on node1"; }
docker exec frr-smoke-1 ip route show "${NODE2_LOOPBACK}/32" | grep -q "$NODE2_LOOPBACK" \
  || fail "${NODE2_LOOPBACK}/32 is not present in the kernel routing table on node1"
ok "node2 loopback (${NODE2_LOOPBACK}/32) learned via iBGP and installed in the kernel FIB on node1"

printf '\nALL SMOKE TESTS PASSED\n'
