# OpenShift Cert Manager Operator Release Tooling

This repository holds release specific content for cert-manager-operator mainly the Containerfiles which comply with the
requirements for releasing builds through konflux. Repository also holds tekton configuration code added by konflux bots
and cert-manager-operator and operand's(cert-manager) repositories are added as git submodules.

## Getting started

Use below command to clone the project since it has submodules configured. By default, when we clone a project with
submodules configured, the directories of the submodules are created but will not be initialized with content. With
below command, it will automatically initialize and update each submodule in the repository, including nested submodules
if any of the submodules in the repository have submodules themselves.
```console
git clone --recurse-submodules https://github.com/openshift/cert-manager-operator-release.git
```

OR

```console
git clone --recurse-submodules `fork_repository_web_url`
```

## Repository structure

Repository contains below repositories added as git submodules which was created to keep release specific content
outside the main code repository for better management.
- [cert-manager-operator](https://github.com/openshift/cert-manager-operator)
- [cert-manager](https://github.com/openshift/jetstack-cert-manager)
- [cert-manager-istio-csr](https://github.com/openshift/cert-manager-istio-csr)

In each release branch the git submodules are configured with equivalent release branch in their respective origin
repositories. And when switching the parent repository between different branches, the submodule branches will not be
automatically switched and requires using below command for the same.
```console
make switch-submodules-branch
```

## Updating submodules

Use below command to update submodules to the revision same as their origin repository using below command.
```console
make update-submodules
```

## Other commands

Use the command below to get usage summary and interact with the repository.
```console
make help
```

## Automated dependency updates

MintMaker (`red-hat-konflux[bot]`) opens pull requests to refresh dependencies in this repository, including Tekton pipeline references under `.tekton/`. Konflux Components for the end-of-life releases below are annotated so they no longer receive those updates:

| cert-manager version | Repository branch |
|----------------------|-------------------|
| 1.14.x               | `release-1.14`    |
| 1.15.x               | `release-1.15`    |
| 1.16.x               | `release-1.16`    |

See [docs/development/konflux.md](docs/development/konflux.md#disabling-mintmaker-for-end-of-life-releases) for how to disable or manage these updates when a release reaches end of life.

## Updating the catalog

Updating the file-based catalog (FBC) requires both an updated `channel.yaml` and a matching `bundle-*.yaml`. `opm validate` needs both present — either order works, but **update channels first, then run `make update-catalog`**. That way the script adds bundle files and runs `opm validate` on each catalog automatically; you do not need a separate manual validate step.

Between the two steps the catalog is temporarily invalid (channels reference a bundle that does not exist yet). That is expected — complete both steps before merging.

### 1. Update channel.yaml (manual step)

In each affected catalog, **manually update `channel.yaml`** to wire the new version into the upgrade graph. Automated channel updates are intentionally out of scope because release scenarios vary:

- **Minor/major releases** (e.g. v1.19.0 → v1.20.0): add entries to `stable-v1`, create/update `stable-v1.20`, set `replaces` and `skipRange`.
- **Z-stream releases** (e.g. v1.19.0 → v1.19.1): often only update the head of `stable-v1.19` existing channel.
- **Multiple channels** may need different graphs depending on which bundles exist in that OCP catalog.

When replicating bundles across OCP versions, apply the same channel changes to each target catalog first.

### 2. Generate bundle files

Use `make update-catalog` to render a published bundle image into the catalog. Required flags:

```console
make update-catalog \
   OPERATOR_BUNDLE_IMAGE=registry.stage.redhat.io/cert-manager/cert-manager-operator-bundle@sha256:<digest> \
   CATALOG_DIR=catalogs/v4.19/catalog \
   BUNDLE_FILE_NAME=bundle-v1.20.0.yaml \
   REPLICATE_BUNDLE_FILE_IN_CATALOGS=4.19-5.0 \
   USE_MIGRATE_LEVEL_FLAG=yes
```

`REPLICATE_BUNDLE_FILE_IN_CATALOGS` defaults to `no`. Use comma-separated OCP versions (`4.19,4.20`) or a range (`4.19-4.22`) to copy the generated bundle into other catalog directories. The script runs `opm validate` after generating the bundle and after each replicated copy.

Build the catalog image for each OCP version once both steps are complete.

### Summary

| Step | Action | `opm validate` |
|------|--------|----------------|
| 1 | Edit `channel.yaml` manually in each affected catalog | Fails until step 2 (expected) |
| 2 | `make update-catalog` — add `bundle-*.yaml` | Passes (run automatically by the script) |