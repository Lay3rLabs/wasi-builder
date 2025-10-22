#!/usr/bin/env bash
set -euo pipefail

# Set fixed locale for reproducible builds
export LC_ALL=C
export LANG=C

# Ensure deterministic file permissions inside the container
umask "${UMASK:-022}"

# Production-ready WASI component builder
# Exit codes:
# 1 - Usage error
# 2 - Configuration error
# 3 - Build error
# 4 - Artifact error
# 5 - Environment error

# Logging functions
log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $*" >&2
}


# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        log_error "Build failed with exit code $exit_code"
    fi
    exit $exit_code
}

trap cleanup EXIT

# Show usage information
show_usage() {
    cat >&2 << EOF
usage: entrypoint [--debug]

Builds WASI components from Rust source code.

Arguments:
  --debug                            Build in debug mode (default: release)
  --help                             Show this help message


Examples:
  entrypoint
  entrypoint --debug

The builder will automatically detect and build:
- Single components
- Cargo workspaces
- Mixed projects with multiple components

All compiled .wasm files will be collected in the output directory.

EOF
}

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    show_usage
    exit 0
fi

# Default configuration
MODE="release"
OUT_DIR="output"

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "${1:-}" in
        --debug)
            MODE="debug"; shift ;;
        *)
            log_error "unknown argument: $1"
            show_usage
            exit 2 ;;
    esac
done

# Check dependencies and environment
check_environment() {

    # Check if required tools are available
    if ! command -v cargo >/dev/null 2>&1; then
        log_error "cargo is not installed or not in PATH"
        exit 5
    fi

    if ! cargo component --version >/dev/null 2>&1; then
        log_error "cargo-component is not installed. Run: cargo install cargo-component"
        exit 5
    fi

    # Check if /docker directory exists
    if [[ ! -d "/docker" ]]; then
        log_error "/docker directory does not exist. This script must be run in the expected container environment."
        exit 5
    fi

    # Check if there are any Cargo.toml files to build
    if ! find /docker -name "Cargo.toml" -type f | head -1 | grep -q .; then
        log_error "No Cargo.toml files found in /docker directory. Nothing to build."
        exit 2
    fi
}


DOCKER_DIR="/docker"
TARGET_DIR="$DOCKER_DIR/target"
DEST_DIR="$DOCKER_DIR/$OUT_DIR"

# Create output directory with proper permissions
if ! mkdir -p "$DEST_DIR"; then
    log_error "Failed to create output directory: $DEST_DIR"
    exit 2
fi

log_info "Build mode: $MODE"

# Run environment checks
check_environment

# Change to /docker root to build everything found
cd "$DOCKER_DIR"

# Clean target directory for reproducible builds
if [[ -d "$TARGET_DIR" ]]; then
    rm -rf "$TARGET_DIR"
fi

# Ensure reproducible builds with secure defaults
umask 022
export CARGO_BUILD_INCREMENTAL=false
export CARGO_PROFILE_RELEASE_LTO="thin"
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1
export CARGO_PROFILE_RELEASE_PANIC="abort"
export CARGO_PROFILE_RELEASE_STRIP="debuginfo"
export CARGO_PROFILE_RELEASE_DEBUG=false
export CARGO_PROFILE_RELEASE_OPT_LEVEL=3
export CARGO_TARGET_DIR="$TARGET_DIR"

# Find and build only component packages
build_component_packages() {
    local build_args=(--locked)
    if [[ "$MODE" == "release" ]]; then
        build_args+=(--release)
    fi

    declare -A component_packages

    # Find all Cargo.toml files and check for component metadata
    while IFS= read -r -d '' cargo_toml; do
        # Check if this package has component metadata
        if grep -q '^[[:space:]]*\[package\.metadata\.component\]' "$cargo_toml" 2>/dev/null; then
            local package_name=$(grep '^name = ' "$cargo_toml" | sed 's/name = "\(.*\)"/\1/' | head -1)
            if [[ -n "$package_name" && -z "${component_packages[$package_name]:-}" ]]; then
                component_packages[$package_name]="-p"
                log_info "Found component package: $package_name"
            fi
        fi
    done < <(find /docker -name "Cargo.toml" -type f -print0 | sort -z)

    if [[ ${#component_packages[@]} -eq 0 ]]; then
        log_error "No component packages found in workspace"
        exit 2
    fi

    log_info "Building ${#component_packages[@]} component package(s)"

    # Convert array to build arguments
    local package_build_args=()
    for package_name in "${!component_packages[@]}"; do
        package_build_args+=("-p" "$package_name")
    done

    if ! cargo component build "${build_args[@]}" "${package_build_args[@]}"; then
        log_error "Build failed"
        exit 3
    fi
}

# Build the components
build_component_packages

log_info "Build completed successfully"

# Copy resulting wasm(s) to the repo output folder
ART_DIR="$TARGET_DIR/wasm32-wasip1/$MODE"

if [[ ! -d "$ART_DIR" ]]; then
    log_error "Artifacts directory not found: $ART_DIR"
    exit 4
fi

copy_artifacts() {
    local art_dir="$1"
    local dest_dir="$2"
    local files_copied=0

    log_info "Copying all WASM artifacts"
    local wasm_files=()
    while IFS= read -r -d '' file; do
        wasm_files+=("$file")
    done < <(find "$art_dir" -maxdepth 1 -type f -name '*.wasm' -print0)

    if [[ ${#wasm_files[@]} -eq 0 ]]; then
        log_warn "No WASM files found in: $art_dir"
    fi

    for file in "${wasm_files[@]}"; do
        local filename=$(basename "$file")
        log_info "Copying artifact: $filename"
        if cp -f "$file" "$dest_dir/"; then
            if chmod 0644 "$dest_dir/$filename"; then
                ((files_copied++))
            else
                log_warn "Failed to set permissions for: $filename"
                # Still count as success since file was copied
                ((files_copied++))
            fi
        else
            log_error "Failed to copy artifact: $filename"
            exit 4
        fi
    done

    printf '%s\n' "$files_copied"
}

# Copy artifacts and count them
copied_count=$(copy_artifacts "$ART_DIR" "$DEST_DIR")

if ! [[ "$copied_count" =~ ^[0-9]+$ ]]; then
    log_error "Failed to determine number of copied artifacts"
    exit 4
fi

if [[ $copied_count -gt 0 ]]; then
    log_info "Successfully copied $copied_count artifact(s) to: $DEST_DIR"
else
    log_warn "No artifacts were copied"
fi

verify_output() {
    local dest_dir="$1"

    local total_size=0
    local file_count=0

    # Check if any WASM files exist first
    local wasm_files
    wasm_files=$(find "$dest_dir" -maxdepth 1 -type f -name '*.wasm' | head -1)
    if [[ -z "$wasm_files" ]]; then
        log_error "No WASM files found in output directory after successful build"
        exit 4
    fi

    while IFS= read -r -d '' file; do
        local size=0
        # Try different stat syntaxes
        if command -v stat >/dev/null 2>&1; then
            if stat -c%s "$file" >/dev/null 2>&1; then
                size=$(stat -c%s "$file" 2>/dev/null)
            elif stat -f%z "$file" >/dev/null 2>&1; then
                size=$(stat -f%z "$file" 2>/dev/null)
            fi
        fi

        # Ensure size is numeric
        if [[ ! "$size" =~ ^[0-9]+$ ]]; then
            size=0
        fi

        total_size=$((total_size + size))
        file_count=$((file_count + 1))
        log_info "Final artifact: $file ($size bytes)"
    done < <(find "$dest_dir" -maxdepth 1 -type f -name '*.wasm' -print0)

    if [[ $file_count -gt 0 ]]; then
        log_info "Total: $file_count artifacts, $total_size bytes"
    fi
}

# Verify output
verify_output "$DEST_DIR"

# Fix ownership of generated files for host user access
if [[ -n "${HOST_UID:-}" ]] && [[ -n "${HOST_GID:-}" ]]; then
    find /docker \( -type f -o -type d \) -user root -exec chown "$HOST_UID:$HOST_GID" {} +
fi

log_info "Build process completed successfully"
exit 0
