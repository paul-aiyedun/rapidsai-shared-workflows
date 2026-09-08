#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Integration test for maven_snapshot_publish.sh with a mocked curl. Verifies
# that:
#   - every file under the signed Maven tree is PUT to the Sonatype snapshot
#     repository URL (no OSSRH staging, no Portal endpoints);
#   - a non-SNAPSHOT --version is rejected before any HTTP call;
#   - a release-shaped file inside a SNAPSHOT bundle is rejected before any
#     HTTP call (publish-side -SNAPSHOT verification).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

VERSION=26.10.0-SNAPSHOT
ARTIFACT_DIR="${TEST_ROOT}/signed/ai/rapids/example/${VERSION}"
MOCK_BIN="${TEST_ROOT}/bin"
MOCK_STATE_DIR="${TEST_ROOT}/state"
mkdir -p "${ARTIFACT_DIR}" "${MOCK_BIN}" "${MOCK_STATE_DIR}"

for suffix in \
  .pom .pom.asc .jar .jar.asc \
  -sources.jar -sources.jar.asc \
  -javadoc.jar -javadoc.jar.asc; do
  printf 'content for %s\n' "${suffix}" > "${ARTIFACT_DIR}/example-${VERSION}${suffix}"
done

# Mock curl. The caller (_sonatype_upload) invokes real curl as
#   curl ... -o <body_file> -w '%{http_code}' <url>
# expecting the body to land in <body_file> and the HTTP status code to be
# printed to stdout. Reproduce that contract so status="200" is captured and
# _sonatype_upload takes the success branch.
# shellcheck disable=SC2016
MOCK_CURL='#!/bin/bash
set -euo pipefail
printf "%s\n" "$*" >> "${MOCK_STATE_DIR}/curl.log"

body_file=""
prev=""
for arg in "$@"; do
  if [[ ${prev} == "-o" ]]; then
    body_file=${arg}
  fi
  prev=${arg}
done

case "$*" in
  *--upload-file*)
    printf "%s\n" "$*" >> "${MOCK_STATE_DIR}/uploads.log"
    [[ -n ${body_file} ]] && : > "${body_file}"
    printf "200"
    ;;
  *) echo "unexpected curl invocation: $*" >&2; exit 1 ;;
esac'
printf '%s\n' "${MOCK_CURL}" > "${MOCK_BIN}/curl"
chmod +x "${MOCK_BIN}/curl"

export PATH="${MOCK_BIN}:${PATH}"
export MOCK_STATE_DIR
export MAVEN_DEPLOY_USERNAME=test-user
export MAVEN_DEPLOY_TOKEN=test-token

OUTPUT_BUNDLE="${TEST_ROOT}/snapshot-bundle.zip"
"${SCRIPT_DIR}/maven_snapshot_publish.sh" \
  --input "${TEST_ROOT}/signed" \
  --group-id ai.rapids \
  --artifact-id example \
  --version "${VERSION}" \
  --output-bundle "${OUTPUT_BUNDLE}"

# Retained ZIP is well-formed and includes generated .sha1 sidecars.
unzip -tq "${OUTPUT_BUNDLE}" >/dev/null
unzip -l "${OUTPUT_BUNDLE}" | grep -F "example-${VERSION}.jar.asc.sha1"

# Expected upload count: 8 originals + 2 (md5+sha1) sidecars per original = 24.
[[ $(wc -l < "${MOCK_STATE_DIR}/uploads.log") -eq 24 ]]

# Every upload must target the Sonatype snapshot repository URL for this
# artifact's version directory.
if grep -F -- '--upload-file' "${MOCK_STATE_DIR}/uploads.log" \
    | grep -Fv "https://central.sonatype.com/repository/maven-snapshots/ai/rapids/example/${VERSION}/" \
    >/dev/null; then
  echo "found upload(s) targeting an unexpected URL:" >&2
  grep -F -- '--upload-file' "${MOCK_STATE_DIR}/uploads.log" >&2
  exit 1
fi

# The snapshot path must not touch OSSRH staging or the Publisher Portal.
if grep -Fq 'manual/search/repositories' "${MOCK_STATE_DIR}/curl.log"; then
  echo "snapshot publish must not query the OSSRH staging service" >&2
  exit 1
fi
if grep -Fq 'api/v1/publisher/' "${MOCK_STATE_DIR}/curl.log"; then
  echo "snapshot publish must not call the Publisher Portal" >&2
  exit 1
fi

# Rejection case: non-SNAPSHOT version must fail before any HTTP call.
rm -f "${MOCK_STATE_DIR}"/*
if "${SCRIPT_DIR}/maven_snapshot_publish.sh" \
    --input "${TEST_ROOT}/signed" \
    --group-id ai.rapids \
    --artifact-id example \
    --version 26.10.0 \
    --output-bundle "${TEST_ROOT}/release-version.zip" \
    >/dev/null 2>&1; then
  echo "a release-shaped --version must be rejected on the snapshot path" >&2
  exit 1
fi
[[ ! -e ${MOCK_STATE_DIR}/uploads.log ]]

# Rejection case: a release-shaped file smuggled into a SNAPSHOT tree must be
# rejected by the publish-side -SNAPSHOT verification, before any HTTP call.
rm -f "${MOCK_STATE_DIR}"/*
BAD_ROOT="${TEST_ROOT}/mixed"
BAD_ARTIFACT_DIR="${BAD_ROOT}/ai/rapids/example/${VERSION}"
mkdir -p "${BAD_ARTIFACT_DIR}"
cp -a "${ARTIFACT_DIR}/." "${BAD_ARTIFACT_DIR}/"
printf 'release smuggle\n' > "${BAD_ARTIFACT_DIR}/example-26.10.0.jar"
if "${SCRIPT_DIR}/maven_snapshot_publish.sh" \
    --input "${BAD_ROOT}" \
    --group-id ai.rapids \
    --artifact-id example \
    --version "${VERSION}" \
    --output-bundle "${TEST_ROOT}/mixed-bundle.zip" \
    >/dev/null 2>&1; then
  echo "a release-shaped file inside a snapshot bundle must be rejected" >&2
  exit 1
fi
[[ ! -e ${MOCK_STATE_DIR}/uploads.log ]]

echo "Sonatype snapshot publish integration test passed"
