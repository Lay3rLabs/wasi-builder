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

    if [[ -n "${HOST_UID:-}" ]] && [[ -n "${HOST_GID:-}" ]]; then
        log_info "Fixing file permissions before exit"
        find /docker \( -type f -o -type d \) -user root -not -path "/docker/.git/*" -exec chown "$HOST_UID:$HOST_GID" {} + 2>/dev/null || true
    fi

    exit $exit_code
}

trap cleanup EXIT

# Show usage information
show_usage() {
    cat >&2 << EOF
usage: entrypoint [COMPONENT_NAME] [--debug]

Builds WASI components from Rust source code.

Arguments:
  COMPONENT_NAME                     Build only the specified component package name (optional)
  --debug                            Build in debug mode (default: release)
  --help                             Show this help message

Examples:
  entrypoint
  entrypoint --debug
  entrypoint my-component
  entrypoint my-component --debug

The builder will automatically detect and build:
- Single components
- Cargo workspaces
- Mixed projects with multiple components

When COMPONENT_NAME is provided, only the specified component will be built.
If not provided, all component packages found in the workspace will be built.

All compiled .wasm files will be collected in the output directory.

EOF
}


# Default configuration
MODE="release"
OUT_DIR="output"
COMPONENT_NAME=""

declare -a COMPONENT_ORDER=()
declare -A COMPONENT_DIRS=()

# Parse command line arguments
while [ $# -gt 0 ]; do
    case "${1:-}" in
        --debug)
            MODE="debug"; shift ;;
        --help|-h)
            show_usage
            exit 0 ;;
        *)
            if [[ -z "$COMPONENT_NAME" && ! "$1" =~ ^-- ]]; then
                COMPONENT_NAME="$1"
                shift
            else
                log_error "unknown argument: $1"
                show_usage
                exit 2
            fi
            ;;
    esac
done

# Check dependencies and environment
check_environment() {

    # Check if required tools are available
    if ! command -v cargo >/dev/null 2>&1; then
        log_error "cargo is not installed or not in PATH"
        exit 5
    fi

  
    if ! command -v wasm-tools >/dev/null 2>&1; then
        log_error "wasm-tools is not installed. Run: cargo install wasm-tools"
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
TARGET_TRIPLE="wasm32-wasip2"

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
export SOURCE_DATE_EPOCH=0 


collect_component_artifacts() {
    local mode_dir="$TARGET_DIR/wasm32-wasip2/$MODE"

    if [[ ! -d "$mode_dir" ]]; then
        log_error "Expected build artifacts directory not found: $mode_dir"
        exit 4
    fi

    # Remove previous artifacts to avoid stale outputs
    if ! find "$DEST_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; then
        log_error "Failed to clean existing artifacts in $DEST_DIR"
        exit 4
    fi

    local artifacts_copied=0
    local total_bytes=0
    local filename
    local dest_path
    while IFS= read -r -d '' artifact; do
        filename=$(basename "$artifact")
        dest_path="$DEST_DIR/$filename"

        if ! wasm-tools strip -a "$artifact" -o "$dest_path"; then
            log_warn "wasm-tools strip failed for $filename; copying unstripped artifact"
            if ! cp "$artifact" "$dest_path"; then
                log_error "Failed to copy artifact $artifact to $DEST_DIR"
                exit 4
            fi
        fi

        local size_bytes=0
        if command -v stat >/dev/null 2>&1; then
            if size_bytes=$(stat -c%s "$dest_path" 2>/dev/null); then
                :
            elif size_bytes=$(stat -f%z "$dest_path" 2>/dev/null); then
                :
            fi
        fi

        if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then
            size_bytes=$(wc -c < "$dest_path" 2>/dev/null | tr -d '[:space:]')
        fi

        if [[ ! "$size_bytes" =~ ^[0-9]+$ ]]; then
            size_bytes=0
        fi

        log_info "Prepared artifact: $filename (${size_bytes} bytes)"
        total_bytes=$((total_bytes + size_bytes))
        artifacts_copied=$((artifacts_copied + 1))
    done < <(find "$mode_dir" -maxdepth 1 -type f -name '*.wasm' -print0)

    if [[ $artifacts_copied -eq 0 ]]; then
        log_error "No .wasm artifacts produced for target ${TARGET_TRIPLE} in $mode_dir"
        exit 4
    fi

    log_info "Collected $artifacts_copied artifact(s) into $DEST_DIR (${total_bytes} bytes total)"
}

# Find and build component packages
build_component_packages() {
    local build_args=(--target "$TARGET_TRIPLE")
    local host_build_args=()

    if [[ -f "$DOCKER_DIR/Cargo.lock" ]]; then
        build_args+=(--locked)
        host_build_args+=(--locked)
    fi
    if [[ "$MODE" == "release" ]]; then
        build_args+=(--release)
    fi

    
    if [[ -n "${COMPONENT_NAME:-}" ]]; then
        log_info "Building specific component: $COMPONENT_NAME (target ${TARGET_TRIPLE})"
    else
        log_info "Building ${#COMPONENT_ORDER[@]} component package(s) for target ${TARGET_TRIPLE}"
    fi

    # First build host dependencies scoped to component packages (for build scripts, proc macros, etc.)
    local host_package_args=()
    for package_name in "${COMPONENT_ORDER[@]}"; do
        host_package_args+=(-p "$package_name")
    done

    if [[ ${#host_package_args[@]} -gt 0 ]]; then
        log_info "Building host dependencies for ${#COMPONENT_ORDER[@]} component package(s)"
        if ! cargo build "${host_build_args[@]}" "${host_package_args[@]}"; then
            log_warn "Host dependency build failed, continuing with component build"
        fi
    fi

    # Then build only component packages for wasm32-wasip2 target
    for package_name in "${COMPONENT_ORDER[@]}"; do
        local package_dir="${COMPONENT_DIRS[$package_name]}"
        log_info "Building component package: $package_name for target ${TARGET_TRIPLE}"

        if ! cargo build "${build_args[@]}" --manifest-path "$package_dir/Cargo.toml" -p "$package_name"; then
            log_error "Failed to build component package: $package_name"
            exit 3
        fi
    done
}

load_component_packages() {
    # Determine components directory - use supplied path or default to current directory
    local components_dir="/docker"
    if [[ -n "${COMPONENTS_DIR:-}" ]]; then
        components_dir="/docker/${COMPONENTS_DIR}"
    fi

    if [[ ! -d "$components_dir" ]]; then
        log_error "Components directory not found: $components_dir"
        exit 2
    fi

    COMPONENT_ORDER=()
    COMPONENT_DIRS=()

    # Parse exclude folders
    local exclude_array=()
    if [[ -n "${EXCLUDE_FOLDERS:-}" ]]; then
        IFS=',' read -ra exclude_array <<< "${EXCLUDE_FOLDERS}"
        # Trim whitespace
        for i in "${!exclude_array[@]}"; do
            exclude_array[$i]=$(echo "${exclude_array[$i]}" | xargs)
        done
    fi

    # Iterate over folders in components directory
    for component_dir in "$components_dir"/*; do
        if [[ ! -d "$component_dir" ]]; then
            continue
        fi

        local component_name
        component_name=$(basename "$component_dir")

        # Check if this folder should be excluded
        local should_exclude=false
        for exclude_folder in "${exclude_array[@]}"; do
            if [[ "$component_name" == "$exclude_folder" ]]; then
                should_exclude=true
                break
            fi
        done

        if [[ "$should_exclude" == "true" ]]; then
            log_info "Excluding component folder: $component_name"
            continue
        fi

        # Check if this folder has a Cargo.toml
        if [[ ! -f "$component_dir/Cargo.toml" ]]; then
            log_warn "Skipping $component_name: no Cargo.toml found"
            continue
        fi

        # Extract package name from Cargo.toml
        local package_name
        package_name=$(grep '^name = ' "$component_dir/Cargo.toml" | head -1 | sed 's/name = "//;s/"//' | tr -d '\r\n')

        if [[ -z "$package_name" ]]; then
            log_warn "Skipping $component_name: could not extract package name from Cargo.toml"
            continue
        fi

        # Skip if looking for specific component and this isn't it
        if [[ -n "${COMPONENT_NAME:-}" && "$package_name" != "$COMPONENT_NAME" && "$component_name" != "$COMPONENT_NAME" ]]; then
            continue
        fi

        COMPONENT_DIRS["$package_name"]="$component_dir"
        COMPONENT_ORDER+=("$package_name")
        log_info "Discovered component package: $package_name (from folder: $component_name)"
    done

    if [[ ${#COMPONENT_ORDER[@]} -eq 0 ]]; then
        if [[ -n "${COMPONENT_NAME:-}" ]]; then
            log_error "Component package '$COMPONENT_NAME' not found in $components_dir"
        else
            log_error "No component packages found in $components_dir"
        fi
        exit 2
    fi
}

# Build the components
load_component_packages
build_component_packages
collect_component_artifacts

log_info "Build completed successfully"
exit 0
