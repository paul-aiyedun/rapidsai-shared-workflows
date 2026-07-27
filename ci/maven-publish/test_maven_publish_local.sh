#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Local-dev-only end-to-end wrapper for the maven-publish pipeline. NOT for
# CI use - CI must call maven-publish.yaml directly (enforced by
# verify_scripts.sh). Chains artifactory_upload.sh -> promote script based
# on --publication-type, forwarding resolved coordinates between them.
#
# With --input <dir>: use the supplied Maven-repo tree (caller supplies GPG
# creds). Without --input: generate a synthetic hello-world payload + a
# throwaway GPG key for zero-setup smoke testing.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck disable=SC1091
. "${SCRIPT_DIR}/argparse.sh"

PUBLICATION_TYPE=""
INPUT_DIR=""
GROUP_ID="io.github.rapidsai-test"
ARTIFACTORY_URL=""
ARTIFACTORY_REPOSITORY=""
RC_NUMBER=""
NIGHTLY_DATE=""
AUTO_DROP="true"
CENTRAL_PORTAL_URL="${CENTRAL_PORTAL_URL:-https://central.sonatype.com}"
DEPLOY_URL=""
DEPLOY_REPOSITORY_ID=""
SKIP_PROMOTE="false"

print_help() {
  cat << EOF

Usage: test_maven_publish_local.sh --publication-type <rc|nightly> \\
                                   --artifactory-url <url> \\
                                   --artifactory-repository <repo> \\
                                   [OPTIONS]

Runs the full maven-publish pipeline (upload + promote) locally, using
either a supplied real Maven-repo directory (--input) or a self-generated
synthetic hello-world payload plus throwaway GPG key.

REQUIRED:
    -t, --publication-type          "rc" or "nightly".
    -u, --artifactory-url           Base URL of the Artifactory server.
    -r, --artifactory-repository    Artifactory repository name.

OPTIONS:
    -i, --input <dir>               Existing Maven-repo-layout directory.
                                    When omitted, generates a synthetic
                                    hello-world payload via
                                    generate_test_maven_repo.sh.
    -g, --group-id <id>             Overrides the synthetic payload's
                                    groupId. Only meaningful when --input
                                    is omitted. Default: io.github.rapidsai-test.
    -n, --rc-number <N>             Explicit RC number (rc only). Otherwise
                                    the upload step auto-increments.
    -d, --nightly-date <YYYY-MM-DD> Explicit nightly date (nightly only).
                                    Otherwise defaults to today (UTC).
    --auto-drop <true|false>        For rc: drop after VALIDATED (default: true).
    --portal-url <url>              Publisher Portal base URL (default:
                                    https://central.sonatype.com).
    --deploy-url <url>              Sonatype snapshots endpoint override
                                    (nightly only). Default: real Sonatype.
    --deploy-repository-id <id>     Maven repositoryId for the deploy URL
                                    (nightly only, default: central-snapshots).
    --skip-promote                  Only run the upload step; skip the promote
                                    script. Useful for testing just the
                                    staging path.
    -h, --help                      Show this help message.

ENVIRONMENT VARIABLES:
    ARTIFACTORY_USERNAME            Required.
    ARTIFACTORY_TOKEN               Required.
    GPG_PRIVATE_KEY / GPG_PASSPHRASE
                                    Required when --input is supplied. When
                                    --input is omitted, a throwaway key is
                                    generated and exported into these vars
                                    for the pipeline.
    MAVEN_DEPLOY_USERNAME / MAVEN_DEPLOY_TOKEN
                                    Required unless --skip-promote.

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        print_help
        exit 0
        ;;
      -t|--publication-type)
        require_value "$1" "$2"
        PUBLICATION_TYPE=$2
        shift 2
        ;;
      -i|--input)
        require_value "$1" "$2"
        INPUT_DIR=$2
        shift 2
        ;;
      -g|--group-id)
        require_value "$1" "$2"
        GROUP_ID=$2
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
      --skip-promote)
        SKIP_PROMOTE="true"
        shift
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

require_arg --publication-type      "${PUBLICATION_TYPE}"
require_arg --artifactory-url       "${ARTIFACTORY_URL}"
require_arg --artifactory-repository "${ARTIFACTORY_REPOSITORY}"

if [[ ${PUBLICATION_TYPE} != "rc" && ${PUBLICATION_TYPE} != "nightly" ]]; then
  echo "Error: --publication-type must be 'rc' or 'nightly'" >&2
  exit 1
fi

for var in ARTIFACTORY_USERNAME ARTIFACTORY_TOKEN; do
  if [[ -z ${!var} ]]; then
    echo "Error: ${var} must be set" >&2
    exit 1
  fi
done

if [[ ${SKIP_PROMOTE} != "true" ]]; then
  for var in MAVEN_DEPLOY_USERNAME MAVEN_DEPLOY_TOKEN; do
    if [[ -z ${!var} ]]; then
      echo "Error: ${var} must be set (or pass --skip-promote)" >&2
      exit 1
    fi
  done
fi

WORK_ROOT="$(mktemp -d)"
cleanup_work_root() {
  rm -rf "${WORK_ROOT}"
}
trap cleanup_work_root EXIT

# Caller supplies GPG creds themselves - won't sign a real payload with a
# throwaway key.
if [[ -n ${INPUT_DIR} ]]; then
  if [[ ! -d ${INPUT_DIR} ]]; then
    echo "Error: --input '${INPUT_DIR}' does not exist" >&2
    exit 1
  fi
  for var in GPG_PRIVATE_KEY GPG_PASSPHRASE; do
    if [[ -z ${!var} ]]; then
      echo "Error: ${var} must be set when --input is supplied" >&2
      exit 1
    fi
  done
  echo "Using supplied Maven-repo input: ${INPUT_DIR}"
  MAVEN_REPO="${INPUT_DIR}"
else
  echo "Generating synthetic Maven-repo payload"
  MAVEN_REPO="${WORK_ROOT}/synthetic-repo"
  # Nightly needs -SNAPSHOT; rc uses the plain release version.
  if [[ ${PUBLICATION_TYPE} == "nightly" ]]; then
    GENERATE_VERSION="0.0.1-SNAPSHOT"
  else
    GENERATE_VERSION="0.0.1"
  fi
  "${SCRIPT_DIR}/generate_test_maven_repo.sh" \
    --output-dir "${MAVEN_REPO}" \
    --group-id "${GROUP_ID}" \
    --version "${GENERATE_VERSION}"

  if ! command -v gpg >/dev/null 2>&1; then
    echo "Error: gpg not available on host; cannot generate throwaway signing key" >&2
    exit 1
  fi
  echo "Generating throwaway GPG signing key"
  GNUPGHOME_LOCAL="${WORK_ROOT}/gnupg"
  mkdir -p "${GNUPGHOME_LOCAL}"
  chmod 700 "${GNUPGHOME_LOCAL}"
  cat > "${WORK_ROOT}/key-batch.cfg" <<EOF
%no-protection
Key-Type: RSA
Key-Length: 2048
Name-Real: maven-publish local test
Name-Email: maven-publish-local@example.invalid
Expire-Date: 1d
%commit
EOF
  GNUPGHOME="${GNUPGHOME_LOCAL}" gpg --batch --pinentry-mode loopback \
    --generate-key "${WORK_ROOT}/key-batch.cfg" >/dev/null 2>&1
  GPG_PRIVATE_KEY=$(GNUPGHOME="${GNUPGHOME_LOCAL}" gpg --batch --pinentry-mode loopback \
    --export-secret-keys --armor)
  GPG_PASSPHRASE=""
  export GPG_PRIVATE_KEY GPG_PASSPHRASE
fi

# Capture upload_metadata via $GITHUB_OUTPUT so we can source resolved
# coordinates back into this shell for the promote step.
echo
echo "=== Artifactory upload ==="
UPLOAD_METADATA="${WORK_ROOT}/upload_metadata.env"
: > "${UPLOAD_METADATA}"

UPLOAD_ARGS=(
  --input "${MAVEN_REPO}"
  --publication-type "${PUBLICATION_TYPE}"
  --artifactory-url "${ARTIFACTORY_URL}"
  --artifactory-repository "${ARTIFACTORY_REPOSITORY}"
)
if [[ -n ${RC_NUMBER} ]]; then
  UPLOAD_ARGS+=(--rc-number "${RC_NUMBER}")
fi
if [[ -n ${NIGHTLY_DATE} ]]; then
  UPLOAD_ARGS+=(--nightly-date "${NIGHTLY_DATE}")
fi

GITHUB_OUTPUT="${UPLOAD_METADATA}" "${SCRIPT_DIR}/artifactory_upload.sh" "${UPLOAD_ARGS[@]}"

# shellcheck disable=SC1090
. "${UPLOAD_METADATA}"

if [[ -z ${GROUP_ID} || -z ${ARTIFACT_ID} || -z ${VERSION} ]]; then
  echo "Error: upload step did not report GROUP_ID / ARTIFACT_ID / VERSION" >&2
  cat "${UPLOAD_METADATA}" >&2 || true
  exit 1
fi

echo
echo "Upload complete. Resolved coordinates:"
echo "  GROUP_ID=${GROUP_ID}"
echo "  ARTIFACT_ID=${ARTIFACT_ID}"
echo "  VERSION=${VERSION}"
if [[ ${PUBLICATION_TYPE} == "rc" ]]; then
  echo "  RC_NUMBER=${RC_NUMBER}"
else
  echo "  NIGHTLY_DATE=${NIGHTLY_DATE}"
fi

if [[ ${SKIP_PROMOTE} == "true" ]]; then
  echo
  echo "--skip-promote set; not running promote step"
  exit 0
fi

echo
echo "=== Promote (${PUBLICATION_TYPE}) ==="

if [[ ${PUBLICATION_TYPE} == "rc" ]]; then
  "${SCRIPT_DIR}/maven_central_publish.sh" \
    --group-id "${GROUP_ID}" \
    --artifact-id "${ARTIFACT_ID}" \
    --version "${VERSION}" \
    --rc-number "${RC_NUMBER}" \
    --artifactory-url "${ARTIFACTORY_URL}" \
    --artifactory-repository "${ARTIFACTORY_REPOSITORY}" \
    --auto-drop "${AUTO_DROP}" \
    --portal-url "${CENTRAL_PORTAL_URL}"
else
  DEPLOY_ARGS=(
    --group-id "${GROUP_ID}"
    --artifact-id "${ARTIFACT_ID}"
    --version "${VERSION}"
    --nightly-date "${NIGHTLY_DATE}"
    --artifactory-url "${ARTIFACTORY_URL}"
    --artifactory-repository "${ARTIFACTORY_REPOSITORY}"
  )
  if [[ -n ${DEPLOY_URL} ]]; then
    DEPLOY_ARGS+=(--deploy-url "${DEPLOY_URL}")
  fi
  if [[ -n ${DEPLOY_REPOSITORY_ID} ]]; then
    DEPLOY_ARGS+=(--deploy-repository-id "${DEPLOY_REPOSITORY_ID}")
  fi
  "${SCRIPT_DIR}/sonatype_snapshots_publish.sh" "${DEPLOY_ARGS[@]}"
fi

echo
echo "test_maven_publish_local.sh finished successfully"
