#include "InstructionSupport.h"
#include "Support.h"
#include <stddef.h>

// Benchmark-only platform adaptation, NOT a production entropy source. The
// SDK's weak _getentropy returns -1; newlib then raises a signal and continues
// because the bare-metal _kill stub also fails. Supply deterministic seed bytes
// in guest ARM code so successful hash/arc4random initialization is measured.
// arc4random's complete PRNG work still executes. Never use this for security.
int _getentropy(void *buffer, size_t length) {
    static uint32_t state = 0x243f6a88u;
    if (length > 256) return -1;
    unsigned char *bytes = buffer;
    for (size_t i = 0; i < length; ++i) {
        state = state * 1664525u + 1013904223u;
        bytes[i] = (unsigned char)(state >> 24);
    }
    return 0;
}

// A is the first instruction of this function. The construction return is the
// intermediate checkpoint; B is entry to benchmark_ready, before its first
// instruction. The emulator counts all intervening callees, not this source's
// static instruction count. No timer/counter/printing runs in the guest interval.
__attribute__((noinline))
uint32_t benchmark_path(uint32_t input, void *output) {
    if (!benchmark_construct(input, output)) return 0;
    return benchmark_prepare(output);
}

__attribute__((noinline))
uint32_t benchmark_ready(const void *descriptor) {
    __asm__ volatile("" : : "r"(descriptor) : "memory");
    return 1;
}

// Verification runs only after B, while the program is still alive. The ready
// callback's borrowed descriptor is snapshotted at B, not accessed after return.
__attribute__((noinline))
uint64_t benchmark_consume(const uint16_t *words, uint32_t count,
                           uint32_t wrap_target, uint32_t wrap,
                           uint32_t gpio, uint32_t fifo, uint32_t side,
                           uint32_t seed) {
    uint64_t hash = seed;
    for (uint32_t i = 0; i < count; ++i) hash = hash * 33 + words[i];
    const uint32_t fields[] = {count, wrap_target, wrap, gpio, fifo, side};
    for (unsigned i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i)
        hash = hash * 33 + fields[i];
    return hash;
}

// Keep a normal SDK-linked ELF, but the emulator enters benchmark_path directly
// after loading data and performing the documented minimal lock initialization.
// This executable is never flashed or started via its reset handler.
int main(void) { return 0; }
