#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Promote a signed RC staging bundle from Artifactory to the Sonatype Central
# Publisher Portal.
#
# Byte-forwarding: every file the RC upload step signed and staged is
# downloaded, zipped, and re-uploaded to the Publisher Portal unmodified. No
# re-signing. Sonatype receives exactly the bytes and .asc signatures that
# were originally staged.
#
# Publisher Portal deployment mode is always USER_MANAGED. This script never
# calls Sonatype's /publish endpoint:
#   --auto-drop true  (CI/test default) - validate, then drop. Nothing goes
#                                          live on Maven Central.
#   --auto-drop false - leave the deployment in the VALIDATED / PENDING state
#                       so a human can log into the Sonatype UI and click
#                       Publish to release it.
#
# HOST-only: this step does not need Maven or GPG, only curl+jq+zip, so it
# runs directly on the runner - no docker, no container - matching
# cudf/java/ci/assemble_maven_repo.sh's precedent of skipping docker when
# the step doesn't need it.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/argparse.sh"

GROUP_ID=""
ARTIFACT_ID=""
VERSION=""
RC_NUMBER=""
ARTIFACTORY_URL=""
ARTIFACTORY_REPOSITORY=""
AUTO_DROP="true"
CENTRAL_PORTAL_URL="${CENTRAL_PORTAL_URL:-https://central.sonatype.com}"
POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-15}"
POLL_TIMEOUT_SEC="${POLL_TIMEOUT_SEC:-900}"

print_help() {
  cat << EOF

Usage: maven_central_publish.sh --group-id <g> --artifact-id <a> --version <v> \\
                                --rc-number <N> --artifactory-url <url> \\
                                --artifactory-repository <repo> [OPTIONS]

Byte-forwards a signed RC staging bundle from Artifactory
(staging/rc-<N>/<groupPath>/<artifactId>/<version>/) to the Sonatype Central
Publisher Portal in USER_MANAGED mode.

REQUIRED:
    -g, --group-id                 Maven groupId of the artifact, e.g. ai.rapids.
                                   In the combined maven-publish.yaml workflow
                                   this is threaded from the upload step's
                                   outputs; on the CLI you supply it yourself.
    -a, --artifact-id              Maven artifactId, e.g. cudf.
    -v, --version                  Release version being promoted, e.g. 26.08.0.
    -n, --rc-number                RC iteration number of the bundle to
                                   promote. In the combined workflow, this is
                                   the exact RC_NUMBER the upload step just
                                   resolved (never re-derived via AQL here).
    -u, --artifactory-url          Base URL of the Artifactory server (no
                                   trailing slash).
    -r, --artifactory-repository   Artifactory repository name to download
                                   from.

OPTIONS:
    --auto-drop <true|false>       Drop after VALIDATED (default: true).
    --portal-url <url>             Publisher Portal base URL (default:
                                   https://central.sonatype.com).
    -h, --help                     Show this help message.

ENVIRONMENT VARIABLES:
    ARTIFACTORY_USERNAME           Read-access account on Artifactory (required).
    ARTIFACTORY_TOKEN              Auth token for ARTIFACTORY_USERNAME (required).
    MAVEN_DEPLOY_USERNAME          Publisher Portal user token username (required).
    MAVEN_DEPLOY_TOKEN             Publisher Portal user token password (required).
    POLL_INTERVAL_SEC              Poll interval while waiting for VALIDATED
                                   (default: 15).
    POLL_TIMEOUT_SEC               Overall poll timeout (default: 900).

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
      -n|--rc-number)
        require_value "$1" "$2"
        RC_NUMBER=$2
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
      --auto-drop)
        require_value "$1" "$2"
        AUTO_DROP=$2
        shift 2
        ;;
      --portal-url)
        require_value "$1" "$2"
        CENTRAL_PORTAL_URL=$2
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
require_arg --rc-number              "${RC_NUMBER}"
require_arg --artifactory-url        "${ARTIFACTORY_URL}"
require_arg --artifactory-repository "${ARTIFACTORY_REPOSITORY}"

if [[ ${AUTO_DROP} != "true" && ${AUTO_DROP} != "false" ]]; then
  echo "Error: --auto-drop must be 'true' or 'false' (got '${AUTO_DROP}')" >&2
  exit 1
fi

if ! [[ ${RC_NUMBER} =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --rc-number must be a positive integer, got '${RC_NUMBER}'" >&2
  exit 1
fi

# RC promotes must never carry -SNAPSHOT.
if [[ ${VERSION} == *-SNAPSHOT ]]; then
  echo "Error: RC promote requires a release-shaped version, got '${VERSION}'" >&2
  exit 1
fi

# Inline env-var assertions - same fail-fast rationale as the upload worker.
for var in ARTIFACTORY_USERNAME ARTIFACTORY_TOKEN \
           MAVEN_DEPLOY_USERNAME MAVEN_DEPLOY_TOKEN; do
  if [[ -z ${!var} ]]; then
    echo "Error: ${var} must be set" >&2
    exit 1
  fi
done

for cmd in curl jq zip; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Error: required command '${cmd}' not found on PATH" >&2
    exit 1
  fi
done

GROUP_PATH="${GROUP_ID//./\/}"
STAGING_SUBPATH="staging/rc-${RC_NUMBER}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}"
STAGING_URL="${ARTIFACTORY_URL}/${ARTIFACTORY_REPOSITORY}/${STAGING_SUBPATH}"

echo "Maven Central promote"
echo "  coordinates:   ${GROUP_ID}:${ARTIFACT_ID}:${VERSION}"
echo "  rc-number:     ${RC_NUMBER}"
echo "  auto-drop:     ${AUTO_DROP}"
echo "  source:        ${STAGING_URL}"
echo "  target portal: ${CENTRAL_PORTAL_URL}"

# Scratch working dir. All downloads land here mirroring the Maven-repo
# layout Central expects inside the uploaded bundle zip.
WORK_DIR="$(mktemp -d)"
BUNDLE_DIR="${WORK_DIR}/bundle"
BUNDLE_ARTIFACT_DIR="${BUNDLE_DIR}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}"
mkdir -p "${BUNDLE_ARTIFACT_DIR}"
cleanup_work_dir() {
  rm -rf "${WORK_DIR}"
}
trap cleanup_work_dir EXIT

retry() {
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

# List the staged files: Artifactory folder-info API returns .children[]
# entries with .uri prefixed by '/'. Filter out the .asc/.md5/... sidecars
# handled implicitly by the loop below.
echo "Listing staged files at ${STAGING_URL}"
STAGE_LISTING=$(retry 3 curl -sS -f \
  --user "${ARTIFACTORY_USERNAME}:${ARTIFACTORY_TOKEN}" \
  "${ARTIFACTORY_URL}/api/storage/${ARTIFACTORY_REPOSITORY}/${STAGING_SUBPATH}")

mapfile -t STAGED_FILES < <(echo "${STAGE_LISTING}" | jq -r '.children[] | select(.folder == false) | .uri | ltrimstr("/")')

if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
  echo "Error: no files found at ${STAGING_URL} to promote" >&2
  exit 1
fi

# Sanity-check the bundle contents up front: Central rejects bundles missing
# the classifier-less primary JAR, POM, sources, javadoc, or their .asc
# sidecars. Fail early with a clear error rather than letting Central spit
# out its opaque VALIDATION_FAILED status codes.
require_present() {
  local pattern=$1
  local desc=$2
  for f in "${STAGED_FILES[@]}"; do
    if [[ ${f} == ${pattern} ]]; then
      return 0
    fi
  done
  echo "Error: staged bundle is missing ${desc} (pattern ${pattern})" >&2
  return 1
}
require_present "${ARTIFACT_ID}-${VERSION}.pom"         "the POM"
require_present "${ARTIFACT_ID}-${VERSION}.pom.asc"     "the POM signature"
require_present "${ARTIFACT_ID}-${VERSION}.jar"         "the unclassified primary jar"
require_present "${ARTIFACT_ID}-${VERSION}.jar.asc"     "the unclassified primary jar signature"
require_present "${ARTIFACT_ID}-${VERSION}-sources.jar" "the sources jar"
require_present "${ARTIFACT_ID}-${VERSION}-javadoc.jar" "the javadoc jar"

echo "Downloading ${#STAGED_FILES[@]} files from Artifactory"
for f in "${STAGED_FILES[@]}"; do
  echo "  GET ${f}"
  retry 3 curl -sS -f \
    --user "${ARTIFACTORY_USERNAME}:${ARTIFACTORY_TOKEN}" \
    -o "${BUNDLE_ARTIFACT_DIR}/${f}" \
    "${STAGING_URL}/${f}"
done

BUNDLE_ZIP="${WORK_DIR}/${ARTIFACT_ID}-${VERSION}-rc${RC_NUMBER}.zip"
echo "Zipping bundle at ${BUNDLE_ZIP}"
(cd "${BUNDLE_DIR}" && zip -qr "${BUNDLE_ZIP}" .)

# Upload to the Sonatype Central Publisher Portal.
#
# https://central.sonatype.org/publish/publish-portal-api/
#
# publishingType=USER_MANAGED means the deployment stays PENDING (i.e. does
# not auto-publish) once VALIDATED. This script never calls /publish on it,
# regardless of --auto-drop: drop-true drops it, drop-false leaves it in the
# PENDING state for human review.
CENTRAL_AUTH=$(printf '%s:%s' "${MAVEN_DEPLOY_USERNAME}" "${MAVEN_DEPLOY_TOKEN}" | base64 -w0)

echo "Uploading bundle to Publisher Portal"
UPLOAD_URL="${CENTRAL_PORTAL_URL}/api/v1/publisher/upload?name=$(printf %s "${ARTIFACT_ID}-${VERSION}-rc${RC_NUMBER}" | jq -sRr @uri)&publishingType=USER_MANAGED"
DEPLOYMENT_ID=$(retry 3 curl -sS -f \
  -H "Authorization: Bearer ${CENTRAL_AUTH}" \
  -F "bundle=@${BUNDLE_ZIP}" \
  -X POST "${UPLOAD_URL}")

if [[ -z ${DEPLOYMENT_ID} ]]; then
  echo "Error: Publisher Portal did not return a deployment id" >&2
  exit 1
fi
echo "  deployment id: ${DEPLOYMENT_ID}"

# Poll until VALIDATED (success) or a terminal failure state. FAILED /
# VALIDATION_FAILED are hard errors; PUBLISHED indicates someone else pushed
# publish underneath us (unexpected in USER_MANAGED but still terminal).
echo "Polling status (interval=${POLL_INTERVAL_SEC}s, timeout=${POLL_TIMEOUT_SEC}s)"
STATUS_URL="${CENTRAL_PORTAL_URL}/api/v1/publisher/status?id=${DEPLOYMENT_ID}"
ELAPSED=0
DEPLOYMENT_STATE=""
while (( ELAPSED < POLL_TIMEOUT_SEC )); do
  STATUS_RESPONSE=$(curl -sS -f \
    -H "Authorization: Bearer ${CENTRAL_AUTH}" \
    -X POST "${STATUS_URL}") || {
      echo "  status poll failed, retrying"
      sleep "${POLL_INTERVAL_SEC}"
      ELAPSED=$((ELAPSED + POLL_INTERVAL_SEC))
      continue
    }
  DEPLOYMENT_STATE=$(echo "${STATUS_RESPONSE}" | jq -r '.deploymentState')
  echo "  [${ELAPSED}s] state=${DEPLOYMENT_STATE}"
  case "${DEPLOYMENT_STATE}" in
    VALIDATED)
      break
      ;;
    FAILED|VALIDATION_FAILED)
      echo "Error: Publisher Portal reported terminal state ${DEPLOYMENT_STATE}" >&2
      echo "${STATUS_RESPONSE}" | jq . >&2 || true
      exit 1
      ;;
    PUBLISHED)
      echo "Error: unexpected PUBLISHED state (USER_MANAGED deployments should never auto-publish)" >&2
      exit 1
      ;;
    *)
      sleep "${POLL_INTERVAL_SEC}"
      ELAPSED=$((ELAPSED + POLL_INTERVAL_SEC))
      ;;
  esac
done

if [[ ${DEPLOYMENT_STATE} != "VALIDATED" ]]; then
  echo "Error: timed out waiting for VALIDATED, last state was '${DEPLOYMENT_STATE}'" >&2
  exit 1
fi

if [[ ${AUTO_DROP} == "true" ]]; then
  echo "Dropping deployment ${DEPLOYMENT_ID} (--auto-drop true)"
  retry 3 curl -sS -f \
    -H "Authorization: Bearer ${CENTRAL_AUTH}" \
    -X DELETE "${CENTRAL_PORTAL_URL}/api/v1/publisher/deployment/${DEPLOYMENT_ID}" \
    -o /dev/null
  echo "Deployment dropped. Nothing was published to Maven Central."
else
  cat <<EOF
Deployment left in PENDING state.
  Deployment id:  ${DEPLOYMENT_ID}
  Portal UI:      ${CENTRAL_PORTAL_URL}/publishing/deployments
A human must review the deployment and click Publish to release it to
Maven Central.
EOF
fi
