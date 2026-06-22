# Konflux release pipeline configuration code

konflux bot creates the initial pipeline configuration code based on the konflux configuration code in `.tekton`
directory. A separate pipeline config is created for each trigger events i.e. on creating pull requests and on
merging pull requests and the same for each application created in the konflux.

## Below changes were made to the base pipeline code presented by the konflux bot

### Add below annotations to configure multi-arch builds
```
build.appstudio.openshift.io/pipeline: '{"name":"docker-build-multi-platform-oci-ta","bundle":"latest"}'
build.appstudio.openshift.io/request: "configure-pac"
```

### Add below validations to avoid redundant builds and to trigger builds only specific changes.

For example, below configuration is for triggering builds only when build trigger event is for a pull request creation,
and the branch is `release-1.15` and following files are updated `.tekton/jetstack-cert-manager-acmesolver-1-15-pull-request.yaml`,
`Containerfile.cert-manager.acmesolver` or when directory `cert-manager` is updated.
```
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" && target_branch == "release-1.15" && (".tekton/jetstack-cert-manager-acmesolver-1-15-pull-request.yaml".pathChanged() || "Containerfile.cert-manager.acmesolver".pathChanged() || "cert-manager/***".pathChanged())
```

### Configure required architectures the images should be built for as build parameter.
```
linux/x86_64
linux/s390x
linux/ppc64le
linux/arm64
```

Refer below PRs for more details on the above changes.
- https://github.com/openshift/cert-manager-operator-release/pull/4
- https://github.com/openshift/cert-manager-operator-release/pull/5
- https://github.com/openshift/cert-manager-operator-release/pull/6
- https://github.com/openshift/cert-manager-operator-release/pull/7

## Disabling MintMaker for end-of-life releases

MintMaker is the Konflux dependency update service built on [Renovate](https://docs.renovatebot.com/). On GitHub it appears as `red-hat-konflux[bot]` and commonly opens pull requests titled **chore(deps): update konflux references** to refresh Tekton task bundle digests and related image references in `.tekton/`. Repository-level behavior is configured in `renovate.json` at the root of the default branch.

Each supported release is represented by one or more Konflux **Components** in App Studio (one Component per Git branch and onboarded image or pipeline). While a release is supported, those Components continue to receive MintMaker updates.

When an OpenShift release reaches end of life, automated updates for that stream are turned off by annotating **every** Konflux Component that targets the EOL Git branch. The supported releases and their annotation status are listed in the [README](../../README.md#automated-dependency-updates).

### Disable updates for a release

1. Identify all Components in your App Studio tenant namespace that use the EOL branch (for example `release-1.14`). Component names match Konflux onboarding (for example `cert-manager-operator-1-14`, `jetstack-cert-manager-1-14`, bundle, catalog/index, and any other Components for that branch).

2. Annotate each Component:

```console
oc -n <tenant-namespace> annotate component/<component-name> mintmaker.appstudio.redhat.com/disabled=true --overwrite
```

3. Add the OpenShift version and repository branch to the table in [README.md](../../README.md#automated-dependency-updates).

4. Close any open `red-hat-konflux[bot]` pull requests that target the EOL branch so stale branches are not updated on a later MintMaker run.

Annotating a Component disables **all** MintMaker activity for that repository and branch (Tekton references, Containerfiles, and other managers). Konflux builds are unaffected; only automated dependency bump pull requests stop.

### Re-enable updates

Remove the annotation if a branch should receive MintMaker updates again:

```console
oc -n <tenant-namespace> annotate component/<component-name> mintmaker.appstudio.redhat.com/disabled- --overwrite
```

Remove the corresponding row from the README table.

### References

- [Konflux dependency management — offboarding a repository](https://konflux-ci.dev/docs/mintmaker/user/#offboarding-a-repository)
