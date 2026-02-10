# FIPS Pipeline Guide

This document describes how to run and manage the FIPS cflinuxfs5 pipeline, including all quirks and special considerations.

## Overview

The FIPS pipeline builds and tests a FIPS-compliant version of cflinuxfs5. It runs separately from the normal cflinuxfs5 pipeline to avoid interference and uses isolated infrastructure.

## Branch Structure

- **fips branch**: Contains FIPS-specific pipeline code. FIPS workflows should be triggered from this branch.
- **main branch**: Contains normal (non-FIPS) pipeline code.

Both branches should have DNS management fixes synchronized.

## Running the FIPS Pipeline

### Trigger the Build Workflow

The build workflow creates the FIPS rootfs image and uploads artifacts to S3:

```bash
gh workflow run build_rootfs.yml \
  --ref fips \
  -f trigger_reason="FIPS build" \
  -f fips_mode="fips" \
  -f fips_method="source" \
  --repo ivo1116/cflinuxfs5-release-develop
```

This workflow:
1. Checks for new CVEs
2. Bumps golang package if needed
3. Builds the FIPS-compliant rootfs Docker image
4. Creates the BOSH release
5. Uploads stack tarball, receipt, and BOSH release to S3
6. Automatically dispatches the test workflow on success

### Trigger the Test Workflow

```bash
gh workflow run test_rootfs.yml \
  --ref fips \
  -f version="1.0.0-rc.1" \
  -f fips_mode="fips" \
  -f skip_cleanup=true \
  -f skip_setup=false \
  -f skip_deploy=false \
  -f skip_cats=false \
  --repo ivo1116/cflinuxfs5-release-develop
```

### Key Parameters

| Parameter | Description | FIPS Value |
|-----------|-------------|------------|
| `--ref` | Branch to run from | `fips` |
| `fips_mode` | Enable FIPS mode | `fips` |
| `fips_method` | FIPS build method | `source` or `ubuntu-pro` |
| `skip_cleanup` | Keep infrastructure after run | `true` (recommended during testing) |
| `skip_setup` | Skip BBL up | `false` for first run, `true` if env exists |
| `skip_deploy` | Skip CF deployment | `false` |
| `skip_cats` | Skip acceptance tests | `false` |

## Infrastructure Separation

The FIPS pipeline uses completely separate infrastructure from the normal pipeline:

| Resource | Normal Pipeline | FIPS Pipeline |
|----------|-----------------|---------------|
| BBL State Directory | `bbl-state/cflinuxfs5/` | `bbl-state/cflinuxfs5-fips/` |
| System Domain | `cf.gcp.cfrt-sof.sapcloud.io` | `fips-cf.gcp.cfrt-sof.sapcloud.io` |
| Stack Name | `cflinuxfs5` | `cflinuxfs5-fips` |
| Environment Name | `cflinuxfs5` | `cflinuxfs5-fips` |

## DNS Configuration (Important!)

### The Problem

When BBL creates a new environment with domain `fips-cf.gcp.cfrt-sof.sapcloud.io`, it creates a **child DNS zone** with its own nameservers. However, this zone is not reachable unless there's an NS delegation record in the **parent zone** (`gcp-zone`).

### The Solution

The pipeline includes automatic DNS management:

1. **On BBL up**: The `manage-gcp-dns` action adds NS records to the parent zone pointing to the child zone's nameservers
2. **On BBL destroy**: The `manage-gcp-dns` action removes the NS records from the parent zone

### Required Repository Variable

Ensure `GCP_DNS_ZONE_NAME` is set in repository variables:

```bash
gh variable set GCP_DNS_ZONE_NAME --body "gcp-zone" --repo ivo1116/cflinuxfs5-release-develop
```

### Manual DNS Verification

If DNS issues occur, verify the delegation:

```bash
# Check parent zone for NS delegation
gcloud dns record-sets list --zone=gcp-zone --filter="fips-cf.gcp.cfrt-sof.sapcloud.io"

# Check child zone nameservers
gcloud dns managed-zones describe bbl-env-<name>-zone --format="value(nameServers)"

# Test DNS resolution
host api.fips-cf.gcp.cfrt-sof.sapcloud.io
```

## Common Issues and Quirks

### 1. DNS Resolution Failure in CATs

**Symptom**: CATs fail with `no such host` error for `api.fips-cf.gcp.cfrt-sof.sapcloud.io`

**Cause**: NS delegation not configured in parent zone

**Fix**: 
- Ensure `GCP_DNS_ZONE_NAME` variable is set
- Re-run BBL up to trigger DNS management
- Or manually add NS records to parent zone

### 2. Terraform Missing in DNS Management

**Symptom**: `bbl lbs --json` fails with "missing terraform"

**Cause**: The `manage-gcp-dns` action needs terraform to read BBL state

**Fix**: Ensure the action includes terraform installation (should be automatic in latest code)

### 3. Empty BBL State Directory

**Symptom**: DNS management fails because BBL state directory is empty

**Cause**: Environment was previously destroyed

**Fix**: Run with `skip_setup=false` to recreate the environment

### 4. Workflow Uses Wrong Branch Code

**Symptom**: Workflow runs with old code even after pushing fixes

**Cause**: Workflow was queued before the push

**Fix**: Cancel the workflow and trigger a new one after pushing

### 5. Both Pipelines Running Simultaneously

The FIPS and normal pipelines can run simultaneously without interference because they use separate:
- BBL state directories
- DNS domains
- GCP resources (VMs, load balancers, etc.)

However, they share:
- The same GCP project
- The same repository secrets
- The same GitHub Actions runners

## Workflow Jobs

The FIPS test workflow includes these jobs:

1. **Resolve Inputs**: Computes effective stack, env_name, and domain based on `fips_mode`
2. **Setup Test Environment**: Runs BBL up + DNS delegation
3. **Deploy CF with New Rootfs**: Deploys Cloud Foundry with FIPS rootfs
4. **Run CATs**: Runs Cloud Foundry Acceptance Tests
5. **Check Race Conditions**: Ensures no newer version is being tested
6. **Cleanup Deployments**: Cleans up CF deployments (if `skip_cleanup=false`)
7. **Destroy Test Environment**: Runs BBL destroy + DNS cleanup (if `skip_cleanup=false`)
8. **Trigger Release Workflow**: Triggers release if tests pass

## Monitoring Workflows

```bash
# List recent runs
gh run list --workflow test_rootfs.yml --repo ivo1116/cflinuxfs5-release-develop

# Watch a specific run
gh run watch <run-id> --repo ivo1116/cflinuxfs5-release-develop

# View failed logs
gh run view <run-id> --log-failed --repo ivo1116/cflinuxfs5-release-develop

# Check job status
gh run view <run-id> --json jobs --jq '.jobs[] | {name: .name, status: .status, conclusion: .conclusion}'
```

## Keeping Branches in Sync

When making infrastructure changes (like DNS management), ensure both branches have the fixes:

```bash
# On main branch
git checkout main
# make changes, commit, push

# Cherry-pick to fips branch
git checkout fips
git cherry-pick <commit-hash>
git push origin fips
```

## Environment Lifecycle

### First Time Setup

```bash
gh workflow run test_rootfs.yml --ref fips \
  -f version="1.0.0-rc.1" \
  -f fips_mode="fips" \
  -f skip_cleanup=true \
  -f skip_setup=false \
  -f skip_deploy=false \
  -f skip_cats=false
```

### Subsequent Runs (Environment Exists)

```bash
gh workflow run test_rootfs.yml --ref fips \
  -f version="1.0.0-rc.2" \
  -f fips_mode="fips" \
  -f skip_cleanup=true \
  -f skip_setup=true \
  -f skip_deploy=false \
  -f skip_cats=false
```

### Cleanup (Destroy Environment)

```bash
gh workflow run test_rootfs.yml --ref fips \
  -f version="1.0.0-rc.1" \
  -f fips_mode="fips" \
  -f skip_cleanup=false \
  -f skip_setup=true \
  -f skip_deploy=true \
  -f skip_cats=true
```

## Files Related to FIPS

- `.github/workflows/build_rootfs.yml` - FIPS build workflow (builds rootfs and uploads to S3)
- `.github/workflows/test_rootfs.yml` - FIPS test workflow (deploys CF and runs CATs)
- `.github/actions/build-and-process-rootfs/action.yml` - Composite action for building rootfs
- `.github/actions/upload-s3/action.yml` - S3 upload action
- `.github/actions/bbl-up/action.yml` - BBL up with DNS management
- `.github/actions/bbl-destroy/action.yml` - BBL destroy with DNS cleanup
- `.github/actions/manage-gcp-dns/action.yml` - DNS management action
- `.github/scripts/manage-gcp-dns.sh` - DNS management script
