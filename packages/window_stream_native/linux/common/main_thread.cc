#include "common/main_thread.h"

#include <utility>

namespace wsn {

namespace {

gboolean RunTask(gpointer data) {
  (*static_cast<std::function<void()>*>(data))();
  return G_SOURCE_REMOVE;
}

void DeleteTask(gpointer data) { delete static_cast<std::function<void()>*>(data); }

}  // namespace

void OnMain(std::function<void()> task) {
  g_idle_add_full(G_PRIORITY_DEFAULT, RunTask, new std::function<void()>(std::move(task)), DeleteTask);
}

guint OnMainAfter(guint delay_ms, std::function<void()> task) {
  return g_timeout_add_full(G_PRIORITY_DEFAULT, delay_ms, RunTask, new std::function<void()>(std::move(task)),
                            DeleteTask);
}

bool OnMainThread() { return g_main_context_is_owner(g_main_context_default()) != FALSE; }

}  // namespace wsn
