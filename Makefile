include VERSION
export

REGISTRY ?= ghcr.io/marcotollini/frr-for-talos
EXT_IMAGE ?= $(REGISTRY)/extension
INSTALLER_IMAGE ?= $(REGISTRY)/installer
# Canonical version string, used identically for the extension image tag
# and the installer image tag - see VERSION and `scripts/bump-version.sh`.
TAG ?= $(TALOS_VERSION)-$(FRR_VERSION)-$(EXTENSION_REVISION)

# Local, unauthenticated registry used by `make installer`, so nothing
# needs to be pushed to ghcr.io just to build locally.
LOCAL_REGISTRY ?= 127.0.0.1:5005
PLATFORMS ?= linux/amd64,linux/arm64

.PHONY: build build-multiarch push smoke-test \
        registry-up registry-down installer clean

## Build the extension image for the host's native platform and load it
## into the local docker daemon (fast inner-loop build).
build:
	docker buildx build \
		--build-arg FRR_VERSION=$(FRR_VERSION) \
		--build-arg EXTENSION_REVISION=$(EXTENSION_REVISION) \
		--build-arg TALOS_VERSION=$(TALOS_VERSION) \
		-t frr-for-talos/extension:dev \
		--load .

## Build+push a multi-arch extension image to REGISTRY.
build-multiarch:
	docker buildx build \
		--platform $(PLATFORMS) \
		--build-arg FRR_VERSION=$(FRR_VERSION) \
		--build-arg EXTENSION_REVISION=$(EXTENSION_REVISION) \
		--build-arg TALOS_VERSION=$(TALOS_VERSION) \
		-t $(EXT_IMAGE):$(TAG) -t $(EXT_IMAGE):latest \
		--push .

## Alias kept explicit for CI readability.
push: build-multiarch

## Container-level smoke test - builds the image and runs it with plain
## docker (no Talos, no KVM required). Safe to run on colima/macOS.
smoke-test:
	./test/smoke-test.sh

## Start/stop a local, unauthenticated registry for `make installer` /
## local experimentation, so nothing needs pushing to ghcr.io.
registry-up:
	docker start frr-local-registry >/dev/null 2>&1 || \
	docker run -d --name frr-local-registry -p $(LOCAL_REGISTRY):5000 registry:2 >/dev/null

registry-down:
	docker rm -f frr-local-registry >/dev/null 2>&1 || true

installer: registry-up
	docker buildx build \
		--platform $(PLATFORMS) \
		--build-arg FRR_VERSION=$(FRR_VERSION) \
		--build-arg EXTENSION_REVISION=$(EXTENSION_REVISION) \
		--build-arg TALOS_VERSION=$(TALOS_VERSION) \
		-t $(EXT_IMAGE):$(TAG) -t $(EXT_IMAGE):latest \
		-t $(LOCAL_REGISTRY)/frr-extension:$(TAG) \
		--push .
	./test/build-installer.sh "$(LOCAL_REGISTRY)/frr-extension:$(TAG)" "$(INSTALLER_IMAGE):$(TAG)" "$(PLATFORMS)"

clean:
	rm -rf _out .smoke-test-tmp-*
	docker rm -f frr-local-registry >/dev/null 2>&1 || true
