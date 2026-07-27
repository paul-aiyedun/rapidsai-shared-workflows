#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# In-container worker for generate_test_maven_repo.sh.
#
# Compiles a trivial HelloWorld.java once with the real javac, packages one
# JAR per classifier via the real jar tool (so the output looks structurally
# identical to a real assemble_maven_repo.sh build), copies the first
# classifier's JAR to the unclassified primary, runs javadoc + zips sources
# on the same source file, and writes a minimal valid POM.
#
# No signing here - .asc files get produced later by
# artifactory_upload_in_container.sh, exactly as they do for a real build.
#
# Inputs (environment variables):
#   GROUP_ID / ARTIFACT_ID / VERSION   (required).
#   CLASSIFIERS                        Comma-separated list of classifier
#                                      names (required).
#   HOST_UID / HOST_GID                chown targets for /output on exit.

set -e

OUTPUT_DIR=/output

for var in GROUP_ID ARTIFACT_ID VERSION CLASSIFIERS HOST_UID HOST_GID; do
  if [[ -z ${!var} ]]; then
    echo "Error: ${var} must be set" >&2
    exit 1
  fi
done

_chown_output_on_exit() {
  chown -R "${HOST_UID}:${HOST_GID}" "${OUTPUT_DIR}" 2>/dev/null || true
}
trap _chown_output_on_exit EXIT

# Ensure the jar/javadoc tools are on PATH. maven:3-eclipse-temurin-17 ships
# them by default, but this makes the failure mode explicit if that changes.
for cmd in javac jar javadoc zip; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    if [[ ${cmd} == "zip" ]]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -qq -y --no-install-recommends zip
    else
      echo "Error: required tool '${cmd}' not found in the container" >&2
      exit 1
    fi
  fi
done

GROUP_PATH="${GROUP_ID//./\/}"
DEST_DIR="${OUTPUT_DIR}/${GROUP_PATH}/${ARTIFACT_ID}/${VERSION}"
mkdir -p "${DEST_DIR}"

SCRATCH="$(mktemp -d)"
SRC_DIR="${SCRATCH}/src"
CLASSES_DIR="${SCRATCH}/classes"
JAVADOC_DIR="${SCRATCH}/javadoc"
mkdir -p "${SRC_DIR}" "${CLASSES_DIR}" "${JAVADOC_DIR}"

SOURCE_FILE="${SRC_DIR}/HelloWorld.java"
cat > "${SOURCE_FILE}" <<'EOF'
/**
 * Trivial hello-world class for the maven-publish pipeline test payload.
 *
 * The class itself does nothing interesting - its purpose is to give the
 * generated JAR a real, compiled .class entry so publish-pipeline tests
 * exercise valid JAR bytecode, not empty stubs.
 */
public class HelloWorld {
    /**
     * Prints a hello message to standard output.
     *
     * @param args command-line arguments (ignored)
     */
    public static void main(String[] args) {
        System.out.println("Hello, World!");
    }
}
EOF

echo "Compiling HelloWorld.java"
javac -d "${CLASSES_DIR}" "${SOURCE_FILE}"

if [[ ! -f "${CLASSES_DIR}/HelloWorld.class" ]]; then
  echo "Error: javac did not produce HelloWorld.class" >&2
  exit 1
fi

# Package one jar per classifier from the SAME compiled classes. The
# classifier is purely a labelling distinction here (real cudf uses it to
# distinguish per-arch/per-cuda binaries); this synthetic build has no such
# variation so all classifier jars are byte-identical modulo classifier
# labelling in the filename.
IFS=',' read -ra CLASSIFIER_LIST <<< "${CLASSIFIERS}"
if [[ ${#CLASSIFIER_LIST[@]} -eq 0 ]]; then
  echo "Error: CLASSIFIERS resolved to an empty list" >&2
  exit 1
fi

FIRST_CLASSIFIER=""
for classifier in "${CLASSIFIER_LIST[@]}"; do
  if [[ -z ${classifier} ]]; then
    echo "Error: empty classifier entry in CLASSIFIERS='${CLASSIFIERS}'" >&2
    exit 1
  fi
  JAR_PATH="${DEST_DIR}/${ARTIFACT_ID}-${VERSION}-${classifier}.jar"
  echo "Packaging classifier jar: ${classifier}"
  jar --create --file "${JAR_PATH}" -C "${CLASSES_DIR}" .
  if [[ -z ${FIRST_CLASSIFIER} ]]; then
    FIRST_CLASSIFIER=${classifier}
  fi
done

# Seed the unclassified primary from the first classifier - mirrors
# assemble_maven_repo.sh's own precedent of copying cuda12 to the
# unclassified primary.
UNCLASSIFIED_JAR="${DEST_DIR}/${ARTIFACT_ID}-${VERSION}.jar"
cp -f "${DEST_DIR}/${ARTIFACT_ID}-${VERSION}-${FIRST_CLASSIFIER}.jar" "${UNCLASSIFIED_JAR}"

# Sources jar: just the .java file(s).
echo "Packaging sources jar"
SOURCES_JAR="${DEST_DIR}/${ARTIFACT_ID}-${VERSION}-sources.jar"
jar --create --file "${SOURCES_JAR}" -C "${SRC_DIR}" .

# Javadoc jar: real javadoc HTML for the same source file.
echo "Generating javadoc"
javadoc -d "${JAVADOC_DIR}" -quiet "${SOURCE_FILE}" > /dev/null

JAVADOC_JAR="${DEST_DIR}/${ARTIFACT_ID}-${VERSION}-javadoc.jar"
jar --create --file "${JAVADOC_JAR}" -C "${JAVADOC_DIR}" .

# Minimal, valid POM. groupId/artifactId/version come from env; packaging is
# jar. No dependencies. Consumers just care that Maven Central sees a
# well-formed POM.
POM_FILE="${DEST_DIR}/${ARTIFACT_ID}-${VERSION}.pom"
cat > "${POM_FILE}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>${GROUP_ID}</groupId>
  <artifactId>${ARTIFACT_ID}</artifactId>
  <version>${VERSION}</version>
  <packaging>jar</packaging>
  <name>${ARTIFACT_ID}</name>
  <description>Synthetic hello-world payload generated by generate_test_maven_repo.sh for maven-publish pipeline testing.</description>
  <url>https://github.com/rapidsai/shared-workflows</url>
  <licenses>
    <license>
      <name>Apache-2.0</name>
      <url>https://www.apache.org/licenses/LICENSE-2.0.txt</url>
    </license>
  </licenses>
  <developers>
    <developer>
      <name>RAPIDS test payload</name>
      <organization>NVIDIA</organization>
      <organizationUrl>https://rapids.ai</organizationUrl>
    </developer>
  </developers>
  <scm>
    <url>https://github.com/rapidsai/shared-workflows</url>
    <connection>scm:git:git://github.com/rapidsai/shared-workflows.git</connection>
    <developerConnection>scm:git:ssh://github.com:rapidsai/shared-workflows.git</developerConnection>
  </scm>
</project>
EOF

echo "Wrote synthetic Maven repo:"
ls -1 "${DEST_DIR}"

rm -rf "${SCRATCH}"
