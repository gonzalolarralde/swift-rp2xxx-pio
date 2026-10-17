#include <stdint.h>
void benchmark_observe(const void *storage, uint32_t size);
uint64_t benchmark_runtime_support(uint32_t input);
uint64_t benchmark_step(uint32_t input);
uint64_t benchmark_consume(const uint16_t *words, uint32_t count,
                           uint32_t wrap_target, uint32_t wrap,
                           uint32_t gpio, uint32_t fifo, uint32_t side,
                           uint32_t seed);
