# shared-workflows

## Introduction

This repository contains [reusable GitHub Action workflows](https://docs.github.com/en/actions/using-workflows/reusing-workflows).

Reusable composite actions can be found in https://github.com/rapidsai/shared-actions.

See the articles below for a comparison between these two types of reusable GitHub Action components:

- https://wallis.dev/blog/composite-github-actions
- https://dev.to/n3wt0n/composite-actions-vs-reusable-workflows-what-is-the-difference-github-actions-11kd

## Folder Structure

Reusable workflows must be placed in the `.github/workflows` directory as mentioned in the community discussions below:

- https://github.com/community/community/discussions/10773
- https://github.com/community/community/discussions/9050

## Usage

### matrix_filter

Several of the workflows in this project have matrices (combinations of workflow inputs) expressed in inline YAML/JSON.
Those workflows tend to offer an input, `matrix_filter`, for post-processing of that matrix.

For example, by default `wheels-build` has builds for all combinations of CPU architecture, Python version, CUDA major version, and operating system supported by RAPIDS.
Not all projects need that, so they sometimes invoke the workflow like this:

```yaml
wheel-build-nx-cugraph:
  secrets: inherit
  uses: rapidsai/shared-workflows/.github/workflows/wheels-build.yaml@main
  with:
    build_type: pull-request
    script: ci/build_wheel_nx-cugraph.sh
    # This selects "ARCH=amd64 + the latest supported Python, 1 job per major CUDA version".
    matrix_filter: map(select(.ARCH == "amd64")) | group_by(.CUDA_VER|split(".")|map(tonumber)|.[0]) | map(max_by([(.PY_VER|split(".")|map(tonumber)), (.CUDA_VER|split(".")|map(tonumber))]))
    package-name: nx-cugraph
    package-type: python
    pure-wheel: true
```

Something like the bash snippet below can be used to test those filters.

```bash
#!/bin/bash

export MATRIX_FILTER='map(select(.ARCH == "amd64")) | group_by(.CUDA_VER|split(".")|map(tonumber)|.[0]) | map(max_by([(.PY_VER|split(".")|map(tonumber)), (.CUDA_VER|split(".")|map(tonumber))]))'

export MATRIX="
# amd64
- { ARCH: 'amd64', PY_VER: '3.11', CUDA_VER: '12.9.1', LINUX_VER: 'rockylinux8' }
- { ARCH: 'amd64', PY_VER: '3.12', CUDA_VER: '12.9.1', LINUX_VER: 'rockylinux8' }
- { ARCH: 'amd64', PY_VER: '3.13', CUDA_VER: '12.9.1', LINUX_VER: 'rockylinux8' }
- { ARCH: 'amd64', PY_VER: '3.11', CUDA_VER: '13.0.2', LINUX_VER: 'rockylinux8' }
- { ARCH: 'amd64', PY_VER: '3.12', CUDA_VER: '13.0.2', LINUX_VER: 'rockylinux8' }
- { ARCH: 'amd64', PY_VER: '3.13', CUDA_VER: '13.0.2', LINUX_VER: 'rockylinux8' }
# arm64
- { ARCH: 'arm64', PY_VER: '3.11', CUDA_VER: '12.9.1', LINUX_VER: 'rockylinux8' }
- { ARCH: 'arm64', PY_VER: '3.12', CUDA_VER: '12.9.1', LINUX_VER: 'rockylinux8' }
- { ARCH: 'arm64', PY_VER: '3.13', CUDA_VER: '12.9.1', LINUX_VER: 'rockylinux8' }
- { ARCH: 'arm64', PY_VER: '3.11', CUDA_VER: '13.0.2', LINUX_VER: 'rockylinux8' }
- { ARCH: 'arm64', PY_VER: '3.12', CUDA_VER: '13.0.2', LINUX_VER: 'rockylinux8' }
- { ARCH: 'arm64', PY_VER: '3.13', CUDA_VER: '13.0.2', LINUX_VER: 'rockylinux8' }
"

MATRIX="$(
    yq -n -o json 'env(MATRIX)' | \
    jq -c "${MATRIX_FILTER} | if (. | length) > 0 then {include: .} else \"Error: Empty matrix\n\" | halt_error(1) end"
)"

echo "${MATRIX}" | jq
```

### Secrets

Some workflows support passing in arbitrary secrets and making them available as environment variables for the `script:` input.

For example, if you had the following:

* a repo secret called `PENGUINS_AND_POLAR_BEARS_DATASET_URI`
* a testing script that downloads whatever it finds in environment variable `BENCHMARK_DATASET_URI`

You could do something like the following:

```yaml
wheel-tests:
  uses: rapidsai/shared-workflows/.github/workflows/wheels-test.yaml@main
  with:
    script: ci/test_wheel.sh
  secrets:
    script-env-secret-1-key: BENCHMARK_DATASET_URI
    script-env-secret-1-value: ${{ secrets.PENGUINS_AND_POLAR_BEARS_DATASET_URI }}
```

Values passed through `secrets:` are redacted everywhere in the GitHub UI, including in logs, and in most cases are replaced with `***`.

### Java/Maven Release Workflows

This repository provides reusable workflows for RAPIDS Java/Maven publication:

* `.github/workflows/maven-artifact-publish.yaml`
* `.github/workflows/maven-central-publish.yaml`
* `.github/workflows/maven-publication-sanity.yaml`
* `.github/workflows/java-api-docs-publish.yaml`

These workflows are intended to keep generic Maven publication logic out of project repositories. Project-specific build logic, classifier matrices, and native-library packaging should remain in the calling repository.

Supported Java/Maven `build_type` values are:

* `pull-request`: validation only. Publication workflows reject this build type.
* `branch`: publish to an internal RAPIDS Artifactory Maven repository.
* `nightly`: publish snapshots to the configured snapshot destinations.
* `release`: stage release artifacts, validate the Central Publisher bundle, promote after caller-controlled approval, publish Java API docs, and run publication sanity checks.

Example Artifactory publish caller:

```yaml
publish-java-branch:
  uses: rapidsai/shared-workflows/.github/workflows/maven-artifact-publish.yaml@main
  with:
    build_type: branch
    artifact_directory: java-maven-repository
    artifactory_url: ${{ vars.RAPIDS_ARTIFACTORY_URL }}
    artifactory_repository: ${{ vars.RAPIDS_MAVEN_BRANCH_REPOSITORY }}
    maven_group_id: ai.rapids
    artifact_id: cudf
    version: 26.08.0-SNAPSHOT
    expected_classifiers: '["cuda12-x86_64", "cuda12-aarch64"]'
    dry_run: true
  secrets:
    ARTIFACTORY_USERNAME: ${{ secrets.ARTIFACTORY_USERNAME }}
    ARTIFACTORY_TOKEN: ${{ secrets.ARTIFACTORY_TOKEN }}
```

The Central Publisher workflow validates deployment bundle size before upload. The default limit is `1073741824` bytes (`1GB`), matching the documented Central Publisher upload bundle limit.

The Java API docs workflow validates that generated Javadocs contain `index.html`. If no docs publication backend has been wired through `publish_script`, non-dry-run calls fail explicitly instead of silently preserving a manual publication step.
