// hello-cpp: a small WASI program for dabterm.
//
// Build on a Mac with wasi-sdk:
//   $WASI_SDK/bin/clang++ -O2 -std=c++20 -o hello-cpp.wasm main.cpp
// Run in dabterm:   wasm hello-cpp.wasm 10
//                   echo "3 1 4 1 5 9 2 6" | wasm hello-cpp.wasm
// Or copy it to ~/bin and run it by name: hello-cpp 10
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <iostream>
#include <map>
#include <string>
#include <vector>

static unsigned long long fib(int n) {
    unsigned long long a = 0, b = 1;
    for (int i = 0; i < n; ++i) { auto t = a + b; a = b; b = t; }
    return a;
}

int main(int argc, char** argv) {
    std::cout << "hello from C++" << __cplusplus / 100 % 100 << " (wasm32-wasi)\n";

    int n = argc > 1 ? std::atoi(argv[1]) : 10;
    auto t0 = std::chrono::steady_clock::now();
    for (int i = 0; i <= n; ++i) std::cout << "fib(" << i << ") = " << fib(i) << '\n';
    auto us = std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - t0).count();
    std::cout << "took " << us << " us\n";

    // Numbers piped in get sorted and tallied.
    std::vector<long> nums;
    long v;
    while (std::cin >> v) nums.push_back(v);
    if (!nums.empty()) {
        std::sort(nums.begin(), nums.end());
        std::map<long, int> counts;
        for (auto x : nums) ++counts[x];
        std::cout << "stdin: " << nums.size() << " numbers, sorted:";
        for (auto x : nums) std::cout << ' ' << x;
        std::cout << "\nmost common:";
        auto best = std::max_element(counts.begin(), counts.end(), [](auto& a, auto& b) { return a.second < b.second; });
        std::cout << ' ' << best->first << " (x" << best->second << ")\n";
    }
    return 0;
}
