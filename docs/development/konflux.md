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
pipelinesascode.tekton.dev/on-cel-expression: event == "pull_request" && target_branch == "release-1.15" && (".tekton/jetstack-cert-manager-acmesolver-1-15-pull-request.yaml".pathChanged() || "Containerfile.cert-manager.acmesolver".pathChanged() || "cert-manager".pathChanged())
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