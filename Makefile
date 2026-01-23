## local variables.
cert_manager_submodule_dir = cert-manager
cert_manager_submodule_tag = $(strip $(shell git config -f .gitmodules submodule.jetstack-cert-manager.tag))
cert_manager_operator_submodule_dir = cert-manager-operator
cert_manager_operator_submodule_branch = $(strip $(shell git config -f .gitmodules submodule.cert-manager-operator.branch))
istio_csr_submodule_dir = cert-manager-istio-csr
istio_csr_submodule_tag = $(strip $(shell git config -f .gitmodules submodule.cert-manager-istio-csr.tag))
cert_manager_containerfile_name = Containerfile.cert-manager
cert_manager_acmesolver_containerfile_name = Containerfile.cert-manager.acmesolver
cert_manager_operator_containerfile_name = Containerfile.cert-manager-operator
cert_manager_operator_bundle_containerfile_name = Containerfile.cert-manager-operator.bundle
istio_csr_containerfile_name = Containerfile.cert-manager-istio-csr
commit_sha = $(strip $(shell git rev-parse HEAD))
source_url = $(strip $(shell git remote get-url origin))
release_version = v$(strip $(shell git branch --show-current | cut -d'-' -f2))

## validate that tags and branches are not empty
ifeq ($(cert_manager_submodule_tag),)
$(error cert_manager_submodule_tag is empty.)
endif
ifeq ($(cert_manager_operator_submodule_branch),)
$(error cert_manager_operator_submodule_branch is empty.)
endif
ifeq ($(istio_csr_submodule_tag),)
$(error istio_csr_submodule_tag is empty.)
endif

## cert-manager-operator-release and cert-manager follow same naming for release
## branches except for cert-manager-operator which has release version as suffix in
## the branch name like in aforementioned repositories, which will be used for
## deriving the submodules branch.
PARENT_BRANCH_SUFFIX = $(strip $(shell git branch --show-current | cut -d'-' -f2))

## current branch name of the cert-manager submodule.
CERT_MANAGER_BRANCH ?= release-$(PARENT_BRANCH_SUFFIX)
## check if the parent module branch is main and assign the equivalent cert-manager
## branch instead of deriving the branch name.
ifeq ($(PARENT_BRANCH_SUFFIX), main)
CERT_MANAGER_BRANCH = master
endif

## current branch name of the cert-manager-operator submodule.
CERT_MANAGER_OPERATOR_BRANCH ?= cert-manager-$(PARENT_BRANCH_SUFFIX)
## check if the parent module branch is main and assign the equivalent cert-manager-operator
## branch instead of deriving the branch name.
ifeq ($(PARENT_BRANCH_SUFFIX), main)
CERT_MANAGER_OPERATOR_BRANCH = master
endif

## current branch name of the istio-csr submodule.
ISTIO_CSR_BRANCH ?= release-$(PARENT_BRANCH_SUFFIX)

ifeq ($(PARENT_BRANCH_SUFFIX), main)
ISTIO_CSR_BRANCH = main
endif

## container build tool to use for creating images.
CONTAINER_ENGINE ?= podman

## image name for cert-manager-operator.
CERT_MANAGER_OPERATOR_IMAGE ?= cert-manager-operator

## image name for cert-manager-operator-bundle.
CERT_MANAGER_OPERATOR_BUNDLE_IMAGE ?= cert-manager-operator-bundle

## image name for cert-manager.
CERT_MANAGER_IMAGE ?= cert-manager

## image name for cert-manager-acmesolver.
CERT_MANAGER_ACMESOLVER_IMAGE ?= cert-manager-acmesolver

## image version to tag the created images with.
IMAGE_VERSION ?= $(release_version)

## image for istio-csr
ISTIO_CSR_IMAGE ?= cert-manager-istio-csr

## image tag makes use of the branch name and
## when branch name is `main` use `latest` as the tag.
ifeq ($(PARENT_BRANCH_SUFFIX), main)
IMAGE_VERSION = latest
endif

## args to pass during image build
IMAGE_BUILD_ARGS ?= --build-arg RELEASE_VERSION=$(release_version) --build-arg COMMIT_SHA=$(commit_sha) --build-arg SOURCE_URL=$(source_url)

## tailored command to build images.
IMAGE_BUILD_CMD = $(CONTAINER_ENGINE) build $(IMAGE_BUILD_ARGS)

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

## checkout submodules branch to match the parent branch.
.PHONY: switch-submodules-branch
switch-submodules-branch:
	# update with local cache.
	git submodule update --recursive

## update submodules revision to match the revision of the origin repository.
.PHONY: update-submodules
update-submodules:
	git submodule foreach --recursive 'git fetch -t'
	cd $(cert_manager_submodule_dir) && git checkout $(cert_manager_submodule_tag) && cd - > /dev/null
	cd $(istio_csr_submodule_dir) && git checkout $(istio_csr_submodule_tag) && cd - > /dev/null
	cd $(cert_manager_operator_submodule_dir) && git checkout $(cert_manager_operator_submodule_branch) && git pull origin $(cert_manager_operator_submodule_branch) && cd - > /dev/null

## build all the images - operator, operand and operator-bundle.
.PHONY: build-images
build-images: build-operand-images build-operator-image build-bundle-image

## build operator image.
.PHONY: build-operator-image
build-operator-image:
	$(IMAGE_BUILD_CMD) -f $(cert_manager_operator_containerfile_name) -t $(CERT_MANAGER_OPERATOR_IMAGE):$(IMAGE_VERSION) .

## build all operand images
.PHONY: build-operand-images
build-operand-images: build-cert-manager-image build-cert-manager-acmesolver-image build-istio-csr-image

## build operator bundle image.
.PHONY: build-bundle-image
build-bundle-image:
	$(IMAGE_BUILD_CMD) -f $(cert_manager_operator_bundle_containerfile_name) -t $(CERT_MANAGER_OPERATOR_BUNDLE_IMAGE):$(IMAGE_VERSION) .

## build operand cert-manager image.
.PHONY: build-cert-manager-image
build-cert-manager-image:
	$(IMAGE_BUILD_CMD) -f $(cert_manager_containerfile_name) -t $(CERT_MANAGER_IMAGE):$(IMAGE_VERSION) .

## build operand cert-manager-acmesolver image.
.PHONY: build-cert-manager-acmesolver-image
build-cert-manager-acmesolver-image:
	$(IMAGE_BUILD_CMD) -f $(cert_manager_acmesolver_containerfile_name) -t $(CERT_MANAGER_ACMESOLVER_IMAGE):$(IMAGE_VERSION) .

## build operand istio-csr image.
.PHONY: build-istio-csr-image
build-istio-csr-image:
	$(IMAGE_BUILD_CMD) -f $(istio_csr_containerfile_name) -t $(ISTIO_CSR_IMAGE):$(IMAGE_VERSION) .

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
verify: verify-shell-scripts verify-containerfiles validate-renovate-config build-images

## update all required contents.
.PHONY: update
update: update-submodules

## clean up temp dirs, images.
.PHONY: clean
clean:
	$(CONTAINER_ENGINE) rmi -i $(CERT_MANAGER_OPERATOR_IMAGE):$(IMAGE_VERSION) \
$(CERT_MANAGER_IMAGE):$(IMAGE_VERSION) \
$(CERT_MANAGER_ACMESOLVER_IMAGE):$(IMAGE_VERSION) \
$(CERT_MANAGER_OPERATOR_BUNDLE_IMAGE):$(IMAGE_VERSION)

## validate renovate config.
.PHONY: validate-renovate-config
validate-renovate-config:
	./hack/renovate-config-validator.sh

