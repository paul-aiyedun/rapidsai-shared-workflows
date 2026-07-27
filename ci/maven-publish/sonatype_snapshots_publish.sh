#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Host orchestrator for promoting a signed nightly bundle from Artifactory
# to the Sonatype snapshots endpoint. Launches a maven-image container
# running sonatype_snapshots_publish_in_container.sh (needs Maven for
# `mvn deploy:deploy-file`). All bundle bytes + .asc signatures are
# byte-forwarded unmodified.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/argparse.sh"

GROUP_ID=""
ARTIFACT_ID=""
VERSION=""
NIGHTLY_DATE=""
ARTIFACTORY_URL=""
ARTIFACTORY_REPOSITORY=""
DEPLOY_URL="${DEPLOY_URL:-https://central.sonatype.com/repository/maven-snapshots/}"
DEPLOY_REPOSITORY_ID="${DEPLOY_REPOSITORY_ID:-central-snapshots}"
IMAGE="${MAVEN_PUBLISH_IMAGE:-maven:3-eclipse-temurin-17}"

print_help() {
  cat << EOF

Usage: sonatype_snapshots_publish.sh --group-id <g> --artifact-id <a> \\
                                     --version <v> --nightly-date <YYYY-MM-DD> \\
                                     --artifactory-url <url> \\
                                     --artifactory-repository <repo> [OPTIONS]

Byte-forwards a signed nightly staging bundle from Artifactory
(staging/nightly/<date>/<groupPath>/<artifactId>/<version>/) to the Sonatype
snapshots endpoint (or a parameterized sandbox for smoke testing).

REQUIRED:
    -g, --group-id                 Maven groupId of the artifact.
    -a, --artifact-id              Maven artifactId.
    -v, --version                  Snapshot version, e.g. 26.08.0-SNAPSHOT.
                                   Must end in -SNAPSHOT.
    -d, --nightly-date             YYYY-MM-DD of the nightly bundle to promote.
    -u, --artifactory-url          Base URL of the Artifactory server.
    -r, --artifactory-repository   Artifactory repository name.

OPTIONS:
    --deploy-url <url>             Sonatype snapshots endpoint (default:
                                   https://central.sonatype.com/repository/maven-snapshots/).
    --deploy-repository-id <id>    Maven repositoryId matching the settings.xml
                                   server entry (default: central-snapshots).
    -h, --help                     Show this help message.

ENVIRONMENT VARIABLES:
    ARTIFACTORY_USERNAME           Read-access account on Artifactory (required).
    ARTIFACTORY_TOKEN              Auth token for ARTIFACTORY_USERNAME (required).
    MAVEN_DEPLOY_USERNAME          Sonatype user token username (required).
    MAVEN_DEPLOY_TOKEN             Sonatype user token password (required).
    MAVEN_PUBLISH_IMAGE            Override the Maven container image (default:
                                   maven:3-eclipse-temurin-17).

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        print_help
        exit 0
        ;;
      -g|--group-id)
        require_value "$1" "$2"
        GROUP_ID=$2
        shift 2
        ;;
      -a|--artifact-id)
        require_value "$1" "$2"
        ARTIFACT_ID=$2
        shift 2
        ;;
      -v|--version)
        require_value "$1" "$2"
        VERSION=$2
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
      --deploy-url)
        require_value "$1" "$2"
        DEPLOY_URL=$2
        shift 2
        ;;
      --deploy-repository-id)
        require_value "$1" "$2"
        DEPLOY_REPOSITORY_ID=$2
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

require_arg --group-id               "${GROUP_ID}"
require_arg --artifact-id            "${ARTIFACT_ID}"
require_arg --version                "${VERSION}"
require_arg --nightly-date           "${NIGHTLY_DATE}"
require_arg --artifactory-url        "${ARTIFACTORY_URL}"
require_arg --artifactory-repository "${ARTIFACTORY_REPOSITORY}"

if [[ ${VERSION} != *-SNAPSHOT ]]; then
  echo "Error: nightly promote requires a -SNAPSHOT version, got '${VERSION}'" >&2
  exit 1
fi

if ! [[ ${NIGHTLY_DATE} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Error: --nightly-date must match YYYY-MM-DD, got '${NIGHTLY_DATE}'" >&2
  exit 1
fi

for var in ARTIFACTORY_USERNAME ARTIFACTORY_TOKEN \
           MAVEN_DEPLOY_USERNAME MAVEN_DEPLOY_TOKEN; do
  if [[ -z ${!var} ]]; then
    echo "Error: ${var} must be set" >&2
    exit 1
  fi
done

echo "Sonatype snapshots promote"
echo "  image:               ${IMAGE}"
echo "  coordinates:         ${GROUP_ID}:${ARTIFACT_ID}:${VERSION}"
echo "  nightly-date:        ${NIGHTLY_DATE}"
echo "  artifactory url:     ${ARTIFACTORY_URL}"
echo "  artifactory repo:    ${ARTIFACTORY_REPOSITORY}"
echo "  deploy url:          ${DEPLOY_URL}"
echo "  deploy repository:   ${DEPLOY_REPOSITORY_ID}"

DOCKER_ARGS=(
  --rm
  --env GROUP_ID="${GROUP_ID}"
  --env ARTIFACT_ID="${ARTIFACT_ID}"
  --env VERSION="${VERSION}"
  --env NIGHTLY_DATE="${NIGHTLY_DATE}"
  --env ARTIFACTORY_URL="${ARTIFACTORY_URL}"
  --env ARTIFACTORY_REPOSITORY="${ARTIFACTORY_REPOSITORY}"
  --env ARTIFACTORY_USERNAME="${ARTIFACTORY_USERNAME}"
  --env ARTIFACTORY_TOKEN="${ARTIFACTORY_TOKEN}"
  --env MAVEN_DEPLOY_USERNAME="${MAVEN_DEPLOY_USERNAME}"
  --env MAVEN_DEPLOY_TOKEN="${MAVEN_DEPLOY_TOKEN}"
  --env DEPLOY_URL="${DEPLOY_URL}"
  --env DEPLOY_REPOSITORY_ID="${DEPLOY_REPOSITORY_ID}"
  --env HOST_UID="$(id -u)"
  --env HOST_GID="$(id -g)"
  --volume "${SCRIPT_DIR}:/scripts:ro"
)

docker run "${DOCKER_ARGS[@]}" "${IMAGE}" \
  bash /scripts/sonatype_snapshots_publish_in_container.sh

echo "Sonatype snapshots promote completed for ${GROUP_ID}:${ARTIFACT_ID}:${VERSION}"
