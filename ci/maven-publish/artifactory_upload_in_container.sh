#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# In-container worker for artifactory_upload.sh. GPG-signs every file under
# /input and uploads the signed bundle to Artifactory at
# staging/{rc-<N>|nightly/<date>}/<groupPath>/<artifactId>/<version>/. For rc
# uploads with RC_NUMBER unset, resolves the next rc number via AQL
# (bootstraps to 1 if no prior rc exists). Writes resolved coordinates to
# /output/upload_metadata.env for the host script.

set -e

INPUT_DIR=/input
OUTPUT_DIR=/output

for var in PUBLICATION_TYPE ARTIFACTORY_URL ARTIFACTORY_REPOSITORY \
           ARTIFACTORY_USERNAME ARTIFACTORY_TOKEN \
           GPG_PRIVATE_KEY GPG_PASSPHRASE; do
  if [[ -z ${!var} ]]; then
    echo "Error: ${var} must be set" >&2
    exit 1
  fi
done

if [[ ${PUBLICATION_TYPE} != "rc" && ${PUBLICATION_TYPE} != "nightly" ]]; then
  echo "Error: PUBLICATION_TYPE must be 'rc' or 'nightly' (got '${PUBLICATION_TYPE}')" >&2
  exit 1
fi
if [[ ${PUBLICATION_TYPE} == "nightly" && -z ${NIGHTLY_DATE} ]]; then
  echo "Error: NIGHTLY_DATE must be set for nightly publications" >&2
  exit 1
fi

if [[ -z ${HOST_UID} || -z ${HOST_GID} ]]; then
  echo "Error: HOST_UID and HOST_GID must both be set" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
_chown_output_on_exit() {
  chown -R "${HOST_UID}:${HOST_GID}" "${OUTPUT_DIR}" 2>/dev/null || true
}
trap _chown_output_on_exit EXIT

# gpg + curl + jq aren't in the base image.
if ! command -v gpg >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1 \
     || ! command -v curl >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -qq -y --no-install-recommends gnupg curl jq
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
  echo "Error: POM location ${ARTIFACT_DIR} does not match expected Maven-repo layout ${EXPECTED_ARTIFACT_DIR}" >&2
  exit 1
fi

# Version shape must match publication type - guards against staging a
# -SNAPSHOT under rc-* or a release version under nightly/.
if [[ ${PUBLICATION_TYPE} == "rc" && ${VERSION} == *-SNAPSHOT ]]; then
  echo "Error: --publication-type rc requires a release-shaped version, got '${VERSION}'" >&2
  exit 1
fi
if [[ ${PUBLICATION_TYPE} == "nightly" && ${VERSION} != *-SNAPSHOT ]]; then
  echo "Error: --publication-type nightly requires a -SNAPSHOT version, got '${VERSION}'" >&2
  exit 1
fi

# Explicit RC_NUMBER wins; otherwise auto-increment via AQL, bootstrapping
# to 1 when no prior rc exists. Concurrent runs racing on the same next
# number is an accepted trade-off (rc creation is rare and human-triggered).
if [[ ${PUBLICATION_TYPE} == "rc" ]]; then
  if [[ -z ${RC_NUMBER} ]]; then
    echo "Resolving next rc-number via AQL against ${ARTIFACTORY_URL}"
    AQL_QUERY=$(cat <<AQL_EOF
items.find({
  "repo": "${ARTIFACTORY_REPOSITORY}",
  "path": {"\$match": "staging/rc-*/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}"},
  "name": {"\$match": "*.pom"},
  "@publication-type": "rc"
}).include("@rc.number").sort({"\$desc": ["@rc.number"]}).limit(1)
AQL_EOF
    )

    AQL_RESPONSE=$(curl -sS \
      --user "${ARTIFACTORY_USERNAME}:${ARTIFACTORY_TOKEN}" \
      -H "Content-Type: text/plain" \
      -X POST "${ARTIFACTORY_URL}/api/search/aql" \
      --data "${AQL_QUERY}")

    RESULT_COUNT=$(echo "${AQL_RESPONSE}" | jq -r '.results | length')
    if [[ ${RESULT_COUNT} -eq 0 ]]; then
      RC_NUMBER=1
      echo "  no existing RC found -> RC_NUMBER=1 (bootstrap)"
    else
      MAX_RC=$(echo "${AQL_RESPONSE}" | jq -r '[.results[].properties[] | select(.key=="rc.number") | .value | tonumber] | max')
      if [[ -z ${MAX_RC} || ${MAX_RC} == "null" ]]; then
        echo "Error: AQL result did not include @rc.number; response:" >&2
        echo "${AQL_RESPONSE}" >&2
        exit 1
      fi
      RC_NUMBER=$((MAX_RC + 1))
      echo "  max existing rc.number=${MAX_RC} -> RC_NUMBER=${RC_NUMBER}"
    fi
  fi

  if ! [[ ${RC_NUMBER} =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: RC_NUMBER must be a positive integer, got '${RC_NUMBER}'" >&2
    exit 1
  fi

  SUB_PATH="staging/rc-${RC_NUMBER}"
  ITERATION_PROP_KEY="rc.number"
  ITERATION_PROP_VALUE="${RC_NUMBER}"
else
  if ! [[ ${NIGHTLY_DATE} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "Error: NIGHTLY_DATE must match YYYY-MM-DD, got '${NIGHTLY_DATE}'" >&2
    exit 1
  fi
  SUB_PATH="staging/nightly/${NIGHTLY_DATE}"
  ITERATION_PROP_KEY="nightly.date"
  ITERATION_PROP_VALUE="${NIGHTLY_DATE}"
fi

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

retry() {
  # retry <times> <cmd...>
  local max=$1
  shift
  local attempt=1
  while true; do
    if "$@"; then
      return 0
    fi
    if (( attempt >= max )); then
      echo "Error: command failed after ${attempt} attempts: $*" >&2
      return 1
    fi
    echo "  retrying (${attempt}/${max})..."
    attempt=$((attempt + 1))
    sleep $((attempt * 2))
  done
}

# Only signing step in the pipeline; both promoters byte-forward these
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

# Matrix params get stored as Artifactory properties, queryable by promoters.
PROP_MATRIX=";publication-type=${PUBLICATION_TYPE}"
PROP_MATRIX+=";${ITERATION_PROP_KEY}=${ITERATION_PROP_VALUE}"
if [[ -n ${SOURCE_GIT_SHA} ]]; then
  PROP_MATRIX+=";source.git-sha=${SOURCE_GIT_SHA}"
fi

upload_one() {
  local local_path=$1
  local remote_name
  remote_name=$(basename "${local_path}")
  local dest_url="${STAGING_URL}/${remote_name}${PROP_MATRIX}"

  # Precompute checksums to skip Artifactory's server-side pass.
  local md5 sha1 sha256
  md5=$(md5sum   "${local_path}" | awk '{print $1}')
  sha1=$(sha1sum "${local_path}" | awk '{print $1}')
  sha256=$(sha256sum "${local_path}" | awk '{print $1}')

  echo "  PUT ${remote_name} -> ${dest_url}"
  retry 3 curl -sS -f \
    --user "${ARTIFACTORY_USERNAME}:${ARTIFACTORY_TOKEN}" \
    -H "X-Checksum-Md5: ${md5}" \
    -H "X-Checksum-Sha1: ${sha1}" \
    -H "X-Checksum-Sha256: ${sha256}" \
    -T "${local_path}" \
    -X PUT "${dest_url}" \
    -o /dev/null
}

echo "Uploading to ${STAGING_URL}"
for artifact in "${ARTIFACTS[@]}"; do
  upload_one "${artifact}"
  upload_one "${artifact}.asc"
done

# Only emit the iteration key relevant to this publication type.
{
  echo "GROUP_ID=${GROUP_ID}"
  echo "ARTIFACT_ID=${ARTIFACT_ID}"
  echo "VERSION=${VERSION}"
  if [[ ${PUBLICATION_TYPE} == "rc" ]]; then
    echo "RC_NUMBER=${RC_NUMBER}"
  else
    echo "NIGHTLY_DATE=${NIGHTLY_DATE}"
  fi
} > "${OUTPUT_DIR}/upload_metadata.env"

echo "Upload complete for ${GROUP_ID}:${ARTIFACT_ID}:${VERSION} at ${STAGING_PATH}"
