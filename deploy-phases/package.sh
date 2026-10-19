#!/bin/bash

# FotoArca FormKIQ Backend - Phase 3: SAM Package
# Extracts the distribution zip, uploads Lambda artifacts to S3, and produces
# a deployable CloudFormation template at build/sam-workdir/packaged-template.yaml

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

# ─── Prepare SAM workdir ──────────────────────────────────────────────────────
# This is a local working directory for extracting the distribution zip and
# running `sam package` against it. It has nothing to do with AWS environments —
# the deploy target (prod/dev/etc) is set by $STACK_NAME from .env.

SAM_WORKDIR="$BACKEND_ROOT/build/sam-workdir"
print_message "\nPreparing SAM workdir: $SAM_WORKDIR" "$YELLOW"

# Clean and recreate on each run to avoid stale artifacts
rm -rf "$SAM_WORKDIR"
mkdir -p "$SAM_WORKDIR"

# ─── Extract zip ─────────────────────────────────────────────────────────────
# The FotoArca fork's distZip uses `into '/'` in build.gradle:183, so the zip
# is flat — all content lives at the zip root, not wrapped in a
# formkiq-core-{version}/ directory. Treat SAM_WORKDIR itself as the
# extraction target.

print_message "Extracting distribution zip..." "$YELLOW"
unzip -q "$DIST_ZIP" -d "$SAM_WORKDIR"

if [ ! -f "$SAM_WORKDIR/template.yaml" ]; then
    print_message "Error: template.yaml not found at $SAM_WORKDIR/template.yaml" "$RED"
    print_message "The distribution zip may be malformed or produced by an unexpected build." "$RED"
    exit 1
fi
print_message "✓ Extracted distribution into $SAM_WORKDIR" "$GREEN"
print_message "✓ Found template.yaml" "$GREEN"

# ─── SAM Package ─────────────────────────────────────────────────────────────
# SAM resolves Lambda CodeUri paths relative to the template, so we must run
# sam package from inside the workdir where the extracted templates live.

PACKAGED_TEMPLATE="$SAM_WORKDIR/packaged-template.yaml"

print_message "\nRunning SAM package..." "$YELLOW"
print_message "  S3 bucket:  $SAM_ARTIFACT_BUCKET" "$YELLOW"
print_message "  S3 prefix:  formkiq-core" "$YELLOW"
print_message "  Region:     $AWS_REGION" "$YELLOW"
print_message "  Output:     $PACKAGED_TEMPLATE" "$YELLOW"
echo ""

PACKAGE_START=$(date +%s)

(cd "$SAM_WORKDIR" && AWS_PROFILE=fotoarca sam package \
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
print_message "  Packaged template: build/sam-workdir/packaged-template.yaml" "$GREEN"
print_message "\nNext step:" "$YELLOW"
echo "  ./scripts/deploy-fotoarca.sh --skip-build --skip-package  # Deploy only"
