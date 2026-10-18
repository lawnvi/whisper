#include "capture/capture_thread.h"

#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>

namespace wsn::capture {

namespace {

struct Thread {
  GMainContext* context = nullptr;
  GMainLoop* loop = nullptr;
  std::thread::id id;
};

std::once_flag g_once;
Thread* g_thread = nullptr;

Thread& Get() {
  std::call_once(g_once, [] {
    auto* thread = new Thread();
    thread->context = g_main_context_new();
    thread->loop = g_main_loop_new(thread->context, FALSE);
    std::mutex mutex;
    std::condition_variable ready;
    bool started = false;
    std::thread([thread, &mutex, &ready, &started] {
      g_main_context_push_thread_default(thread->context);
      {
        // Notified under the lock: the waiter owns these and may return
        // (destroying them) as soon as it sees `started`.
        std::lock_guard<std::mutex> lock(mutex);
        thread->id = std::this_thread::get_id();
        started = true;
        ready.notify_all();
      }
      // Lives as long as the process: Mutter removes the virtual monitors
      // and the helper puts windows back when our bus connection closes.
      g_main_loop_run(thread->loop);
    }).detach();
    std::unique_lock<std::mutex> lock(mutex);
    ready.wait(lock, [&] { return started; });
    g_thread = thread;
  });
  return *g_thread;
}

gboolean RunTask(gpointer data) {
  auto* task = static_cast<std::function<void()>*>(data);
  (*task)();
  return G_SOURCE_REMOVE;
}

void DeleteTask(gpointer data) { delete static_cast<std::function<void()>*>(data); }

}  // namespace

void Post(std::function<void()> task) {
  Thread& thread = Get();
  GSource* source = g_idle_source_new();
  g_source_set_priority(source, G_PRIORITY_DEFAULT);
  g_source_set_callback(source, RunTask, new std::function<void()>(std::move(task)), DeleteTask);
  g_source_attach(source, thread.context);
  g_source_unref(source);
}

guint PostAfter(guint delay_ms, std::function<void()> task) {
  Thread& thread = Get();
  GSource* source = g_timeout_source_new(delay_ms);
  g_source_set_callback(source, RunTask, new std::function<void()>(std::move(task)), DeleteTask);
  guint id = g_source_attach(source, thread.context);
  g_source_unref(source);
  return id;
}

void CancelTimer(guint id) {
  if (id == 0) return;
  GSource* source = g_main_context_find_source_by_id(Get().context, id);
  if (source != nullptr) g_source_destroy(source);
}

bool PostAndWait(std::function<void()> task, int timeout_ms) {
  struct Wait {
    std::mutex mutex;
    std::condition_variable done;
    bool finished = false;
  };
  auto wait = std::make_shared<Wait>();
  Post([wait, task = std::move(task)] {
    task();
    std::lock_guard<std::mutex> lock(wait->mutex);
    wait->finished = true;
    wait->done.notify_all();
  });
  std::unique_lock<std::mutex> lock(wait->mutex);
  return wait->done.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return wait->finished; });
}

bool OnCaptureThread() { return std::this_thread::get_id() == Get().id; }

GMainContext* Context() { return Get().context; }

}  // namespace wsn::capture
