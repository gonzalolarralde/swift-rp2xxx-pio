#include <stdint.h>

// The output buffer owns a complete PIOProgramData until benchmark_destroy.
uint32_t benchmark_construct(uint32_t input, void *output);
uint32_t benchmark_prepare(const void *program);
uint32_t benchmark_path(uint32_t input, void *output);
uint32_t benchmark_ready(const void *descriptor);
uint32_t benchmark_storage_size(void);
uint32_t benchmark_label_count(const void *program);
int32_t benchmark_entry(const void *program);
uint64_t benchmark_verify(const void *program, uint32_t input);
void benchmark_destroy(void *program);
