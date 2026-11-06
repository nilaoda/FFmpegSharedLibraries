/* 同时引用原生线程接口和 C++ 运行时，检查静态线程库链接是否一致。 */
#include <mutex>
#include <stdexcept>
#include <thread>
#include <pthread.h>

int main()
{
    if (pthread_num_processors_np() < 1)
        return 1;
    std::mutex mutex;
    int value = 0;
    std::thread worker([&] {
        std::lock_guard<std::mutex> lock(mutex);
        value = 1;
    });
    worker.join();
    try {
        throw std::runtime_error("static linkage probe");
    } catch (const std::runtime_error &) {
        return value == 1 ? 0 : 1;
    }
}
