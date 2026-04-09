#!/bin/bash

# FotoArca FormKIQ Backend - Phase 2: Build
# Compiles Java/GraalVM lambdas and produces build/distributions/formkiq-core-*.zip

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common.sh"

print_message "=== FotoArca Backend Build Phase ===" "$BLUE"

# Find backend root
if ! find_backend_root; then
    print_message "Error: Could not find backend root directory" "$RED"
    exit 1
fi

# Read version from build.gradle (line like: version = '1.18.1')
GRADLE_VERSION_RAW=$(grep "version = '" "$BACKEND_ROOT/build.gradle" | head -1 \
    | sed "s/.*version = '//;s/'.*//" 2>/dev/null || echo "unknown")
print_message "Building version: $GRADLE_VERSION_RAW" "$GREEN"

# ─── Check for existing distribution zip ─────────────────────────────────────

DIST_DIR="$BACKEND_ROOT/build/distributions"
EXISTING_ZIP=""

if [ -d "$DIST_DIR" ]; then
    EXISTING_ZIPS=()
    while IFS= read -r -d '' f; do
        EXISTING_ZIPS+=("$f")
    done < <(find "$DIST_DIR" -maxdepth 1 -name "formkiq-core-*.zip" -print0 2>/dev/null)

    if [ ${#EXISTING_ZIPS[@]} -gt 0 ]; then
        EXISTING_ZIP=$(ls -t "${EXISTING_ZIPS[@]}" | head -1)
    fi
fi

if [ -n "$EXISTING_ZIP" ]; then
    print_message "\nDistribution zip already exists: $(basename "$EXISTING_ZIP")" "$YELLOW"
    print_message "  Size:     $(du -sh "$EXISTING_ZIP" | cut -f1)" "$YELLOW"
    print_message "  Modified: $(date -r "$EXISTING_ZIP" '+%Y-%m-%d %H:%M:%S')" "$YELLOW"

    # Non-interactive bypass via --yes flag or CI=true
    if [ "${1:-}" == "--yes" ] || [ "${CI:-}" == "true" ]; then
        print_message "Rebuilding (non-interactive mode)..." "$YELLOW"
    else
        read -p "Do you want to rebuild? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_message "Skipping rebuild. Using existing distribution zip." "$YELLOW"
            print_message "✓ Build phase complete (skipped — using existing zip)" "$GREEN"
            exit 0
        fi
    fi

    print_message "Cleaning previous distribution zip..." "$YELLOW"
    rm -f "$DIST_DIR"/formkiq-core-*.zip
fi

# ─── Build ────────────────────────────────────────────────────────────────────

print_message "\nBuilding distribution (this takes 15–35 minutes)..." "$YELLOW"
print_message "Command: ./gradlew build distZip --no-daemon --console=plain" "$YELLOW"
echo ""

BUILD_START=$(date +%s)

(cd "$BACKEND_ROOT" && ./gradlew build distZip --no-daemon --console=plain)

BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))
BUILD_MINUTES=$((BUILD_TIME / 60))
BUILD_SECONDS=$((BUILD_TIME % 60))

# ─── Verify output ────────────────────────────────────────────────────────────

NEW_ZIPS=()
while IFS= read -r -d '' f; do
    NEW_ZIPS+=("$f")
done < <(find "$DIST_DIR" -maxdepth 1 -name "formkiq-core-*.zip" -print0 2>/dev/null)

if [ ${#NEW_ZIPS[@]} -eq 0 ]; then
    print_message "Error: Build completed but no distribution zip found in $DIST_DIR" "$RED"
    exit 1
fi

BUILT_ZIP=$(ls -t "${NEW_ZIPS[@]}" | head -1)
ZIP_SIZE=$(du -sh "$BUILT_ZIP" | cut -f1)

print_message "\n========================================" "$GREEN"
print_message "✓ Build completed successfully!" "$GREEN"
print_message "========================================" "$GREEN"
echo ""
print_message "Build Statistics:" "$GREEN"
print_message "  Version:    $GRADLE_VERSION_RAW" "$GREEN"
print_message "  Build time: ${BUILD_MINUTES}m ${BUILD_SECONDS}s" "$GREEN"
print_message "  Zip file:   $(basename "$BUILT_ZIP")" "$GREEN"
print_message "  Zip size:   $ZIP_SIZE" "$GREEN"
print_message "\nNext step:" "$YELLOW"
echo "  ./scripts/deploy-fotoarca.sh --skip-build  # Package + deploy"
