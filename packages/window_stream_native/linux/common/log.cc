#include "common/log.h"

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace wsn {

void Log(const char* format, ...) {
  char line[1024];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof(line), format, args);
  va_end(args);
  GDateTime* now = g_date_time_new_now_local();
  std::fprintf(stderr, "[window_stream %02d:%02d:%02d.%03d] %s\n", g_date_time_get_hour(now),
               g_date_time_get_minute(now), g_date_time_get_second(now), g_date_time_get_microsecond(now) / 1000,
               line);
  g_date_time_unref(now);
}

bool TraceEnabled() {
  static const bool enabled = [] {
    const char* value = std::getenv("WHISPER_WSN_TRACE");
    return value != nullptr && std::strcmp(value, "0") != 0 && *value != '\0';
  }();
  return enabled;
}

}  // namespace wsn
