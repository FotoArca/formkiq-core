#!/usr/bin/env bash
# Verify that every GraalVM native binary in the FormKIQ fork matches the
# Architectures setting declared for its corresponding Lambda in CloudFormation.
#
# Rationale: The formkiq.gradle.graalvm-native-plugin uses a multi-arch Docker
# image (ghcr.io/graalvm/native-image-community:24) without specifying a platform.
# On Apple Silicon, this produces aarch64 binaries by default; on x86 hosts it
# produces amd64 binaries. Shipping a mismatched binary to Lambda fails at runtime
# with: /var/task/bootstrap: line 3: ./server: cannot execute binary file: Exec format error
#
# Usage (run from formkiq-backend/ root):
#   ./scripts/verify-graalvm-architectures.sh
#
# Fails with exit 1 if any binary has an architecture that doesn't match its
# CloudFormation Architectures declaration.

set -euo pipefail

# Map of <binary-path> → <cfn-template-path>:<lambda-resource-name>
# Add new entries here when FormKIQ adds more GraalVM-based Lambdas.
declare -a ENTRIES=(
  "lambda-apikey-authorizer/build/graalvm/output/server|src/main/resources/cloudformation/api/api-apikey.yaml|ApiKeyAuthorizer"
  "lambda-api-graalvm/build/graalvm/output/server|src/main/resources/cloudformation/api/api-lambda.yaml|DocumentsApiRequests"
  "lambda-typesense/build/graalvm/output/server|src/main/resources/cloudformation/typesense/template.yaml|TypesenseProcessor"
  "lambda-s3-graalvm/build/graalvm/server|src/main/resources/cloudformation/storage/template.yaml|DocumentsS3Update"
)

FAIL=0

get_binary_arch() {
  # Returns "arm64" or "x86_64" based on the ELF header
  local path="$1"
  local header
  header=$(file "$path" 2>/dev/null || echo "")
  if echo "$header" | grep -q "ARM aarch64"; then
    echo "arm64"
  elif echo "$header" | grep -q "x86-64"; then
    echo "x86_64"
  else
    echo "unknown"
  fi
}

get_cfn_arch() {
  # Extracts the Architectures value from a CFN template for a given Lambda resource.
  # Returns "x86_64" (default when Architectures is not set) or "arm64".
  local template="$1"
  local resource="$2"

  # Scoped search within the resource block. CloudFormation resources use
  # 2-space indent for the resource name, 4 for Type/Properties, and 6 for
  # fields inside Properties (including Architectures). List items are at 8.
  awk -v res="$resource" '
    $0 ~ "^  "res":[[:space:]]*$" { in_res = 1; next }
    in_res && /^  [A-Za-z]/ { in_res = 0 }
    in_res && /^      Architectures:/ { in_arch = 1; next }
    in_arch && /^        - / { print; in_arch = 0 }
    in_arch && /^      [A-Za-z]/ { in_arch = 0 }
  ' "$template" | sed -E 's/^ *- *//' | head -1 | tr -d '[:space:]'
}

for entry in "${ENTRIES[@]}"; do
  IFS='|' read -r bin_path tpl_path resource <<< "$entry"

  if [ ! -f "$bin_path" ]; then
    echo "SKIP: $bin_path not built yet ($resource)"
    continue
  fi

  if [ ! -f "$tpl_path" ]; then
    echo "FAIL: CFN template not found: $tpl_path"
    FAIL=1
    continue
  fi

  bin_arch=$(get_binary_arch "$bin_path")
  cfn_arch=$(get_cfn_arch "$tpl_path" "$resource")
  cfn_arch=${cfn_arch:-x86_64}  # CFN default if unset

  if [ "$bin_arch" = "unknown" ]; then
    echo "FAIL: Could not detect architecture for $bin_path"
    FAIL=1
  elif [ "$bin_arch" = "$cfn_arch" ]; then
    echo "OK  : $resource ($bin_arch) matches $tpl_path"
  else
    echo "FAIL: $resource binary is $bin_arch but $tpl_path declares $cfn_arch"
    echo "      Fix: either rebuild the binary to match, or update CFN Architectures"
    FAIL=1
  fi
done

if [ $FAIL -ne 0 ]; then
  echo ""
  echo "Architecture mismatch detected. Deploying would break the Lambda at runtime with:"
  echo "  /var/task/bootstrap: line 3: ./server: cannot execute binary file: Exec format error"
  exit 1
fi

echo ""
echo "All GraalVM binaries match their CFN Architectures declarations."
