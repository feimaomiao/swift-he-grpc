# SwiftNIO Has a Serious Problem with CPU-Intensive Async Tasks

We discovered that running CPU-intensive async operations inside SwiftNIO handlers causes a **100x performance degradation**. This affects all NIO-based servers including gRPC, Vapor, Hummingbird, and any custom NIO HTTP server.

## What We Found

We were building a privacy-preserving search service using Apple's Homomorphic Encryption library. The HE computation takes about 6ms when run directly. But when we put it inside a gRPC handler, it suddenly took 500ms - almost 100 times slower.

At first we thought it was a gRPC issue. We tried gRPC 1.x, gRPC 2.x, even built a plain NIO HTTP server. Same problem everywhere. Then we tried Apple's Network.framework (which doesn't use NIO) - and it was fast again.

| How We Ran the Computation | Time |
|---------------------------|------|
| Direct execution (no server) | 6ms |
| Network.framework server | 6ms |
| gRPC server with process isolation | 6ms |
| gRPC 1.x server (in-process) | 500ms |
| gRPC 2.x server (in-process) | 500ms |
| NIO HTTP server (in-process) | 500ms |

The pattern is clear: **anything running inside a SwiftNIO handler is 100x slower**.

## Why This Matters

This isn't just about homomorphic encryption. Any CPU-intensive async work will be affected:

- **Machine learning inference** - Running CoreML or other ML models in your server
- **Image/video processing** - Resizing, encoding, filtering
- **Cryptographic operations** - Encryption, signing, hashing large data
- **Data compression** - Compressing responses or files
- **Complex calculations** - Financial models, simulations, algorithms

If you're running any of these inside a Vapor route handler, a Hummingbird endpoint, or a gRPC service method, you're likely seeing this slowdown without realizing it.

### Real-World Impact

Imagine you're running an ML inference service:
- **Expected**: 50ms inference time, handle 20 requests/second
- **Actual with NIO**: 5000ms inference time, handle 0.2 requests/second

That's the difference between a responsive service and one that times out constantly.

## How to Reproduce

```bash
# Clone and build
git clone <this-repo>
cd swift-he-grpc
./build.sh
./setup.sh

# Run the benchmark
./benchmark.sh
```

You'll see 7 different tests proving the issue.

## What's Causing This

When you `await` something inside a NIO handler, the Swift concurrency runtime inherits the NIO executor context. This means your CPU-intensive Task gets scheduled on the NIO event loop, which is designed for quick I/O operations, not sustained computation.

The result: constant context switching, cache thrashing, and your CPU work getting interrupted by I/O scheduling. Hence the 100x slowdown.

```swift
// Inside a gRPC/Vapor/Hummingbird handler
func handleRequest() async throws -> Response {
    // This runs on the NIO event loop - SLOW!
    let result = try await expensiveComputation()
    return Response(result)
}
```

## Mitigations

### 1. Process Isolation (Recommended for Heavy Workloads)

Run CPU-intensive work in a separate process that doesn't use NIO:

```
┌─────────────────────────┐     ┌─────────────────────────┐
│  Your NIO Server        │     │  Worker Process         │
│  (gRPC, Vapor, etc.)    │────▶│  (No NIO)               │
│  Handles network I/O    │     │  Does CPU work          │
└─────────────────────────┘     └─────────────────────────┘
        Fast I/O                      Fast compute
```

We implemented this as `HEServerIsolated` + `HEWorker`. The gRPC server handles network traffic, then forwards compute requests to the worker via Unix socket. Result: 6ms compute time (same as native) with only ~10ms IPC overhead.

**Pros**: Full native performance, clean separation of concerns
**Cons**: More complex deployment, IPC overhead (usually ~10-15ms)

### 2. Use Network.framework Instead of NIO

If you don't need gRPC specifically, you can build your server using Apple's Network.framework:

```swift
// Network.framework doesn't have this problem
let listener = try NWListener(using: .tcp, on: 8080)
```

We implemented this as `NativeRESTServer`. It runs at full native speed.

**Pros**: Native performance, simpler than process isolation
**Cons**: macOS/iOS only, lose gRPC ecosystem, more low-level work

### 3. Custom TaskExecutor (Experimental)

Swift 5.9+ has experimental support for custom executors. In theory, you could create an executor that runs Tasks off the NIO event loop:

```swift
// Hypothetical - API still evolving
await Task.detached(on: cpuExecutor) {
    await expensiveComputation()
}.value
```

**Pros**: Could be cleanest solution long-term
**Cons**: API is experimental, may not fully escape NIO context

### 4. Synchronous Execution on Separate Thread Pool

If your CPU work can be made synchronous, dispatch it to a separate thread:

```swift
let result = await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
        let result = synchronousComputation() // Not async
        continuation.resume(returning: result)
    }
}
```

**Pros**: Relatively simple
**Cons**: Only works for synchronous code, doesn't help with async APIs

### 5. Accept the Overhead for Light Workloads

If your CPU work is light (< 10ms), the overhead might be acceptable. Profile first before optimizing.

## What We'd Like to See

Ideally, NIO or Swift Concurrency would provide a way to opt-out of executor inheritance for specific Tasks. Something like:

```swift
// Wishful thinking
await Task.detached(executor: .default) {
    // Runs on default executor, not NIO
    await cpuIntensiveWork()
}
```

Until then, process isolation is the most reliable solution for heavy workloads.

## Project Structure

```
Sources/
├── HESlowdownReproducer/  # All-in-one benchmark showing the problem
├── NativeBenchmark/       # Baseline (no network)
│
├── HEServer/              # gRPC 2.x - SLOW (in-process NIO)
├── HEServerV1/            # gRPC 1.x - SLOW (in-process NIO)
├── RESTServer/            # NIO HTTP - SLOW (in-process NIO)
│
├── NativeRESTServer/      # Network.framework - FAST (no NIO)
├── HEServerIsolated/      # gRPC + worker - FAST (process isolation)
├── HEWorker/              # Worker process - FAST (no NIO)
│
└── *Client/               # Test clients for each server
```

## Running Individual Tests

```bash
# Baseline (should be ~6ms)
.build/release/NativeBenchmark databases/dim16_vec10000/database.binpb

# gRPC in-process (will be ~500ms - demonstrating the problem)
.build/release/HEServer databases/dim16_vec10000/database.binpb &
.build/release/HEClient databases/dim16_vec10000/database.binpb --verbose

# Process isolation (should be ~6ms compute, ~20ms total)
.build/release/HEWorker databases/dim16_vec10000/database.binpb &
.build/release/HEServerIsolated --socket-path /tmp/he-worker.sock &
.build/release/HEClient databases/dim16_vec10000/database.binpb --port 50055 --verbose
```

## Requirements

- macOS 26+ / Swift 6.0+
- swift-homomorphic-encryption (included as submodule)

## Contributing

If you've found other mitigations or have insights into why this happens at the NIO/Swift Concurrency level, please open an issue or PR.

## License

MIT
