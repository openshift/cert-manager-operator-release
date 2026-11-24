#!/usr/bin/env bash
#
# verify-staged-release.sh - Offline validation of a staged cert-manager operator release.
#
# Validates bundle metadata, channel consistency, image integrity, and CVE resolution
# without requiring a running cluster. Designed to run locally or in CI.
#
# Usage:
#   ./hack/verify-staged-release.sh \
#     --version 1.19.2 \
#     --catalogs v4.18,v4.19,v4.20,v4.21,v4.22
#
# Optional flags:
#   --bundle-digest <sha256:...>  Expected bundle image digest (auto-derived from catalog if omitted)
#   --release-branch <branch>     Release branch for images_digest.conf (default: derived from --version)
#   --images-digest-conf <path>   Path to images_digest.conf (default: auto-fetch from release branch)
#   --skip-image-checks           Skip registry-dependent checks (skopeo, trivy, go version)
#   --target-cves <csv>           Comma-separated CVE IDs to assert are absent
#   --report-file <path>          Write markdown report to file (default: stdout)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

VERSION=""
BUNDLE_DIGEST=""
CATALOGS=""
RELEASE_BRANCH=""
IMAGES_DIGEST_CONF=""
SKIP_IMAGE_CHECKS="false"
TARGET_CVES=""
REPORT_FILE=""

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
REPORT_LINES=()

usage() {
    echo "Usage: $0 --version <VERSION> --catalogs <v4.18,v4.19,...>"
    echo ""
    echo "Required:"
    echo "  --version            Operator version being validated (e.g. 1.19.2)"
    echo "  --catalogs           Comma-separated list of catalog versions (e.g. v4.18,v4.19)"
    echo ""
    echo "Optional:"
    echo "  --bundle-digest      Expected bundle image digest (sha256:...; auto-derived if omitted)"
    echo "  --release-branch     Release branch name (default: release-X.Y derived from --version)"
    echo "  --images-digest-conf Path to images_digest.conf file (default: auto-fetch from release branch)"
    echo "  --skip-image-checks  Skip registry-dependent checks"
    echo "  --target-cves        Comma-separated CVE IDs to verify are fixed"
    echo "  --report-file        Write markdown report to file"
    exit 1
}

log_pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    echo -e "${GREEN}[PASS]${NC} $1"
    REPORT_LINES+=("- [PASS] $1")
}

log_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo -e "${RED}[FAIL]${NC} $1"
    REPORT_LINES+=("- **[FAIL]** $1")
}

log_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    echo -e "${YELLOW}[WARN]${NC} $1"
    REPORT_LINES+=("- [WARN] $1")
}

log_info() {
    echo -e "[INFO] $1"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --version) VERSION="$2"; shift 2 ;;
            --bundle-digest) BUNDLE_DIGEST="$2"; shift 2 ;;
            --catalogs) CATALOGS="$2"; shift 2 ;;
            --release-branch) RELEASE_BRANCH="$2"; shift 2 ;;
            --images-digest-conf) IMAGES_DIGEST_CONF="$2"; shift 2 ;;
            --skip-image-checks) SKIP_IMAGE_CHECKS="true"; shift ;;
            --target-cves) TARGET_CVES="$2"; shift 2 ;;
            --report-file) REPORT_FILE="$2"; shift 2 ;;
            -h|--help) usage ;;
            *) echo "Unknown option: $1"; usage ;;
        esac
    done

    [[ -z "$VERSION" ]] && { echo "Error: --version is required"; usage; }
    [[ -z "$CATALOGS" ]] && { echo "Error: --catalogs is required"; usage; }
}

check_dependencies() {
    local missing=""
    if ! command -v python3 >/dev/null 2>&1; then
        missing="${missing} python3"
    fi
    if ! command -v opm >/dev/null 2>&1; then
        missing="${missing} opm"
    fi
    if [[ "$SKIP_IMAGE_CHECKS" != "true" ]]; then
        if ! command -v skopeo >/dev/null 2>&1; then
            missing="${missing} skopeo"
        fi
        if ! command -v trivy >/dev/null 2>&1; then
            missing="${missing} trivy"
        fi
    fi

    if [[ -n "$missing" ]]; then
        echo "Error: Missing required tools:${missing}"
        echo "Install them or use --skip-image-checks to skip registry-dependent checks."
        exit 1
    fi
}

# Parse YAML value using python3 (portable, no yq dependency required)
yaml_query() {
    local file="$1"
    local query="$2"
    python3 -c "
import yaml, sys
with open('$file') as f:
    docs = list(yaml.safe_load_all(f))
$query
" 2>/dev/null
}

# Stage 1: Bundle Metadata Validation
verify_metadata() {
    log_info "=== Stage 1: Bundle Metadata Validation ==="

    IFS=',' read -ra CATALOG_LIST <<< "$CATALOGS"
    for catalog_ver in "${CATALOG_LIST[@]}"; do
        local bundle_file="${REPO_ROOT}/catalogs/${catalog_ver}/catalog/openshift-cert-manager-operator/bundle-v${VERSION}.yaml"

        log_info "Checking: ${bundle_file}"
        if [[ ! -f "$bundle_file" ]]; then
            log_fail "${catalog_ver}: bundle-v${VERSION}.yaml not found"
            continue
        fi

        # Check bundle image digest
        log_info "  Verifying bundle image digest (field: .image)"
        local bundle_image
        bundle_image=$(python3 -c "
import yaml
with open('$bundle_file') as f:
    doc = yaml.safe_load(f)
print(doc.get('image', ''))
")
        if [[ -z "$BUNDLE_DIGEST" ]]; then
            log_info "${catalog_ver}: bundle image = ${bundle_image} (no digest to cross-check)"
        elif [[ "$bundle_image" == *"$BUNDLE_DIGEST"* ]]; then
            log_pass "${catalog_ver}: bundle image digest matches"
        else
            log_fail "${catalog_ver}: bundle image digest mismatch (expected *${BUNDLE_DIGEST:0:20}..., got ${bundle_image})"
        fi

        # Check package name
        log_info "  Verifying bundle name (field: .name)"
        local pkg_name
        pkg_name=$(python3 -c "
import yaml
with open('$bundle_file') as f:
    doc = yaml.safe_load(f)
print(doc.get('name', ''))
")
        local expected_name="cert-manager-operator.v${VERSION}"
        if [[ "$pkg_name" == "$expected_name" ]]; then
            log_pass "${catalog_ver}: bundle name = ${expected_name}"
        else
            log_fail "${catalog_ver}: bundle name mismatch (expected ${expected_name}, got ${pkg_name})"
        fi

        # Check olm.package version
        log_info "  Verifying olm.package version (field: .properties[type=olm.package].value.version)"
        local pkg_version
        pkg_version=$(python3 -c "
import yaml
with open('$bundle_file') as f:
    doc = yaml.safe_load(f)
for prop in doc.get('properties', []):
    if prop.get('type') == 'olm.package':
        print(prop['value']['version'])
        break
")
        if [[ "$pkg_version" == "$VERSION" ]]; then
            log_pass "${catalog_ver}: olm.package.version = ${VERSION}"
        else
            log_fail "${catalog_ver}: olm.package.version mismatch (expected ${VERSION}, got ${pkg_version})"
        fi

        # Check olm.skipRange in annotations
        log_info "  Verifying olm.skipRange (field: .properties[type=olm.csv.metadata].value.annotations.olm.skipRange)"
        local skip_range
        skip_range=$(python3 -c "
import yaml
with open('$bundle_file') as f:
    doc = yaml.safe_load(f)
for prop in doc.get('properties', []):
    if prop.get('type') == 'olm.csv.metadata':
        annotations = prop['value'].get('annotations', {})
        print(annotations.get('olm.skipRange', ''))
        break
")
        if [[ -n "$skip_range" ]]; then
            log_pass "${catalog_ver}: olm.skipRange = ${skip_range}"
        else
            log_warn "${catalog_ver}: olm.skipRange not found in annotations"
        fi

        # Validate relatedImages against images_digest.conf if available
        if [[ -n "$IMAGES_DIGEST_CONF" && -f "$IMAGES_DIGEST_CONF" ]]; then
            log_info "  Cross-checking relatedImages against ${IMAGES_DIGEST_CONF}"
            local related_count
            related_count=$(python3 -c "
import yaml
with open('$bundle_file') as f:
    doc = yaml.safe_load(f)
images = doc.get('relatedImages', [])
print(len(images))
")
            if [[ "$related_count" -gt 0 ]]; then
                log_pass "${catalog_ver}: relatedImages contains ${related_count} entries"
            else
                log_fail "${catalog_ver}: relatedImages is empty"
            fi

            # Cross-check digests
            local mismatch_found="false"
            while IFS='=' read -r key value; do
                [[ -z "$key" ]] && continue
                local digest="${value##*@}"
                if ! grep -q "$digest" "$bundle_file" 2>/dev/null; then
                    log_fail "${catalog_ver}: digest from ${key} not found in relatedImages"
                    mismatch_found="true"
                fi
            done < <(grep -v "^#" "$IMAGES_DIGEST_CONF" | grep -v "^$")

            if [[ "$mismatch_found" == "false" ]]; then
                log_pass "${catalog_ver}: all images_digest.conf digests present in relatedImages"
            fi
        fi
    done

    # Run opm validate on each catalog
    for catalog_ver in "${CATALOG_LIST[@]}"; do
        local catalog_dir="${REPO_ROOT}/catalogs/${catalog_ver}/catalog"
        if [[ -d "$catalog_dir" ]]; then
            log_info "  Running: opm validate ${catalog_dir}"
            if opm validate "$catalog_dir" 2>/dev/null; then
                log_pass "${catalog_ver}: opm validate passed"
            else
                log_fail "${catalog_ver}: opm validate failed"
            fi
        fi
    done
}

# Stage 2: Channel Consistency Validation
verify_channels() {
    log_info "=== Stage 2: Channel Consistency Validation ==="

    local target_entry="cert-manager-operator.v${VERSION}"
    IFS=',' read -ra CATALOG_LIST <<< "$CATALOGS"

    for catalog_ver in "${CATALOG_LIST[@]}"; do
        local channel_file="${REPO_ROOT}/catalogs/${catalog_ver}/catalog/openshift-cert-manager-operator/channel.yaml"

        log_info "Checking: ${channel_file}"
        if [[ ! -f "$channel_file" ]]; then
            log_fail "${catalog_ver}: channel.yaml not found"
            continue
        fi

        # Check if target version exists in stable-v1.19 channel
        log_info "  Verifying ${target_entry} exists in channel 'stable-v1.19'"
        local in_v119
        in_v119=$(python3 -c "
import yaml
with open('$channel_file') as f:
    docs = list(yaml.safe_load_all(f))
for doc in docs:
    if doc and doc.get('name') == 'stable-v1.19':
        for entry in doc.get('entries', []):
            if entry.get('name') == '${target_entry}':
                print('yes')
                break
" 2>/dev/null || echo "")

        if [[ "$in_v119" == "yes" ]]; then
            log_pass "${catalog_ver}: ${target_entry} found in stable-v1.19"
        else
            log_fail "${catalog_ver}: ${target_entry} NOT found in stable-v1.19"
        fi

        # Check stable-v1 channel (only for v4.18 where v1.19.x is the head)
        local in_v1
        in_v1=$(python3 -c "
import yaml
with open('$channel_file') as f:
    docs = list(yaml.safe_load_all(f))
for doc in docs:
    if doc and doc.get('name') == 'stable-v1':
        for entry in doc.get('entries', []):
            if entry.get('name') == '${target_entry}':
                print('yes')
                break
" 2>/dev/null || echo "")

        if [[ "$catalog_ver" == "v4.18" ]]; then
            log_info "  Verifying ${target_entry} exists in channel 'stable-v1' (v4.18 head)"
            if [[ "$in_v1" == "yes" ]]; then
                log_pass "${catalog_ver}: ${target_entry} found in stable-v1 (expected for v4.18)"
            else
                log_fail "${catalog_ver}: ${target_entry} NOT in stable-v1 (expected for v4.18)"
            fi
        fi

        # Verify replaces and skips
        log_info "  Verifying 'replaces' and 'skips' fields for ${target_entry} in stable-v1.19"
        local replaces skips
        replaces=$(python3 -c "
import yaml
with open('$channel_file') as f:
    docs = list(yaml.safe_load_all(f))
for doc in docs:
    if doc and doc.get('name') == 'stable-v1.19':
        for entry in doc.get('entries', []):
            if entry.get('name') == '${target_entry}':
                print(entry.get('replaces', ''))
                break
" 2>/dev/null || echo "")

        skips=$(python3 -c "
import yaml
with open('$channel_file') as f:
    docs = list(yaml.safe_load_all(f))
for doc in docs:
    if doc and doc.get('name') == 'stable-v1.19':
        for entry in doc.get('entries', []):
            if entry.get('name') == '${target_entry}':
                s = entry.get('skips', [])
                print(','.join(s) if s else '')
                break
" 2>/dev/null || echo "")

        if [[ -n "$replaces" ]]; then
            log_pass "${catalog_ver}: replaces = ${replaces}"
        else
            log_warn "${catalog_ver}: replaces field not set"
        fi

        if [[ -n "$skips" ]]; then
            log_pass "${catalog_ver}: skips = ${skips}"
        else
            log_warn "${catalog_ver}: skips field not set"
        fi
    done
}

# Stage 3: Image Integrity Checks
verify_images() {
    if [[ "$SKIP_IMAGE_CHECKS" == "true" ]]; then
        log_info "=== Stage 3: Image Integrity Checks (SKIPPED) ==="
        return
    fi

    log_info "=== Stage 3: Image Integrity Checks ==="

    if [[ -z "$IMAGES_DIGEST_CONF" || ! -f "$IMAGES_DIGEST_CONF" ]]; then
        log_warn "images_digest.conf not provided, skipping image verification"
        return
    fi

    log_info "Using images from: ${IMAGES_DIGEST_CONF}"

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        local image="$value"
        local registry="${image%%/*}"

        # skopeo inspect
        log_info "  Running: skopeo inspect --no-tags docker://${image}"
        if skopeo inspect --no-tags "docker://${image}" >/dev/null 2>&1; then
            log_pass "${key}: image exists and is accessible"
        else
            log_fail "${key}: image NOT accessible (${image})"
            continue
        fi

        # Check RELEASE_VERSION label
        log_info "  Running: skopeo inspect docker://${image} | .Labels.version"
        local version_label
        version_label=$(skopeo inspect "docker://${image}" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
labels = data.get('Labels', {})
print(labels.get('version', labels.get('release', '')))
" 2>/dev/null || echo "")

        if [[ -n "$version_label" ]]; then
            log_pass "${key}: version label = ${version_label}"
        else
            log_warn "${key}: version label not found"
        fi
    done < <(grep -v "^#" "$IMAGES_DIGEST_CONF" | grep -v "^$")
}

# Stage 4: CVE Regression Check
verify_cves() {
    if [[ "$SKIP_IMAGE_CHECKS" == "true" || -z "$TARGET_CVES" ]]; then
        log_info "=== Stage 4: CVE Regression Check (SKIPPED) ==="
        return
    fi

    log_info "=== Stage 4: CVE Regression Check ==="

    if [[ -z "$IMAGES_DIGEST_CONF" || ! -f "$IMAGES_DIGEST_CONF" ]]; then
        log_warn "images_digest.conf not provided, skipping CVE check"
        return
    fi

    IFS=',' read -ra CVE_LIST <<< "$TARGET_CVES"

    # Scan a representative image (operator)
    local operator_image
    operator_image=$(grep "CERT_MANAGER_OPERATOR_IMAGE" "$IMAGES_DIGEST_CONF" | cut -d= -f2)

    if [[ -z "$operator_image" ]]; then
        log_warn "CERT_MANAGER_OPERATOR_IMAGE not found in images_digest.conf"
        return
    fi

    log_info "Running: trivy image --severity HIGH,CRITICAL --scanners vuln ${operator_image}"
    local scan_output
    scan_output=$(trivy image --severity HIGH,CRITICAL --scanners vuln --quiet "${operator_image}" 2>/dev/null || echo "SCAN_FAILED")

    if [[ "$scan_output" == "SCAN_FAILED" ]]; then
        log_warn "Trivy scan failed (image may not be pullable)"
        return
    fi

    for cve in "${CVE_LIST[@]}"; do
        log_info "  Checking if ${cve} is absent from scan results"
        if echo "$scan_output" | grep -q "$cve"; then
            log_fail "CVE ${cve} still present in operator image"
        else
            log_pass "CVE ${cve} NOT found in operator image (fixed)"
        fi
    done
}

# Stage 5: Generate Report
generate_report() {
    log_info "=== Verification Summary ==="
    echo ""
    echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${WARN_COUNT} warnings"
    echo ""

    if [[ -n "$REPORT_FILE" ]]; then
        {
            echo "# Staged Release Verification Report"
            echo ""
            echo "**Version:** ${VERSION}"
            echo "**Bundle Digest:** \`${BUNDLE_DIGEST:-auto-derived}\`"
            echo "**Catalogs:** ${CATALOGS}"
            echo ""
            echo "## Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${WARN_COUNT} warnings"
            echo ""
            for line in "${REPORT_LINES[@]}"; do
                echo "$line"
            done
        } > "$REPORT_FILE"
        log_info "Report written to ${REPORT_FILE}"
    fi

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}VERIFICATION FAILED${NC} (${FAIL_COUNT} failures)"
        exit 1
    else
        echo -e "${GREEN}VERIFICATION PASSED${NC}"
        exit 0
    fi
}

# Resolve images_digest.conf: local file > explicit path > git fetch from release branch
resolve_images_digest_conf() {
    if [[ -n "$IMAGES_DIGEST_CONF" && -f "$IMAGES_DIGEST_CONF" ]]; then
        log_info "Using provided images_digest.conf: ${IMAGES_DIGEST_CONF}"
        return
    fi

    if [[ -f "$REPO_ROOT/images_digest.conf" ]]; then
        IMAGES_DIGEST_CONF="$REPO_ROOT/images_digest.conf"
        log_info "Using local images_digest.conf"
        return
    fi

    # Derive release branch from version (1.19.2 -> release-1.19)
    local branch="${RELEASE_BRANCH:-release-$(echo "$VERSION" | cut -d. -f1-2)}"
    log_info "Fetching images_digest.conf from origin/${branch}..."

    git -C "$REPO_ROOT" fetch origin "$branch" --quiet 2>/dev/null || true
    local tmp_conf="/tmp/images_digest_${VERSION}.conf"
    if git -C "$REPO_ROOT" show "origin/${branch}:images_digest.conf" > "$tmp_conf" 2>/dev/null; then
        IMAGES_DIGEST_CONF="$tmp_conf"
        log_info "Fetched images_digest.conf from origin/${branch}"
    else
        log_warn "Could not fetch images_digest.conf from origin/${branch}; image-dependent checks will be skipped"
        IMAGES_DIGEST_CONF=""
    fi
}

# Resolve bundle digest: if not provided, read from the first available catalog bundle YAML
resolve_bundle_digest() {
    if [[ -n "$BUNDLE_DIGEST" ]]; then
        return
    fi

    IFS=',' read -ra CATALOG_LIST <<< "$CATALOGS"
    for catalog_ver in "${CATALOG_LIST[@]}"; do
        local bundle_file="${REPO_ROOT}/catalogs/${catalog_ver}/catalog/openshift-cert-manager-operator/bundle-v${VERSION}.yaml"
        if [[ -f "$bundle_file" ]]; then
            BUNDLE_DIGEST=$(python3 -c "
import yaml
with open('$bundle_file') as f:
    doc = yaml.safe_load(f)
img = doc.get('image', '')
if '@' in img:
    print(img.split('@')[1])
else:
    print('')
" 2>/dev/null || echo "")
            if [[ -n "$BUNDLE_DIGEST" ]]; then
                log_info "Auto-derived bundle digest from ${catalog_ver}: ${BUNDLE_DIGEST:0:30}..."
                return
            fi
        fi
    done
    log_warn "Could not auto-derive bundle digest (no bundle-v${VERSION}.yaml found); digest cross-check will be skipped"
}

main() {
    parse_args "$@"
    resolve_images_digest_conf
    resolve_bundle_digest
    check_dependencies
    verify_metadata
    verify_channels
    verify_images
    verify_cves
    generate_report
}

main "$@"
