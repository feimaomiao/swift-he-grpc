#!/bin/bash
# Build Script
# ============
# Builds swift-homomorphic-encryption and all benchmark targets

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "============================================="
echo "Building HE gRPC Slowdown Reproducer"
echo "============================================="
echo

# Step 1: Build swift-homomorphic-encryption
echo "Building swift-homomorphic-encryption (release mode)..."
echo "  This may take several minutes on first build..."
pushd "$SCRIPT_DIR/swift-homomorphic-encryption" > /dev/null
swift build -c release
HE_BIN_PATH=$(swift build -c release --show-bin-path)
popd > /dev/null
echo "  HE tools path: $HE_BIN_PATH"
echo

# Step 2: Build main project
echo "Building benchmark targets (release mode)..."
swift build -c release
BIN_PATH=$(swift build -c release --show-bin-path)
echo "  Binary path: $BIN_PATH"
echo

echo "============================================="
echo "Build complete!"
echo "============================================="
echo
echo "Available binaries:"
echo "  - HESlowdownReproducer  (all-in-one v2 benchmark)"
echo "  - HEServer / HEClient   (gRPC 2.x - HAS SLOWDOWN)"
echo "  - HEServerV1 / HEClientV1 (gRPC 1.x - NO SLOWDOWN)"
echo "  - NativeBenchmark       (baseline, no gRPC)"
echo
echo "Next steps:"
echo "  1. Generate databases: ./setup.sh"
echo "  2. Run benchmarks:     ./benchmark.sh"
