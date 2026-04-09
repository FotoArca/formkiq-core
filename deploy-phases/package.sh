#!/bin/bash

# FotoArca FormKIQ Backend - Phase 3: SAM Package
# Extracts the distribution zip, uploads Lambda artifacts to S3, and produces
# a deployable CloudFormation template at build/deploy-staging/packaged-template.yaml

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common.sh"

print_message "=== FotoArca Backend SAM Package Phase ===" "$BLUE"

# Load environment variables
load_env_vars || true

if ! check_env_vars; then
    exit 1
fi

show_config

# ─── Find distribution zip ────────────────────────────────────────────────────

if ! find_dist_zip; then
    exit 1
fi

print_message "Distribution zip: $(basename "$DIST_ZIP")" "$GREEN"
print_message "  Size:     $(du -sh "$DIST_ZIP" | cut -f1)" "$GREEN"
print_message "  Modified: $(date -r "$DIST_ZIP" '+%Y-%m-%d %H:%M:%S')" "$GREEN"

# ─── Prepare staging directory ────────────────────────────────────────────────

STAGING_DIR="$BACKEND_ROOT/build/deploy-staging"
print_message "\nPreparing staging directory: $STAGING_DIR" "$YELLOW"

# Clean and recreate on each run to avoid stale artifacts
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# ─── Extract zip ─────────────────────────────────────────────────────────────

print_message "Extracting distribution zip..." "$YELLOW"
unzip -q "$DIST_ZIP" -d "$STAGING_DIR"

# Find the extracted directory (should be formkiq-core-{version}/)
EXTRACTED_DIRS=()
while IFS= read -r -d '' d; do
    EXTRACTED_DIRS+=("$d")
done < <(find "$STAGING_DIR" -maxdepth 1 -type d -name "formkiq-core-*" -print0 2>/dev/null)

if [ ${#EXTRACTED_DIRS[@]} -eq 0 ]; then
    print_message "Error: Expected a formkiq-core-* directory after extraction in $STAGING_DIR" "$RED"
    exit 1
fi

EXTRACTED_DIR="${EXTRACTED_DIRS[0]}"
print_message "✓ Extracted to: $(basename "$EXTRACTED_DIR")" "$GREEN"

# Verify template.yaml exists inside the extracted directory
if [ ! -f "$EXTRACTED_DIR/template.yaml" ]; then
    print_message "Error: template.yaml not found in extracted distribution" "$RED"
    print_message "Expected: $EXTRACTED_DIR/template.yaml" "$RED"
    exit 1
fi
print_message "✓ Found template.yaml" "$GREEN"

# ─── SAM Package ─────────────────────────────────────────────────────────────
# SAM resolves Lambda CodeUri paths relative to the template, so we must run
# sam package from inside the extracted directory.

PACKAGED_TEMPLATE="$STAGING_DIR/packaged-template.yaml"

print_message "\nRunning SAM package..." "$YELLOW"
print_message "  S3 bucket:  $SAM_ARTIFACT_BUCKET" "$YELLOW"
print_message "  S3 prefix:  formkiq-core" "$YELLOW"
print_message "  Region:     $AWS_REGION" "$YELLOW"
print_message "  Output:     $PACKAGED_TEMPLATE" "$YELLOW"
echo ""

PACKAGE_START=$(date +%s)

(cd "$EXTRACTED_DIR" && AWS_PROFILE=fotoarca sam package \
    --template-file template.yaml \
    --s3-bucket "$SAM_ARTIFACT_BUCKET" \
    --s3-prefix formkiq-core \
    --region "$AWS_REGION" \
    --output-template-file "$PACKAGED_TEMPLATE")

PACKAGE_END=$(date +%s)
PACKAGE_TIME=$((PACKAGE_END - PACKAGE_START))
PACKAGE_MINUTES=$((PACKAGE_TIME / 60))
PACKAGE_SECONDS=$((PACKAGE_TIME % 60))

# ─── Verify output ────────────────────────────────────────────────────────────

if [ ! -f "$PACKAGED_TEMPLATE" ]; then
    print_message "Error: SAM package completed but packaged-template.yaml not found at:" "$RED"
    print_message "  $PACKAGED_TEMPLATE" "$RED"
    exit 1
fi

TEMPLATE_SIZE=$(du -sh "$PACKAGED_TEMPLATE" | cut -f1)

print_message "\n========================================" "$GREEN"
print_message "✓ SAM package completed!" "$GREEN"
print_message "========================================" "$GREEN"
echo ""
print_message "Package Statistics:" "$GREEN"
print_message "  Package time:      ${PACKAGE_MINUTES}m ${PACKAGE_SECONDS}s" "$GREEN"
print_message "  Template size:     $TEMPLATE_SIZE" "$GREEN"
print_message "  Packaged template: build/deploy-staging/packaged-template.yaml" "$GREEN"
print_message "\nNext step:" "$YELLOW"
echo "  ./scripts/deploy-fotoarca.sh --skip-build --skip-package  # Deploy only"
