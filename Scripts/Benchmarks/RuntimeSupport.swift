import BenchmarkSupport

// Deliberately independent of PIO. The C driver calls this once before running
// the probe, so support stays linked without adding it to each timed PIO call.
#if BENCH_SUPPORT_ALLOCATION || BENCH_SUPPORT_COMMON
private final class AllocationToken {
    let value: UInt32
    init(_ value: UInt32) { self.value = value }
}

private func allocation(_ input: UInt32) -> UInt64 {
    let token = AllocationToken(input)
    withUnsafePointer(to: token) {
        benchmark_observe($0, UInt32(MemoryLayout.size(ofValue: token)))
    }
    return UInt64(token.value)
}
#endif

#if BENCH_SUPPORT_STRINGS || BENCH_SUPPORT_COMMON
private func strings(_ input: UInt32) -> UInt64 {
    let prefix = [UInt8](repeating: UInt8(97 + (input & 15)), count: 32 + Int(input & 31))
    let composed = String(decoding: prefix + [0xc3, 0xa9], as: UTF8.self)
    let decomposed = String(decoding: prefix + [0x65, 0xcc, 0x81], as: UTF8.self)
    // Exercise canonical equality and string-key hashing, not just literals.
    var table: [String: UInt32] = [composed: input]
    withUnsafePointer(to: &table) {
        benchmark_observe($0, UInt32(MemoryLayout<[String: UInt32]>.size))
    }
    precondition(composed == decomposed && table[decomposed] == input)
    var hasher = Hasher()
    composed.hash(into: &hasher)
    return UInt64(truncatingIfNeeded: hasher.finalize())
}
#endif

#if BENCH_SUPPORT_COLLECTIONS || BENCH_SUPPORT_COMMON
private func collections(_ input: UInt32) -> UInt64 {
    var values = [UInt32](repeating: input, count: 16 + Int(input & 15))
    values[0] = input &+ 1
    var table: [UInt32: UInt32] = [input: values[0], input &+ 1: input]
    withUnsafePointer(to: &table) {
        benchmark_observe($0, UInt32(MemoryLayout<[UInt32: UInt32]>.size))
    }
    values.withUnsafeBufferPointer {
        benchmark_observe($0.baseAddress, UInt32($0.count * MemoryLayout<UInt32>.stride))
    }
    precondition(table[input] == input &+ 1)
    return UInt64(table[input]!) &+ UInt64(values.count)
}
#endif

@_cdecl("benchmark_runtime_support")
public func benchmarkRuntimeSupport(_ input: UInt32) -> UInt64 {
    var result = UInt64(input)
    #if BENCH_SUPPORT_ALLOCATION || BENCH_SUPPORT_COMMON
    result &+= allocation(input)
    #endif
    #if BENCH_SUPPORT_STRINGS || BENCH_SUPPORT_COMMON
    result &+= strings(input)
    #endif
    #if BENCH_SUPPORT_COLLECTIONS || BENCH_SUPPORT_COMMON
    result &+= collections(input)
    #endif
    return result
}
