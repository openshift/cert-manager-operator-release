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