// Minimal model of WinRT's immediately-invoked capturing coroutine lambdas.
// This demonstrates C++ closure lifetime, not a Windows integration test.
// clang++ -std=c++20 -O1 -g -fsanitize=address -fsanitize-address-use-after-scope \
//   coroutine_lifetime.cpp -o /tmp/fbp-coroutine-audit && /tmp/fbp-coroutine-audit
#include <coroutine>
#include <memory>
#include <cstdio>

std::coroutine_handle<> pending;
struct FireAndForget {
  struct promise_type {
    FireAndForget get_return_object() { return {}; }
    std::suspend_never initial_suspend() noexcept { return {}; }
    std::suspend_never final_suspend() noexcept { return {}; }
    void return_void() {}
    void unhandled_exception() { std::terminate(); }
  };
};
struct SwitchThread {
  bool await_ready() { return false; }
  void await_suspend(std::coroutine_handle<> handle) { pending = handle; }
  void await_resume() {}
};

FireAndForget deliver(std::shared_ptr<bool> alive) {
  co_await SwitchThread{};
  if (*alive) std::puts("event delivered safely");
}

int main() {
  auto alive = std::make_shared<bool>(true);
#ifdef FBP_REPRODUCE_OLD_CLOSURE
  [alive]() -> FireAndForget {
    co_await SwitchThread{};
    if (*alive) std::puts("event delivered");
  }(); // closure dies here while the coroutine is suspended
#else
  deliver(alive); // by-value parameter lives in the coroutine frame
  alive.reset();
#endif
  pending.resume();
}
