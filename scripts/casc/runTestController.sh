#! /bin/bash

set -euo pipefail

# Default values
_CI_VERSION="latest"
_CI_TYPE="mm"
_JH_PATH_SUFFIX="jenkins_home-controller-base"
_CASC_BUNDLE_PATH_SUFFIX="controller-base"
_DOCKER_PORT_MAPPING="9080:8080"
_CONTAINER_NAME=""

# Help message
usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  -v, --version VERSION   Set the CloudBees CI version (default: ${_CI_VERSION})
  -t, --type TYPE         Set the CloudBees CI type (default: ${_CI_TYPE})
  -j, --jenkins-home PATH Set the Jenkins home directory (default: PWD/${_JH_PATH_SUFFIX})
  -c, --casc-bundle PATH  Set the CasC bundle path (default: PWD/${_CASC_BUNDLE_PATH_SUFFIX})
  -p, --port PORT_MAPPING Set the Docker port mapping (default: ${_DOCKER_PORT_MAPPING})
  -n, --name NAME         Set the Docker container name (default: docker generated)
  -h, --help              Display this help message
EOF
}

# Parse arguments
while [[ "$#" -gt 0 ]]; do
  case $1 in
    -v|--version) _CI_VERSION="$2"; shift ;;
    -t|--type) _CI_TYPE="$2"; shift ;;
    -j|--jenkins-home) _JH_PATH="$2"; shift ;;
    -c|--casc-bundle) _CASC_BUNDLE_PATH="$2"; shift ;;
    -p|--port) _DOCKER_PORT_MAPPING="$2"; shift ;;
    -n|--name) _CONTAINER_NAME="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown parameter passed: $1"; usage; exit 1 ;;
  esac
  shift
done

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
  echo "Docker does not seem to be running, please start it and try again."
  exit 1
fi

# Set paths if not provided via arguments
_JH_PATH=${_JH_PATH:-"$(pwd)/${_JH_PATH_SUFFIX}"}
_CASC_BUNDLE_PATH=${_CASC_BUNDLE_PATH:-"$(pwd)/${_CASC_BUNDLE_PATH_SUFFIX}"}

# Create Jenkins home directory
mkdir -p "${_JH_PATH}"
chmod 775 "${_JH_PATH}"

# Docker treats a relative volume source as a volume name, so resolve both paths to absolute ones
if [[ ! -d "${_CASC_BUNDLE_PATH}" ]]; then
  echo "CasC bundle directory not found: ${_CASC_BUNDLE_PATH}" >&2
  exit 1
fi
_JH_PATH="$(cd "${_JH_PATH}" && pwd)"
_CASC_BUNDLE_PATH="$(cd "${_CASC_BUNDLE_PATH}" && pwd)"

# Cleanup function
cleanup() {
  echo "Cleaning up..."
  # Add cleanup commands here if needed
}

# Trap to call cleanup function on exit
trap cleanup EXIT

# Run Docker container
echo "Starting CloudBees CI..."
#-Dcore.casc.config.bundle=/tmp/casc-bundle
docker run \
  -e JENKINS_OPTS="--accessLoggerClassName=winstone.accesslog.SimpleAccessLogger --simpleAccessLogger.format=combined --simpleAccessLogger.file=/var/jenkins_home/access.log" \
  -e JAVA_OPTS="-Dhudson.model.DownloadService.noSignatureCheck=true  -Dcom.cloudbees.jenkins.ha=false -Dcore.casc.config.bundle=/tmp/casc-bundle" \
  --rm \
  ${_CONTAINER_NAME:+--name "${_CONTAINER_NAME}"} \
  -p "${_DOCKER_PORT_MAPPING}" \
  -v "${_JH_PATH}:/var/jenkins_home" \
  -v "${_CASC_BUNDLE_PATH}:/tmp/casc-bundle" \
  "cloudbees/cloudbees-core-${_CI_TYPE}:${_CI_VERSION}" | tee tmp.log