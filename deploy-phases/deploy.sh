#!/bin/bash

# FotoArca FormKIQ Backend - Phase 4: SAM Deploy
# Creates or updates the CloudFormation stack using the packaged template

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$SCRIPT_DIR/common.sh"

print_message "=== FotoArca Backend SAM Deploy Phase ===" "$BLUE"

# Load environment variables
load_env_vars || true

if ! check_env_vars; then
    exit 1
fi

show_config

# ─── Locate packaged template ─────────────────────────────────────────────────

if ! find_backend_root; then
    exit 1
fi

PACKAGED_TEMPLATE="$BACKEND_ROOT/build/deploy-staging/packaged-template.yaml"

if [ ! -f "$PACKAGED_TEMPLATE" ]; then
    print_message "Error: Packaged template not found: $PACKAGED_TEMPLATE" "$RED"
    print_message "Please run the package phase first:" "$RED"
    echo "  ./scripts/deploy-fotoarca.sh --skip-build"
    exit 1
fi
print_message "Using packaged template: build/deploy-staging/packaged-template.yaml" "$GREEN"

# ─── Detect existing stack ───────────────────────────────────────────────────

print_message "\nChecking CloudFormation stack: $STACK_NAME..." "$YELLOW"

if AWS_PROFILE=fotoarca aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" &> /dev/null; then
    STACK_EXISTS=true
    STACK_STATUS=$(AWS_PROFILE=fotoarca aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$AWS_REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text)
    print_message "✓ Stack exists — updating (current status: $STACK_STATUS)" "$GREEN"

    # Warn if stack is in a problematic state
    if [[ "$STACK_STATUS" == *FAILED* ]] || [[ "$STACK_STATUS" == *ROLLBACK* ]]; then
        print_message "Warning: Stack is in $STACK_STATUS state" "$YELLOW"
        print_message "You may need to resolve rollback issues before deploying." "$YELLOW"
        print_message "See DEPLOYMENT.md > Troubleshooting for guidance." "$YELLOW"
    fi
else
    STACK_EXISTS=false
    print_message "Stack does not exist — will create a new stack" "$YELLOW"
fi

# ─── SAM Deploy ───────────────────────────────────────────────────────────────
# --no-confirm-changeset:      Skip interactive change set confirmation
# --no-fail-on-empty-changeset: Return success when nothing changed (idempotent)

print_message "\nRunning SAM deploy..." "$YELLOW"
print_message "  Stack:       $STACK_NAME" "$YELLOW"
print_message "  Region:      $AWS_REGION" "$YELLOW"
print_message "  Environment: $APP_ENVIRONMENT" "$YELLOW"
echo ""

PARAMETER_OVERRIDES="AdminEmail=$ADMIN_EMAIL AppEnvironment=$APP_ENVIRONMENT"
if [ -n "${EXTRA_PARAMETERS:-}" ]; then
    PARAMETER_OVERRIDES="$PARAMETER_OVERRIDES $EXTRA_PARAMETERS"
fi

DEPLOY_START=$(date +%s)

AWS_PROFILE=fotoarca sam deploy \
    --template-file "$PACKAGED_TEMPLATE" \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM \
    --parameter-overrides $PARAMETER_OVERRIDES \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset

DEPLOY_END=$(date +%s)
DEPLOY_TIME=$((DEPLOY_END - DEPLOY_START))
DEPLOY_MINUTES=$((DEPLOY_TIME / 60))
DEPLOY_SECONDS=$((DEPLOY_TIME % 60))

# ─── Verify final stack status ────────────────────────────────────────────────

print_message "\nVerifying stack status..." "$YELLOW"
FINAL_STATUS=$(AWS_PROFILE=fotoarca aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || echo "UNKNOWN")

if [[ "$FINAL_STATUS" == *"COMPLETE"* ]] && [[ "$FINAL_STATUS" != *"ROLLBACK"* ]]; then
    print_message "✓ Stack status: $FINAL_STATUS" "$GREEN"
else
    print_message "Warning: Unexpected stack status: $FINAL_STATUS" "$YELLOW"
    print_message "Check CloudFormation events for details:" "$YELLOW"
    echo "  AWS_PROFILE=fotoarca aws cloudformation describe-stack-events \\"
    echo "    --stack-name $STACK_NAME --region $AWS_REGION \\"
    echo "    --query 'StackEvents[0:10].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId]' \\"
    echo "    --output table"
fi

# ─── Print stack outputs ──────────────────────────────────────────────────────

print_message "\nStack Outputs:" "$GREEN"
AWS_PROFILE=fotoarca aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$AWS_REGION" \
    --query 'Stacks[0].Outputs[*].[OutputKey,OutputValue]' \
    --output table 2>/dev/null || print_message "  (no outputs available)" "$YELLOW"

print_message "\n========================================" "$GREEN"
print_message "✓ SAM deploy completed!" "$GREEN"
print_message "========================================" "$GREEN"
echo ""
print_message "Deploy Statistics:" "$GREEN"
print_message "  Deploy time: ${DEPLOY_MINUTES}m ${DEPLOY_SECONDS}s" "$GREEN"
print_message "  Stack:       $STACK_NAME" "$GREEN"
print_message "  Region:      $AWS_REGION" "$GREEN"
print_message "  Status:      $FINAL_STATUS" "$GREEN"
