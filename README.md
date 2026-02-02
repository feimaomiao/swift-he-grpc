# Swift Homomorphic Encryption: Performance Impact with SwiftNIO

We observe a critical performance issue when running Apple's [swift-homomorphic-encryption](https://github.com/apple/swift-homomorphic-encryption) inside SwiftNIO-based servers, and provide working mitigations.

## The Problem

Homomorphic encryption computations experience **100x performance degradation** when executed inside SwiftNIO handler contexts.

| Execution Context | HE Compute Time |
|-------------------|-----------------|
| Direct execution (no server) | 6ms |
| Network.framework server | 6ms |
| gRPC server with process isolation | 6ms |
| gRPC 1.x server (in-process) | 500ms |
| gRPC 2.x server (in-process) | 500ms |
| NIO HTTP server (in-process) | 500ms |


## Benchmarks

This repository provides 7 benchmarks to demonstrate and quantify the issue:

```bash
./build.sh
./setup.sh
./benchmark.sh
```

### Benchmark Results

| # | Benchmark | Description | Expected Time |
|---|-----------|-------------|---------------|
| 1 | `NativeBenchmark` | Direct HE execution baseline | ~6ms |
| 2 | `HESlowdownReproducer` | Side-by-side comparison: direct vs NIO | 6ms vs 500ms |
| 3 | `HEServer` + `HEClient` | gRPC 2.x in-process | ~500ms |
| 4 | `HEServerV1` + `HEClientV1` | gRPC 1.x in-process | ~500ms |
| 5 | `RESTServer` + `RESTClient` | Plain NIO HTTP in-process | ~500ms |
| 6 | `NativeRESTServer` + `NativeRESTClient` | Network.framework (no NIO) | ~6ms |
| 7 | `HEServerIsolated` + `HEWorker` | gRPC + process isolation | ~6ms compute, ~20ms total |

## Mitigations

### 1. Process Isolation 

Run HE computations in a separate worker process that doesn't use NIO:

```
┌─────────────────────────┐     ┌─────────────────────────┐
│  gRPC/HTTP Server       │     │  HE Worker Process      │
│  (SwiftNIO)             │────▶│  (No NIO)               │
│  Handles network I/O    │     │  Runs HE computations   │
└─────────────────────────┘     └─────────────────────────┘
```

**Implementation:** `HEServerIsolated` + `HEWorker`

The gRPC server forwards compute requests to the worker via Unix socket. The worker runs HE operations at native speed (~6ms), with only ~10-15ms IPC overhead.

```bash
# Start worker
.build/release/HEWorker databases/dim16_vec10000/database.binpb &

# Start isolated gRPC server
.build/release/HEServerIsolated --socket-path /tmp/he-worker.sock &

# Test
.build/release/HEClient databases/dim16_vec10000/database.binpb --port 50055
```

### 2. Network.framework Server

If you don't require gRPC, use Apple's Network.framework instead of SwiftNIO:

**Implementation:** `NativeRESTServer`

```bash
.build/release/NativeRESTServer databases/dim16_vec10000/database.binpb &
.build/release/NativeRESTClient databases/dim16_vec10000/database.binpb
```

HE operations run at native speed since Network.framework doesn't have the executor inheritance issue.

**Trade-offs:**
- macOS/iOS only
- No gRPC ecosystem
- More low-level implementation work

## Project Structure

```
Sources/
├── NativeBenchmark/       # Baseline: direct HE execution
│
├── HEServer/              # gRPC 2.x - SLOW (in-process NIO)
├── HEServerV1/            # gRPC 1.x - SLOW (in-process NIO)
├── RESTServer/            # NIO HTTP - SLOW (in-process NIO)
│
├── NativeRESTServer/      # Network.framework - FAST (no NIO)
├── HEServerIsolated/      # gRPC frontend - FAST (forwards to worker)
├── HEWorker/              # Worker process - FAST (no NIO)
│
├── HESlowdownReproducer/  # All-in-one benchmark
└── *Client/               # Test clients
```

## Requirements

- macOS 26+ / Swift 6.0+
- swift-homomorphic-encryption (included as submodule)


## Note

All benchmarking is done locally (Macbook Pro M5) 
