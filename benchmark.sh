#!/bin/bash
# HE gRPC Slowdown Benchmark Script
# ==================================
# Demonstrates the gRPC-Swift 2.x NIO executor slowdown vs 1.x (no slowdown)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/release"

# Default parameters
DATABASE="${1:-$SCRIPT_DIR/databases/dim16_vec10000/database.binpb}"
ITERATIONS="${2:-5}"
PORT_BASE="${3:-50050}"

echo "============================================="
echo "SwiftNIO Executor Slowdown Benchmark"
echo "============================================="
echo
echo "Database: $DATABASE"
echo "Iterations: $ITERATIONS"
echo
echo "This benchmark demonstrates:"
echo "  - Direct execution: Fast (~6ms)"
echo "  - NIO handler execution: Slow (~500ms, 100x slowdown)"
echo "  - Affects ALL NIO-based servers (gRPC 1.x, 2.x, HTTP)"
echo

# Check if binaries exist
if [ ! -f "$BUILD_DIR/HESlowdownReproducer" ]; then
    echo "Building release binaries..."
    swift build -c release
    echo
fi

# ============================================
# Benchmark 1: Native baseline
# ============================================
echo "============================================="
echo "BENCHMARK 1: Native (Baseline)"
echo "============================================="
echo

"$BUILD_DIR/NativeBenchmark" "$DATABASE" --iterations "$ITERATIONS" 
echo
echo

# ============================================
# Benchmark 2: All-in-one reproducer (gRPC 2.x)
# ============================================
echo "============================================="
echo "BENCHMARK 2: HESlowdownReproducer (gRPC 2.x)"
echo "============================================="
echo

"$BUILD_DIR/HESlowdownReproducer" "$DATABASE" --iterations "$ITERATIONS" --port $((PORT_BASE + 100)) 
echo
echo

# ============================================
# Benchmark 3: gRPC 2.x Server/Client
# ============================================
echo "============================================="
echo "BENCHMARK 3: HEServer/HEClient (gRPC 2.x)"
echo "(Demonstrates the slowdown in real deployment)"
echo "============================================="
echo

PORT_V2=$((PORT_BASE + 1))

# Start server in background
echo "Starting gRPC 2.x server on port $PORT_V2..."
"$BUILD_DIR/HEServer" "$DATABASE" --port "$PORT_V2" $BFV_FLAG &
SERVER_PID=$!

# Wait for server to start
sleep 2

# Run client
"$BUILD_DIR/HEClient" "$DATABASE" --host 127.0.0.1 --port "$PORT_V2" --requests "$ITERATIONS" --verbose 
# Stop server
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo
echo

# ============================================
# Benchmark 4: gRPC 1.x Server/Client
# ============================================
echo "============================================="
echo "BENCHMARK 4: HEServerV1/HEClientV1 (gRPC 1.x)"
echo "(Also shows slowdown - NIO executor issue)"
echo "============================================="
echo

PORT_V1=$((PORT_BASE + 2))

# Start server in background
echo "Starting gRPC 1.x server on port $PORT_V1..."
"$BUILD_DIR/HEServerV1" "$DATABASE" --port "$PORT_V1" $BFV_FLAG &
SERVER_PID=$!

# Wait for server to start
sleep 2

# Run client
"$BUILD_DIR/HEClientV1" "$DATABASE" --host 127.0.0.1 --port "$PORT_V1" --requests "$ITERATIONS" --verbose 
# Stop server
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo
echo

# ============================================
# Benchmark 5: REST Server/Client (plain NIO HTTP)
# ============================================
echo "============================================="
echo "BENCHMARK 5: RESTServer/RESTClient (plain NIO HTTP)"
echo "(Also shows slowdown - confirms NIO executor issue)"
echo "============================================="
echo

PORT_REST=$((PORT_BASE + 3))

# Start server in background
echo "Starting REST server on port $PORT_REST..."
"$BUILD_DIR/RESTServer" "$DATABASE" --port "$PORT_REST" &
SERVER_PID=$!

# Wait for server to start
sleep 2

# Run client
"$BUILD_DIR/RESTClient" "$DATABASE" --host 127.0.0.1 --port "$PORT_REST" --requests "$ITERATIONS" --verbose

# Stop server
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo
echo

# ============================================
# Benchmark 6: Native REST (Network.framework - NO NIO)
# ============================================
echo "============================================="
echo "BENCHMARK 6: NativeRESTServer (Network.framework)"
echo "(NO SwiftNIO - should show NO slowdown)"
echo "============================================="
echo

PORT_NATIVE=$((PORT_BASE + 4))

# Start server in background
echo "Starting Native REST server on port $PORT_NATIVE..."
"$BUILD_DIR/NativeRESTServer" "$DATABASE" --port "$PORT_NATIVE" &
SERVER_PID=$!

# Wait for server to start
sleep 3

# Run client
"$BUILD_DIR/NativeRESTClient" "$DATABASE" --host 127.0.0.1 --port "$PORT_NATIVE" --requests "$ITERATIONS" --verbose

# Stop server
kill $SERVER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true

echo
echo

# ============================================
# Benchmark 7: Process-Isolated gRPC Server
# ============================================
echo "============================================="
echo "BENCHMARK 7: HEServerIsolated + HEWorker"
echo "(gRPC + process isolation - HE runs in separate process)"
echo "============================================="
echo

SOCKET_PATH="/tmp/he-worker-bench.sock"
PORT_ISOLATED=$((PORT_BASE + 5))

# Start worker process (no NIO)
echo "Starting HE worker process..."
"$BUILD_DIR/HEWorker" "$DATABASE" --socket-path "$SOCKET_PATH" &
WORKER_PID=$!
sleep 3

# Start isolated gRPC server
echo "Starting isolated gRPC server on port $PORT_ISOLATED..."
"$BUILD_DIR/HEServerIsolated" --port "$PORT_ISOLATED" --socket-path "$SOCKET_PATH" &
SERVER_PID=$!
sleep 2

# Run client
"$BUILD_DIR/HEClient" "$DATABASE" --host 127.0.0.1 --port "$PORT_ISOLATED" --requests "$ITERATIONS" --verbose

# Stop servers
kill $SERVER_PID 2>/dev/null || true
kill $WORKER_PID 2>/dev/null || true
wait $SERVER_PID 2>/dev/null || true
wait $WORKER_PID 2>/dev/null || true