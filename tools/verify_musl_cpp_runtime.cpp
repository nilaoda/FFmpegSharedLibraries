#include <atomic>
#include <stdexcept>
#include <thread>

int main()
{
    std::atomic<unsigned> completed{0};
    std::thread worker([&completed]() { completed.fetch_add(1, std::memory_order_relaxed); });
    bool caught = false;
    try {
        throw std::runtime_error("static musl C++ unwind probe");
    } catch (const std::runtime_error &) {
        caught = true;
    }
    worker.join();
    return caught && completed.load(std::memory_order_relaxed) == 1 ? 0 : 1;
}
