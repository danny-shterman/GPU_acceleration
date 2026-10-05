#include <hip/hip_runtime.h>

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <numeric>
#include <random>
#include <vector>

#define HIP_CHECK(x) do {                                      \
    hipError_t e = (x);                                        \
    if (e != hipSuccess) {                                     \
        std::cerr << "HIP error: " << hipGetErrorString(e)     \
                  << " at " << __FILE__ << ":" << __LINE__     \
                  << std::endl;                                \
        std::exit(1);                                          \
    }                                                          \
} while (0)

__global__ void pointer_chase(
    const uint64_t* __restrict__ next,
    uint64_t iterations,
    uint64_t* result,
    unsigned long long* elapsed_ticks)
{
    if (blockIdx.x != 0 || threadIdx.x != 0) return;

    uint64_t p = 0;

    // Small warmup. Large working sets still miss the cache hierarchy.
    for (int i = 0; i < 4096; ++i)
        p = next[p];

    unsigned long long start = wall_clock64();

    for (uint64_t i = 0; i < iterations; ++i)
        p = next[p];

    unsigned long long stop = wall_clock64();

    result[0] = p;
    elapsed_ticks[0] = stop - start;
}

static uint64_t mib(uint64_t x) {
    return x * 1024ULL * 1024ULL;
}

int main(int argc, char** argv)
{
    uint64_t max_gib = argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 8;
    uint64_t iterations =
        argc > 2 ? std::strtoull(argv[2], nullptr, 10) : 1000000ULL;

    int device = 0;
    HIP_CHECK(hipSetDevice(device));

    hipDeviceProp_t prop{};
    HIP_CHECK(hipGetDeviceProperties(&prop, device));

    int wall_khz = 0;
    HIP_CHECK(hipDeviceGetAttribute(
        &wall_khz, hipDeviceAttributeWallClockRate, device));

    std::cerr << "# device=" << prop.name << "\n";
    std::cerr << "# gcnArchName=" << prop.gcnArchName << "\n";
    std::cerr << "# wall_clock_khz=" << wall_khz << "\n";
    std::cerr << "# iterations=" << iterations << "\n";

    std::cout
        << "working_set_bytes,elements,iterations,"
        << "ticks_per_access,ns_per_access\n";

    std::mt19937_64 rng(0x300ULL);

    for (uint64_t bytes = mib(1);
         bytes <= max_gib * 1024ULL * 1024ULL * 1024ULL;
         bytes *= 2)
    {
        uint64_t n = bytes / sizeof(uint64_t);

        std::vector<uint64_t> permutation(n);
        std::iota(permutation.begin(), permutation.end(), 0ULL);
        std::shuffle(permutation.begin(), permutation.end(), rng);

        std::vector<uint64_t> next(n);
        for (uint64_t i = 0; i + 1 < n; ++i)
            next[permutation[i]] = permutation[i + 1];

        next[permutation[n - 1]] = permutation[0];

        uint64_t* d_next = nullptr;
        uint64_t* d_result = nullptr;
        unsigned long long* d_ticks = nullptr;

        HIP_CHECK(hipMalloc(&d_next, bytes));
        HIP_CHECK(hipMalloc(&d_result, sizeof(uint64_t)));
        HIP_CHECK(hipMalloc(&d_ticks, sizeof(unsigned long long)));

        HIP_CHECK(hipMemcpy(
            d_next, next.data(), bytes, hipMemcpyHostToDevice));

        hipLaunchKernelGGL(
            pointer_chase,
            dim3(1), dim3(1), 0, 0,
            d_next, iterations, d_result, d_ticks);

        HIP_CHECK(hipDeviceSynchronize());

        uint64_t result = 0;
        unsigned long long ticks = 0;

        HIP_CHECK(hipMemcpy(
            &result, d_result, sizeof(result), hipMemcpyDeviceToHost));
        HIP_CHECK(hipMemcpy(
            &ticks, d_ticks, sizeof(ticks), hipMemcpyDeviceToHost));

        const double ticks_per_access =
            static_cast<double>(ticks) / iterations;

        const double ns_per_tick =
            wall_khz > 0 ? 1.0e6 / static_cast<double>(wall_khz) : 0.0;

        const double ns_per_access = ticks_per_access * ns_per_tick;

        std::cout
            << bytes << ","
            << n << ","
            << iterations << ","
            << ticks_per_access << ","
            << ns_per_access << "\n";

        // Prevent the final dependent load from becoming dead code.
        if (result >= n)
            std::cerr << "invalid result\n";

        HIP_CHECK(hipFree(d_ticks));
        HIP_CHECK(hipFree(d_result));
        HIP_CHECK(hipFree(d_next));
    }

    return 0;
}
