#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

GNUPGHOME="${TEST_ROOT}/gnupg"
export GNUPGHOME
mkdir -m 700 "${GNUPGHOME}"
GPG_PASSPHRASE=test-passphrase
gpg --batch --yes --pinentry-mode loopback \
  --passphrase "${GPG_PASSPHRASE}" \
  --quick-generate-key 'Maven Publish Test <maven-publish-test@nvidia.com>' \
  rsa2048 sign 1d
GPG_PRIVATE_KEY=$(gpg --batch --yes --pinentry-mode loopback \
  --passphrase "${GPG_PASSPHRASE}" --armor --export-secret-keys)

export GPG_PRIVATE_KEY GPG_PASSPHRASE

# Sign both a release-shaped and a -SNAPSHOT-shaped input to cover both
# publication destinations. Both must succeed; the destination check is
# enforced by the publish scripts, not the signer.
run_prepare_bundle_case() {
  local case_name=$1 version=$2

  local input_dir="${TEST_ROOT}/input-${case_name}"
  local output_dir="${TEST_ROOT}/signed-${case_name}"
  local github_output="${TEST_ROOT}/github-output-${case_name}"
  local artifact_dir="${input_dir}/ai/rapids/example/${version}"
  mkdir -p "${artifact_dir}"

  printf '%s\n' \
    '<project xmlns="http://maven.apache.org/POM/4.0.0">' \
    '  <modelVersion>4.0.0</modelVersion>' \
    '  <groupId>ai.rapids</groupId>' \
    '  <artifactId>example</artifactId>' \
    "  <version>${version}</version>" \
    '</project>' \
    > "${artifact_dir}/example-${version}.pom"
  printf 'primary jar\n' > "${artifact_dir}/example-${version}.jar"
  printf 'sources jar\n' > "${artifact_dir}/example-${version}-sources.jar"
  printf 'javadoc jar\n' > "${artifact_dir}/example-${version}-javadoc.jar"
  printf 'stale checksum\n' > "${artifact_dir}/example-${version}.jar.sha1"

  GITHUB_OUTPUT="${github_output}" \
  "${SCRIPT_DIR}/prepare_maven_bundle.sh" \
    --input "${input_dir}" \
    --output "${output_dir}"

  local signed_dir="${output_dir}/ai/rapids/example/${version}"
  for artifact in \
    "example-${version}.pom" \
    "example-${version}.jar" \
    "example-${version}-sources.jar" \
    "example-${version}-javadoc.jar"; do
    gpg --verify "${signed_dir}/${artifact}.asc" "${signed_dir}/${artifact}"
  done

  [[ ! -e ${signed_dir}/example-${version}.jar.sha1 ]]
  grep -Fx 'GROUP_ID=ai.rapids' "${github_output}"
  grep -Fx 'ARTIFACT_ID=example' "${github_output}"
  grep -Fx "VERSION=${version}" "${github_output}"
}

run_prepare_bundle_case release 26.08.0
run_prepare_bundle_case snapshot 26.10.0-SNAPSHOT

echo "Maven bundle preparation integration test passed"
