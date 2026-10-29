<!-- formkiq-backend-specific rule. Part of the FotoArca CLAUDE.md documentation set
     (see root CLAUDE.md > "CLAUDE.md Documentation Architecture"). -->

## FormKIQ GraalVM Binary Architecture

### The Problem
FormKIQ's 3 native-image Lambdas (`lambda-apikey-authorizer`, `lambda-api-graalvm`, `lambda-typesense`) are compiled to **platform-specific ELF binaries** that must match the AWS Lambda runtime architecture (`arm64` or `x86_64`). Deploying a mismatched binary fails at the first invocation with:
```
/var/task/bootstrap: line 3: ./server: cannot execute binary file: Exec format error
Runtime.ExitError
```
When this happens behind an API Gateway custom Lambda authorizer, callers get a generic `500 Internal Server Error` with no useful detail and `"integrationStatus": "-"` in the API access logs.

### Why This Happens in FotoArca's Fork
The `formkiq-backend` project uses `com.formkiq.gradle.graalvm-native-plugin:1.7.4` which runs native-image inside Docker via `dockerImage = "ghcr.io/graalvm/native-image-community:24"`. That image is a multi-arch manifest — Docker picks `linux/arm64` on Apple Silicon hosts and `linux/amd64` on x86 hosts, **without any platform override option in the plugin's DSL**. The plugin's `docker-java` client does not expose `--platform`, and the `platform` extension property is only used for downloading standalone GraalVM distributions (non-Docker path).

Result: binaries built on Alex's Apple Silicon Mac are `arm64` by default. Binaries built in CI or on x86 hosts are `x86_64`. Historical binaries on disk in this repo have been mixed.

### The Rule
- [ ] **Before deploying FormKIQ backend**, run the verification script to catch arch mismatches:
  ```bash
  cd ~/workspace/FotoArca/formkiq-backend
  ./scripts/verify-graalvm-architectures.sh
  ```
  It inspects each `build/graalvm/output/server` binary with `file`, parses the `Architectures` declaration from the corresponding CFN template, and fails the build if they don't match.
- [ ] **When rebuilding a GraalVM Lambda**, verify the new binary architecture with `file lambda-<name>/build/graalvm/output/server`. If the result differs from the CFN template, you have two choices:
  - **Rebuild with the matching architecture** (requires setting `DOCKER_DEFAULT_PLATFORM` in your shell env and/or changing Docker Desktop settings before running `./gradlew`)
  - **Update the CFN template's `Architectures` declaration** to match the binary (this is what we did for `ApiKeyAuthorizer` which is stuck on arm64)
- [ ] **When adding a new GraalVM-based Lambda to the fork**, add an entry to `scripts/verify-graalvm-architectures.sh` so it's included in the preflight check.

### Current State (as of 2026-04-10)
| Lambda | Binary on disk | CFN Architectures | Status |
|---|---|---|---|
| `ApiKeyAuthorizer` (api-apikey.yaml) | `arm64` (built Mar 3 on Apple Silicon) | `arm64` (persisted in fork) | OK |
| `DocumentsApiRequests` (api-lambda.yaml) | `x86_64` (built Mar 6) | unset → `x86_64` default | OK |
| `TypesenseProcessor` (typesense/template.yaml) | `x86_64` (built Mar 6) | unset → `x86_64` default | OK |
| `DocumentsS3Update` (storage/template.yaml) | `x86_64` (rebuilt Apr 10) | unset → `x86_64` default | OK — was arm64, causing 100% failure |

### GraalVM Build Mechanisms
There are **two different build systems** for native binaries — both must target the correct architecture:

| Build system | Lambdas | How architecture is enforced |
|---|---|---|
| `graalvm-native-plugin` (Gradle) | ApiKeyAuthorizer, DocumentsApiRequests, TypesenseProcessor | `build.sh` pre-pulls `ghcr.io/graalvm/native-image-community:24` with `--platform linux/amd64` |
| Custom Dockerfile (`amazonlinux:2`) | DocumentsS3Update (`lambda-s3-graalvm`) | `FROM --platform=linux/amd64` in Dockerfile + `--platform linux/amd64` in Gradle `dockerBuild` task |

### When a force rebuild is needed
Use `./deploy-fotoarca.sh --force` (or `-f`) to trigger the nuclear cache wipe. This purges all intermediate GraalVM artifacts (including `build/graalvm.zip`, `build/dist/`, `build/libs/`, and the entire `build/` dir for each of the 4 GraalVM subprojects), removes stale Docker builder images, clears the Gradle configuration cache, and adds `--rerun-tasks` so Gradle ignores task up-to-date checks globally.

**Trigger situations**:
- [ ] `verify-graalvm-architectures.sh` reports a binary/CFN mismatch
- [ ] `build.sh` handler-path check reports missing handlers (stale staging class files)
- [ ] Deployed Lambda returns `Exec format error` or `ClassNotFoundException` despite a recent build
- [ ] `./gradlew` build completes successfully but the output looks stale (e.g., rebuild produces identical BuildID)
- [ ] Fork pulled upstream changes that touched subproject `build.gradle` files
- [ ] Docker Desktop architecture/Rosetta settings changed since the last build

**Invocations**:
```bash
./deploy-fotoarca.sh --force --build-only   # Just rebuild, verify the zip
./deploy-fotoarca.sh --force                # Full force build + package + deploy
./deploy-fotoarca.sh --force --fast         # Force build, skip tests (iteration)
```

**Expected impact**: `--force` adds ~5–10 min vs a normal build (because nothing is cached). Use it as a targeted recovery tool, not the default build path.

### Deployed Lambda Architecture
After a CFN deploy, verify with:
```bash
aws lambda get-function-configuration \
  --function-name <name> \
  --profile fotoarca --region ca-central-1 \
  --query 'Architectures'
```

### Emergency Fix: Flip Architecture Without Rebuilding
If a deployed Lambda is broken with `Exec format error`, you can re-upload the existing deployment package with a different architecture flag (no rebuild needed):
```bash
# Download current package
CODE_URL=$(aws lambda get-function --function-name <name> --profile fotoarca --region ca-central-1 --query 'Code.Location' --output text)
curl -sS "$CODE_URL" -o /tmp/fn.zip

# Re-upload with the correct architecture
aws lambda update-function-code \
  --function-name <name> \
  --zip-file fileb:///tmp/fn.zip \
  --architectures arm64 \
  --profile fotoarca --region ca-central-1

rm /tmp/fn.zip
```
This works because the binary inside the zip stays the same; only the Lambda runtime selector changes. Only useful if the binary architecture actually matches the new selector.

### Diagnostic Signature
If any FormKIQ API call returns `500 Internal Server Error` with `"integrationStatus": "-"` in the access logs, suspect the authorizer. Check the custom log group (not the default `/aws/lambda/...` path):
```bash
aws lambda get-function --function-name <authorizer-name> --query 'Configuration.LoggingConfig.LogGroup'
# Then tail that log group
```
If you see `Exec format error`, the binary arch is wrong — apply the emergency fix above and then persist via CFN.
