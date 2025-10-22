# WASI Builder

A Docker-based builder for creating [WASI (WebAssembly System Interface)](https://wasi.dev/) components from Rust source code using the [cargo-component](https://github.com/bytecodealliance/cargo-component) tool.

## Features

- Builds WASI components from Rust crates
- Supports both debug and release modes
- Secure sandboxed build environment
- Reproducible builds with fixed versions
- Multi-architecture support (amd64, arm64)

## Development

```bash
# Install Task (if not already installed)
curl -sL https://taskfile.dev/install.sh | sh
```

## Configuration

The project uses a `.env` file for configuration:

```bash
# Docker Configuration
ORG=lay3rlabs
IMAGE_NAME=wasi-builder
REGISTRY=ghcr.io
DOCKERFILE=Dockerfile

# Build Tool Versions
RUST_VERSION=1.90-slim-bookworm
CARGO_COMPONENT_VERSION=0.21.1
WASM_TOOLS_VERSION=1.238.1
WKG_VERSION=0.12.0
```

## Quick Start

```bash
# Build the Docker image
task build

# Test the build
task test
```

## Usage

The container automatically detects and builds all Rust components found in the mounted `/docker` directory. Built WASM files are output to `/docker/output`.

### Container Arguments

```
entrypoint [--debug]
```

- `--debug`: Build in debug mode (default: release)
- `--help`: Show usage information

### Examples

```bash
# Build all components in release mode (default)
docker run --rm \
  -v $(pwd)/my-project:/docker \
  -v $(pwd)/output:/docker/output \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  wasi-builder

# Build all components in debug mode
docker run --rm \
  -v $(pwd)/my-project:/docker \
  -v $(pwd)/output:/docker/output \
  -e HOST_UID=$(id -u) -e HOST_GID=$(id -g) \
  wasi-builder --debug
```

The builder will automatically detect and build:
- Single components
- Cargo workspaces
- Mixed projects with multiple components

## Build Targets

- Target: `wasm32-wasip1`
- Output: `.wasm` files compatible with WASI runtime

## License

This project is part of the [Lay3rLabs](https://github.com/Lay3rLabs) ecosystem.