#!/bin/bash

# FotoArca FormKIQ Backend - Phase 2: Build
# Compiles Java/GraalVM lambdas and produces build/distributions/formkiq-core-*.zip

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common.sh"

# ─── Parse arguments ──────────────────────────────────────────────────────────
YES_MODE=false
FAST=false
FORCE=false
for arg in "$@"; do
    case $arg in
        --yes|-y)   YES_MODE=true ;;
        --fast)     FAST=true ;;
        --force|-f) FORCE=true; YES_MODE=true ;;  # --force implies --yes
    esac
done

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
    if [ "$YES_MODE" = true ] || [ "${CI:-}" == "true" ]; then
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

# ─── Pre-pull amd64 Docker images (cross-compile x86_64 on Apple Silicon) ────
# Two build mechanisms produce GraalVM native binaries:
#
# 1. graalvm-native-plugin (lambda-api-graalvm, lambda-apikey-authorizer,
#    lambda-typesense): uses docker-java, which does not pass --platform.
#    Pre-pulling the amd64 variant overwrites the locally-tagged image so
#    the subsequent native-image container runs amd64.
#
# 2. lambda-s3-graalvm: custom Dockerfile with amazonlinux:2 base image.
#    The Dockerfile and build.gradle both specify --platform linux/amd64,
#    but pre-pulling ensures the image is cached before build starts.

GRAALVM_IMAGE="ghcr.io/graalvm/native-image-community:24"
AMAZONLINUX_IMAGE="amazonlinux:2"

if command -v docker &> /dev/null && docker info &> /dev/null; then
    print_message "\nPre-pulling amd64 builder images..." "$YELLOW"

    for img in "$GRAALVM_IMAGE" "$AMAZONLINUX_IMAGE"; do
        print_message "  Image: $img (platform: linux/amd64)" "$YELLOW"
        if docker pull --platform linux/amd64 "$img"; then
            print_message "  ✓ amd64 image cached: $img" "$GREEN"
        else
            print_message "  Warning: Failed to pre-pull amd64 $img" "$YELLOW"
        fi
    done
    echo ""
else
    print_message "Warning: Docker not running — cannot pre-pull amd64 builder images" "$YELLOW"
    print_message "If the GraalVM Lambdas need rebuilding, the build will fail." "$YELLOW"
    echo ""
fi

# ─── Purge all GraalVM build caches ──────────────────────────────────────────
# The GraalVM Gradle plugin (graalvm-native-plugin) has multiple caching bugs:
#
# 1. STAGING (build/graalvm/java/main/): The plugin's decompressJar() method
#    NEVER overwrites existing files. Stale .class files from prior builds
#    persist and get compiled into the native image instead of fresh ones.
#
# 2. DOCKER LAYER CACHE: Docker may reuse a cached COPY layer with stale
#    staging content if file checksums haven't changed enough to bust the cache.
#
# 3. DISTRIBUTION ZIPS (build/distributions/): Subproject dist zips package
#    the native binary; stale zips carry stale binaries into the root distZip.
#
# We purge all three layers to guarantee a clean native-image build.

if [ "$FORCE" = true ]; then
    print_message "\n╔══════════════════════════════════════════════════════════╗" "$RED"
    print_message "║  FORCE MODE: wiping ALL build caches + --rerun-tasks     ║" "$RED"
    print_message "║  This takes longer than a normal build. Use when output  ║" "$RED"
    print_message "║  looks stale (wrong arch, missing handlers, etc).        ║" "$RED"
    print_message "╚══════════════════════════════════════════════════════════╝" "$RED"
fi

print_message "\nPurging GraalVM build caches..." "$YELLOW"

# 1. Delete GraalVM staging + output directories
GRAALVM_DIRS=$(find "$BACKEND_ROOT" -path "*/build/graalvm" -type d 2>/dev/null)
if [ -n "$GRAALVM_DIRS" ]; then
    while IFS= read -r d; do
        print_message "  Removing staging: ${d#$BACKEND_ROOT/}" "$YELLOW"
        rm -rf "$d"
    done <<< "$GRAALVM_DIRS"
fi

# 2. Delete subproject distribution zips (contain stale native binaries)
DIST_DIRS=$(find "$BACKEND_ROOT" -mindepth 2 -path "*/build/distributions" -type d 2>/dev/null)
if [ -n "$DIST_DIRS" ]; then
    while IFS= read -r d; do
        print_message "  Removing dist:    ${d#$BACKEND_ROOT/}" "$YELLOW"
        rm -rf "$d"
    done <<< "$DIST_DIRS"
fi

# 3. Remove stale Docker images from prior GraalVM builds
if command -v docker &> /dev/null && docker info &> /dev/null; then
    for img in "generated-graalvm-native-plugin:latest" "amazonlinux-graalvm:latest"; do
        if docker image inspect "$img" &>/dev/null; then
            print_message "  Removing Docker image: $img" "$YELLOW"
            docker rmi "$img" 2>/dev/null || true
        fi
    done
fi

# 4. Clear Gradle configuration cache (can hold stale dependency resolution)
if [ -d "$BACKEND_ROOT/.gradle/configuration-cache" ]; then
    print_message "  Clearing Gradle configuration cache" "$YELLOW"
    rm -rf "$BACKEND_ROOT/.gradle/configuration-cache"
fi

# ─── FORCE MODE: aggressive cache wipe ────────────────────────────────────────
# Triggered by --force. Removes intermediate artifacts the standard purge misses,
# and nukes the entire build/ dir for each GraalVM subproject. This is the
# hammer to swing when the standard purge above doesn't resolve a stale build.
if [ "$FORCE" = true ]; then
    print_message "\n  [FORCE] Additional cache wipes..." "$RED"

    # 5. Delete intermediate GraalVM zip files (the missing piece from the
    #    standard purge): lambda-s3-graalvm/build/graalvm.zip is produced by
    #    the dockerCp task and consumed by unzipFile. If it persists across
    #    builds, unzipFile may not re-extract even when the zip changed.
    GRAALVM_ZIPS=$(find "$BACKEND_ROOT" -path "*/build/graalvm.zip" -type f 2>/dev/null)
    if [ -n "$GRAALVM_ZIPS" ]; then
        while IFS= read -r f; do
            print_message "    Removing: ${f#$BACKEND_ROOT/}" "$RED"
            rm -f "$f"
        done <<< "$GRAALVM_ZIPS"
    fi

    # 6. Delete subproject custom dist dirs (lambda-s3-graalvm/build/dist/)
    CUSTOM_DIST_DIRS=$(find "$BACKEND_ROOT" -mindepth 2 -path "*/build/dist" -type d 2>/dev/null)
    if [ -n "$CUSTOM_DIST_DIRS" ]; then
        while IFS= read -r d; do
            print_message "    Removing: ${d#$BACKEND_ROOT/}" "$RED"
            rm -rf "$d"
        done <<< "$CUSTOM_DIST_DIRS"
    fi

    # 7. Delete subproject build/libs/ dirs (stale copied runtime classpath jars)
    LIBS_DIRS=$(find "$BACKEND_ROOT" -mindepth 2 -path "*/build/libs" -type d 2>/dev/null)
    if [ -n "$LIBS_DIRS" ]; then
        while IFS= read -r d; do
            print_message "    Removing: ${d#$BACKEND_ROOT/}" "$RED"
            rm -rf "$d"
        done <<< "$LIBS_DIRS"
    fi

    # 8. Nuclear: wipe entire build/ dir for each GraalVM subproject. Ensures
    #    absolutely no stale output can be reused. Add new GraalVM-based
    #    subprojects here if/when they get added to the fork.
    for p in lambda-s3-graalvm lambda-api-graalvm lambda-apikey-authorizer lambda-typesense; do
        if [ -d "$BACKEND_ROOT/$p/build" ]; then
            print_message "    Nuking:  $p/build" "$RED"
            rm -rf "$BACKEND_ROOT/$p/build"
        fi
    done
fi

print_message "✓ GraalVM caches purged" "$GREEN"

# ─── Build ────────────────────────────────────────────────────────────────────

# --rerun-tasks ignores task up-to-date checks globally. Defense-in-depth for
# the stale-task-cache class of bugs (e.g., Exec tasks with no inputs/outputs).
GRADLE_EXTRA_FLAGS=""
if [ "$FORCE" = true ]; then
    GRADLE_EXTRA_FLAGS="--rerun-tasks"
fi

if [ "$FAST" = true ]; then
    print_message "\nBuilding distribution in FAST mode (skipping test/spotlessCheck/checkstyleMain)..." "$YELLOW"
    print_message "Command: ./gradlew build distZip -x test -x spotlessCheck -x checkstyleMain --no-build-cache --no-daemon --console=plain $GRADLE_EXTRA_FLAGS" "$YELLOW"
else
    print_message "\nBuilding distribution (this takes 15–35 minutes)..." "$YELLOW"
    print_message "Command: ./gradlew build distZip --no-build-cache --no-daemon --console=plain $GRADLE_EXTRA_FLAGS" "$YELLOW"
fi
echo ""

BUILD_START=$(date +%s)

if [ "$FAST" = true ]; then
    (cd "$BACKEND_ROOT" && ./gradlew build distZip \
        -x test -x spotlessCheck -x checkstyleMain \
        --no-build-cache --no-daemon --console=plain $GRADLE_EXTRA_FLAGS)
else
    (cd "$BACKEND_ROOT" && ./gradlew build distZip \
        --no-build-cache --no-daemon --console=plain $GRADLE_EXTRA_FLAGS)
fi

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

# ─── Verify GraalVM binary architectures ────────────────────────────────────
# Fail fast locally if any lambda-*-graalvm binary doesn't match its CFN
# Architectures declaration — better than deploying an Exec format error.

if [ -f "$BACKEND_ROOT/scripts/verify-graalvm-architectures.sh" ]; then
    print_message "\nVerifying GraalVM binary architectures..." "$YELLOW"
    if ! (cd "$BACKEND_ROOT" && ./scripts/verify-graalvm-architectures.sh); then
        print_message "Error: GraalVM binaries do not match CFN Architectures declarations" "$RED"
        print_message "Fix: rebuild with the correct platform, or update CFN templates" "$RED"
        exit 1
    fi
    print_message "✓ All GraalVM binary architectures match CFN" "$GREEN"
fi

# ─── Verify GraalVM binary contains all registered handlers ─────────────────
# Catch stale-staging bugs before deploy: confirm the lambda-api-graalvm binary
# contains handler path strings that we know must be present.

API_BINARY="$BACKEND_ROOT/lambda-api-graalvm/build/graalvm/output/server"
if [ -f "$API_BINARY" ]; then
    print_message "\nVerifying lambda-api-graalvm binary handler coverage..." "$YELLOW"
    HANDLER_CHECK_FAILED=false

    # Sample of handler paths that must exist — add new ones as features are added
    REQUIRED_PATHS=(
        "/documents/upload"
        "/documents/upload/multipart"
        "/documents/compress"
    )

    # Extract strings once to a temp file (avoid repeated 150MB scans).
    # Using a file also avoids the pipefail + grep -q SIGPIPE bug where
    # strings receives SIGPIPE (exit 141) when grep -q closes the pipe early.
    STRINGS_FILE=$(mktemp)
    strings "$API_BINARY" > "$STRINGS_FILE"

    for path in "${REQUIRED_PATHS[@]}"; do
        if ! grep -qF "$path" "$STRINGS_FILE"; then
            print_message "  MISSING handler path: $path" "$RED"
            HANDLER_CHECK_FAILED=true
        fi
    done

    rm -f "$STRINGS_FILE"

    if [ "$HANDLER_CHECK_FAILED" = true ]; then
        print_message "Error: GraalVM binary is missing registered handler paths." "$RED"
        print_message "This indicates a stale native-image build. The staging directory" "$RED"
        print_message "may still contain old .class files. Try: rm -rf */build/graalvm" "$RED"
        exit 1
    fi
    print_message "✓ All required handler paths found in binary" "$GREEN"
fi

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
