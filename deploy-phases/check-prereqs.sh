#!/bin/bash

# FotoArca FormKIQ Backend - Phase 1: Prerequisites Check
# Validates tools (Java 17, Gradle, SAM, AWS CLI), credentials, and environment config

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common.sh"

print_message "=== FotoArca Backend Prerequisites Check ===" "$BLUE"

# Load environment variables (tolerate missing .env — may be using system env)
load_env_vars || true

# Check required environment variables
if ! check_env_vars; then
    exit 1
fi

# Display configuration
show_config

# ─── Tool Checks ──────────────────────────────────────────────────────────────

# Java — must be version 17
print_message "Checking Java..." "$YELLOW"
if ! command -v java &> /dev/null; then
    print_message "Error: Java is not installed" "$RED"
    print_message "Please install Java 17 (Temurin): https://adoptium.net/" "$RED"
    exit 1
fi
JAVA_VERSION_RAW=$(java -version 2>&1 | head -1)
JAVA_MAJOR=$(java -version 2>&1 | head -1 | cut -d '"' -f2 | cut -d '.' -f1)
if [ "$JAVA_MAJOR" != "17" ]; then
    print_message "Error: Java 17 is required, found: $JAVA_VERSION_RAW" "$RED"
    print_message "Please install Java 17 (Temurin): https://adoptium.net/" "$RED"
    exit 1
fi
print_message "✓ Java 17 is installed: $JAVA_VERSION_RAW" "$GREEN"

# Gradle wrapper
print_message "Checking Gradle wrapper..." "$YELLOW"
if ! find_backend_root; then
    print_message "Error: Could not find backend root directory" "$RED"
    exit 1
fi
if [ ! -f "$BACKEND_ROOT/gradlew" ]; then
    print_message "Error: gradlew not found at $BACKEND_ROOT/gradlew" "$RED"
    exit 1
fi
GRADLE_VERSION=$(cd "$BACKEND_ROOT" && ./gradlew --version 2>/dev/null | grep "^Gradle" | head -1 || echo "Gradle (version unknown)")
print_message "✓ Gradle wrapper is available: $GRADLE_VERSION" "$GREEN"

# SAM CLI
print_message "Checking SAM CLI..." "$YELLOW"
if ! command -v sam &> /dev/null; then
    print_message "Error: AWS SAM CLI is not installed" "$RED"
    print_message "Install guide: https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html" "$RED"
    exit 1
fi
SAM_VERSION=$(sam --version 2>&1 | head -1)
print_message "✓ SAM CLI is installed: $SAM_VERSION" "$GREEN"

# AWS CLI
print_message "Checking AWS CLI..." "$YELLOW"
if ! command -v aws &> /dev/null; then
    print_message "Error: AWS CLI is not installed" "$RED"
    print_message "Please install: https://aws.amazon.com/cli/" "$RED"
    exit 1
fi
AWS_VERSION=$(aws --version 2>&1 | head -1)
print_message "✓ AWS CLI is installed: $AWS_VERSION" "$GREEN"

# ytt (YAML templating tool used by Gradle build)
print_message "Checking ytt (YAML templating tool)..." "$YELLOW"
if ! command -v ytt &> /dev/null; then
    print_message "Error: ytt is not installed" "$RED"
    print_message "Install with: brew tap vmware-tanzu/carvel && brew install ytt" "$RED"
    exit 1
fi
YTT_VERSION=$(ytt --version 2>&1 | head -1)
print_message "✓ ytt is installed: $YTT_VERSION" "$GREEN"

# ─── AWS Credentials ──────────────────────────────────────────────────────────

print_message "\nChecking AWS credentials for 'fotoarca' profile..." "$YELLOW"
if ! AWS_PROFILE=fotoarca aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
    print_message "Error: Unable to authenticate with AWS using 'fotoarca' profile" "$RED"
    print_message "Please configure your AWS credentials:" "$RED"
    echo "  aws configure --profile fotoarca"
    exit 1
fi
CALLER_ACCOUNT=$(AWS_PROFILE=fotoarca aws sts get-caller-identity \
    --region "$AWS_REGION" \
    --query 'Account' \
    --output text)
print_message "✓ AWS credentials configured (Account: $CALLER_ACCOUNT)" "$GREEN"

# ─── SAM Artifact Bucket ──────────────────────────────────────────────────────

print_message "\nChecking SAM artifact bucket: $SAM_ARTIFACT_BUCKET..." "$YELLOW"
if AWS_PROFILE=fotoarca aws s3api head-bucket \
    --bucket "$SAM_ARTIFACT_BUCKET" \
    --region "$AWS_REGION" &> /dev/null; then
    print_message "✓ SAM artifact bucket exists" "$GREEN"
else
    print_message "Error: SAM artifact bucket not found: $SAM_ARTIFACT_BUCKET" "$RED"
    print_message "Create it with:" "$RED"
    echo "  AWS_PROFILE=fotoarca aws s3 mb s3://$SAM_ARTIFACT_BUCKET --region $AWS_REGION"
    exit 1
fi

print_message "\n========================================" "$GREEN"
print_message "✓ All prerequisites check passed!" "$GREEN"
print_message "========================================" "$GREEN"
print_message "\nYou can proceed with deployment using:" "$GREEN"
echo "  ./scripts/deploy-fotoarca.sh               # Full deployment"
echo "  ./scripts/deploy-fotoarca.sh --skip-build  # Deploy without rebuilding"
