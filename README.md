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

The container expects your Rust component to be mounted at `/docker/<component-name>` and will output built WASM files to `/docker/output`.

### Container Arguments

```
entrypoint <component-path> [--debug]
```

- `component-path`: Relative path to your Rust component (from `/docker`)
- `--debug`: Build in debug mode (default: release)

### Examples

```bash
# Build a component in release mode (default)
docker run --rm \
  -v $(pwd)/my-component:/docker/my-component \
  -v $(pwd)/output:/docker/output \
  wasi-builder my-component

# Build a component in debug mode
docker run --rm \
  -v $(pwd)/my-component:/docker/my-component \
  -v $(pwd)/output:/docker/output \
  wasi-builder my-component --debug

# Build a component in a workspace
docker run --rm \
  -v $(pwd)/my-workspace:/docker/my-workspace \
  -v $(pwd)/output:/docker/output \
  wasi-builder my-workspace/components/my-component
```

## Build Targets

- Target: `wasm32-wasip1`
- Output: `.wasm` files compatible with WASI runtime

## License

This project is part of the [Lay3rLabs](https://github.com/Lay3rLabs) ecosystem.