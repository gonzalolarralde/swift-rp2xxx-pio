#include "Support.h"
#ifndef BENCH_FIRMWARE
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
// Only captured Swift probes define this host-only correctness hook.
__attribute__((weak, noinline)) void benchmark_verify_capture(void) {}
#endif

// An opaque escape keeps an allocation or collection observable without
// reading uninitialized padding or interpreting a Swift storage layout.
__attribute__((noinline))
void benchmark_observe(const void *storage, uint32_t size) {
    __asm__ volatile("" : : "r"(storage), "r"(size) : "memory");
}

#ifdef BENCH_RUNTIME_SUPPORT
volatile uint64_t benchmark_support_output;
static void initialize_runtime_support(void) {
    // Exercise varying values as a correctness smoke check. This is outside
    // all timing intervals and independent of the PIO result checksum.
    for (uint32_t input = 0; input < 64; ++input)
        benchmark_support_output = benchmark_runtime_support(input);
}
#else
static void initialize_runtime_support(void) {}
#endif

// A separately compiled consumer forces actual instruction storage to exist.
// No LTO: the Swift compiler cannot replace this with a constant checksum.
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

#ifdef BENCH_FIRMWARE
// Used only for linked-size inspection. No board is flashed or executed by the
// harness. A volatile input/output keeps the probe observable to both compilers.
volatile uint32_t benchmark_input = 1;
volatile uint64_t benchmark_output;
int main(void) {
    initialize_runtime_support();
    benchmark_output = benchmark_step(benchmark_input);
    for (;;) __asm__ volatile("wfi");
}
#else
static uint64_t now(void) {
    struct timespec stamp;
    clock_gettime(CLOCK_MONOTONIC, &stamp);
    return (uint64_t)stamp.tv_sec * 1000000000 + (uint64_t)stamp.tv_nsec;
}

int main(int argc, char **argv) {
    initialize_runtime_support();
    if (argc > 1 && strcmp(argv[1], "--verify") == 0) {
        benchmark_verify_capture();
        for (unsigned i = 0; i < 64; ++i) printf("%" PRIu64 "\n", benchmark_step(i));
        return 0;
    }
    const unsigned iterations = argc > 1 ? (unsigned)strtoul(argv[1], NULL, 10) : 100000;
    if (iterations == 0) return 2;
    uint64_t begin = now();
    uint64_t hash = benchmark_step(0);
    const uint64_t cold = now() - begin;
    for (unsigned i = 0; i < 1000; ++i) hash += benchmark_step(i);
    printf("{\"cold_first_call_ns\":%" PRIu64 ",\"samples_ns_per_call\":[", cold);
    for (unsigned round = 0; round < 7; ++round) {
        begin = now();
        for (unsigned i = 0; i < iterations; ++i) hash += benchmark_step(i);
        const uint64_t elapsed = now() - begin;
        printf("%s%.6f", round ? "," : "", (double)elapsed / iterations);
    }
    struct rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    // macOS reports ru_maxrss in bytes. This includes the process and shared
    // runtime; it is not an allocation count or the program's own heap size.
    printf("],\"checksum\":%" PRIu64 ",\"peak_rss_bytes\":%ld}\n", hash, usage.ru_maxrss);
    return 0;
}
#endif
