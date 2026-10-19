#!/bin/bash

# FotoArca FormKIQ Backend Deployment Script
# Orchestrates the 4-phase backend deployment:
#   1. Prerequisites check (Java 17, SAM, AWS credentials)
#   2. Gradle build  → build/distributions/formkiq-core-*.zip
#   3. SAM package   → uploads Lambda code to S3, produces packaged-template.yaml
#   4. SAM deploy    → creates/updates the CloudFormation stack

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source common functions (temporarily disable -u for sourcing)
set +u
source "$SCRIPT_DIR/deploy-phases/common.sh"
set -u

# ─── Parse arguments ──────────────────────────────────────────────────────────

SKIP_CHECK=false
SKIP_BUILD=false
SKIP_PACKAGE=false
SKIP_DEPLOY=false
CHECK_ONLY=false
BUILD_ONLY=false
PACKAGE_ONLY=false
DEPLOY_ONLY=false
YES_FLAG=""
FAST_FLAG=""
FORCE_FLAG=""
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-check)    SKIP_CHECK=true;     shift ;;
        --skip-build)    SKIP_BUILD=true;     shift ;;
        --skip-package)  SKIP_PACKAGE=true;   shift ;;
        --skip-deploy)   SKIP_DEPLOY=true;    shift ;;
        --check-only)    CHECK_ONLY=true;     shift ;;
        --build-only)    BUILD_ONLY=true;     shift ;;
        --package-only)  PACKAGE_ONLY=true;   shift ;;
        --deploy-only)   DEPLOY_ONLY=true;    shift ;;
        --yes|-y)        YES_FLAG="--yes";    shift ;;
        --fast)          FAST_FLAG="--fast";  shift ;;
        --force|-f)      FORCE_FLAG="--force"; shift ;;
        --help|-h)       SHOW_HELP=true;      shift ;;
        *)
            print_message "Unknown option: $1" "$RED"
            SHOW_HELP=true
            shift
            ;;
    esac
done

if [ "$SHOW_HELP" = true ]; then
    print_message "FotoArca FormKIQ Backend Deployment Script" "$GREEN"
    echo ""
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Skip phases:"
    echo "  --skip-check     Skip prerequisites check"
    echo "  --skip-build     Skip build phase (use existing distribution zip)"
    echo "  --skip-package   Skip SAM package phase"
    echo "  --skip-deploy    Skip SAM deploy phase"
    echo ""
    echo "Run single phase:"
    echo "  --check-only     Run only prerequisites check"
    echo "  --build-only     Run only build phase (no deploy)"
    echo "  --package-only   Run only SAM package phase"
    echo "  --deploy-only    Run only SAM deploy phase"
    echo ""
    echo "Other options:"
    echo "  --yes, -y        Skip interactive prompts (non-interactive mode)"
    echo "  --fast           Skip tests, spotlessCheck, and checkstyleMain (fast iteration mode)"
    echo "  --force, -f      Full cache wipe + Gradle --rerun-tasks. Use when build output"
    echo "                   looks stale (binary architecture mismatch, missing handler paths,"
    echo "                   \"works on fresh clone but not here\"). Implies --yes."
    echo "  --help, -h       Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                          # Full deployment (build takes 15–35 min)"
    echo "  $0 --skip-build             # Package + deploy using existing zip"
    echo "  $0 --check-only             # Validate prerequisites only"
    echo "  $0 --build-only             # Build the distribution zip only"
    echo "  $0 --skip-build --yes       # Non-interactive package + deploy"
    echo "  $0 --fast                   # Full deploy, skip tests for fast iteration"
    echo "  $0 --fast --yes             # Non-interactive fast deploy"
    echo "  $0 --force                  # Nuke all caches, rebuild + deploy (stale state recovery)"
    echo "  $0 --force --build-only     # Nuke caches + rebuild only (no deploy)"
    echo "  $0 --force --fast           # Nuke caches, skip tests, rebuild + deploy"
    exit 0
fi

# Banner
print_message "╔═══════════════════════════════════════════════╗" "$BLUE"
print_message "║   FotoArca FormKIQ Backend Deployment Suite   ║" "$BLUE"
print_message "╚═══════════════════════════════════════════════╝" "$BLUE"
echo ""

# ─── Resolve --*-only flags into skip combinations ────────────────────────────

if [ "$CHECK_ONLY" = true ]; then
    SKIP_BUILD=true; SKIP_PACKAGE=true; SKIP_DEPLOY=true
elif [ "$BUILD_ONLY" = true ]; then
    SKIP_CHECK=true; SKIP_PACKAGE=true; SKIP_DEPLOY=true
elif [ "$PACKAGE_ONLY" = true ]; then
    SKIP_CHECK=true; SKIP_BUILD=true; SKIP_DEPLOY=true
elif [ "$DEPLOY_ONLY" = true ]; then
    SKIP_CHECK=true; SKIP_BUILD=true; SKIP_PACKAGE=true
fi

# ─── Build phase summary string ───────────────────────────────────────────────

PHASES_TO_RUN=""
[ "$SKIP_CHECK"   = false ] && PHASES_TO_RUN="${PHASES_TO_RUN}Prerequisites → "
[ "$SKIP_BUILD"   = false ] && PHASES_TO_RUN="${PHASES_TO_RUN}Build → "
[ "$SKIP_PACKAGE" = false ] && PHASES_TO_RUN="${PHASES_TO_RUN}SAM Package → "
[ "$SKIP_DEPLOY"  = false ] && PHASES_TO_RUN="${PHASES_TO_RUN}SAM Deploy"
PHASES_TO_RUN=$(echo "$PHASES_TO_RUN" | sed 's/ → $//')

if [ -z "$PHASES_TO_RUN" ]; then
    print_message "Error: No phases selected to run" "$RED"
    print_message "Use --help for usage information" "$RED"
    exit 1
fi

print_message "Deployment phases:" "$GREEN"
print_message "  $PHASES_TO_RUN" "$YELLOW"
echo ""

# ─── FotoArca Backend Version Management ─────────────────────────────────────
# The deploy counter is only incremented (and committed + tagged) when the
# deploy phase actually runs, ensuring the counter tracks successful deploys.

if [ "$SKIP_DEPLOY" = false ]; then
    FOTOARCA_VERSION_FILE="$SCRIPT_DIR/.fotoarca-backend-version"

    if [ ! -f "$FOTOARCA_VERSION_FILE" ]; then
        print_message "Error: .fotoarca-backend-version file not found at $FOTOARCA_VERSION_FILE" "$RED"
        exit 1
    fi

    CURRENT_DEPLOY_NUMBER=$(cat "$FOTOARCA_VERSION_FILE" | tr -d '[:space:]')
    NEW_DEPLOY_NUMBER=$((CURRENT_DEPLOY_NUMBER + 1))
    DEPLOY_TAG="fotoarca-backend-deploy-${NEW_DEPLOY_NUMBER}"

    print_message "This deployment will be tagged: $DEPLOY_TAG" "$YELLOW"
    echo ""
fi
# ─────────────────────────────────────────────────────────────────────────────

# ─── Phase 1: Prerequisites Check ────────────────────────────────────────────

if [ "$SKIP_CHECK" = false ]; then
    print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
    print_message "Phase 1/4: Prerequisites Check" "$BLUE"
    print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
    echo ""

    bash "$SCRIPT_DIR/deploy-phases/check-prereqs.sh"

    echo ""
else
    print_message "Skipping prerequisites check (--skip-check)" "$YELLOW"
fi

# ─── Phase 2: Build ───────────────────────────────────────────────────────────

if [ "$SKIP_BUILD" = false ]; then
    print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
    print_message "Phase 2/4: Build Application" "$BLUE"
    print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
    echo ""

    bash "$SCRIPT_DIR/deploy-phases/build.sh" $YES_FLAG $FAST_FLAG $FORCE_FLAG

    echo ""
else
    print_message "Skipping build phase (--skip-build)" "$YELLOW"
fi

# ─── Phase 3: SAM Package ─────────────────────────────────────────────────────

if [ "$SKIP_PACKAGE" = false ]; then
    print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
    print_message "Phase 3/4: SAM Package" "$BLUE"
    print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
    echo ""

    bash "$SCRIPT_DIR/deploy-phases/package.sh"

    echo ""
else
    print_message "Skipping SAM package phase (--skip-package)" "$YELLOW"
fi

# ─── Phase 4: SAM Deploy ──────────────────────────────────────────────────────

if [ "$SKIP_DEPLOY" = false ]; then
    print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
    print_message "Phase 4/4: SAM Deploy" "$BLUE"
    print_message "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" "$BLUE"
    echo ""

    bash "$SCRIPT_DIR/deploy-phases/deploy.sh"

    echo ""

    # ─── Post-deploy: increment counter, commit, and tag ────────────────────
    echo "$NEW_DEPLOY_NUMBER" > "$FOTOARCA_VERSION_FILE"

    git -C "$SCRIPT_DIR" add ".fotoarca-backend-version"
    git -C "$SCRIPT_DIR" commit -m "chore: bump FotoArca backend deploy counter to $DEPLOY_TAG"
    git -C "$SCRIPT_DIR" tag -a "$DEPLOY_TAG" -m "FotoArca backend deploy $DEPLOY_TAG"

    print_message "✓ Deploy counter committed and tagged as $DEPLOY_TAG" "$GREEN"
    echo ""
    # ─────────────────────────────────────────────────────────────────────────
else
    print_message "Skipping SAM deploy phase (--skip-deploy)" "$YELLOW"
fi

# ─── Success summary ──────────────────────────────────────────────────────────

print_message "╔═══════════════════════════════════════════════╗" "$GREEN"
print_message "║        Deployment Pipeline Completed!         ║" "$GREEN"
print_message "╚═══════════════════════════════════════════════╝" "$GREEN"
echo ""
print_message "Completed phases:" "$GREEN"
[ "$SKIP_CHECK"   = false ] && print_message "  ✓ Prerequisites verified" "$GREEN"
[ "$SKIP_BUILD"   = false ] && print_message "  ✓ Application built" "$GREEN"
[ "$SKIP_PACKAGE" = false ] && print_message "  ✓ Lambda artifacts packaged to S3" "$GREEN"
[ "$SKIP_DEPLOY"  = false ] && print_message "  ✓ CloudFormation stack deployed" "$GREEN"
[ "$SKIP_DEPLOY"  = false ] && print_message "  ✓ Tagged as $DEPLOY_TAG" "$GREEN"
echo ""
