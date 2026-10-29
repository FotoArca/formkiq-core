# FormKIQ Core — FotoArca Fork Deployment Guide

This guide covers building, packaging, and deploying FormKIQ Core from the FotoArca fork: `~/workspace/FotoArca/formkiq-backend` (GitHub `FotoArca/formkiq-core`).

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Prerequisites](#prerequisites)
- [Build Process](#build-process)
- [CI/CD Pipeline (GitHub Actions)](#cicd-pipeline-github-actions)
- [Local Deployment (SAM CLI)](#local-deployment-sam-cli)
- [Updating an Existing CloudFormation Stack](#updating-an-existing-cloudformation-stack)
- [Key Configuration](#key-configuration)
- [Key File Paths](#key-file-paths)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

The deployment pipeline has four stages:

```
Gradle Build         YTT Render            SAM Package           CloudFormation Deploy
─────────────  →  ──────────────────  →  ─────────────────  →  ──────────────────────
Compile Java       Inject version &       Upload Lambda code    Create/update AWS
& GraalVM          hashes into CF         to S3, produce        resources from the
lambdas            templates              final template        packaged template
```

**Key components deployed:**
- Lambda functions (API, S3 event processor, Typesense sync, OCR, API key authorizer)
- DynamoDB tables & S3 buckets (storage layer)
- API Gateway (JWT, IAM, and API key auth variants)
- Cognito user pool
- Optional: VPC, Typesense (Fargate), OpenSearch, Admin Console

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Java JDK | 17 (Temurin) | Compile Lambda functions |
| Gradle | 8.x (wrapper included) | Build system |
| AWS SAM CLI | Latest | Package & deploy CloudFormation |
| AWS CLI | v2 | AWS operations |
| YTT | 0.41.1 | CloudFormation template rendering (downloaded automatically by Gradle) |
| Docker | Latest | GraalVM native image builds (optional, for local native builds) |

**AWS credentials** must be configured via `~/.aws/credentials` or environment variables.

---

## Build Process

### Full Build

```bash
cd ~/workspace/FotoArca/formkiq-backend

# Clean build with all subprojects, tests, and distribution zip
./gradlew clean build
```

This compiles all 42 subprojects (Lambda functions, shared libraries, AWS adapters), runs tests, and produces JARs and GraalVM native images.

**Build time**: ~15–35 minutes depending on hardware (GraalVM native compilation is the bottleneck).

### Distribution Zip

```bash
./gradlew distZip
```

Produces `build/distributions/formkiq-core-{version}.zip` containing:
- All rendered CloudFormation templates (via YTT)
- Lambda deployment packages (GraalVM native images + Java JARs)
- Admin console installer
- VPC and add-on templates
- OpenAPI specifications

### Individual Tasks

| Task | Purpose |
|------|---------|
| `./gradlew build` | Full build + tests |
| `./gradlew distZip` | Package distribution zip |
| `./gradlew yttRenderAll` | Render CloudFormation templates only |
| `./gradlew spotlessCheck` | Check code formatting |
| `./gradlew licenseReport` | Generate license inventory |
| `./gradlew buildOpenApi` | Extract OpenAPI specs from templates |

### Gradle Configuration

Key settings in `gradle.properties`:

```properties
org.gradle.parallel=true
org.gradle.jvmargs=-Xmx6g -XX:+HeapDumpOnOutOfMemoryError
org.gradle.configuration-cache=true
```

The build requires **6 GB heap** (`-Xmx6g`) due to GraalVM native image compilation.

---

## CI/CD Pipeline (GitHub Actions)

### Workflow Overview

```
Push to branch
      │
      ▼
┌─────────────┐     manual trigger     ┌──────────────────┐
│ gradle.yml  │ ──────────────────────► │ deployment.yml   │
│ (Build+Test)│                         │ (Multi-region    │
│             │     manual trigger      │  SAM package)    │
│ Uploads zip │ ──────────────────────► │                  │
│ to S3       │                         │ deployment-dev.  │
└─────────────┘                         │ yml (single      │
                                        │  region)         │
                                        └──────────────────┘
```

### 1. `gradle.yml` — Build & Test

**Trigger**: Push to any branch (automatic)

**What it does**:
1. Sets up Java 17 + downloads YTT v0.41.1
2. Runs `./gradlew build` (compiles, tests, packages)
3. Uploads the distribution zip to S3: `s3://${S3_BUCKET}/formkiq-core/`
4. Publishes test reports as GitHub artifacts (5-day retention)

**Region**: us-east-2

### 2. `deployment.yml` — Multi-Region Production Packaging

**Trigger**: Manual (`workflow_dispatch`), requires version input

**What it does**:
1. Downloads the distribution zip from S3
2. Runs `sam package` for **each target region** (15+ regions)
3. Uploads packaged templates to regional distribution buckets

**Distribution buckets**: `formkiq-core-distribution-{region}`

**Supported regions**: us-east-1, us-east-2, us-west-2, ca-central-1, ca-west-1, eu-central-1, eu-west-1, eu-west-2, eu-west-3, eu-north-1, eu-south-1, ap-south-1, ap-southeast-1, ap-southeast-2, ap-northeast-1, ap-northeast-2, sa-east-1, af-south-1, me-south-1, me-central-1

### 3. `deployment-dev.yml` — Single-Region Dev Packaging

**Trigger**: Manual, requires version + region selection

Same as `deployment.yml` but targets a single region for faster iteration.

### 4. `docker-hub.yml` — Docker Image Build

**Trigger**: Manual, requires version

Builds and pushes multi-arch (amd64/arm64) Docker image `formkiq/api-server:{version}` for the Netty API server.

### Required GitHub Secrets

| Secret | Purpose |
|--------|---------|
| `AWS_ACCESS_KEY_ID` | IAM credentials for S3 upload & SAM packaging |
| `AWS_SECRET_ACCESS_KEY` | IAM credentials |
| `S3_BUCKET` | Artifact staging bucket (e.g., `formkiq-core-artifacts`) |
| `DISTRIBUTION_ID` | CloudFront distribution ID (for cache invalidation) |
| `DOCKER_USERNAME` | Docker Hub credentials (for docker-hub.yml) |
| `DOCKER_PASSWORD` | Docker Hub credentials |

---

## Local Deployment (SAM CLI)

For deploying directly from your machine without going through CI/CD.

### Step 1: Build the Distribution

```bash
cd ~/workspace/FotoArca/formkiq-backend
./gradlew clean build distZip
```

### Step 2: Extract the Distribution

```bash
cd build/distributions
unzip formkiq-core-*.zip
cd formkiq-core-*/
```

### Step 3: SAM Package

Upload Lambda code to S3 and produce a deployable template:

```bash
sam package \
  --template-file template.yaml \
  --s3-bucket YOUR_ARTIFACT_BUCKET \
  --s3-prefix formkiq-core/$(date +%Y%m%d) \
  --region us-east-2 \
  --output-template-file packaged-template.yaml
```

Replace `YOUR_ARTIFACT_BUCKET` with an S3 bucket you own in the target region.

### Step 4: SAM Deploy

```bash
sam deploy \
  --template-file packaged-template.yaml \
  --stack-name formkiq-fotoarca-prod \
  --region us-east-2 \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    AdminEmail=admin@example.com \
    AppEnvironment=prod
```

### One-Liner (Package + Deploy)

```bash
sam package \
  --template-file template.yaml \
  --s3-bucket YOUR_ARTIFACT_BUCKET \
  --s3-prefix formkiq-core \
  --region us-east-2 \
  --output-template-file packaged.yaml \
&& sam deploy \
  --template-file packaged.yaml \
  --stack-name formkiq-fotoarca-prod \
  --region us-east-2 \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    AdminEmail=admin@example.com \
    AppEnvironment=prod
```

---

## Updating an Existing CloudFormation Stack

### Option A: Via SAM CLI (Recommended)

Re-run `sam deploy` with the same stack name. SAM/CloudFormation will create a change set and apply only the differences:

```bash
sam deploy \
  --template-file packaged-template.yaml \
  --stack-name formkiq-fotoarca-prod \
  --region us-east-2 \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM \
  --parameter-overrides \
    AdminEmail=admin@example.com \
    AppEnvironment=prod \
    EnablePublicUrls=true
```

Add `--no-confirm-changeset` to skip the interactive confirmation prompt.

### Option B: Via AWS Console

1. Go to **CloudFormation** → select your stack
2. Click **Update** → **Replace current template**
3. Upload or provide the S3 URL for your packaged template
4. Review/modify parameters
5. Acknowledge IAM capabilities
6. Submit — CloudFormation will execute the change set

### Option C: Via AWS CLI

```bash
aws cloudformation update-stack \
  --stack-name formkiq-fotoarca-prod \
  --template-url https://YOUR_BUCKET.s3.us-east-2.amazonaws.com/packaged-template.yaml \
  --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=AdminEmail,ParameterValue=admin@example.com \
    ParameterKey=AppEnvironment,ParameterValue=prod \
  --region us-east-2
```

### Monitoring Stack Updates

```bash
# Watch update progress
aws cloudformation describe-stack-events \
  --stack-name formkiq-fotoarca-prod \
  --region us-east-2 \
  --query 'StackEvents[0:10].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId]' \
  --output table

# Check stack status
aws cloudformation describe-stacks \
  --stack-name formkiq-fotoarca-prod \
  --region us-east-2 \
  --query 'Stacks[0].StackStatus'
```

---

## Key Configuration

### CloudFormation Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `AdminEmail` | Yes | — | Administrator email for Cognito |
| `AppEnvironment` | Yes | — | Unique environment ID (e.g., `prod`, `staging`) |
| `EnablePublicUrls` | No | `false` | Allow public document submission |
| `VpcStackName` | No | — | Name of VPC stack (required for Typesense) |
| `TypesenseApiKey` | No | — | Typesense search API key |
| `TypesenseMemory` | No | `1024` | Typesense memory (1024–32768 MB) |
| `CapacityProvider` | No | `FARGATE` | ECS capacity: `FARGATE` or `FARGATE_SPOT` |
| `LogRetentionInDays` | No | `90` | CloudWatch log retention (1–3653) |
| `LogFormat` | No | `Text` | Log format: `Text` or `JSON` |
| `LogLevelApplication` | No | `INFO` | App log level: `TRACE`/`DEBUG`/`INFO`/`ERROR` |
| `EnableDeletionProtection` | No | `false` | Prevent accidental stack deletion |
| `PasswordMinimumLength` | No | `8` | Cognito password policy |

### VPC Deployment (Optional)

Deploy VPC first if you need Typesense, OpenSearch, or private networking:

```bash
# Deploy VPC stack
sam deploy \
  --template-file vpc.yaml \
  --stack-name formkiq-vpc-prod \
  --region us-east-2 \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    AppEnvironment=prod

# Then reference it in the main stack
sam deploy \
  --template-file packaged-template.yaml \
  --stack-name formkiq-fotoarca-prod \
  --parameter-overrides \
    AppEnvironment=prod \
    AdminEmail=admin@example.com \
    VpcStackName=formkiq-vpc-prod
```

### Version Management

The version is defined in `build.gradle`:

```groovy
version '1.18.1'
```

Update this before building a new release.

---

## Key File Paths

### Build System

| Path | Purpose |
|------|---------|
| `build.gradle` | Root build config, version number, plugins |
| `settings.gradle` | Subproject declarations (42 modules) |
| `gradle.properties` | JVM args, parallelism, test properties |
| `gradlew` / `gradlew.bat` | Gradle wrapper (no Gradle install needed) |

### CloudFormation Templates

| Path | Purpose |
|------|---------|
| `src/main/resources/cloudformation/template.yaml` | Master/root stack |
| `src/main/resources/cloudformation/api/api-lambda.yaml` | API Lambda + Gateway |
| `src/main/resources/cloudformation/api/api.yaml` | Base API Gateway (JWT) |
| `src/main/resources/cloudformation/api/api-iam.yaml` | IAM auth API |
| `src/main/resources/cloudformation/api/api-apikey.yaml` | API key auth |
| `src/main/resources/cloudformation/storage/template.yaml` | DynamoDB + S3 storage |
| `src/main/resources/cloudformation/typesense/template.yaml` | Typesense (Fargate) |
| `src/main/resources/cloudformation/console/template-install.yaml` | Admin console |
| `src/main/resources/cloudformation/vpc.yaml` | VPC add-on |

### CI/CD Workflows

| Path | Purpose |
|------|---------|
| `.github/workflows/gradle.yml` | Build + test + upload to S3 |
| `.github/workflows/deployment.yml` | Multi-region SAM packaging |
| `.github/workflows/deployment-dev.yml` | Single-region SAM packaging |
| `.github/workflows/docker-hub.yml` | Docker image build + push |

### Lambda Functions

| Path | Purpose |
|------|---------|
| `lambda-api/` | Main REST API (Java) |
| `lambda-api-graalvm/` | GraalVM native image variant |
| `lambda-s3/` | S3 event processor (Java) |
| `lambda-s3-graalvm/` | GraalVM native image variant |
| `lambda-typesense/` | Typesense sync (GraalVM) |
| `lambda-ocr-tesseract/` | OCR processing |
| `lambda-apikey-authorizer/` | API key validation |

### Build Outputs

| Path | Purpose |
|------|---------|
| `build/distributions/formkiq-core-*.zip` | Complete distribution artifact |
| `build/ytt/` | YTT-rendered templates (intermediate) |
| `docs/openapi/` | Generated OpenAPI specifications |

---

## Troubleshooting

### Build fails with OutOfMemoryError

Ensure Gradle has enough heap:
```bash
export GRADLE_OPTS="-Xmx6g"
./gradlew build
```

### SAM package fails with "bucket does not exist"

Create the artifact bucket first:
```bash
aws s3 mb s3://YOUR_ARTIFACT_BUCKET --region us-east-2
```

### CloudFormation stack stuck in `UPDATE_ROLLBACK_FAILED`

```bash
aws cloudformation continue-update-rollback \
  --stack-name formkiq-fotoarca-prod \
  --region us-east-2
```

### Nested stack failures

Check the **nested stack** events (not just the parent). The root cause is usually in a child stack:
```bash
aws cloudformation describe-stack-events \
  --stack-name NESTED_STACK_ID \
  --region us-east-2
```

### Lambda code not updating after deploy

Ensure you ran `sam package` (not just `sam deploy`) — SAM package uploads new Lambda code to S3 and updates the template references. Deploying without re-packaging will use stale Lambda code.
