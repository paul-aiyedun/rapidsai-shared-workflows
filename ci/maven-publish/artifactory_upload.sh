#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Host orchestrator for signing + uploading a Maven repository directory
# to Artifactory. Launches a maven-image container running
# artifactory_upload_in_container.sh, then relays the worker's resolved
# GROUP_ID/ARTIFACT_ID/VERSION/RC_NUMBER both to stdout and to
# $GITHUB_OUTPUT. Same script for CI and local dev - no separate wrapper.
# See --help for arg reference.
#
# TODO: reintroduce --nightly-date + NIGHTLY_DATE env plumbing when nightly
# support returns (removed for the initial rc-only rollout).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/argparse.sh"

INPUT_DIR=""
PUBLICATION_TYPE=""
ARTIFACTORY_URL=""
ARTIFACTORY_REPOSITORY=""
SOURCE_GIT_SHA=""
IMAGE="${MAVEN_PUBLISH_IMAGE:-maven:3-eclipse-temurin-17}"

print_help() {
  cat << EOF

Usage: artifactory_upload.sh --input <path> --publication-type rc [OPTIONS]

Signs every file under a Maven repository directory and uploads the result
to an internal Artifactory repository at a per-iteration sub-path.

REQUIRED:
    -i, --input                Maven repository directory to sign and upload
                               (e.g. <input>/<groupPath>/<artifactId>/<version>/*).
    -t, --publication-type     Only "rc" is currently supported. Nightly is
                               a future addition; the flag is retained so
                               callers do not have to change when it lands.
    -u, --artifactory-url      Base URL of the Artifactory server (no trailing
                               slash), e.g. https://urm.nvidia.com/artifactory.
    -r, --artifactory-repository
                               Artifactory repository name to upload into, e.g.
                               sw-spark-maven-local.

OPTIONS:
    -s, --source-git-sha       Git SHA to attach as the source.git-sha
                               Artifactory property (default: empty).
    -h, --help                 Show this help message.

ENVIRONMENT VARIABLES:
    GPG_PRIVATE_KEY            Armored GPG private key (required).
    GPG_PASSPHRASE             Passphrase for the GPG private key (required).
    ARTIFACTORY_USERNAME       Artifactory account with write access (required).
    ARTIFACTORY_TOKEN          Auth token for ARTIFACTORY_USERNAME (required).
    MAVEN_PUBLISH_IMAGE        Override the Maven container image (default:
                               maven:3-eclipse-temurin-17).
    GITHUB_OUTPUT              If set, the resolved GROUP_ID / ARTIFACT_ID /
                               RC_NUMBER key=value lines are also appended
                               here so downstream GHA steps can read them as
                               step outputs.

OUTPUTS (stdout key=value lines, and \$GITHUB_OUTPUT when set):
    GROUP_ID=<derived from POM>
    ARTIFACT_ID=<derived from POM>
    RC_NUMBER=1 (hardcoded until AQL auto-increment lands)
    VERSION=<derived from POM>

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        print_help
        exit 0
        ;;
      -i|--input)
        require_value "$1" "$2"
        INPUT_DIR=$2
        shift 2
        ;;
      -t|--publication-type)
        require_value "$1" "$2"
        PUBLICATION_TYPE=$2
        shift 2
        ;;
      -u|--artifactory-url)
        require_value "$1" "$2"
        ARTIFACTORY_URL=$2
        shift 2
        ;;
      -r|--artifactory-repository)
        require_value "$1" "$2"
        ARTIFACTORY_REPOSITORY=$2
        shift 2
        ;;
      -s|--source-git-sha)
        require_value "$1" "$2"
        SOURCE_GIT_SHA=$2
        shift 2
        ;;
      *)
        echo "Error: Unknown argument $1"
        print_help
        exit 1
        ;;
    esac
  done
}

parse_args "$@"

require_arg --input                 "${INPUT_DIR}"
require_arg --publication-type      "${PUBLICATION_TYPE}"
require_arg --artifactory-url       "${ARTIFACTORY_URL}"
require_arg --artifactory-repository "${ARTIFACTORY_REPOSITORY}"

if [[ ${PUBLICATION_TYPE} != "rc" ]]; then
  echo "Error: only --publication-type rc is supported for now; nightly is a future addition (got '${PUBLICATION_TYPE}')" >&2
  exit 1
fi

if [[ ! -d ${INPUT_DIR} ]]; then
  echo "Error: --input '${INPUT_DIR}' does not exist or is not a directory" >&2
  exit 1
fi

# Fail-fast before launching a container.
for var in GPG_PRIVATE_KEY GPG_PASSPHRASE ARTIFACTORY_USERNAME ARTIFACTORY_TOKEN; do
  if [[ -z ${!var} ]]; then
    echo "Error: ${var} must be set" >&2
    exit 1
  fi
done

INPUT_DIR="$(cd "${INPUT_DIR}" && pwd)"

# Worker writes upload_metadata.env here; we source it back after docker exits.
OUTPUT_SCRATCH="$(mktemp -d)"
cleanup_output_scratch() {
  rm -rf "${OUTPUT_SCRATCH}"
}
trap cleanup_output_scratch EXIT

echo "Artifactory upload"
echo "  image:                ${IMAGE}"
echo "  publication type:     ${PUBLICATION_TYPE}"
echo "  artifactory url:      ${ARTIFACTORY_URL}"
echo "  artifactory repo:     ${ARTIFACTORY_REPOSITORY}"
echo "  input dir:            ${INPUT_DIR}"
echo "  metadata scratch:     ${OUTPUT_SCRATCH}"

DOCKER_ARGS=(
  --rm
  --volume "${INPUT_DIR}:/input:ro"
  --volume "${OUTPUT_SCRATCH}:/output"
  --workdir /input
  --env ARTIFACTORY_URL="${ARTIFACTORY_URL}"
  --env ARTIFACTORY_REPOSITORY="${ARTIFACTORY_REPOSITORY}"
  --env ARTIFACTORY_USERNAME="${ARTIFACTORY_USERNAME}"
  --env ARTIFACTORY_TOKEN="${ARTIFACTORY_TOKEN}"
  --env GPG_PRIVATE_KEY="${GPG_PRIVATE_KEY}"
  --env GPG_PASSPHRASE="${GPG_PASSPHRASE}"
  --env SOURCE_GIT_SHA="${SOURCE_GIT_SHA}"
  --env HOST_UID="$(id -u)"
  --env HOST_GID="$(id -g)"
  --volume "${SCRIPT_DIR}:/scripts:ro"
)

docker run "${DOCKER_ARGS[@]}" "${IMAGE}" \
  bash /scripts/artifactory_upload_in_container.sh

# Fail loudly on missing/incomplete metadata rather than propagating empties.
METADATA_FILE="${OUTPUT_SCRATCH}/upload_metadata.env"
if [[ ! -f ${METADATA_FILE} ]]; then
  echo "Error: worker did not produce ${METADATA_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${METADATA_FILE}"

if [[ -z ${GROUP_ID} || -z ${ARTIFACT_ID} || -z ${VERSION} || -z ${RC_NUMBER} ]]; then
  echo "Error: worker metadata file is missing GROUP_ID / ARTIFACT_ID / VERSION / RC_NUMBER" >&2
  cat "${METADATA_FILE}" >&2 || true
  exit 1
fi

# Relay to stdout (human-eval-able) and to $GITHUB_OUTPUT when in GHA.
{
  echo "GROUP_ID=${GROUP_ID}"
  echo "ARTIFACT_ID=${ARTIFACT_ID}"
  echo "VERSION=${VERSION}"
  echo "RC_NUMBER=${RC_NUMBER}"
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"

echo "Artifactory upload completed for ${GROUP_ID}:${ARTIFACT_ID}:${VERSION}"
