#include <hip/hip_runtime.h>

#include <cstdint>
#include <cstdlib>
#include <iostream>

#define HIP_CHECK(x) do {                                      \
    hipError_t e = (x);                                        \
    if (e != hipSuccess) {                                     \
        std::cerr << hipGetErrorString(e) << std::endl;        \
        std::exit(1);                                          \
    }                                                          \
} while (0)

__global__ void stream_copy(
    const float4* __restrict__ src,
    float4* __restrict__ dst,
    size_t n)
{
    size_t i =
        static_cast<size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    size_t stride =
        static_cast<size_t>(gridDim.x) * blockDim.x;

    for (; i < n; i += stride)
        dst[i] = src[i];
}

int main(int argc, char** argv)
{
    uint64_t gib =
        argc > 1 ? std::strtoull(argv[1], nullptr, 10) : 8;
    int repeats =
        argc > 2 ? std::atoi(argv[2]) : 10;

    size_t bytes = gib * 1024ULL * 1024ULL * 1024ULL;
    size_t n4 = bytes / sizeof(float4);
    bytes = n4 * sizeof(float4);

    float4* src = nullptr;
    float4* dst = nullptr;

    HIP_CHECK(hipMalloc(&src, bytes));
    HIP_CHECK(hipMalloc(&dst, bytes));
    HIP_CHECK(hipMemset(src, 1, bytes));
    HIP_CHECK(hipMemset(dst, 0, bytes));

    hipDeviceProp_t prop{};
    HIP_CHECK(hipGetDeviceProperties(&prop, 0));

    int blocks = prop.multiProcessorCount * 8;
    int threads = 256;

    hipEvent_t start, stop;
    HIP_CHECK(hipEventCreate(&start));
    HIP_CHECK(hipEventCreate(&stop));

    stream_copy<<<blocks, threads>>>(src, dst, n4);
    HIP_CHECK(hipDeviceSynchronize());

    HIP_CHECK(hipEventRecord(start));

    for (int r = 0; r < repeats; ++r)
        stream_copy<<<blocks, threads>>>(src, dst, n4);

    HIP_CHECK(hipEventRecord(stop));
    HIP_CHECK(hipEventSynchronize(stop));

    float ms = 0.0f;
    HIP_CHECK(hipEventElapsedTime(&ms, start, stop));

    // Each copy performs one HBM read and one HBM write.
    double transferred =
        2.0 * static_cast<double>(bytes) * repeats;

    double gbps =
        transferred / (static_cast<double>(ms) / 1000.0) / 1.0e9;

    std::cout << "device," << prop.name << "\n";
    std::cout << "bytes_per_buffer," << bytes << "\n";
    std::cout << "repeats," << repeats << "\n";
    std::cout << "elapsed_ms," << ms << "\n";
    std::cout << "read_plus_write_GBps," << gbps << "\n";

    HIP_CHECK(hipEventDestroy(stop));
    HIP_CHECK(hipEventDestroy(start));
    HIP_CHECK(hipFree(dst));
    HIP_CHECK(hipFree(src));

    return 0;
}
