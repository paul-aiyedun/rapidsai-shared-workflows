#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# In-container worker for sonatype_snapshots_publish.sh. Downloads the
# signed nightly bundle from Artifactory, forwards it via
# `mvn deploy:deploy-file`, then sidecar-uploads the .asc files to the
# server-assigned timestamped filenames (deploy:deploy-file can't attach
# them). All configuration comes from env vars set by the host script.

set -e

for var in GROUP_ID ARTIFACT_ID VERSION NIGHTLY_DATE \
           ARTIFACTORY_URL ARTIFACTORY_REPOSITORY \
           ARTIFACTORY_USERNAME ARTIFACTORY_TOKEN \
           MAVEN_DEPLOY_USERNAME MAVEN_DEPLOY_TOKEN \
           DEPLOY_URL DEPLOY_REPOSITORY_ID; do
  if [[ -z ${!var} ]]; then
    echo "Error: ${var} must be set" >&2
    exit 1
  fi
done

if [[ ${VERSION} != *-SNAPSHOT ]]; then
  echo "Error: nightly promote requires a -SNAPSHOT version, got '${VERSION}'" >&2
  exit 1
fi

if ! [[ ${NIGHTLY_DATE} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Error: NIGHTLY_DATE must match YYYY-MM-DD, got '${NIGHTLY_DATE}'" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 \
     || ! command -v xmllint >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -qq -y --no-install-recommends curl jq libxml2-utils
fi

WORK_DIR="$(mktemp -d)"
BUNDLE_DIR="${WORK_DIR}/bundle"
mkdir -p "${BUNDLE_DIR}"

if [[ -n ${HOST_UID} && -n ${HOST_GID} ]]; then
  _chown_work_on_exit() {
    chown -R "${HOST_UID}:${HOST_GID}" "${WORK_DIR}" 2>/dev/null || true
  }
  trap _chown_work_on_exit EXIT
fi

GROUP_PATH="${GROUP_ID//./\/}"
STAGING_SUBPATH="staging/nightly/${NIGHTLY_DATE}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}"
STAGING_URL="${ARTIFACTORY_URL}/${ARTIFACTORY_REPOSITORY}/${STAGING_SUBPATH}"

echo "Downloading nightly bundle from ${STAGING_URL}"

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

STAGE_LISTING=$(retry 3 curl -sS -f \
  --user "${ARTIFACTORY_USERNAME}:${ARTIFACTORY_TOKEN}" \
  "${ARTIFACTORY_URL}/api/storage/${ARTIFACTORY_REPOSITORY}/${STAGING_SUBPATH}")

mapfile -t STAGED_FILES < <(echo "${STAGE_LISTING}" | jq -r '.children[] | select(.folder == false) | .uri | ltrimstr("/")')

if [[ ${#STAGED_FILES[@]} -eq 0 ]]; then
  echo "Error: no files found at ${STAGING_URL} to promote" >&2
  exit 1
fi

for f in "${STAGED_FILES[@]}"; do
  echo "  GET ${f}"
  retry 3 curl -sS -f \
    --user "${ARTIFACTORY_USERNAME}:${ARTIFACTORY_TOKEN}" \
    -o "${BUNDLE_DIR}/${f}" \
    "${STAGING_URL}/${f}"
done

POM_FILE="${BUNDLE_DIR}/${ARTIFACT_ID}-${VERSION}.pom"
POM_ASC="${POM_FILE}.asc"
if [[ ! -f ${POM_FILE} || ! -f ${POM_ASC} ]]; then
  echo "Error: missing POM or POM signature under ${BUNDLE_DIR}" >&2
  exit 1
fi

mapfile -t ALL_JARS < <(find "${BUNDLE_DIR}" -maxdepth 1 -type f \
  -name "${ARTIFACT_ID}-${VERSION}*.jar" | sort)
if [[ ${#ALL_JARS[@]} -eq 0 ]]; then
  echo "Error: no JARs found under ${BUNDLE_DIR}" >&2
  exit 1
fi

# Per-run settings.xml keeps MAVEN_DEPLOY_TOKEN out of any shared ~/.m2 config.
SETTINGS_FILE="${WORK_DIR}/settings.xml"
cat > "${SETTINGS_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <servers>
    <server>
      <id>${DEPLOY_REPOSITORY_ID}</id>
      <username>${MAVEN_DEPLOY_USERNAME}</username>
      <password>${MAVEN_DEPLOY_TOKEN}</password>
    </server>
  </servers>
</settings>
EOF

echo "Deploying bundle to ${DEPLOY_URL} (repositoryId=${DEPLOY_REPOSITORY_ID})"

MAIN_JAR="${BUNDLE_DIR}/${ARTIFACT_ID}-${VERSION}.jar"
if [[ ! -f ${MAIN_JAR} ]]; then
  echo "Error: no unclassified primary jar found at ${MAIN_JAR}" >&2
  exit 1
fi

# Comma-separated -Dfiles / -Dclassifiers / -Dtypes for all non-main jars.
SIDE_FILES=""
SIDE_CLASSIFIERS=""
SIDE_TYPES=""
for jar in "${ALL_JARS[@]}"; do
  base=$(basename "${jar}" .jar)
  if [[ ${base} == "${ARTIFACT_ID}-${VERSION}" ]]; then
    continue
  fi
  classifier=${base#"${ARTIFACT_ID}-${VERSION}-"}
  if [[ -n ${SIDE_FILES} ]]; then
    SIDE_FILES+=","
    SIDE_CLASSIFIERS+=","
    SIDE_TYPES+=","
  fi
  SIDE_FILES+="${jar}"
  SIDE_CLASSIFIERS+="${classifier}"
  SIDE_TYPES+="jar"
done

DEPLOY_ARGS=(
  --batch-mode
  --settings "${SETTINGS_FILE}"
  deploy:deploy-file
  -DrepositoryId="${DEPLOY_REPOSITORY_ID}"
  -Durl="${DEPLOY_URL}"
  -DpomFile="${POM_FILE}"
  -Dfile="${MAIN_JAR}"
  -DgroupId="${GROUP_ID}"
  -DartifactId="${ARTIFACT_ID}"
  -Dversion="${VERSION}"
  -Dpackaging=jar
)
if [[ -n ${SIDE_FILES} ]]; then
  DEPLOY_ARGS+=(
    -Dfiles="${SIDE_FILES}"
    -Dclassifiers="${SIDE_CLASSIFIERS}"
    -Dtypes="${SIDE_TYPES}"
  )
fi

retry 3 mvn "${DEPLOY_ARGS[@]}"

# Sonatype rewrites SNAPSHOT filenames to a timestamped form
# (e.g. cudf-26.08.0-20260727.123456-1.jar); discover them from maven-metadata.xml
# so we can upload each .asc under its corresponding server-side name.
echo "Reading maven-metadata.xml to discover server-assigned timestamped filenames"
DEPLOY_URL_STRIPPED="${DEPLOY_URL%/}"
METADATA_URL="${DEPLOY_URL_STRIPPED}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}/maven-metadata.xml"
METADATA_FILE="${WORK_DIR}/maven-metadata.xml"
retry 3 curl -sS -f \
  --user "${MAVEN_DEPLOY_USERNAME}:${MAVEN_DEPLOY_TOKEN}" \
  -o "${METADATA_FILE}" \
  "${METADATA_URL}"

# <snapshot><timestamp> + <buildNumber> => 26.08.0-SNAPSHOT becomes e.g.
# 26.08.0-20260727.123456-1 on the server.
TIMESTAMP=$(xmllint --xpath 'string(/metadata/versioning/snapshot/timestamp)' "${METADATA_FILE}")
BUILD_NUMBER=$(xmllint --xpath 'string(/metadata/versioning/snapshot/buildNumber)' "${METADATA_FILE}")
if [[ -z ${TIMESTAMP} || -z ${BUILD_NUMBER} ]]; then
  echo "Error: could not read timestamp/buildNumber from ${METADATA_URL}" >&2
  cat "${METADATA_FILE}" >&2 || true
  exit 1
fi
VERSION_BASE="${VERSION%-SNAPSHOT}"
TIMESTAMPED_VERSION="${VERSION_BASE}-${TIMESTAMP}-${BUILD_NUMBER}"

echo "Server-assigned timestamped version: ${TIMESTAMPED_VERSION}"

# PUT each .asc under its server-assigned timestamped name, preserving
# classifier/suffix from the local filename.
upload_asc() {
  local local_asc=$1
  local base
  base=$(basename "${local_asc}")
  local remote_base=${base/${VERSION}/${TIMESTAMPED_VERSION}}
  local remote_url="${DEPLOY_URL_STRIPPED}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}/${remote_base}"

  echo "  PUT ${remote_base} -> ${remote_url}"
  retry 3 curl -sS -f \
    --user "${MAVEN_DEPLOY_USERNAME}:${MAVEN_DEPLOY_TOKEN}" \
    -T "${local_asc}" \
    -X PUT "${remote_url}" \
    -o /dev/null
}

echo "Uploading .asc sidecars"
mapfile -t ASC_FILES < <(find "${BUNDLE_DIR}" -maxdepth 1 -type f -name '*.asc' | sort)
if [[ ${#ASC_FILES[@]} -eq 0 ]]; then
  echo "Error: no .asc files present in ${BUNDLE_DIR}; nothing to sidecar" >&2
  exit 1
fi

for asc in "${ASC_FILES[@]}"; do
  upload_asc "${asc}"
done

echo "Snapshot promote complete for ${GROUP_ID}:${ARTIFACT_ID}:${VERSION}"
