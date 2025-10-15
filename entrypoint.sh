#!/usr/bin/env bash
set -euo pipefail

# Set fixed locale for reproducible builds
export LC_ALL=C
export LANG=C

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

# Validate input arguments
validate_input() {
    local component_dir="$1"

    if [[ -z "$component_dir" ]]; then
        log_error "Component directory cannot be empty"
        exit 1
    fi

    # Check for path traversal attempts
    if [[ "$component_dir" == *".."* ]]; then
        log_error "Path traversal detected in component directory: $component_dir"
        exit 2
    fi

    # Check for absolute paths (should be relative)
    if [[ "$component_dir" == /* ]]; then
        log_error "Component directory must be relative path: $component_dir"
        exit 2
    fi
}

show_usage() {
    cat >&2 << EOF
usage: entrypoint <relative-path-to-component-crate> --out-dir PATH [--debug]

Builds WASI components from Rust source code.

Arguments:
  <relative-path-to-component-crate>  Path to the component crate directory (relative to /docker)
  --out-dir PATH                     Output directory for built artifacts
  --debug                            Build in debug mode (default: release)
  --help                             Show this help message


Examples:
  entrypoint my-component --out-dir ./build
  entrypoint my-component --out-dir ./build --debug
  entrypoint my-component --out-dir /absolute/path

EOF
}

if [ $# -lt 1 ]; then
    show_usage
    exit 1
fi

if [[ "${1:-}" == "--help" ]] || [[ "${1:-}" == "-h" ]]; then
    show_usage
    exit 0
fi

validate_input "$1"

COMPONENT_DIR="$1"
MODE="release"
OUT_DIR=""
shift || true

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

    # Check if component directory exists
    local component_path="/docker/$COMPONENT_DIR"
    if [[ ! -d "$component_path" ]]; then
        log_error "Component directory does not exist: $component_path"
        exit 2
    fi

    # Check if Cargo.toml exists in component directory
    if [[ ! -f "$component_path/Cargo.toml" ]]; then
        log_error "Cargo.toml not found in component directory: $component_path"
        exit 2
    fi
}

while [ $# -gt 0 ]; do
    case "${1:-}" in
        --debug)
            MODE="debug"; shift ;;
        --out-dir)
            if [ $# -lt 2 ]; then
                log_error "--out-dir requires a value"
                exit 2
            fi
            OUT_DIR="$2"; shift 2 ;;
        *)
            log_error "unknown argument: $1"
            show_usage
            exit 2 ;;
    esac
done

if [ -z "$OUT_DIR" ]; then
    log_error "--out-dir is required"
    show_usage
    exit 2
fi

# Validate output directory
validate_output_dir() {
    local out_dir="$1"

    # Check for path traversal in output directory
    if [[ "$out_dir" == *".."* ]]; then
        log_error "Path traversal detected in output directory: $out_dir"
        exit 2
    fi
}

validate_output_dir "$OUT_DIR"

DOCKER_DIR="/docker"
TARGET_DIR="$DOCKER_DIR/target"

if [[ "$OUT_DIR" = /* ]]; then
    DEST_DIR="$OUT_DIR"
else
    DEST_DIR="$DOCKER_DIR/$OUT_DIR"
fi

# Create output directory with proper permissions
if ! mkdir -p "$DEST_DIR"; then
    log_error "Failed to create output directory: $DEST_DIR"
    exit 2
fi

log_info "Building component: $COMPONENT_DIR"
log_info "Build mode: $MODE"
log_info "Output directory: $DEST_DIR"
log_info "Target directory: $TARGET_DIR"

# Run environment checks
check_environment

cd "$DOCKER_DIR/$COMPONENT_DIR"

# Clean target directory for reproducible builds
log_info "Cleaning target directory: $TARGET_DIR"
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

# Build the component
log_info "Starting cargo component build in $MODE mode"

build_args=(--locked)
if [[ "$MODE" == "release" ]]; then
    build_args+=(--release)
elif [[ "$MODE" != "debug" ]]; then
    log_warn "Unknown build mode '$MODE'; defaulting to debug build"
fi

if ! cargo component build "${build_args[@]}"; then
    log_error "Build failed for component: $COMPONENT_DIR"
    exit 3
fi

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
    while IFS= read -r -d '' file; do
        local size
        size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
        total_size=$((total_size + size))
        ((file_count++))
        log_info "Final artifact: $file ($size bytes)"
    done < <(find "$dest_dir" -maxdepth 1 -type f -name '*.wasm' -print0)

    if [[ $file_count -gt 0 ]]; then
        log_info "Total: $file_count artifacts, $total_size bytes"
    fi
}

# Verify output
verify_output "$DEST_DIR"

log_info "Build process completed successfully"
