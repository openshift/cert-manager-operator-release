#!/usr/bin/env bash
#
# test-upgrade-paths.sh - Test operator upgrades from production catalog to staged Konflux index.
#
# For each discoverable upgrade path, this script:
#   1. Installs the operator from the production redhat-operators catalog
#   2. Verifies the installation succeeds
#   3. Swaps the catalog to a staged Konflux index image
#   4. Verifies OLM resolves and applies the upgrade
#   5. Validates operand health and basic cert issuance
#
# Usage:
#   export KUBECONFIG=/path/to/kubeconfig
#   ./hack/test-upgrade-paths.sh --ocp-version 4.22 --channel stable-v1.19
#
# Optional:
#   --staged-index-image <IMAGE>  Override auto-derived Konflux index image
#   --from-version 1.19.1         Test only this upgrade path (for debugging)
#   --operator-package <name>     OLM package name (default: openshift-cert-manager-operator)
#   --timeout <seconds>           Timeout for waiting on resources (default: 600)
#   --no-cleanup                  Skip cleanup (for debugging)
#   --skip-auth-setup             Skip registry auth + IDMS setup

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

STAGED_INDEX_IMAGE=""
CHANNEL=""
OCP_VERSION=""
CATALOG_DIR=""
FROM_VERSION=""
OPERATOR_PACKAGE="openshift-cert-manager-operator"
TIMEOUT=600
NO_CLEANUP="false"
SKIP_AUTH_SETUP="false"
NAMESPACE="cert-manager-operator"
CSV_PREFIX=""

PASS_COUNT=0
FAIL_COUNT=0
RESULTS=()

usage() {
    cat <<EOF
Usage: $0 --ocp-version <VERSION> --channel <CHANNEL>

Required:
  --ocp-version          OCP version (e.g. 4.22)
  --channel              OLM channel to test (e.g. stable-v1.19)

Optional:
  --staged-index-image   Override auto-derived Konflux index image URL
  --catalog-dir          Override auto-derived catalog directory path
  --from-version         Test only this specific "from" version (e.g. 1.19.1)
  --operator-package     OLM package name (default: openshift-cert-manager-operator)
  --timeout              Timeout in seconds for resource waits (default: 600)
  --no-cleanup           Skip cleanup after each path (for debugging)
  --skip-auth-setup      Skip registry auth + IDMS setup (use if already configured)

Environment:
  KUBECONFIG             Must be set to a valid cluster kubeconfig
  REVISION               Git commit SHA override (set by Prow CI; otherwise uses HEAD)
EOF
    exit 1
}

log_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}[PASS]${NC} $1"
    RESULTS+=("[PASS] $1")
}

log_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}[FAIL]${NC} $1"
    RESULTS+=("[FAIL] $1")
}

log_info() {
    echo -e "[INFO] $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --staged-index-image) STAGED_INDEX_IMAGE="$2"; shift 2 ;;
            --ocp-version) OCP_VERSION="$2"; shift 2 ;;
            --channel) CHANNEL="$2"; shift 2 ;;
            --catalog-dir) CATALOG_DIR="$2"; shift 2 ;;
            --from-version) FROM_VERSION="$2"; shift 2 ;;
            --operator-package) OPERATOR_PACKAGE="$2"; shift 2 ;;
            --timeout) TIMEOUT="$2"; shift 2 ;;
            --no-cleanup) NO_CLEANUP="true"; shift ;;
            --skip-auth-setup) SKIP_AUTH_SETUP="true"; shift ;;
            -h|--help) usage ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    [[ -z "$OCP_VERSION" && -z "$CATALOG_DIR" ]] && { echo "Error: --ocp-version is required"; usage; }
    [[ -z "$CHANNEL" ]] && { echo "Error: --channel is required"; usage; }

    # Derive catalog-dir from ocp-version if not provided explicitly
    if [[ -z "$CATALOG_DIR" ]]; then
        CATALOG_DIR="${REPO_ROOT}/catalogs/v${OCP_VERSION}/catalog/openshift-cert-manager-operator"
    fi

    if [[ ! -d "$CATALOG_DIR" ]]; then
        echo "Error: Catalog directory not found: ${CATALOG_DIR}"
        exit 1
    fi

    # Derive OCP_VERSION from catalog-dir if provided via --catalog-dir
    if [[ -z "$OCP_VERSION" ]]; then
        OCP_VERSION=$(echo "$CATALOG_DIR" | grep -oP 'v\K[0-9]+\.[0-9]+' | head -1)
    fi
}

resolve_staged_index_image() {
    if [[ -n "$STAGED_INDEX_IMAGE" ]]; then
        log_info "Using provided staged index image: ${STAGED_INDEX_IMAGE}"
        return
    fi

    log_info "Auto-deriving staged index image..."

    local ocp_tag
    ocp_tag=$(echo "$OCP_VERSION" | tr '.' '-')

    # Get commit SHA: REVISION env (Prow CI) > origin/main HEAD > git HEAD
    # Konflux builds from main, so prefer origin/main over local HEAD
    local sha=""
    if [[ -n "${REVISION:-}" ]]; then
        sha="$REVISION"
        log_info "Using REVISION env var: ${sha}"
    elif sha=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null); then
        log_info "Using origin/main: ${sha}"
    elif sha=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null); then
        log_info "Using git HEAD: ${sha}"
    else
        echo "Error: Could not determine commit SHA. Set REVISION env var or run from a git checkout."
        exit 1
    fi

    STAGED_INDEX_IMAGE="quay.io/redhat-user-workloads/cert-manager-oape-tenant/cert-manager-operator-${ocp_tag}/cert-manager-operator-index-${ocp_tag}:${sha}"
    log_info "Derived staged index image: ${STAGED_INDEX_IMAGE}"
}

check_prerequisites() {
    local ok="true"

    if [[ -z "${KUBECONFIG:-}" ]]; then
        echo "Error: KUBECONFIG environment variable must be set"
        ok="false"
    fi

    if ! command -v oc >/dev/null 2>&1; then
        echo "Error: 'oc' CLI not found in PATH"
        ok="false"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "Error: 'python3' not found in PATH"
        ok="false"
    fi

    local channel_file="${CATALOG_DIR}/channel.yaml"
    if [[ ! -f "$channel_file" ]]; then
        # Try relative to repo root
        channel_file="${REPO_ROOT}/${CATALOG_DIR}/channel.yaml"
        if [[ ! -f "$channel_file" ]]; then
            echo "Error: channel.yaml not found at ${CATALOG_DIR}/channel.yaml"
            ok="false"
        else
            CATALOG_DIR="${REPO_ROOT}/${CATALOG_DIR}"
        fi
    fi

    if [[ "$ok" == "false" ]]; then
        exit 1
    fi

    # Verify cluster connectivity
    if ! oc whoami >/dev/null 2>&1; then
        echo "Error: Cannot connect to cluster. Check KUBECONFIG."
        exit 1
    fi
    log_info "Connected to cluster as: $(oc whoami)"
}

# Discover upgrade paths by parsing channel.yaml
discover_upgrade_paths() {
    local channel_file="${CATALOG_DIR}/channel.yaml"
    log_info "Parsing ${channel_file} for channel '${CHANNEL}'..."

    local paths
    paths=$(python3 -c "
import yaml, sys

channel_file = '${channel_file}'
target_channel = '${CHANNEL}'

with open(channel_file) as f:
    docs = list(yaml.safe_load_all(f))

for doc in docs:
    if not doc or doc.get('name') != target_channel:
        continue

    entries = doc.get('entries', [])
    if not entries:
        print('ERROR: no entries in channel', file=sys.stderr)
        sys.exit(1)

    # Find the latest entry (last one in the list is typically the head)
    head = entries[-1]
    head_name = head['name']  # e.g. cert-manager-operator.v1.19.2
    head_version = head_name.split('.v')[-1]

    # Collect from-versions: replaces + skips
    from_versions = []
    replaces = head.get('replaces', '')
    if replaces:
        from_versions.append(replaces.split('.v')[-1])
    for skip in head.get('skips', []):
        from_versions.append(skip.split('.v')[-1])

    # Output: TARGET_VERSION followed by FROM versions, one per line
    print(f'TARGET={head_version}')
    # Also output the CSV name prefix (e.g. 'cert-manager-operator')
    csv_prefix = head_name.rsplit('.v', 1)[0]
    print(f'CSV_PREFIX={csv_prefix}')
    for v in from_versions:
        print(f'FROM={v}')
    sys.exit(0)

print('ERROR: channel not found', file=sys.stderr)
sys.exit(1)
" 2>&1)

    if echo "$paths" | grep -q "^ERROR:"; then
        echo "Error: Failed to parse channel: $paths"
        exit 1
    fi

    TARGET_VERSION=$(echo "$paths" | grep "^TARGET=" | cut -d= -f2)
    CSV_PREFIX=$(echo "$paths" | grep "^CSV_PREFIX=" | cut -d= -f2)
    mapfile -t FROM_VERSIONS < <(echo "$paths" | grep "^FROM=" | cut -d= -f2)

    if [[ -z "$TARGET_VERSION" ]]; then
        echo "Error: Could not determine target version from channel"
        exit 1
    fi

    log_info "Target version: ${TARGET_VERSION}"
    log_info "Discoverable upgrade paths: ${FROM_VERSIONS[*]}"

    # Filter if --from-version specified
    if [[ -n "$FROM_VERSION" ]]; then
        FROM_VERSIONS=("$FROM_VERSION")
        log_info "Filtered to single path: ${FROM_VERSION} -> ${TARGET_VERSION}"
    fi
}

# Inject stage registry auth if running in CI
setup_registry_auth() {
    if [[ "$SKIP_AUTH_SETUP" == "true" ]]; then
        log_info "Auth setup skipped (--skip-auth-setup)"
        return
    fi

    # Check if cluster already has stage registry auth
    local has_stage_auth
    has_stage_auth=$(oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | \
        base64 -d | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'registry.stage.redhat.io' in d.get('auths',{}) else 'no')" 2>/dev/null || echo "no")

    if [[ "$has_stage_auth" == "yes" ]]; then
        log_info "Cluster already has registry.stage.redhat.io auth, skipping injection"
        return
    fi

    local vault_path="/var/run/vault/mirror-registry"
    if [[ -d "$vault_path" ]]; then
        # CI path: use vault-mounted credentials
        log_info "CI environment detected, injecting stage registry auth..."
        local registry_auth="${vault_path}/registry_stage.json"
        if [[ -f "$registry_auth" ]]; then
            oc extract secret/pull-secret -n openshift-config --confirm --to /tmp/ps-extract
            local stage_user stage_pass stage_b64
            stage_user=$(python3 -c "import json; print(json.load(open('${registry_auth}')).get('user',''))" 2>/dev/null || echo "")
            stage_pass=$(python3 -c "import json; print(json.load(open('${registry_auth}')).get('password',''))" 2>/dev/null || echo "")
            if [[ -n "$stage_user" && -n "$stage_pass" ]]; then
                stage_b64=$(echo -n "${stage_user}:${stage_pass}" | base64 -w 0)
                python3 -c "
import json
with open('/tmp/ps-extract/.dockerconfigjson') as f:
    d = json.load(f)
d.setdefault('auths',{})['registry.stage.redhat.io'] = {'auth': '${stage_b64}'}
with open('/tmp/ps-extract/merged.json','w') as f:
    json.dump(d, f)
"
                oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/ps-extract/merged.json
                log_info "Stage registry auth injected"
            fi
        fi
    else
        # Local path: try merging from ~/.docker/config.json
        log_info "No vault credentials; attempting to merge from local Docker config..."
        local local_docker_cfg=""
        for cfg in "$HOME/.docker/config.json" "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json" "$HOME/.config/containers/auth.json"; do
            if [[ -f "$cfg" ]]; then
                local_docker_cfg="$cfg"
                break
            fi
        done

        if [[ -z "$local_docker_cfg" ]]; then
            log_warn "No local Docker config found. Stage registry auth must be configured manually."
            log_warn "Use --skip-auth-setup if auth is already on the cluster."
            return
        fi

        local has_local_stage
        has_local_stage=$(python3 -c "import json; d=json.load(open('${local_docker_cfg}')); print('yes' if 'registry.stage.redhat.io' in d.get('auths',{}) else 'no')" 2>/dev/null || echo "no")
        if [[ "$has_local_stage" != "yes" ]]; then
            log_warn "Local Docker config does not have registry.stage.redhat.io auth."
            log_warn "Log in with: podman login registry.stage.redhat.io"
            return
        fi

        oc extract secret/pull-secret -n openshift-config --confirm --to /tmp/ps-extract
        python3 -c "
import json
with open('/tmp/ps-extract/.dockerconfigjson') as f:
    cluster = json.load(f)
with open('${local_docker_cfg}') as f:
    local_cfg = json.load(f)
stage = local_cfg.get('auths',{}).get('registry.stage.redhat.io')
if stage:
    cluster.setdefault('auths',{})['registry.stage.redhat.io'] = stage
with open('/tmp/ps-extract/merged.json','w') as f:
    json.dump(cluster, f)
"
        oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/ps-extract/merged.json
        log_info "Stage registry auth merged from local config"
    fi

    # Create ImageDigestMirrorSet if not present
    if ! oc get imagedigestmirrorset stage-registry >/dev/null 2>&1; then
        log_info "Creating ImageDigestMirrorSet for registry.stage.redhat.io..."
        cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: stage-registry
spec:
  imageDigestMirrors:
  - mirrors:
    - registry.stage.redhat.io
    source: registry.redhat.io
EOF
    else
        log_info "ImageDigestMirrorSet 'stage-registry' already exists"
    fi

    # Wait for MCP rollout
    log_info "Waiting for MachineConfigPool rollout..."
    local mcp_deadline=$((SECONDS + 600))
    sleep 15
    while [[ $SECONDS -lt $mcp_deadline ]]; do
        local total updated
        total=$(oc get mcp worker -o jsonpath='{.status.machineCount}' 2>/dev/null || echo "0")
        updated=$(oc get mcp worker -o jsonpath='{.status.updatedMachineCount}' 2>/dev/null || echo "0")
        if [[ "$total" -gt 0 && "$updated" == "$total" ]]; then
            log_info "MCP rollout complete (${updated}/${total} workers updated)"
            return
        fi
        log_info "  MCP rollout in progress (${updated}/${total})..."
        sleep 20
    done
    log_warn "MCP rollout did not complete within 600s; continuing anyway"
}

# Install operator at a specific version from the default catalog
install_from_prod() {
    local version="$1"
    local csv_name="${CSV_PREFIX}.v${version}"
    log_info "Installing ${csv_name} from redhat-operators..."

    # Determine the correct channel for the "from" version.
    # If the from-version's major.minor differs from the target channel, use stable-v1
    # (which contains all versions) instead of the target channel.
    local install_channel="$CHANNEL"
    local target_minor
    target_minor=$(echo "$CHANNEL" | grep -oP '[0-9]+\.[0-9]+' || echo "")
    local from_minor
    from_minor=$(echo "$version" | cut -d. -f1-2)
    if [[ -n "$target_minor" && "$from_minor" != "$target_minor" ]]; then
        install_channel="stable-v1"
        log_info "Cross-channel install: using channel '${install_channel}' for v${version} (target channel: ${CHANNEL})"
    fi

    # Ensure namespace exists
    oc get namespace "$NAMESPACE" >/dev/null 2>&1 || \
        oc create namespace "$NAMESPACE"

    # Create OperatorGroup if not present
    if ! oc get operatorgroup -n "$NAMESPACE" 2>/dev/null | grep -q .; then
        cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
EOF
    fi

    # Create Subscription with manual approval and specific starting CSV
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${OPERATOR_PACKAGE}
  namespace: ${NAMESPACE}
spec:
  channel: ${install_channel}
  installPlanApproval: Manual
  name: ${OPERATOR_PACKAGE}
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: ${csv_name}
EOF

    # Wait for InstallPlan
    log_info "Waiting for InstallPlan..."
    local deadline=$((SECONDS + TIMEOUT))
    local ip_name=""
    while [[ $SECONDS -lt $deadline ]]; do
        ip_name=$(oc get installplan -n "$NAMESPACE" -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' 2>/dev/null | awk '{print $1}')
        if [[ -n "$ip_name" ]]; then
            break
        fi
        sleep 5
    done

    if [[ -z "$ip_name" ]]; then
        log_fail "Install: No InstallPlan found for ${csv_name} within ${TIMEOUT}s"
        log_info "Diagnostic: subscription status:"
        oc get subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null | \
            python3 -c "import json,sys; [print(f\"  {c['type']}: {c['status']} - {c.get('reason','')} {c.get('message','')[:200]}\") for c in json.loads(sys.stdin.read() or '[]')]" 2>/dev/null || true
        oc get events -n "$NAMESPACE" --sort-by='.lastTimestamp' 2>/dev/null | tail -10 || true
        return 1
    fi

    # Approve the install plan
    oc patch installplan "$ip_name" -n "$NAMESPACE" --type merge -p '{"spec":{"approved":true}}'
    log_info "Approved InstallPlan: ${ip_name}"

    # Wait for CSV to succeed
    if ! wait_for_csv "$csv_name"; then
        log_fail "Install: CSV ${csv_name} did not reach Succeeded"
        return 1
    fi

    log_pass "Installed ${csv_name} from production catalog"
    return 0
}

# Wait for a CSV to reach Succeeded phase
wait_for_csv() {
    local csv_name="$1"
    local deadline=$((SECONDS + TIMEOUT))
    log_info "Waiting for CSV ${csv_name} to succeed..."

    while [[ $SECONDS -lt $deadline ]]; do
        local phase
        phase=$(oc get csv "$csv_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
        if [[ "$phase" == "Succeeded" ]]; then
            return 0
        elif [[ "$phase" == "Failed" ]]; then
            log_info "CSV ${csv_name} phase: Failed"
            oc get csv "$csv_name" -n "$NAMESPACE" -o jsonpath='{.status.message}' 2>/dev/null || true
            return 1
        fi
        sleep 10
    done

    log_info "Timeout waiting for CSV ${csv_name} (last phase: $(oc get csv "$csv_name" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo 'unknown'))"
    return 1
}

# Swap from default catalog to staged index
swap_to_staged_catalog() {
    local staged_catalog_name="cert-manager-staged"

    # Create the staged CatalogSource FIRST (must be READY before subscription change)
    log_info "Creating staged CatalogSource from ${STAGED_INDEX_IMAGE}..."
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${staged_catalog_name}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${STAGED_INDEX_IMAGE}
  displayName: Cert-Manager Staged
  publisher: Red Hat (staging)
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

    # Wait for CatalogSource to be ready
    local deadline=$((SECONDS + 120))
    while [[ $SECONDS -lt $deadline ]]; do
        local state
        state=$(oc get catalogsource "${staged_catalog_name}" -n openshift-marketplace -o jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")
        if [[ "$state" == "READY" ]]; then
            log_info "Staged CatalogSource is READY"
            break
        fi
        sleep 5
    done

    if [[ "$state" != "READY" ]]; then
        log_fail "Staged CatalogSource did not become READY within 120s"
        return 1
    fi

    # NOW patch subscription to point to the staged catalog (source swap only)
    log_info "Patching subscription source to ${staged_catalog_name}..."
    oc patch subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" --type merge \
        -p "{\"spec\":{\"source\":\"${staged_catalog_name}\",\"channel\":\"${CHANNEL}\"}}"

    # Also remove startingCSV if present (allows OLM to resolve to head)
    oc patch subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" --type json \
        -p '[{"op": "remove", "path": "/spec/startingCSV"}]' 2>/dev/null || true

    log_info "Subscription source swapped to staged catalog (channel: ${CHANNEL})"

    # Delete stale InstallPlans from the previous catalog so OLM re-resolves
    local stale_plans
    stale_plans=$(oc get installplan -n "$NAMESPACE" -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$stale_plans" ]]; then
        log_info "Deleting stale unapproved InstallPlans: ${stale_plans}"
        for plan in $stale_plans; do
            oc delete installplan "$plan" -n "$NAMESPACE" 2>/dev/null || true
        done
    fi

    return 0
}

# Wait for upgrade InstallPlan and approve it
approve_upgrade() {
    local target_csv="${CSV_PREFIX}.v${TARGET_VERSION}"
    log_info "Waiting for upgrade InstallPlan to ${target_csv}..."

    local deadline=$((SECONDS + TIMEOUT))
    local ip_name=""
    while [[ $SECONDS -lt $deadline ]]; do
        # Find unapproved install plan that references the target CSV
        ip_name=$(oc get installplan -n "$NAMESPACE" -o json 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data.get('items', []):
    if item['spec'].get('approved', True):
        continue
    csvs = item['spec'].get('clusterServiceVersionNames', [])
    if '${target_csv}' in csvs:
        print(item['metadata']['name'])
        break
" 2>/dev/null || echo "")

        if [[ -n "$ip_name" ]]; then
            break
        fi
        sleep 10
    done

    if [[ -z "$ip_name" ]]; then
        log_fail "Upgrade: No InstallPlan found for ${target_csv} within ${TIMEOUT}s"
        log_info "Diagnostic: subscription status:"
        oc get subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" -o jsonpath='{.status.conditions}' 2>/dev/null | \
            python3 -c "import json,sys; [print(f\"  {c['type']}: {c['status']} - {c.get('reason','')} {c.get('message','')[:200]}\") for c in json.loads(sys.stdin.read() or '[]')]" 2>/dev/null || true
        log_info "Diagnostic: install plans:"
        oc get installplan -n "$NAMESPACE" -o wide 2>/dev/null || true
        return 1
    fi

    oc patch installplan "$ip_name" -n "$NAMESPACE" --type merge -p '{"spec":{"approved":true}}'
    log_info "Approved upgrade InstallPlan: ${ip_name}"

    if ! wait_for_csv "$target_csv"; then
        log_fail "Upgrade: CSV ${target_csv} did not reach Succeeded"
        return 1
    fi

    log_pass "Upgraded to ${target_csv}"
    return 0
}

# Verify operands are healthy
verify_operands() {
    log_info "Verifying operand health..."

    local deployments=("cert-manager" "cert-manager-cainjector" "cert-manager-webhook")
    local cert_manager_ns="cert-manager"

    local deadline=$((SECONDS + 120))
    for dep in "${deployments[@]}"; do
        while [[ $SECONDS -lt $deadline ]]; do
            local ready
            ready=$(oc get deployment "$dep" -n "$cert_manager_ns" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
            if [[ "${ready:-0}" -ge 1 ]]; then
                log_pass "Operand ${dep}: ready (${ready} replicas)"
                break
            fi
            sleep 5
        done

        if [[ "${ready:-0}" -lt 1 ]]; then
            log_fail "Operand ${dep}: not ready within timeout"
        fi
    done
}

# Basic cert issuance smoke test
smoke_test_cert_issuance() {
    local test_ns="cert-manager-test-$$"
    log_info "Running cert issuance smoke test in namespace ${test_ns}..."

    oc create namespace "$test_ns" 2>/dev/null || true

    # Create a self-signed Issuer
    cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata:
  name: selfsigned-issuer
  namespace: ${test_ns}
spec:
  selfSigned: {}
EOF

    # Create a Certificate
    cat <<EOF | oc apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: test-cert
  namespace: ${test_ns}
spec:
  secretName: test-cert-tls
  duration: 2160h
  renewBefore: 360h
  issuerRef:
    name: selfsigned-issuer
    kind: Issuer
  dnsNames:
  - test.example.com
EOF

    # Wait for certificate to be Ready
    local deadline=$((SECONDS + 60))
    while [[ $SECONDS -lt $deadline ]]; do
        local ready
        ready=$(oc get certificate test-cert -n "$test_ns" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$ready" == "True" ]]; then
            log_pass "Smoke test: Certificate issued successfully"
            oc delete namespace "$test_ns" --wait=false 2>/dev/null || true
            return 0
        fi
        sleep 3
    done

    log_fail "Smoke test: Certificate did not become Ready within 60s"
    oc get certificate test-cert -n "$test_ns" -o yaml 2>/dev/null || true
    oc delete namespace "$test_ns" --wait=false 2>/dev/null || true
    return 1
}

# Clean up all operator resources
cleanup() {
    if [[ "$NO_CLEANUP" == "true" ]]; then
        log_info "Cleanup skipped (--no-cleanup)"
        return
    fi

    log_info "Cleaning up resources..."

    # Delete subscription
    oc delete subscription "$OPERATOR_PACKAGE" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

    # Delete CSVs
    oc delete csv --all -n "$NAMESPACE" 2>/dev/null || true

    # Delete install plans
    oc delete installplan --all -n "$NAMESPACE" 2>/dev/null || true

    # Delete staged CatalogSource
    oc delete catalogsource cert-manager-staged -n openshift-marketplace --ignore-not-found 2>/dev/null || true

    # Delete OperatorGroup
    oc delete operatorgroup cert-manager-operator -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

    # Wait for operand namespace cleanup
    local deadline=$((SECONDS + 60))
    while [[ $SECONDS -lt $deadline ]]; do
        local pods
        pods=$(oc get pods -n cert-manager --no-headers 2>/dev/null | wc -l)
        if [[ "$pods" -eq 0 ]]; then
            break
        fi
        sleep 5
    done

    log_info "Cleanup complete"
}

# Test a single upgrade path
test_upgrade_path() {
    local from_version="$1"
    log_info "============================================"
    log_info "Testing upgrade path: v${from_version} -> v${TARGET_VERSION}"
    log_info "============================================"

    # Step 1: Install from prod
    if ! install_from_prod "$from_version"; then
        cleanup
        return 1
    fi

    # Step 2: Verify initial operands
    verify_operands

    # Step 3: Swap to staged catalog
    if ! swap_to_staged_catalog; then
        cleanup
        return 1
    fi

    # Step 4: Approve upgrade and wait
    if ! approve_upgrade; then
        cleanup
        return 1
    fi

    # Step 5: Verify post-upgrade operands
    verify_operands

    # Step 6: Smoke test
    smoke_test_cert_issuance

    # Step 7: Cleanup
    cleanup
    return 0
}

# Print summary
print_summary() {
    echo ""
    log_info "============================================"
    log_info "UPGRADE TEST SUMMARY"
    log_info "============================================"

    for result in "${RESULTS[@]}"; do
        echo "  $result"
    done

    echo ""
    echo "Total: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    echo ""

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}UPGRADE TESTS FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}ALL UPGRADE TESTS PASSED${NC}"
        return 0
    fi
}

main() {
    parse_args "$@"
    resolve_staged_index_image
    check_prerequisites
    setup_registry_auth
    discover_upgrade_paths

    if [[ ${#FROM_VERSIONS[@]} -eq 0 ]]; then
        echo "Error: No upgrade paths discovered"
        exit 1
    fi

    # Guard: skip paths where from == target (stale channel.yaml)
    local valid_from=()
    for from_ver in "${FROM_VERSIONS[@]}"; do
        if [[ "$from_ver" == "$TARGET_VERSION" ]]; then
            log_warn "Skipping path v${from_ver} -> v${TARGET_VERSION} (from == target; channel.yaml may be stale)"
        else
            valid_from+=("$from_ver")
        fi
    done

    # Filter out versions not present in any channel in the local catalog
    local all_catalog_versions
    all_catalog_versions=$(python3 -c "
import yaml, sys
with open('${CATALOG_DIR}/channel.yaml') as f:
    docs = list(yaml.safe_load_all(f))
versions = set()
for doc in docs:
    if doc:
        for entry in doc.get('entries', []):
            name = entry.get('name', '')
            # Entry names are like 'cert-manager-operator.vX.Y.Z'
            if '.v' in name:
                versions.add(name.split('.v', 1)[1])
for v in sorted(versions):
    print(v)
" 2>/dev/null || echo "")

    if [[ -n "$all_catalog_versions" ]]; then
        local installable_from=()
        for from_ver in "${valid_from[@]}"; do
            if echo "$all_catalog_versions" | grep -q "^${from_ver}$"; then
                installable_from+=("$from_ver")
            else
                log_warn "Skipping path v${from_ver} -> v${TARGET_VERSION} (v${from_ver} not in OCP ${OCP_VERSION} catalog)"
            fi
        done
        valid_from=("${installable_from[@]+"${installable_from[@]}"}")
    fi

    if [[ ${#valid_from[@]} -eq 0 ]]; then
        log_warn "No valid upgrade paths after filtering. Check that the production catalog contains installable from-versions."
        exit 1
    fi

    log_info "Testable upgrade paths: ${valid_from[*]}"

    local total_paths=${#valid_from[@]}
    local path_idx=0
    for from_ver in "${valid_from[@]}"; do
        path_idx=$((path_idx + 1))
        # Always cleanup between paths; only skip cleanup on the very last path if --no-cleanup
        if [[ $path_idx -lt $total_paths ]]; then
            local saved_no_cleanup="$NO_CLEANUP"
            NO_CLEANUP="false"
            test_upgrade_path "$from_ver"
            NO_CLEANUP="$saved_no_cleanup"
        else
            test_upgrade_path "$from_ver"
        fi
    done

    print_summary
    exit $FAIL_COUNT
}

main "$@"
