#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Common Functions for CI Gateway API Scripts
# -----------------------------------------------------------------------------

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Check if a command exists
check_command() {
    if ! command -v "$1" &>/dev/null; then
        error "$1 is required but not installed."
    fi
}

# Load environment variables from .env file
load_env() {
    local env_file="$1"
    if [[ -f "${env_file}" ]]; then
        # shellcheck source=/dev/null
        source "${env_file}"
        log "Loaded environment from ${env_file}"
    else
        error "No .env file found at ${env_file}. Please create one based on .env-template."
    fi
}

# Validate required environment variables
validate_vars() {
    local missing=()
    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("${var}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "The following required variables are not set: ${missing[*]}"
    fi
}
