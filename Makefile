## local variables.
commit_sha = $(strip $(shell git rev-parse HEAD))
source_url = $(strip $(shell git remote get-url origin))
release_version = v$(strip $(shell git branch --show-current | cut -d'-' -f2))

## cert-manager-operator-release and cert-manager follow same naming for release
## branches except for cert-manager-operator which has release version as suffix in
## the branch name like in aforementioned repositories, which will be used for
## deriving the submodules branch.
PARENT_BRANCH_SUFFIX = $(strip $(shell git branch --show-current | cut -d'-' -f2))

## container build tool to use for creating images.
CONTAINER_ENGINE ?= podman

## image name for cert-manager catalog.
CATALOG_IMAGE ?= cert-manager-catalog

## image version to tag the created images with.
IMAGE_VERSION ?= $(release_version)

## image tag makes use of the branch name and
## when branch name is `main` use `latest` as the tag.
ifeq ($(PARENT_BRANCH_SUFFIX), main)
IMAGE_VERSION = latest
endif

## args to pass during image build
IMAGE_BUILD_ARGS ?= --build-arg RELEASE_VERSION=$(release_version) --build-arg COMMIT_SHA=$(commit_sha) --build-arg SOURCE_URL=$(source_url)

## tailored command to build images.
IMAGE_BUILD_CMD = $(CONTAINER_ENGINE) build $(IMAGE_BUILD_ARGS)

## path to store the tools binary.
TOOL_BIN_DIR = $(strip $(shell git rev-parse --show-toplevel --show-superproject-working-tree | tail -1))/bin/tools

## URL to download Operator Package Manager tool.
OPM_DOWNLOAD_URL = https://github.com/operator-framework/operator-registry/releases/download/v1.48.0/$(shell go env GOOS)-$(shell go env GOARCH)-opm

## Operator Package Manager tool path.
OPM_TOOL_PATH ?= $(TOOL_BIN_DIR)/opm

## Operator bundle image to use for generating catalog.
OPERATOR_BUNDLE_IMAGE ?= 

## Catalog directory where generated catalog will be stored. Directory must have sub-directory with package `openshift-cert-manager-operator` name.
CATALOG_DIR ?= "catalog/"

.DEFAULT_GOAL := help
## usage summary.
.PHONY: help
help:
	@ echo
	@ echo '  Usage:'
	@ echo ''
	@ echo '    make <target> [flags...]'
	@ echo ''
	@ echo '  Targets:'
	@ echo ''
	@ awk '/^#/{ comment = substr($$0,3) } comment && /^[a-zA-Z][a-zA-Z0-9_-]+ ?:/{ print "   ", $$1, comment }' $(MAKEFILE_LIST) | column -t -s ':' | sort
	@ echo ''
	@ echo '  Flags:'
	@ echo ''
	@ awk '/^#/{ comment = substr($$0,3) } comment && /^[a-zA-Z][a-zA-Z0-9_-]+ ?\?=/{ print "   ", $$1, $$2, comment }' $(MAKEFILE_LIST) | column -t -s '?=' | sort
	@ echo ''

## execute all required targets.
.PHONY: all
all: verify

## build operator catalog image.
.PHONY: build-catalog-image
build-catalog-image:
	$(CONTAINER_ENGINE) build -f Containerfile.catalog -t $(CATALOG_IMAGE):$(IMAGE_VERSION) .

## update catalog using the provided bundle image.
.PHONY: update-catalog
update-catalog: get-opm
	@# Ex: make update-catalog OPERATOR_BUNDLE_IMAGE=registry.stage.redhat.io/cert-manager/cert-manager-operator-bundle@sha256:4114321b0ab6ceb882f26501ff9b22214d90b83d92466e7c5a62217f592c1fed CATALOG_DIR=catalogs/v4.17/catalog BUNDLE_FILE_NAME=bundle-v1.15.0.yaml REPLICATE_BUNDLE_FILE_IN_CATALOGS=no USE_MIGRATE_LEVEL_FLAG=yes
	./hack/update_catalog.sh $(OPM_TOOL_PATH) $(OPERATOR_BUNDLE_IMAGE) $(CATALOG_DIR) $(BUNDLE_FILE_NAME) $(REPLICATE_BUNDLE_FILE_IN_CATALOGS) $(USE_MIGRATE_LEVEL_FLAG)

## update catalog and build catalog image.
.PHONY: catalog
catalog: get-opm build-catalog-image

# Only run update-catalog if OPERATOR_BUNDLE_IMAGE is set
ifneq ($(OPERATOR_BUNDLE_IMAGE),)
    catalog: get-opm update-catalog build-catalog-image
endif

## check shell scripts.
.PHONY: verify-shell-scripts
verify-shell-scripts:
	./hack/shell-scripts-linter.sh

## check containerfiles.
.PHONY: verify-containerfiles
verify-containerfiles:
	./hack/containerfile-linter.sh

## verify the changes are working as expected.
.PHONY: verify
verify: verify-shell-scripts verify-containerfiles validate-renovate-config

## get opm(operator package manager) tool.
.PHONY: get-opm
get-opm:
	$(call get-bin,$(OPM_TOOL_PATH),$(TOOL_BIN_DIR),$(OPM_DOWNLOAD_URL))

define get-bin
@[ -f "$(1)" ] || { \
	[ ! -d "$(2)" ] && mkdir -p "$(2)" || true ;\
	echo "Downloading $(3)" ;\
	curl -fL $(3) -o "$(1)" ;\
	chmod +x "$(1)" ;\
}
endef

## clean up temp dirs, images.
.PHONY: clean
clean:
	$(CONTAINER_ENGINE) rmi -i $(CATALOG_IMAGE):$(IMAGE_VERSION)
	rm -r $(TOOL_BIN_DIR)

## validate renovate config.
.PHONY: validate-renovate-config
validate-renovate-config:
	./hack/renovate-config-validator.sh

