#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Sonatype snapshot upload helpers for maven_snapshot_publish.sh.
#
# Snapshots publish straight to https://central.sonatype.com/repository/maven-snapshots/
# via HTTP PUT; there is no staging repository, no Portal validation, and no
# human-gated publish step. This file relies on _sonatype_upload (Basic-auth
# PUT with retry) from maven_central_publish_steps.sh, which the calling
# script sources before this one.

# require_snapshot_artifact_names DIR VERSION
# Fail if any file under DIR (recursively) does not contain "-SNAPSHOT" in its
# name. This is the publish-side "-SNAPSHOT jar verification": it catches
# release-shaped artifacts that would otherwise be uploaded to the snapshot
# repository by mistake.
require_snapshot_artifact_names() {
  local dir=$1
  local version=$2
  local file offender_count=0
  if [[ ${version} != *-SNAPSHOT ]]; then
    fatal "require_snapshot_artifact_names called with non-snapshot version '${version}'"
  fi
  while IFS= read -r -d '' file; do
    case "$(basename "${file}")" in
      *-SNAPSHOT*|maven-metadata.xml*) ;;
      *)
        echo "Error: snapshot bundle contains non-SNAPSHOT file: ${file}" >&2
        offender_count=$((offender_count + 1))
        ;;
    esac
  done < <(find "${dir}" -type f -print0)
  if (( offender_count > 0 )); then
    fatal "found ${offender_count} file(s) missing '-SNAPSHOT' in their name under ${dir}"
  fi
}

# snapshot_upload_file LOCAL_PATH REPOSITORY_PATH
# PUT LOCAL_PATH to <SNAPSHOT_REPOSITORY_URL>/<REPOSITORY_PATH>.
snapshot_upload_file() {
  local file_path=$1 repository_path=$2
  local encoded_path
  encoded_path=$(jq -rn --arg path "${repository_path}" \
    '$path | split("/") | map(@uri) | join("/")')
  _sonatype_upload "${file_path}" \
    "${SNAPSHOT_REPOSITORY_URL}/${encoded_path}"
}

# upload_tree_to_snapshots ROOT
# Walk ROOT (already a Maven-repository-layout tree) and PUT every file to
# the Sonatype snapshot repository.
upload_tree_to_snapshots() {
  local root=$1 file repository_path count=0
  echo "Uploading Maven repository files to the Sonatype snapshot repository"
  while IFS= read -r -d '' file; do
    repository_path=${file#"${root}/"}
    snapshot_upload_file "${file}" "${repository_path}"
    count=$((count + 1))
  done < <(find "${root}" -type f -print0)
  echo "  uploaded files: ${count}"
}
