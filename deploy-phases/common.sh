#!/bin/bash

# Common functions and variables for FotoArca backend deployment scripts

set -euo pipefail

# Colors for output
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# Function to print colored messages
print_message() {
    echo -e "${2}${1}${NC}"
}

# Function to find the backend root directory (contains build.gradle + gradlew)
find_backend_root() {
    local current_dir="${1:-$(pwd)}"
    local root_dir=""

    while [ "$current_dir" != "/" ]; do
        if [ -f "$current_dir/build.gradle" ] && [ -f "$current_dir/gradlew" ]; then
            root_dir="$current_dir"
            break
        fi
        current_dir="$(dirname "$current_dir")"
    done

    if [ -z "$root_dir" ]; then
        # Fallback: calculate from script location
        local script_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" 2>/dev/null && pwd )"
        if [ -n "$script_dir" ]; then
            root_dir="$(cd "$script_dir/../.." 2>/dev/null && pwd)"
        fi
    fi

    if [ -z "$root_dir" ] || [ ! -d "$root_dir" ]; then
        print_message "Error: Could not find backend root directory" "$RED"
        print_message "Please run this script from the formkiq-backend directory or a subdirectory" "$RED"
        return 1
    fi

    export BACKEND_ROOT="$root_dir"
    return 0
}

# Function to load environment variables from .env
load_env_vars() {
    if ! find_backend_root; then
        return 1
    fi

    local env_file="$BACKEND_ROOT/.env"

    if [ -f "$env_file" ]; then
        print_message "Loading environment variables from .env file..." "$YELLOW"
        set -a  # Mark all subsequently defined variables for export
        source "$env_file"
        set +a
        return 0
    else
        print_message "Warning: .env file not found at $env_file" "$YELLOW"
        print_message "Using system environment variables." "$YELLOW"
        return 1
    fi
}

# Function to check required environment variables
check_env_vars() {
    local missing_vars=0

    for var in AWS_REGION SAM_ARTIFACT_BUCKET STACK_NAME ADMIN_EMAIL APP_ENVIRONMENT; do
        if [ -z "${!var:-}" ]; then
            print_message "Error: $var environment variable is not set" "$RED"
            missing_vars=1
        fi
    done

    if [ $missing_vars -eq 1 ]; then
        print_message "Please set the missing variables in your .env file" "$RED"
        print_message "See .env.example for reference" "$RED"
        return 1
    fi

    return 0
}

# Function to display deployment configuration
show_config() {
    print_message "\nDeployment Configuration:" "$GREEN"
    echo "  AWS Region:          ${AWS_REGION:-<not set>}"
    echo "  SAM Artifact Bucket: ${SAM_ARTIFACT_BUCKET:-<not set>}"
    echo "  Stack Name:          ${STACK_NAME:-<not set>}"
    echo "  Admin Email:         ${ADMIN_EMAIL:-<not set>}"
    echo "  App Environment:     ${APP_ENVIRONMENT:-<not set>}"
    echo "  AWS Profile:         fotoarca"
    if [ -n "${EXTRA_PARAMETERS:-}" ]; then
        echo "  Extra Parameters:    $EXTRA_PARAMETERS"
    fi
    echo ""
}

# Function to find the built distribution zip
# Sets DIST_ZIP on success
find_dist_zip() {
    if ! find_backend_root 2>/dev/null; then
        return 1
    fi

    local dist_dir="$BACKEND_ROOT/build/distributions"

    if [ ! -d "$dist_dir" ]; then
        print_message "Error: Distribution directory not found: $dist_dir" "$RED"
        print_message "Please run the build phase first." "$RED"
        return 1
    fi

    # Collect matching zip files into an array
    local zip_files=()
    while IFS= read -r -d '' f; do
        zip_files+=("$f")
    done < <(find "$dist_dir" -maxdepth 1 -name "formkiq-core-*.zip" -print0 2>/dev/null)

    if [ ${#zip_files[@]} -eq 0 ]; then
        print_message "Error: No distribution zip found in $dist_dir" "$RED"
        print_message "Expected: formkiq-core-*.zip" "$RED"
        print_message "Please run the build phase first." "$RED"
        return 1
    fi

    if [ ${#zip_files[@]} -gt 1 ]; then
        print_message "Warning: Multiple distribution zips found; using the most recent" "$YELLOW"
        # Sort by modification time (newest first), take first
        DIST_ZIP=$(ls -t "${zip_files[@]}" | head -1)
    else
        DIST_ZIP="${zip_files[0]}"
    fi

    export DIST_ZIP
    return 0
}

# Export functions so subshells can use them
export -f print_message
export -f find_backend_root
export -f load_env_vars
export -f check_env_vars
export -f show_config
export -f find_dist_zip
