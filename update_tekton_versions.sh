#!/bin/bash

# Script to update Tekton pipeline files with new version numbers
# This script renames files from old version pattern to new version pattern
# and updates all version references within the files

set -euo pipefail

# Default values
TEKTON_DIR=".tekton"
DRY_RUN=false

# Version inputs
CERT_MANAGER_OPERATOR_VERSION=""
CERT_MANAGER_ISTIO_CSR_VERSION=""
JETSTACK_CERT_MANAGER_VERSION=""

# Function to display usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

This script updates Tekton pipeline files to use new version numbers.
It renames files and updates version references within the files.

OPTIONS:
    -o, --operator-version VERSION      cert-manager-operator version (e.g., v1.18.0)
    -i, --istio-csr-version VERSION     cert-manager-istio-csr version (e.g., v0.14.2)
    -j, --jetstack-version VERSION      jetstack-cert-manager version (e.g., v1.18.2)
    -d, --tekton-dir DIR               Tekton directory path (default: .tekton)
    --dry-run                          Show what would be done without making changes
    -h, --help                         Display this help message

EXAMPLES:
    # Update all components with specific versions
    $0 -o v1.18.0 -i v0.14.2 -j v1.18.2

    # Update only cert-manager-operator files
    $0 -o v1.18.0

    # Dry run to see what would be changed
    $0 --dry-run -o v1.18.0 -i v0.14.2 -j v1.18.2

SPECIAL BEHAVIOR:
    For cert-manager-istio-csr files:
    - RELEASE_VERSION uses the istio-csr version (e.g., v0.14.2)
    - File names and other version references follow standard pattern (1-17 → 1-18)

EOF
}

# Function to extract version parts
extract_version_parts() {
    local version="$1"
    # Remove 'v' prefix if present
    version="${version#v}"
    
    # Extract major.minor (e.g., "1.18" from "1.18.0")
    local major_minor=$(echo "$version" | cut -d'.' -f1,2)
    
    # Convert dots to dashes for filename (e.g., "1-18" from "1.18")
    local dash_version=$(echo "$major_minor" | tr '.' '-')
    
    echo "$major_minor $dash_version"
}

# Function to find current version pattern in existing files
find_current_version_pattern() {
    local file_prefix="$1"
    local tekton_dir="$2"
    
    # Look for existing files with this prefix
    local existing_files=$(find "$tekton_dir" -name "${file_prefix}-*" -type f 2>/dev/null | head -1)
    
    if [[ -n "$existing_files" ]]; then
        # Extract version pattern from filename (e.g., "1-17" from "cert-manager-operator-1-17-push.yaml")
        local filename=$(basename "$existing_files")
        # Use a more specific regex to extract version pattern
        local version_pattern=$(echo "$filename" | sed -E "s/.*-([0-9]+-[0-9]+)-(push|pull-request)\.yaml/\1/")
        
        if [[ "$version_pattern" =~ ^[0-9]+-[0-9]+$ ]]; then
            echo "$version_pattern"
        fi
    fi
}

# Function to update file content
update_file_content() {
    local file_path="$1"
    local old_version_dash="$2"
    local new_version_dash="$3"
    local old_version_dot="$4"
    local new_version_dot="$5"
    local release_version="$6"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [DRY RUN] Would update content in: $file_path"
        return
    fi
    
    # Create temporary file
    local temp_file=$(mktemp)
    
    # Update all version references in the file
    sed -e "s/${old_version_dash}/${new_version_dash}/g" \
        -e "s/${old_version_dot}/${new_version_dot}/g" \
        -e "s/release-${old_version_dot}/release-${new_version_dot}/g" \
        -e "s/RELEASE_VERSION=v[^\"]*\"/RELEASE_VERSION=${release_version}\"/g" \
        -e "s/RELEASE_VERSION=v[^ ]*/RELEASE_VERSION=${release_version}/g" \
        "$file_path" > "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$file_path"
    echo "  Updated content in: $file_path"
}

# Function to process component files
process_component_files() {
    local component="$1"
    local new_release_version="$2"
    local tekton_dir="$3"
    local target_file_version="${4:-}"  # Optional: for cases where file version differs from release version
    
    echo "Processing $component files..."
    
    # Find current version pattern
    local current_version_dash=$(find_current_version_pattern "$component" "$tekton_dir")
    
    if [[ -z "$current_version_dash" ]]; then
        echo "  No existing files found for component: $component"
        return
    fi
    
    echo "  Found current version pattern: $current_version_dash"
    
    # Determine which version to use for file/path updates
    local version_for_files="$new_release_version"
    if [[ -n "$target_file_version" ]]; then
        version_for_files="$target_file_version"
    fi
    
    # Extract new version parts for file/path naming
    local version_parts=($(extract_version_parts "$version_for_files"))
    local new_version_dot="${version_parts[0]}"
    local new_version_dash="${version_parts[1]}"
    
    echo "  New file version will be: $new_version_dot (dash format: $new_version_dash)"
    echo "  Release version will be: $new_release_version"
    
    # Convert dash version back to dot version for old version
    local old_version_dot=$(echo "$current_version_dash" | tr '-' '.')
    
    # Check if we're already at the target version
    if [[ "$current_version_dash" == "$new_version_dash" ]]; then
        # Still need to check if RELEASE_VERSION needs updating
        local files=$(find "$tekton_dir" -name "${component}-${current_version_dash}-*" -type f 2>/dev/null)
        local needs_release_update=false
        
        if [[ -n "$files" ]]; then
            for file in $files; do
                if ! grep -q "RELEASE_VERSION=${new_release_version}" "$file" 2>/dev/null; then
                    needs_release_update=true
                    break
                fi
            done
        fi
        
        if [[ "$needs_release_update" == "false" ]]; then
            echo "  Already at target version ($new_version_dash) with correct RELEASE_VERSION ($new_release_version)"
            echo "  Completed processing $component files"
            echo
            return
        else
            echo "  Already at target file version ($new_version_dash) but RELEASE_VERSION needs updating"
        fi
    fi
    
    # Find all files for this component
    local files=$(find "$tekton_dir" -name "${component}-${current_version_dash}-*" -type f 2>/dev/null)
    
    if [[ -z "$files" ]]; then
        echo "  No files found matching pattern: ${component}-${current_version_dash}-*"
        return
    fi
    
    # Process each file
    for file in $files; do
        local filename=$(basename "$file")
        local new_filename=$(echo "$filename" | sed "s/${current_version_dash}/${new_version_dash}/g")
        local new_file_path="$tekton_dir/$new_filename"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            echo "  [DRY RUN] Would rename: $filename -> $new_filename"
            echo "  [DRY RUN] Would update version references: $old_version_dot -> $new_version_dot"
            echo "  [DRY RUN] Would update release version to: $new_release_version"
        else
            # Update file content first
            update_file_content "$file" "$current_version_dash" "$new_version_dash" \
                              "$old_version_dot" "$new_version_dot" "$new_release_version"
            
            # Rename file if name has changed
            if [[ "$file" != "$new_file_path" ]]; then
                mv "$file" "$new_file_path"
                echo "  Renamed: $filename -> $new_filename"
            fi
        fi
    done
    
    echo "  Completed processing $component files"
    echo
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -o|--operator-version)
            CERT_MANAGER_OPERATOR_VERSION="$2"
            shift 2
            ;;
        -i|--istio-csr-version)
            CERT_MANAGER_ISTIO_CSR_VERSION="$2"
            shift 2
            ;;
        -j|--jetstack-version)
            JETSTACK_CERT_MANAGER_VERSION="$2"
            shift 2
            ;;
        -d|--tekton-dir)
            TEKTON_DIR="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate inputs
if [[ -z "$CERT_MANAGER_OPERATOR_VERSION" && -z "$CERT_MANAGER_ISTIO_CSR_VERSION" && -z "$JETSTACK_CERT_MANAGER_VERSION" ]]; then
    echo "Error: At least one version must be specified"
    usage
    exit 1
fi

# Check if tekton directory exists
if [[ ! -d "$TEKTON_DIR" ]]; then
    echo "Error: Tekton directory does not exist: $TEKTON_DIR"
    exit 1
fi

echo "Starting Tekton version update..."
echo "Tekton directory: $TEKTON_DIR"
echo "Dry run mode: $DRY_RUN"
echo

# Process each component if version is provided
if [[ -n "$CERT_MANAGER_OPERATOR_VERSION" ]]; then
    process_component_files "cert-manager-operator" "$CERT_MANAGER_OPERATOR_VERSION" "$TEKTON_DIR"
    process_component_files "cert-manager-operator-bundle" "$CERT_MANAGER_OPERATOR_VERSION" "$TEKTON_DIR"
fi

if [[ -n "$CERT_MANAGER_ISTIO_CSR_VERSION" ]]; then
    # For istio-csr: use the istio-csr version for RELEASE_VERSION, but use standard versioning for files/paths
    # Extract the target file version from the operator version or use a default pattern
    default_file_version="v1.18.0"  # This should match the general release pattern
    if [[ -n "$CERT_MANAGER_OPERATOR_VERSION" ]]; then
        # Use the same version pattern as the operator for file naming
        operator_parts=($(extract_version_parts "$CERT_MANAGER_OPERATOR_VERSION"))
        default_file_version="v${operator_parts[0]}.0"
    elif [[ -n "$JETSTACK_CERT_MANAGER_VERSION" ]]; then
        # Use the same version pattern as jetstack cert-manager for file naming
        jetstack_parts=($(extract_version_parts "$JETSTACK_CERT_MANAGER_VERSION"))
        default_file_version="v${jetstack_parts[0]}.0"
    fi
    process_component_files "cert-manager-istio-csr" "$CERT_MANAGER_ISTIO_CSR_VERSION" "$TEKTON_DIR" "$default_file_version"
fi

if [[ -n "$JETSTACK_CERT_MANAGER_VERSION" ]]; then
    process_component_files "jetstack-cert-manager" "$JETSTACK_CERT_MANAGER_VERSION" "$TEKTON_DIR"
    process_component_files "jetstack-cert-manager-acmesolver" "$JETSTACK_CERT_MANAGER_VERSION" "$TEKTON_DIR"
fi

if [[ "$DRY_RUN" == "true" ]]; then
    echo "Dry run completed. No files were modified."
else
    echo "Version update completed successfully!"
fi

echo "Summary: All specified components are now at their target versions."