#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Offline verification harness for the ci/maven-publish/*.sh scripts.
#
# Covers the negative-path and offline positive-path assertions from the
# unified maven-publish plan without requiring a live Artifactory, real
# Sonatype credentials, or a docker daemon. Live-service checks (real AQL
# query, real Publisher Portal round-trip) are covered by ref-pinning a
# WIP cudf PR against this workflow branch and by cudf's own CI once the
# integration lands - see the plan for the coverage matrix.
#
# Run with:
#   ci/maven-publish/tests/verify_scripts.sh
#
# Exits 0 on success, 1 on the first assertion failure.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  echo "  PASS: $*"
}
fail() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $*" >&2
}

# Run a script with the given args and env, capturing stdout+stderr and the
# exit code. Then assert:
#   - exit code matches EXPECTED_RC
#   - output contains EXPECTED_MSG (fixed string, case-sensitive)
assert_fails_with() {
  local desc=$1
  local expected_rc=$2
  local expected_msg=$3
  shift 3

  local out rc
  out=$("$@" 2>&1) && rc=0 || rc=$?

  if [[ ${rc} -ne ${expected_rc} ]]; then
    fail "${desc}: expected exit ${expected_rc}, got ${rc}"
    echo "----- output -----" >&2
    echo "${out}" >&2
    echo "-------------------" >&2
    return
  fi
  if [[ "${out}" != *"${expected_msg}"* ]]; then
    fail "${desc}: expected output to contain '${expected_msg}'"
    echo "----- output -----" >&2
    echo "${out}" >&2
    echo "-------------------" >&2
    return
  fi
  pass "${desc}"
}

# Same as assert_fails_with but for a shell-runnable expression via bash -c.
assert_fails_with_env() {
  local desc=$1
  local expected_rc=$2
  local expected_msg=$3
  local cmd=$4

  local out rc
  out=$(bash -c "${cmd}" 2>&1) && rc=0 || rc=$?

  if [[ ${rc} -ne ${expected_rc} ]]; then
    fail "${desc}: expected exit ${expected_rc}, got ${rc}"
    echo "----- output -----" >&2
    echo "${out}" >&2
    echo "-------------------" >&2
    return
  fi
  if [[ "${out}" != *"${expected_msg}"* ]]; then
    fail "${desc}: expected output to contain '${expected_msg}'"
    echo "----- output -----" >&2
    echo "${out}" >&2
    echo "-------------------" >&2
    return
  fi
  pass "${desc}"
}

echo "== 1. Bash syntax check on every script =="
for f in "${BASE_DIR}"/*.sh; do
  if bash -n "${f}"; then
    pass "syntax: $(basename "${f}")"
  else
    fail "syntax: $(basename "${f}")"
  fi
done

echo
echo "== 2. Every host script prints help via --help and exits 0 =="
for host in artifactory_upload maven_central_publish sonatype_snapshots_publish \
            generate_test_maven_repo test_maven_publish_local; do
  script="${BASE_DIR}/${host}.sh"
  if out=$("${script}" --help 2>&1) && [[ "${out}" == *"Usage:"* ]]; then
    pass "help: ${host}.sh --help"
  else
    fail "help: ${host}.sh --help (missing 'Usage:' or non-zero exit)"
    echo "${out}" >&2
  fi
done

echo
echo "== 3. Unknown flag rejection =="
for host in artifactory_upload maven_central_publish sonatype_snapshots_publish \
            generate_test_maven_repo test_maven_publish_local; do
  script="${BASE_DIR}/${host}.sh"
  assert_fails_with "unknown-flag: ${host}.sh --nonsense-flag" \
    1 "Unknown argument --nonsense-flag" \
    "${script}" --nonsense-flag
done

echo
echo "== 4. Required-flag omission is caught with 'is required' error =="
# artifactory_upload requires --input, --publication-type, --artifactory-url,
# --artifactory-repository.
assert_fails_with "artifactory_upload: missing --input" \
  1 "--input is required" \
  "${BASE_DIR}/artifactory_upload.sh" \
    --publication-type rc \
    --artifactory-url http://example \
    --artifactory-repository test-repo

# generate_test_maven_repo requires --output-dir and --group-id.
assert_fails_with "generate_test_maven_repo: missing --output-dir" \
  1 "--output-dir is required" \
  "${BASE_DIR}/generate_test_maven_repo.sh" --group-id io.github.myuser

assert_fails_with "generate_test_maven_repo: missing --group-id" \
  1 "--group-id is required" \
  "${BASE_DIR}/generate_test_maven_repo.sh" --output-dir /tmp/gen-missing-groupid

# maven_central_publish requires the full coordinates set.
assert_fails_with "maven_central_publish: missing --group-id" \
  1 "--group-id is required" \
  "${BASE_DIR}/maven_central_publish.sh" \
    --artifact-id cudf --version 26.08.0 --rc-number 1 \
    --artifactory-url http://example --artifactory-repository test

# sonatype_snapshots_publish requires the full coordinates set + nightly-date.
assert_fails_with "sonatype_snapshots_publish: missing --nightly-date" \
  1 "--nightly-date is required" \
  "${BASE_DIR}/sonatype_snapshots_publish.sh" \
    --group-id ai.rapids --artifact-id cudf --version 26.08.0-SNAPSHOT \
    --artifactory-url http://example --artifactory-repository test

# test_maven_publish_local requires --publication-type + artifactory info.
assert_fails_with "test_maven_publish_local: missing --publication-type" \
  1 "--publication-type is required" \
  "${BASE_DIR}/test_maven_publish_local.sh" \
    --artifactory-url http://example \
    --artifactory-repository test

echo
echo "== 5. --publication-type validation =="
assert_fails_with "artifactory_upload: invalid --publication-type" \
  1 "--publication-type must be 'rc' or 'nightly'" \
  "${BASE_DIR}/artifactory_upload.sh" \
    --input /tmp --publication-type bogus \
    --artifactory-url http://example --artifactory-repository test

echo
echo "== 6. Env-var assertions (fail-fast, no docker/network call) =="
# artifactory_upload.sh: with GPG_PRIVATE_KEY unset, must fail before docker
# with a clear named error. All the CLI flags are present so we're
# specifically testing the env-var check.
TMP_INPUT="$(mktemp -d)"
trap 'rm -rf "${TMP_INPUT}"' EXIT
mkdir -p "${TMP_INPUT}/ai/rapids/cudf/26.08.0"
touch "${TMP_INPUT}/ai/rapids/cudf/26.08.0/cudf-26.08.0.pom"

assert_fails_with_env "artifactory_upload: missing GPG_PRIVATE_KEY" \
  1 "GPG_PRIVATE_KEY must be set" \
  "unset GPG_PRIVATE_KEY; export GPG_PASSPHRASE=x ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t; \
   '${BASE_DIR}/artifactory_upload.sh' \
     --input '${TMP_INPUT}' --publication-type rc \
     --artifactory-url http://example --artifactory-repository test"

assert_fails_with_env "artifactory_upload: missing ARTIFACTORY_TOKEN" \
  1 "ARTIFACTORY_TOKEN must be set" \
  "export GPG_PRIVATE_KEY=x GPG_PASSPHRASE=x ARTIFACTORY_USERNAME=u; unset ARTIFACTORY_TOKEN; \
   '${BASE_DIR}/artifactory_upload.sh' \
     --input '${TMP_INPUT}' --publication-type rc \
     --artifactory-url http://example --artifactory-repository test"

# maven_central_publish.sh: no docker involved, but same env-var checks
# should fail-fast before any curl.
assert_fails_with_env "maven_central_publish: missing MAVEN_DEPLOY_TOKEN" \
  1 "MAVEN_DEPLOY_TOKEN must be set" \
  "export ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t MAVEN_DEPLOY_USERNAME=u; unset MAVEN_DEPLOY_TOKEN; \
   '${BASE_DIR}/maven_central_publish.sh' \
     --group-id ai.rapids --artifact-id cudf --version 26.08.0 --rc-number 1 \
     --artifactory-url http://example --artifactory-repository test"

# sonatype_snapshots_publish.sh: same fail-fast on missing env vars.
assert_fails_with_env "sonatype_snapshots_publish: missing MAVEN_DEPLOY_USERNAME" \
  1 "MAVEN_DEPLOY_USERNAME must be set" \
  "export ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t MAVEN_DEPLOY_TOKEN=t; unset MAVEN_DEPLOY_USERNAME; \
   '${BASE_DIR}/sonatype_snapshots_publish.sh' \
     --group-id ai.rapids --artifact-id cudf --version 26.08.0-SNAPSHOT \
     --nightly-date 2026-07-27 \
     --artifactory-url http://example --artifactory-repository test"

echo
echo "== 7. Format validation =="
# maven_central_publish: --rc-number must be a positive integer.
assert_fails_with_env "maven_central_publish: --rc-number 0 rejected" \
  1 "--rc-number must be a positive integer" \
  "export ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t MAVEN_DEPLOY_USERNAME=u MAVEN_DEPLOY_TOKEN=t; \
   '${BASE_DIR}/maven_central_publish.sh' \
     --group-id ai.rapids --artifact-id cudf --version 26.08.0 --rc-number 0 \
     --artifactory-url http://example --artifactory-repository test"

# maven_central_publish: -SNAPSHOT version rejected on rc branch.
assert_fails_with_env "maven_central_publish: -SNAPSHOT rejected" \
  1 "release-shaped version" \
  "export ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t MAVEN_DEPLOY_USERNAME=u MAVEN_DEPLOY_TOKEN=t; \
   '${BASE_DIR}/maven_central_publish.sh' \
     --group-id ai.rapids --artifact-id cudf --version 26.08.0-SNAPSHOT --rc-number 1 \
     --artifactory-url http://example --artifactory-repository test"

# sonatype_snapshots_publish: non-SNAPSHOT version rejected on nightly branch.
assert_fails_with_env "sonatype_snapshots_publish: non-SNAPSHOT rejected" \
  1 "-SNAPSHOT version" \
  "export ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t MAVEN_DEPLOY_USERNAME=u MAVEN_DEPLOY_TOKEN=t; \
   '${BASE_DIR}/sonatype_snapshots_publish.sh' \
     --group-id ai.rapids --artifact-id cudf --version 26.08.0 \
     --nightly-date 2026-07-27 \
     --artifactory-url http://example --artifactory-repository test"

# sonatype_snapshots_publish: bad nightly-date format rejected.
assert_fails_with_env "sonatype_snapshots_publish: bad --nightly-date rejected" \
  1 "YYYY-MM-DD" \
  "export ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t MAVEN_DEPLOY_USERNAME=u MAVEN_DEPLOY_TOKEN=t; \
   '${BASE_DIR}/sonatype_snapshots_publish.sh' \
     --group-id ai.rapids --artifact-id cudf --version 26.08.0-SNAPSHOT \
     --nightly-date 2026/07/27 \
     --artifactory-url http://example --artifactory-repository test"

echo
echo "== 8. generate_test_maven_repo argument validation =="
# Reject non-empty --output-dir.
NON_EMPTY_DIR="$(mktemp -d)"
touch "${NON_EMPTY_DIR}/stray-file"
assert_fails_with "generate_test_maven_repo: non-empty --output-dir rejected" \
  1 "must be empty or nonexistent" \
  "${BASE_DIR}/generate_test_maven_repo.sh" \
    --output-dir "${NON_EMPTY_DIR}" --group-id io.github.myuser
rm -rf "${NON_EMPTY_DIR}"

# Reject invalid --group-id.
assert_fails_with "generate_test_maven_repo: invalid --group-id rejected" \
  1 "--group-id must contain only" \
  "${BASE_DIR}/generate_test_maven_repo.sh" \
    --output-dir /tmp/gen-bad-groupid --group-id 'a b c'

# --version flag exists and is advertised in --help output.
if "${BASE_DIR}/generate_test_maven_repo.sh" --help 2>&1 | grep -qE -- '--version'; then
  pass "generate_test_maven_repo: --help advertises --version flag"
else
  fail "generate_test_maven_repo: --help output does not mention --version"
fi

# test_maven_publish_local.sh no longer inlines the SNAPSHOT rewrite - it
# now delegates to generate_test_maven_repo.sh --version 0.0.1-SNAPSHOT.
# Guard against regression of the dedupe.
if grep -qE 'hello-world-0\.0\.1-SNAPSHOT' "${BASE_DIR}/test_maven_publish_local.sh"; then
  fail "test_maven_publish_local.sh still contains inline SNAPSHOT rewrite (references hello-world-0.0.1-SNAPSHOT directly)"
else
  pass "test_maven_publish_local.sh: inline SNAPSHOT rewrite is gone"
fi

echo
echo "== 9. --input handling in test_maven_publish_local =="
# With --input pointing at a non-existent directory, we should fail-fast
# with a clear error.
assert_fails_with_env "test_maven_publish_local: --input to nonexistent dir rejected" \
  1 "does not exist" \
  "export ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t MAVEN_DEPLOY_USERNAME=u MAVEN_DEPLOY_TOKEN=t; \
   '${BASE_DIR}/test_maven_publish_local.sh' \
     --publication-type rc \
     --input /nonexistent/path/should/not/exist \
     --artifactory-url http://example \
     --artifactory-repository test"

# With --input supplied but GPG_PRIVATE_KEY missing, the wrapper must fail
# with a clear "must be set" error (rather than silently generating a
# throwaway key over a real payload).
REAL_INPUT="$(mktemp -d)"
mkdir -p "${REAL_INPUT}/ai/rapids/cudf/26.08.0"
touch "${REAL_INPUT}/ai/rapids/cudf/26.08.0/cudf-26.08.0.pom"
assert_fails_with_env "test_maven_publish_local: --input requires GPG_PRIVATE_KEY" \
  1 "GPG_PRIVATE_KEY must be set" \
  "export ARTIFACTORY_USERNAME=u ARTIFACTORY_TOKEN=t MAVEN_DEPLOY_USERNAME=u MAVEN_DEPLOY_TOKEN=t; unset GPG_PRIVATE_KEY; \
   '${BASE_DIR}/test_maven_publish_local.sh' \
     --publication-type rc \
     --input '${REAL_INPUT}' \
     --artifactory-url http://example \
     --artifactory-repository test"
rm -rf "${REAL_INPUT}"

echo
echo "== 10. maven-publish.yaml lint / structural checks =="
WORKFLOWS_DIR="${BASE_DIR}/../../.github/workflows"
YAML_FILE="${WORKFLOWS_DIR}/maven-publish.yaml"
SMOKE_YAML_FILE="${WORKFLOWS_DIR}/maven-publish-smoke-test.yaml"

check_yaml_contains() {
  local file=$1
  local pattern=$2
  local desc=$3
  if grep -qE "${pattern}" "${file}"; then
    pass "${desc}"
  else
    fail "${desc}: pattern '${pattern}' not found in ${file}"
  fi
}

check_yaml_lacks() {
  local file=$1
  local pattern=$2
  local desc=$3
  if grep -qE "${pattern}" "${file}"; then
    fail "${desc}: pattern '${pattern}' unexpectedly found in ${file}"
  else
    pass "${desc}"
  fi
}

# maven-publish.yaml: workflow_call, no container: field, rc/nightly branches.
check_yaml_contains "${YAML_FILE}" '^on:' \
  "maven-publish.yaml: has 'on:' block"
check_yaml_contains "${YAML_FILE}" 'workflow_call:' \
  "maven-publish.yaml: is a workflow_call reusable workflow"
check_yaml_lacks "${YAML_FILE}" '^\s{4,}container:\s*$' \
  "maven-publish.yaml: no 'container:' field on any job"
check_yaml_contains "${YAML_FILE}" "publication-type == 'rc'" \
  "maven-publish.yaml: rc-conditional step is present"
check_yaml_contains "${YAML_FILE}" "publication-type == 'nightly'" \
  "maven-publish.yaml: nightly-conditional step is present"
check_yaml_contains "${YAML_FILE}" 'artifactory_upload.sh' \
  "maven-publish.yaml: invokes artifactory_upload.sh"
check_yaml_contains "${YAML_FILE}" 'maven_central_publish.sh' \
  "maven-publish.yaml: invokes maven_central_publish.sh"
check_yaml_contains "${YAML_FILE}" 'sonatype_snapshots_publish.sh' \
  "maven-publish.yaml: invokes sonatype_snapshots_publish.sh"

# Self-checkout must NOT fall back to raw github.ref - that would resolve to
# the caller's ref (e.g. a cudf release tag) which doesn't exist in this
# repo. The fix parses github.workflow_ref via a helper step; guard against
# regressing back to the raw-fallback shape.
check_yaml_lacks "${YAML_FILE}" 'inputs\.shared-workflows-ref \|\| github\.ref' \
  "maven-publish.yaml: self-checkout no longer uses raw github.ref fallback"
check_yaml_contains "${YAML_FILE}" 'github\.workflow_ref' \
  "maven-publish.yaml: self-checkout derives ref from github.workflow_ref"

# The caller-facing publish-gate input must be the new positive-direction
# name (stage-for-maven-central-publish), not the old opaque auto-drop.
# Match against the input declaration line specifically (2 spaces of indent
# under `inputs:` puts us at 6 spaces).
check_yaml_contains "${YAML_FILE}" '^\s{6}stage-for-maven-central-publish:' \
  "maven-publish.yaml: declares 'stage-for-maven-central-publish' input"
check_yaml_lacks "${YAML_FILE}" '^\s{6}auto-drop:' \
  "maven-publish.yaml: old 'auto-drop' input declaration is gone"

echo
echo "== 11. Repo-wide workflow invariants =="
# Positive assertion: the smoke workflow is deleted and stays deleted. A
# future PR that resurrects it trips this guard and forces a rethink of
# the coverage-matrix trade-off documented in the plan.
if [[ -e "${SMOKE_YAML_FILE}" ]]; then
  fail "maven-publish-smoke-test.yaml exists at ${SMOKE_YAML_FILE} (was intentionally deleted)"
else
  pass "maven-publish-smoke-test.yaml does not exist (per plan)"
fi

# test_maven_publish_local.sh is a developer entry point only. Failing here
# preserves the local-dev-only invariant even if someone adds a new
# workflow that tries to short-circuit through the wrapper.
if grep -lE 'test_maven_publish_local\.sh' \
     "${WORKFLOWS_DIR}"/*.yaml 2>/dev/null \
   | while read -r wf; do
       # Strip YAML comments and re-check to allow "don't call this" prose
       # in comments without tripping the guard.
       if grep -vE '^\s*#' "${wf}" | grep -qE 'test_maven_publish_local\.sh'; then
         echo "${wf}"
       fi
     done | grep -q .; then
  fail "test_maven_publish_local.sh is referenced by a workflow file (local-dev-only script)"
else
  pass "no workflow file references test_maven_publish_local.sh"
fi

# ai.rapids is cudf-specific and must not be baked into a shared workflow
# file. Comments explaining the constraint are fine; actionable lines are
# not. Repo-wide since the smoke workflow (the previous scope) is gone.
OFFENDING_AI_RAPIDS=""
for wf in "${WORKFLOWS_DIR}"/*.yaml; do
  [[ -f ${wf} ]] || continue
  if grep -vE '^\s*#' "${wf}" | grep -qE 'ai\.rapids'; then
    OFFENDING_AI_RAPIDS+=" ${wf}"
  fi
done
if [[ -n ${OFFENDING_AI_RAPIDS} ]]; then
  fail "ai.rapids referenced on a non-comment line in:${OFFENDING_AI_RAPIDS}"
else
  pass "no workflow file references ai.rapids on a non-comment line"
fi

echo
echo "==================================================="
echo "PASSED: ${PASS}"
echo "FAILED: ${FAIL}"
echo "==================================================="

if [[ ${FAIL} -gt 0 ]]; then
  exit 1
fi
