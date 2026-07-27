#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Sign a Maven-repo-layout input tree and upload it to an internal Artifactory
# repository under a per-iteration sub-path.
#
# This is the HOST-side orchestrator: it parses CLI args, launches a
# maven:3-eclipse-temurin-17 container that runs artifactory_upload_in_container.sh
# to do the actual signing + upload, then reads the worker's output metadata
# file (GROUP_ID / ARTIFACT_ID / RC_NUMBER) off a bind-mounted output dir and
# relays it both to stdout (as key=value lines) and, when running in GitHub
# Actions, to $GITHUB_OUTPUT.
#
# The same host script is what both CI and a developer's local terminal call.
# There is no separate local-only wrapper.
#
# Publication types:
#   rc       - RC iteration N lives at staging/rc-<N>/<groupPath>/<artifactId>/<version>/.
#              --rc-number may be omitted, in which case the worker auto-increments
#              via an Artifactory AQL query and treats zero-results as bootstrap
#              (RC_NUMBER=1).
#   nightly  - Nightly for date D lives at staging/nightly/<D>/<groupPath>/<artifactId>/<version>/.
#              --nightly-date defaults to today's UTC date if omitted.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/argparse.sh"

INPUT_DIR=""
PUBLICATION_TYPE=""
RC_NUMBER=""
NIGHTLY_DATE=""
ARTIFACTORY_URL=""
ARTIFACTORY_REPOSITORY=""
SOURCE_GIT_SHA=""
IMAGE="${MAVEN_PUBLISH_IMAGE:-maven:3-eclipse-temurin-17}"

print_help() {
  cat << EOF

Usage: artifactory_upload.sh --input <path> --publication-type <rc|nightly> [OPTIONS]

Signs every file under a Maven-repo-layout input tree and uploads the result
to an internal Artifactory repository at a per-iteration sub-path.

REQUIRED:
    -i, --input                Maven-repo-layout directory to sign and upload
                               (e.g. <input>/<groupPath>/<artifactId>/<version>/*).
    -t, --publication-type     "rc" or "nightly".
    -u, --artifactory-url      Base URL of the Artifactory server (no trailing
                               slash), e.g. https://urm.nvidia.com/artifactory.
    -r, --artifactory-repository
                               Artifactory repository name to upload into, e.g.
                               sw-spark-maven-local.

OPTIONS:
    -n, --rc-number            RC iteration number (rc only). If omitted, the
                               worker auto-increments by AQL-querying the max
                               existing rc.number for this group+artifact and
                               using max+1 (defaults to 1 on the first-ever RC).
    -d, --nightly-date         YYYY-MM-DD (nightly only, default: today UTC).
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
    RC_NUMBER=<resolved RC number> (rc only; unset for nightly)
    NIGHTLY_DATE=<resolved nightly date> (nightly only; unset for rc)
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
      -n|--rc-number)
        require_value "$1" "$2"
        RC_NUMBER=$2
        shift 2
        ;;
      -d|--nightly-date)
        require_value "$1" "$2"
        NIGHTLY_DATE=$2
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

if [[ ${PUBLICATION_TYPE} != "rc" && ${PUBLICATION_TYPE} != "nightly" ]]; then
  echo "Error: --publication-type must be 'rc' or 'nightly' (got '${PUBLICATION_TYPE}')" >&2
  exit 1
fi

if [[ ! -d ${INPUT_DIR} ]]; then
  echo "Error: --input '${INPUT_DIR}' does not exist or is not a directory" >&2
  exit 1
fi

# Nightly convenience: default --nightly-date to today (UTC). --rc-number
# stays optional and is resolved by the worker via AQL auto-increment when
# empty.
if [[ ${PUBLICATION_TYPE} == "nightly" && -z ${NIGHTLY_DATE} ]]; then
  NIGHTLY_DATE=$(date -u +%Y-%m-%d)
fi

if [[ ${PUBLICATION_TYPE} == "nightly" && -n ${RC_NUMBER} ]]; then
  echo "Error: --rc-number is only valid for --publication-type rc" >&2
  exit 1
fi
if [[ ${PUBLICATION_TYPE} == "rc" && -n ${NIGHTLY_DATE} ]]; then
  echo "Error: --nightly-date is only valid for --publication-type nightly" >&2
  exit 1
fi

# Fail-fast on missing credentials before we spend time launching a container.
# This mirrors the inline env-var assertions in the worker: it turns "someone
# forgot to set a secret" into an immediate, clearly-named error rather than
# a confusing downstream 401.
for var in GPG_PRIVATE_KEY GPG_PASSPHRASE ARTIFACTORY_USERNAME ARTIFACTORY_TOKEN; do
  if [[ -z ${!var} ]]; then
    echo "Error: ${var} must be set" >&2
    exit 1
  fi
done

INPUT_DIR="$(cd "${INPUT_DIR}" && pwd)"

# Bind-mounted scratch dir. The worker writes a small metadata file
# (upload_metadata.env) there containing the resolved GROUP_ID / ARTIFACT_ID /
# RC_NUMBER / NIGHTLY_DATE / VERSION lines. This host script reads it back
# after `docker run` exits, per cudf/java/ci/build_cudf_java_jar.sh's
# host-reads-worker-output pattern.
OUTPUT_SCRATCH="$(mktemp -d)"
cleanup_output_scratch() {
  rm -rf "${OUTPUT_SCRATCH}"
}
trap cleanup_output_scratch EXIT

echo "Artifactory upload"
echo "  image:                ${IMAGE}"
echo "  publication type:     ${PUBLICATION_TYPE}"
if [[ ${PUBLICATION_TYPE} == "rc" ]]; then
  echo "  rc-number:            ${RC_NUMBER:-<auto-increment>}"
else
  echo "  nightly-date:         ${NIGHTLY_DATE}"
fi
echo "  artifactory url:      ${ARTIFACTORY_URL}"
echo "  artifactory repo:     ${ARTIFACTORY_REPOSITORY}"
echo "  input dir:            ${INPUT_DIR}"
echo "  metadata scratch:     ${OUTPUT_SCRATCH}"

DOCKER_ARGS=(
  --rm
  --volume "${INPUT_DIR}:/input:ro"
  --volume "${OUTPUT_SCRATCH}:/output"
  --workdir /input
  --env PUBLICATION_TYPE="${PUBLICATION_TYPE}"
  --env RC_NUMBER="${RC_NUMBER}"
  --env NIGHTLY_DATE="${NIGHTLY_DATE}"
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

# Post-run: assert the worker wrote its metadata file, and that every expected
# key is present. Silently propagating empty GROUP_ID / ARTIFACT_ID / RC_NUMBER
# downstream would be worse than failing loudly here.
METADATA_FILE="${OUTPUT_SCRATCH}/upload_metadata.env"
if [[ ! -f ${METADATA_FILE} ]]; then
  echo "Error: worker did not produce ${METADATA_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "${METADATA_FILE}"

if [[ -z ${GROUP_ID} || -z ${ARTIFACT_ID} || -z ${VERSION} ]]; then
  echo "Error: worker metadata file is missing GROUP_ID / ARTIFACT_ID / VERSION" >&2
  cat "${METADATA_FILE}" >&2 || true
  exit 1
fi

if [[ ${PUBLICATION_TYPE} == "rc" && -z ${RC_NUMBER} ]]; then
  echo "Error: worker metadata file is missing RC_NUMBER for rc publication" >&2
  cat "${METADATA_FILE}" >&2 || true
  exit 1
fi
if [[ ${PUBLICATION_TYPE} == "nightly" && -z ${NIGHTLY_DATE} ]]; then
  echo "Error: worker metadata file is missing NIGHTLY_DATE for nightly publication" >&2
  cat "${METADATA_FILE}" >&2 || true
  exit 1
fi

# Relay the resolved metadata both to stdout (so a human running this locally
# can `eval` it if they want) and, when running in GHA, to $GITHUB_OUTPUT
# where downstream job steps read it as step outputs.
{
  echo "GROUP_ID=${GROUP_ID}"
  echo "ARTIFACT_ID=${ARTIFACT_ID}"
  echo "VERSION=${VERSION}"
  if [[ ${PUBLICATION_TYPE} == "rc" ]]; then
    echo "RC_NUMBER=${RC_NUMBER}"
  else
    echo "NIGHTLY_DATE=${NIGHTLY_DATE}"
  fi
} | tee -a "${GITHUB_OUTPUT:-/dev/null}"

echo "Artifactory upload completed for ${GROUP_ID}:${ARTIFACT_ID}:${VERSION}"
