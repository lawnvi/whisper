// Native diagnostics on stderr (the journal when launched from the desktop).
// No user content: ids, sizes, codes. WHISPER_WSN_TRACE=1 turns on WSN_TRACE.

#ifndef WSN_COMMON_LOG_H_
#define WSN_COMMON_LOG_H_

#include <glib.h>

namespace wsn {

void Log(const char* format, ...) G_GNUC_PRINTF(1, 2);
bool TraceEnabled();

}  // namespace wsn

#define WSN_LOG(...) ::wsn::Log(__VA_ARGS__)
#define WSN_TRACE(...)                              \
  do {                                              \
    if (::wsn::TraceEnabled()) ::wsn::Log(__VA_ARGS__); \
  } while (0)

#endif  // WSN_COMMON_LOG_H_
