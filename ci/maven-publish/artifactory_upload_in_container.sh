#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# In-container worker for artifactory_upload.sh. GPG-signs every file under
# /input and uploads the signed bundle to Artifactory at
# staging/rc-<N>/<groupPath>/<artifactId>/<version>/. Writes resolved
# coordinates to /output/upload_metadata.env for the host script.
#
# TODO: restore the nightly path (staging/nightly/<date>/...) when nightly
# support is reintroduced.

set -e

INPUT_DIR=/input
OUTPUT_DIR=/output

: "${ARTIFACTORY_URL:?must be set}"
: "${ARTIFACTORY_REPOSITORY:?must be set}"
: "${ARTIFACTORY_USERNAME:?must be set}"
: "${ARTIFACTORY_TOKEN:?must be set}"
: "${GPG_PRIVATE_KEY:?must be set}"
: "${GPG_PASSPHRASE:?must be set}"
: "${HOST_UID:?must be set}"
: "${HOST_GID:?must be set}"

mkdir -p "${OUTPUT_DIR}"
_chown_output_on_exit() {
  chown -R "${HOST_UID}:${HOST_GID}" "${OUTPUT_DIR}" 2>/dev/null || true
}
trap _chown_output_on_exit EXIT

# gpg + curl aren't in the base image.
if ! command -v gpg >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -qq -y --no-install-recommends gnupg curl
fi

# Expect exactly one POM anywhere under INPUT_DIR.
mapfile -t POM_CANDIDATES < <(find "${INPUT_DIR}" -type f -name '*.pom' | sort)
if [[ ${#POM_CANDIDATES[@]} -eq 0 ]]; then
  echo "Error: no *.pom found anywhere under ${INPUT_DIR}" >&2
  exit 1
fi
if [[ ${#POM_CANDIDATES[@]} -gt 1 ]]; then
  echo "Error: expected exactly one POM under ${INPUT_DIR}, found:" >&2
  printf '  %s\n' "${POM_CANDIDATES[@]}" >&2
  exit 1
fi
POM_FILE="${POM_CANDIDATES[0]}"
ARTIFACT_DIR="$(dirname "${POM_FILE}")"

# POM is the authoritative source for coordinates; caller never restates them.
GROUP_ID=$(mvn -q -B -f "${POM_FILE}" help:evaluate -Dexpression=project.groupId -DforceStdout)
ARTIFACT_ID=$(mvn -q -B -f "${POM_FILE}" help:evaluate -Dexpression=project.artifactId -DforceStdout)
VERSION=$(mvn -q -B -f "${POM_FILE}" help:evaluate -Dexpression=project.version -DforceStdout)

if [[ -z ${GROUP_ID} || -z ${ARTIFACT_ID} || -z ${VERSION} ]]; then
  echo "Error: failed to read groupId/artifactId/version from ${POM_FILE}" >&2
  exit 1
fi

GROUP_PATH="${GROUP_ID//./\/}"
EXPECTED_ARTIFACT_DIR="${INPUT_DIR}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}"
if [[ "${ARTIFACT_DIR}" != "${EXPECTED_ARTIFACT_DIR}" ]]; then
  echo "Error: POM location ${ARTIFACT_DIR} does not match expected Maven repository layout ${EXPECTED_ARTIFACT_DIR}" >&2
  exit 1
fi

# rc requires a release-shaped version; guards against staging a -SNAPSHOT.
if [[ ${VERSION} == *-SNAPSHOT ]]; then
  echo "Error: rc requires a release-shaped version, got '${VERSION}'" >&2
  exit 1
fi

# TODO: auto-increment via Artifactory AQL against existing staging/rc-*/.
RC_NUMBER=1
SUB_PATH="staging/rc-${RC_NUMBER}"
ITERATION_PROP_KEY="rc.number"
ITERATION_PROP_VALUE="${RC_NUMBER}"

STAGING_PATH="${SUB_PATH}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}"
STAGING_URL="${ARTIFACTORY_URL}/${ARTIFACTORY_REPOSITORY}/${STAGING_PATH}"

echo "Staging destination: ${STAGING_URL}"

# Per-run GNUPGHOME to isolate from any ambient state.
export GNUPGHOME
GNUPGHOME="$(mktemp -d)"
chmod 700 "${GNUPGHOME}"

echo "${GPG_PRIVATE_KEY}" | gpg --batch --yes --pinentry-mode loopback \
  --passphrase "${GPG_PASSPHRASE}" --import

GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format=long --with-colons \
  | awk -F: '$1=="sec" { print $5; exit }')
if [[ -z ${GPG_KEY_ID} ]]; then
  echo "Error: no GPG secret key was imported" >&2
  exit 1
fi
echo "GPG signing key: ${GPG_KEY_ID}"

# Only signing step in the pipeline; the promoter byte-forwards these
# signatures unmodified.
echo "Signing artifacts under ${ARTIFACT_DIR}"
mapfile -t ARTIFACTS < <(find "${ARTIFACT_DIR}" -maxdepth 1 -type f \
  ! -name '*.asc' ! -name '*.md5' ! -name '*.sha1' ! -name '*.sha256' \
  ! -name '*.sha512' | sort)

if [[ ${#ARTIFACTS[@]} -eq 0 ]]; then
  echo "Error: no artifacts found under ${ARTIFACT_DIR} to sign" >&2
  exit 1
fi

for artifact in "${ARTIFACTS[@]}"; do
  gpg --batch --yes --pinentry-mode loopback \
    --passphrase "${GPG_PASSPHRASE}" \
    --local-user "${GPG_KEY_ID}" \
    --armor --detach-sign \
    --output "${artifact}.asc" \
    "${artifact}"
done

# Matrix params get stored as Artifactory properties, queryable by the promoter.
PROP_MATRIX=";${ITERATION_PROP_KEY}=${ITERATION_PROP_VALUE}"
if [[ -n ${SOURCE_GIT_SHA} ]]; then
  PROP_MATRIX+=";source.git-sha=${SOURCE_GIT_SHA}"
fi

upload_one() {
  local local_path=$1
  local remote_name
  remote_name=$(basename "${local_path}")
  local dest_url="${STAGING_URL}/${remote_name}${PROP_MATRIX}"

  echo "  PUT ${remote_name} -> ${dest_url}"
  curl -sS -f --retry 3 --retry-delay 2 \
    --user "${ARTIFACTORY_USERNAME}:${ARTIFACTORY_TOKEN}" \
    -T "${local_path}" \
    -X PUT "${dest_url}" \
    -o /dev/null
}

echo "Uploading to ${STAGING_URL}"
for artifact in "${ARTIFACTS[@]}"; do
  upload_one "${artifact}"
  upload_one "${artifact}.asc"
done

{
  echo "GROUP_ID=${GROUP_ID}"
  echo "ARTIFACT_ID=${ARTIFACT_ID}"
  echo "VERSION=${VERSION}"
  echo "RC_NUMBER=${RC_NUMBER}"
} > "${OUTPUT_DIR}/upload_metadata.env"

echo "Upload complete for ${GROUP_ID}:${ARTIFACT_ID}:${VERSION} at ${STAGING_PATH}"
