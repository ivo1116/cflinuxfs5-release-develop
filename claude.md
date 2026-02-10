# cflinuxfs5-release Pipeline Guide

## Overview

This repository contains the CI/CD pipeline for building, testing, and releasing cflinuxfs5 (Cloud Foundry Linux Filesystem based on Ubuntu 24.04 Noble). The pipeline runs on GitHub Actions and deploys test environments on GCP.

## Pipeline Architecture

### Main Workflows

1. **Build Rootfs** (`build-rootfs.yml`) - Builds the cflinuxfs5 Docker image and rootfs tarball
2. **Test Rootfs** (`test-rootfs.yml`) - Deploys CF and runs Cloud Foundry Acceptance Tests (CATs)
3. **Release** (`release.yml`) - Creates BOSH releases and GitHub releases

### Branches

- `main` - Standard cflinuxfs5 pipeline
- `fips` - FIPS-compliant cflinuxfs5 pipeline (separate environment)

## Running the Pipeline

### Manual Dispatch (Test Rootfs)

```bash
# Full run (setup + deploy + cats + cleanup)
gh workflow run "Test Rootfs" --ref main --field version="1.0.0-rc.1"

# Skip environment setup (reuse existing)
gh workflow run "Test Rootfs" --ref main \
  --field skip_setup=true \
  --field version="1.0.0-rc.1"

# Run only CATs (skip setup, deploy, cleanup)
gh workflow run "Test Rootfs" --ref main \
  --field skip_setup=true \
  --field skip_deploy=true \
  --field skip_cleanup=true \
  --field skip_cats=false \
  --field version="1.0.0-rc.1"

# Skip CATs (only deploy)
gh workflow run "Test Rootfs" --ref main \
  --field skip_cats=true \
  --field version="1.0.0-rc.1"
```

### Workflow Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `version` | Required | Version string for the release |
| `skip_setup` | false | Skip BBL environment setup |
| `skip_deploy` | false | Skip CF deployment |
| `skip_cats` | false | Skip Cloud Foundry Acceptance Tests |
| `skip_cleanup` | false | Skip environment cleanup |

## DNS Configuration

The pipeline uses GCP Cloud DNS. If DNS records become stale after infrastructure changes, update them:

```bash
# Get current LB IPs from terraform output in the workflow logs
# Then update DNS records:

gcloud dns record-sets delete "*.cf.gcp.cfrt-sof.sapcloud.io." --zone="gcp-zone" --type="A" --project=sap-gcp-cf-rt-sof-dev3
gcloud dns record-sets delete "ssh.cf.gcp.cfrt-sof.sapcloud.io." --zone="gcp-zone" --type="A" --project=sap-gcp-cf-rt-sof-dev3
gcloud dns record-sets delete "tcp.cf.gcp.cfrt-sof.sapcloud.io." --zone="gcp-zone" --type="A" --project=sap-gcp-cf-rt-sof-dev3

gcloud dns record-sets create "*.cf.gcp.cfrt-sof.sapcloud.io." --zone="gcp-zone" --type="A" --ttl="300" --rrdatas="<ROUTER_LB_IP>" --project=sap-gcp-cf-rt-sof-dev3
gcloud dns record-sets create "ssh.cf.gcp.cfrt-sof.sapcloud.io." --zone="gcp-zone" --type="A" --ttl="300" --rrdatas="<SSH_PROXY_LB_IP>" --project=sap-gcp-cf-rt-sof-dev3
gcloud dns record-sets create "tcp.cf.gcp.cfrt-sof.sapcloud.io." --zone="gcp-zone" --type="A" --ttl="300" --rrdatas="<TCP_ROUTER_LB_IP>" --project=sap-gcp-cf-rt-sof-dev3
```

## Buildpacks

The pipeline uses custom buildpacks compiled for cflinuxfs5 (Ubuntu 24.04). These are required because official CF buildpacks are built for cflinuxfs4 (Ubuntu 22.04).

### Current Buildpacks

| Buildpack | Version | Repository |
|-----------|---------|------------|
| ruby_buildpack | v1.11.06-beta-cflinuxfs5 | [ivanovac/ruby-buildpack](https://github.com/ivanovac/ruby-buildpack) |
| nodejs_buildpack | v1.9.0-beta-cflinuxfs5 | [ivanovac/nodejs-buildpack](https://github.com/ivanovac/nodejs-buildpack) |
| go_buildpack | - | Custom build |
| python_buildpack | - | Custom build |
| staticfile_buildpack | - | Custom build |
| binary_buildpack | - | Official (stack-agnostic) |

### Building Buildpacks for cflinuxfs5

When compiling language runtimes for cflinuxfs5, ensure:

1. **Build inside cflinuxfs5 container** - Ensures correct library linking
2. **Use `--enable-load-relative`** (Ruby) - Makes load paths relocatable
3. **Fix RPATH** - Use `$ORIGIN/../lib` instead of hardcoded paths
4. **Fix shebangs** - Use `#!/usr/bin/env <lang>` instead of hardcoded paths

Example for Ruby:
```bash
docker run -it cloudfoundry/cflinuxfs5 /bin/bash
./configure --prefix=/tmp/ruby-3.2.5 --enable-load-relative
make && make install
# Fix shebangs in bin/*
# Package as tgz
```

## CATs Configuration

Cloud Foundry Acceptance Tests configuration is in `.github/actions/run-cats/action.yml`.

### Enabled Test Groups

- `include_apps: true` - Core app lifecycle tests
- `include_detect: true` - Buildpack detection tests
- `include_routing: true` - HTTP routing tests
- `include_v3: true` - v3 API tests
- `include_tasks: true` - Task execution tests
- `include_security_groups: true` - ASG tests

### Skipped Buildpacks

- `skip_java: true` - No Java buildpack for cflinuxfs5
- `skip_php: true` - No PHP buildpack for cflinuxfs5
- `skip_dotnet: true` - No .NET buildpack for cflinuxfs5

### Expected Results

With current configuration:
- **~100 tests run** out of 277
- **~89 passed** (89% pass rate)
- **~11 failed** (expected - missing Java/PHP/DotNet buildpacks)
- **~175 skipped**

## Troubleshooting

### Common Issues

1. **DNS EOF errors** - DNS records are stale, update with current LB IPs
2. **Buildpack 404** - External URL expired, update buildpack URL in action.yml
3. **Ruby "unable to determine engine"** - Ruby binary has hardcoded paths, needs rebuild with `--enable-load-relative`
4. **GLIBC version errors** - Binary built on wrong OS version, rebuild inside cflinuxfs5 container

### Checking Run Status

```bash
# List recent runs
gh run list --workflow "Test Rootfs" --limit 5

# Watch a run
gh run watch <run_id> --exit-status

# Get CATs results
gh run view <run_id> --log 2>&1 | grep -E "Ran [0-9]+ of|FAIL!|SUCCESS!"

# Check failed logs
gh run view <run_id> --log-failed
```

## Development Guidelines

1. **Test changes on main first** before merging to release branches
2. **Update buildpack URLs** to use GitHub releases (not temporary upload services)
3. **Document DNS changes** - LB IPs change when infrastructure is recreated
4. **Keep FIPS branch separate** - Different environment and configuration
5. **Monitor CATs pass rate** - Regressions indicate buildpack or rootfs issues

## Secrets Required

- `GCP_SERVICE_ACCOUNT_KEY` - GCP service account for BBL/terraform
- `GCP_DNS_SERVICE_ACCOUNT_KEY` - GCP service account for DNS management
- `CFLINUXFS5_LB_CERT` - TLS certificate for load balancer
- `CFLINUXFS5_LB_KEY` - TLS private key for load balancer
- `BBL_STATE_REPO_DEPLOY_KEY` - SSH key for bbl-state repository
