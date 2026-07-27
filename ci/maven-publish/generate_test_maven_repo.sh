#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Generate an assemble_maven_repo.sh-shaped Maven repo containing a real
# (compiled) hello-world jar, for exercising the maven-publish pipeline
# without a real cudf build. artifact-id and classifiers are hardcoded;
# --version defaults to 0.0.1 (override for -SNAPSHOT testing). See --help
# for output layout.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/argparse.sh"

OUTPUT_DIR=""
GROUP_ID=""
VERSION="0.0.1"

# Hardcoded - callers needing different values should use their own
# Maven-repo layout via artifactory_upload.sh --input directly.
readonly ARTIFACT_ID="hello-world"
readonly CLASSIFIERS="x86_64,aarch64"

IMAGE="${MAVEN_PUBLISH_IMAGE:-maven:3-eclipse-temurin-17}"

print_help() {
  cat << EOF

Usage: generate_test_maven_repo.sh --output-dir <path> --group-id <groupId>
                                   [--version <version>]

Produces an assemble_maven_repo.sh-shaped Maven repo directory containing a
trivial hello-world Java class, packaged into one unclassified primary jar,
two classified jars (x86_64, aarch64), a sources jar, a javadoc jar, and a
POM. All jars are real, compiled, non-empty ZIPs - not placeholder stubs.

REQUIRED:
    -o, --output-dir     Directory to write the Maven-repo tree into. Must
                         be empty or not exist yet.
    -g, --group-id       Maven groupId (e.g. io.github.<your-username>).
                         Only need to match your verified Sonatype Central
                         namespace if you're going to promote the resulting
                         bundle to the live Publisher Portal.

OPTIONS:
    -v, --version        Maven version string to embed in the POM and JAR
                         filenames (default: 0.0.1). Pass e.g. 0.0.1-SNAPSHOT
                         to exercise the nightly/snapshots path end-to-end.
    -h, --help           Show this help message.

ENVIRONMENT VARIABLES:
    MAVEN_PUBLISH_IMAGE  Override the Maven container image (default:
                         maven:3-eclipse-temurin-17).

EXAMPLE:
    generate_test_maven_repo.sh --output-dir /tmp/fake-maven-repo \\
                                --group-id io.github.myusername
    # -> /tmp/fake-maven-repo/io/github/myusername/hello-world/${VERSION}/
    #      hello-world-${VERSION}.jar          (unclassified)
    #      hello-world-${VERSION}-x86_64.jar
    #      hello-world-${VERSION}-aarch64.jar
    #      hello-world-${VERSION}-sources.jar
    #      hello-world-${VERSION}-javadoc.jar
    #      hello-world-${VERSION}.pom

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        print_help
        exit 0
        ;;
      -o|--output-dir)
        require_value "$1" "$2"
        OUTPUT_DIR=$2
        shift 2
        ;;
      -g|--group-id)
        require_value "$1" "$2"
        GROUP_ID=$2
        shift 2
        ;;
      -v|--version)
        require_value "$1" "$2"
        VERSION=$2
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

require_arg --output-dir "${OUTPUT_DIR}"
require_arg --group-id   "${GROUP_ID}"

# Alphanum + . _ - only; anything else confuses the groupId->path split.
if ! [[ ${GROUP_ID} =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Error: --group-id must contain only [A-Za-z0-9._-] (got '${GROUP_ID}')" >&2
  exit 1
fi

if [[ -e ${OUTPUT_DIR} && -n "$(ls -A "${OUTPUT_DIR}" 2>/dev/null)" ]]; then
  echo "Error: --output-dir '${OUTPUT_DIR}' must be empty or nonexistent" >&2
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"

echo "Generating synthetic Maven repo"
echo "  image:       ${IMAGE}"
echo "  output dir:  ${OUTPUT_DIR}"
echo "  group id:    ${GROUP_ID}"
echo "  artifact id: ${ARTIFACT_ID} (hardcoded)"
echo "  version:     ${VERSION}"
echo "  classifiers: ${CLASSIFIERS} (hardcoded)"

DOCKER_ARGS=(
  --rm
  --volume "${OUTPUT_DIR}:/output"
  --volume "${SCRIPT_DIR}:/scripts:ro"
  --workdir /output
  --env GROUP_ID="${GROUP_ID}"
  --env ARTIFACT_ID="${ARTIFACT_ID}"
  --env VERSION="${VERSION}"
  --env CLASSIFIERS="${CLASSIFIERS}"
  --env HOST_UID="$(id -u)"
  --env HOST_GID="$(id -g)"
)

docker run "${DOCKER_ARGS[@]}" "${IMAGE}" \
  bash /scripts/generate_test_maven_repo_in_container.sh

# Fail-loud if worker produced empty stubs instead of real jars.
GROUP_PATH="${GROUP_ID//./\/}"
DEST_DIR="${OUTPUT_DIR}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}"

if [[ ! -d ${DEST_DIR} ]]; then
  echo "Error: worker did not create ${DEST_DIR}" >&2
  exit 1
fi

EXPECTED_JARS=(
  "${ARTIFACT_ID}-${VERSION}.jar"
  "${ARTIFACT_ID}-${VERSION}-sources.jar"
  "${ARTIFACT_ID}-${VERSION}-javadoc.jar"
)
IFS=',' read -ra CLASSIFIER_LIST <<< "${CLASSIFIERS}"
for c in "${CLASSIFIER_LIST[@]}"; do
  EXPECTED_JARS+=("${ARTIFACT_ID}-${VERSION}-${c}.jar")
done

for jar in "${EXPECTED_JARS[@]}"; do
  if [[ ! -s "${DEST_DIR}/${jar}" ]]; then
    echo "Error: ${DEST_DIR}/${jar} missing or empty" >&2
    exit 1
  fi
  if ! unzip -l "${DEST_DIR}/${jar}" >/dev/null 2>&1; then
    echo "Error: ${DEST_DIR}/${jar} is not a valid ZIP/jar" >&2
    exit 1
  fi
done

if [[ ! -s "${DEST_DIR}/${ARTIFACT_ID}-${VERSION}.pom" ]]; then
  echo "Error: ${DEST_DIR}/${ARTIFACT_ID}-${VERSION}.pom missing or empty" >&2
  exit 1
fi

echo "Synthetic Maven repo written to ${DEST_DIR}"
ls -1 "${DEST_DIR}"
