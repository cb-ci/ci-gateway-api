#! /bin/bash

# Definitipons: 
# Source controller: the old jcasc-controller Jenkins OSS with jcasc plugin ninstalled (controller1)
# Target controller: the new casc-controller CloudBees CI 
#  Goal: we want to create a cloudBees CasC bundle that contains a jenkins.yml taken from the soruce controller, a plugins.yaml taken from the plugin export of the source controller, and put it all together in a bundle.yaml that can be applied to the target controller. 
# Iplementation plan:
# 0. create local tmp working directory for this migration.
# 1. run curl to download jenkins yaml from source controller
# 2. run a curl script on controller1 to export plugins see https://raw.githubusercontent.com/cb-ci/ci-groovy/refs/heads/main/plugins-listInstalledPluginsAsPluginYAML.groovy?token=GHSAT0AAAAAAEMP4WWSLJBFTF5TUDK2TCKK2XBXCEQ
# 3. transform plugin export file into a valid plugin.yaml
# 4. correct yaml indent in jenkins.yaml and plugin.yaml using the scripts in the scripts/casc/scripts/ directory
# 5. clean jenkins.yaml to remove unwanted sections using the scripts in the scripts/casc/scripts/ directory
# 6. create bundle.yaml by adding the plugin.yaml to the jenkins.yaml https://docs.cloudbees.com/docs/cloudbees-ci/latest/casc-create-bundle/
# 7. update the bundle.yaml to api version 2 as per: https://docs.cloudbees.com/docs/cloudbees-ci/latest/casc-create-bundle/#-update-bundle-to-use-api-version-2
# 8. validate bundle.yaml using curl to https://raw.githubusercontent.com/jenkinsci/configuration-as-code-plugin/master/plugin/src/main/resources/io/jenkins/plugins/casc/src/main/resources/org/jenkinsci/plugins/casc/impl/jenkins.yaml
# 9. apply bundle.yaml to target controller using the CloudBees CLI or Jenkins web UI

set -euo pipefail

# Configuration (from .env or environment variables, nothing is hardcoded):
#   SRC_URL, SRC_USER, SRC_TOKEN   source controller (Jenkins OSS + JCasC), user + API token
#   TGT_URL, TGT_USER, TGT_TOKEN   target controller (CloudBees CI), used for validation only (optional)
#   KEEP_TEST_CONTROLLER           keep the test controller running after the script (default: false, see --keep-controller)
#   START_TEST_CONTROLLER          start a local test controller (runTestController.sh) when TGT_URL is empty (default: true)
#   TEST_CI_VERSION, TEST_CI_TYPE, TEST_JENKINS_HOME, TEST_PORT, TEST_STARTUP_TIMEOUT   test controller settings (default: latest, mm, 9080, 300)
#   BUNDLE_ID                      bundle id (default: casc-controller)
#   WORK_DIR                       work dir (default: ${TMPDIR:-/tmp}/casc-migration-workdir); wiped at the start of each run, kept after it
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPERS_DIR="${SCRIPT_DIR}/scripts"

# Load configuration from .env (see .env.template); values set in .env override the environment
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  set -a; source "${SCRIPT_DIR}/.env"; set +a
fi
BUNDLE_ID="${BUNDLE_ID:-casc-controller}"
START_TEST_CONTROLLER="${START_TEST_CONTROLLER:-true}"
TEST_CI_VERSION="${TEST_CI_VERSION:-latest}"
TEST_CI_TYPE="${TEST_CI_TYPE:-mm}"
TEST_PORT="${TEST_PORT:-9080}"
TEST_CONTAINER_NAME="${TEST_CONTAINER_NAME:-casc-migration-test}"
TEST_STARTUP_TIMEOUT="${TEST_STARTUP_TIMEOUT:-300}"
KEEP_TEST_CONTROLLER="${KEEP_TEST_CONTROLLER:-false}"
ASSUME_YES=false

usage() {
  cat <<USAGE
Usage: $0 [options]

Options:
  --keep-controller   leave the test controller running after the script (default: stop it).
                      Same as KEEP_TEST_CONTROLLER=true in .env, the flag wins.
  -y, --yes           do not ask before stopping an already running test controller and
                      deleting its Jenkins home (required when there is no terminal)
  -h, --help          show this help
USAGE
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --keep-controller) KEEP_TEST_CONTROLLER=true ;;
    -y|--yes) ASSUME_YES=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown parameter: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

: "${SRC_URL:?set SRC_URL, e.g. https://jenkins.example.com/jcasc-controller}"
: "${SRC_USER:?set SRC_USER}"
: "${SRC_TOKEN:?set SRC_TOKEN (Jenkins API token)}"
SRC_URL="${SRC_URL%/}"
TGT_URL="${TGT_URL:-}"; TGT_URL="${TGT_URL%/}"

for tool in curl yq zip; do
  command -v "$tool" >/dev/null || { echo "❌ missing tool: $tool" >&2; exit 1; }
done

# curl with credentials passed via a config on stdin so the token never shows up in the process list
curl_auth() { # user token curl-args...
  local user="$1" token="$2"; shift 2
  curl -sS --fail-with-body --config <(printf 'user = "%s:%s"\n' "$user" "$token") "$@"
}

# 0. local tmp working directory, wiped before each run
WORK_DIR="${WORK_DIR:-${TMPDIR:-/tmp}/casc-migration-workdir}"
WORK_DIR="${WORK_DIR%/}"
WORK_MARKER=".casc-migration-workdir"
case "$WORK_DIR" in
  ""|"/"|"$HOME"|"$SCRIPT_DIR"|"$PWD") echo "❌ refusing to use WORK_DIR='$WORK_DIR'" >&2; exit 1 ;;
esac
# A test controller from a previous run (e.g. started with --keep-controller) holds the old jenkins_home.
# Ask before stopping it and deleting that home, so the new run starts fresh.
if [[ -z "$TGT_URL" && "$START_TEST_CONTROLLER" == "true" ]] \
   && command -v docker >/dev/null && docker info >/dev/null 2>&1 \
   && [[ -n "$(docker ps -q --filter "name=^${TEST_CONTAINER_NAME}$")" ]]; then
  OLD_HOME="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/jenkins_home"}}{{.Source}}{{end}}{{end}}' "$TEST_CONTAINER_NAME" 2>/dev/null || true)"
  echo "⚠️  Test controller '${TEST_CONTAINER_NAME}' is already running (Jenkins home: ${OLD_HOME:-unknown})."
  if [[ "$ASSUME_YES" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      echo "❌ no terminal to ask, re-run with --yes to stop it and delete its Jenkins home" >&2
      exit 1
    fi
    read -r -p "Stop it and delete its Jenkins home for a fresh start? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Aborted, nothing changed."; exit 1; }
  fi
  docker stop "$TEST_CONTAINER_NAME" >/dev/null
  # only delete a home this script manages: below WORK_DIR or the configured TEST_JENKINS_HOME
  if [[ -n "$OLD_HOME" && "$OLD_HOME" != "/" && "$OLD_HOME" != "$HOME" && -d "$OLD_HOME" \
        && ( "$OLD_HOME" == "$WORK_DIR"/* || "$OLD_HOME" == "${TEST_JENKINS_HOME:-}" ) ]]; then
    echo "🧹 Deleting old Jenkins home $OLD_HOME"
    rm -rf -- "$OLD_HOME" || echo "⚠️  could not fully delete $OLD_HOME, remove it manually" >&2
  elif [[ -n "$OLD_HOME" ]]; then
    echo "⚠️  Jenkins home $OLD_HOME is outside WORK_DIR/TEST_JENKINS_HOME, not deleting it" >&2
  fi
fi
if [[ -d "$WORK_DIR" ]]; then
  # only delete a dir this script created (marker file) or an empty one
  if [[ ! -f "${WORK_DIR}/${WORK_MARKER}" && -n "$(ls -A "$WORK_DIR")" ]]; then
    echo "❌ $WORK_DIR exists, is not empty and was not created by this script, not deleting it" >&2
    exit 1
  fi
  echo "🧹 Cleaning $WORK_DIR"
  rm -rf -- "$WORK_DIR"
fi
BUNDLE_DIR="${WORK_DIR}/bundle"
mkdir -p "$BUNDLE_DIR" "${WORK_DIR}/helpers"
touch "${WORK_DIR}/${WORK_MARKER}"
echo "📁 Work dir: $WORK_DIR"

# The helper scripts source their own .env and edit files in place under CASC_BUNDLES_PATH.
# Run copies of them against the work dir so the repo's scripts/.env is not touched.
cp "${HELPERS_DIR}"/00-indent2Yaml.sh "${HELPERS_DIR}"/01-jenkinsYamlClean.sh \
   "${HELPERS_DIR}"/02-pluginsRemoveSuspended.sh "${WORK_DIR}/helpers/"
cp "${SCRIPT_DIR}/transform.yaml" "${WORK_DIR}/"
cat > "${WORK_DIR}/helpers/.env" <<ENV
CASC_BUNDLES_PATH=${BUNDLE_DIR}
BASE_PATH=${BUNDLE_DIR}
TRANSFORM_FILE=${WORK_DIR}/transform.yaml
JENKINS_YAML=jenkins.yaml
PLUGINS_YAML=plugins.yaml
ENV

# 1. download jenkins.yaml from the source controller (JCasC export)
echo "⬇️  Exporting jenkins.yaml from $SRC_URL"
curl_auth "$SRC_USER" "$SRC_TOKEN" -X POST "${SRC_URL}/configuration-as-code/export" -o "${BUNDLE_DIR}/jenkins.yaml"

# 2. run the plugin export groovy script on the source controller (script console)
echo "⬇️  Exporting plugin list from $SRC_URL"
GROOVY_FILE="${WORK_DIR}/plugins-export.groovy"
# Inline groovy: prints one "- id: <shortName>" line per installed plugin
cat > "$GROOVY_FILE" <<'GROOVY'
import jenkins.model.Jenkins

Jenkins.instance.pluginManager.plugins
  .collect { it.shortName }
  .sort()
  .each { println "- id: ${it}" }
GROOVY
curl_auth "$SRC_USER" "$SRC_TOKEN" -X POST "${SRC_URL}/scriptText" \
  --data-urlencode "script@${GROOVY_FILE}" -o "${WORK_DIR}/plugins-export.txt"

# 3. transform the export into a valid plugins.yaml
#    Accepts either "- id: foo" lines or plain plugin ids, one per line (anything else is ignored).
IDS_FILE="${WORK_DIR}/plugin-ids.txt"
sed -nE 's/^[[:space:]]*-[[:space:]]*id:[[:space:]]*"?([A-Za-z0-9._-]+)"?[[:space:]]*$/\1/p' \
  "${WORK_DIR}/plugins-export.txt" | sort -u > "$IDS_FILE"
if [[ ! -s "$IDS_FILE" ]]; then
  { grep -E '^[A-Za-z0-9._-]+$' "${WORK_DIR}/plugins-export.txt" || true; } | sort -u > "$IDS_FILE"
fi
[[ -s "$IDS_FILE" ]] || { echo "❌ no plugins found in export, see ${WORK_DIR}/plugins-export.txt" >&2; exit 1; }
{
  echo "plugins:"
  while IFS= read -r id; do echo "- id: ${id}"; done < "$IDS_FILE"
} > "${BUNDLE_DIR}/plugins.yaml"
echo "🔌 $(wc -l < "$IDS_FILE" | tr -d ' ') plugins exported"

# 4./5. fix indent, clean jenkins.yaml, drop suspended plugins (run from the helpers dir: transform path is relative)
(
  cd "${WORK_DIR}/helpers"
  ./00-indent2Yaml.sh
  ./01-jenkinsYamlClean.sh
  ./02-pluginsRemoveSuspended.sh
)

# 6./7. bundle.yaml, written directly as apiVersion 2
cat > "${BUNDLE_DIR}/bundle.yaml" <<YAML
apiVersion: "2"
id: "${BUNDLE_ID}"
description: "Migrated from ${SRC_URL##*/} (JCasC)"
version: "1"
jcasc:
  - "jenkins.yaml"
plugins:
  - "plugins.yaml"
YAML

# 8. validate: local syntax check, then the target's CasC bundle validation API (if TGT_* is set)
for f in bundle.yaml jenkins.yaml plugins.yaml; do
  yq e '.' "${BUNDLE_DIR}/${f}" >/dev/null || { echo "❌ invalid YAML: $f" >&2; exit 1; }
done
(cd "$BUNDLE_DIR" && zip -q -FS ../bundle.zip bundle.yaml jenkins.yaml plugins.yaml)
# Start a throwaway CloudBees CI controller via runTestController.sh when no TGT_URL is configured.
# The generated bundle is mounted into it, so the controller loads it on startup.
TEST_CONTAINER=""
stop_test_controller() {
  [[ -n "$TEST_CONTAINER" ]] || return 0
  if [[ "$KEEP_TEST_CONTROLLER" == "true" ]]; then
    echo "▶️  Test controller kept running: ${TGT_URL} (container ${TEST_CONTAINER_NAME}, user admin, see ${WORK_DIR}/patches/jenkins_securityrealm.yaml)"
    echo "   stop it with: docker stop ${TEST_CONTAINER_NAME}"
  else
    echo "🛑 Stopping test controller"
    docker stop "$TEST_CONTAINER" >/dev/null 2>&1 || true
  fi
}
trap stop_test_controller EXIT

TEST_LOG=""
if [[ -z "$TGT_URL" && "$START_TEST_CONTROLLER" == "true" ]]; then
  command -v docker >/dev/null || { echo "❌ missing tool: docker" >&2; exit 1; }
  TEST_DIR="${WORK_DIR}/test-controller"
  TEST_LOG="${TEST_DIR}/tmp.log"   # runTestController.sh tees the controller log to ./tmp.log
  mkdir -p "$TEST_DIR"
  TEST_JENKINS_HOME="${TEST_JENKINS_HOME:-${TEST_DIR}/jenkins_home}"
  # The test controller has no Operations Center, so validate an OC-free copy of the bundle:
  # local security realm with a random admin password, no RBAC strategy. The real bundle stays untouched.
  command -v openssl >/dev/null || { echo "❌ missing tool: openssl" >&2; exit 1; }
  TEST_BUNDLE_DIR="${WORK_DIR}/test-bundle"
  mkdir -p "$TEST_BUNDLE_DIR" "${WORK_DIR}/test-helpers" "${WORK_DIR}/patches"
  cp -R "${BUNDLE_DIR}/." "$TEST_BUNDLE_DIR/"
  cp "${HELPERS_DIR}/001-jenkinsYamlDisableOC.sh" "${WORK_DIR}/test-helpers/"
  cp "${SCRIPT_DIR}/patches/jenkins_securityrealm.yaml" "${WORK_DIR}/patches/"
  export TEST_ADMIN_PASSWORD="$(openssl rand -hex 12)"
  # drop the user "properties" of the shared patch: newer controllers reject some of them (e.g. apiToken)
#   yq -i '.local.users[0].password = strenv(TEST_ADMIN_PASSWORD) | del(.local.users[0].properties)' \
#     "${WORK_DIR}/patches/jenkins_securityrealm.yaml"
  cat > "${WORK_DIR}/test-helpers/.env" <<ENV
CASC_BUNDLES_PATH=${TEST_BUNDLE_DIR}
JENKINS_YAML=jenkins.yaml
PLUGINS_YAML=plugins.yaml
ENV
  (cd "${WORK_DIR}/test-helpers" && ./001-jenkinsYamlDisableOC.sh)
  (cd "$TEST_BUNDLE_DIR" && zip -q -FS ../test-bundle.zip bundle.yaml jenkins.yaml plugins.yaml)
  echo "🚀 Starting test controller (cloudbees-core-${TEST_CI_TYPE}:${TEST_CI_VERSION}) on port ${TEST_PORT}"
  (cd "$TEST_DIR" && "${SCRIPT_DIR}/runTestController.sh" \
      -v "$TEST_CI_VERSION" -t "$TEST_CI_TYPE" \
      -j "$TEST_JENKINS_HOME" -c "$TEST_BUNDLE_DIR" -p "127.0.0.1:${TEST_PORT}:8080" \
      -n "$TEST_CONTAINER_NAME" > run.log 2>&1) &
  LAUNCH_PID=$!
  TGT_URL="http://localhost:${TEST_PORT}"

  # wait until the named container exists (runTestController.sh runs docker in the foreground)
  for _ in $(seq 1 60); do
    TEST_CONTAINER="$(docker ps -q --filter "name=^${TEST_CONTAINER_NAME}$")"
    [[ -n "$TEST_CONTAINER" ]] && break
    if ! kill -0 "$LAUNCH_PID" 2>/dev/null; then   # launcher exited before the container showed up
      echo "❌ runTestController.sh exited early:" >&2; tail -n 20 "${TEST_DIR}/run.log" >&2; exit 1
    fi
    sleep 2
  done
  [[ -n "$TEST_CONTAINER" ]] || { echo "❌ test controller did not start, see ${TEST_DIR}/run.log" >&2; exit 1; }

  echo "⏳ Waiting for ${TGT_URL} (max ${TEST_STARTUP_TIMEOUT}s)"
  up=false
  for _ in $(seq 1 $((TEST_STARTUP_TIMEOUT / 5))); do
    code="$(curl -s -o /dev/null -w '%{http_code}' "${TGT_URL}/login" || true)"
    if [[ "$code" == "200" || "$code" == "401" || "$code" == "403" ]]; then up=true; break; fi
    sleep 5
  done
  $up || { echo "❌ test controller not ready, see ${TEST_LOG}" >&2; exit 1; }

  # use the local admin of the OC-free test bundle unless target credentials are configured
  if [[ -z "${TGT_USER:-}" ]]; then
    TGT_USER="admin"; TGT_TOKEN="$TEST_ADMIN_PASSWORD"
  fi
  # a bundle that fails to load is reported in the controller log
  if grep -qiE 'SEVERE.*(casc|configuration-as-code|bundle)|Failed to (load|apply).*bundle' "$TEST_LOG"; then
    echo "❌ bundle errors in controller log: ${TEST_LOG}" >&2
    grep -iE 'SEVERE.*(casc|configuration-as-code|bundle)|Failed to (load|apply).*bundle' "$TEST_LOG" | head -20 >&2
    exit 1
  fi
fi


# VALIDATE_ZIP="${WORK_DIR}/bundle.zip"
# [[ -n "$TEST_CONTAINER" ]] && VALIDATE_ZIP="${WORK_DIR}/test-bundle.zip"
# if [[ -n "$TGT_URL" && -n "${TGT_USER:-}" && -n "${TGT_TOKEN:-}" ]]; then
#   echo "🔎 Validating bundle on $TGT_URL"
#   curl_auth "$TGT_USER" "$TGT_TOKEN" -X POST -H "Content-Type: application/zip" \
#     --data-binary "@${VALIDATE_ZIP}" "${TGT_URL}/casc-bundle-mgnt/casc-bundle-validate" \
#     | tee "${WORK_DIR}/validation.json"
#   echo
#   if command -v jq >/dev/null && jq -e '.valid == false' "${WORK_DIR}/validation.json" >/dev/null 2>&1; then
#     echo "❌ bundle validation failed, see ${WORK_DIR}/validation.json" >&2
#     exit 1
#   fi
# else
#   echo "⚠️  no target credentials available, skipped remote validation"
# fi

# 9. apply: intentionally not automated
cat <<MSG

✅ Bundle ready: ${BUNDLE_DIR}  (zip: ${WORK_DIR}/bundle.zip)
Review jenkins.yaml (secrets, removed sections), then apply it yourself:
  - copy ${BUNDLE_DIR} into the CasC bundle location of the target controller (e.g. the OC bundle repo), or
  - upload it through the CloudBees CI UI.
MSG
