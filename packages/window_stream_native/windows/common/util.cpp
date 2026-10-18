// Strings, time and logging.

#include "wsn_common.h"

#include <algorithm>
#include <cstdarg>
#include <cstdio>
#include <mutex>

namespace wsn {

std::wstring Utf8ToWide(const char* text) {
  if (text == nullptr || *text == 0) {
    return std::wstring();
  }
  int length = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
  if (length <= 1) {
    return std::wstring();
  }
  std::wstring out(static_cast<size_t>(length - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text, -1, out.data(), length);
  return out;
}

std::wstring Utf8ToWide(const std::string& text) { return Utf8ToWide(text.c_str()); }

std::string WideToUtf8(const wchar_t* text, int length) {
  if (text == nullptr || length == 0) {
    return std::string();
  }
  if (length < 0) {
    length = static_cast<int>(wcslen(text));
    if (length == 0) {
      return std::string();
    }
  }
  int bytes = WideCharToMultiByte(CP_UTF8, 0, text, length, nullptr, 0, nullptr, nullptr);
  if (bytes <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(bytes), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text, length, out.data(), bytes, nullptr, nullptr);
  return out;
}

bool EnvFlag(const wchar_t* name) {
  wchar_t value[8] = {};
  DWORD length = GetEnvironmentVariableW(name, value, 8);
  return length > 0 && length < 8 && value[0] == L'1';
}

std::string WideToUtf8(const std::wstring& text) {
  return WideToUtf8(text.c_str(), static_cast<int>(text.size()));
}

namespace {

double QpcFrequency() {
  static const double frequency = [] {
    LARGE_INTEGER value;
    QueryPerformanceFrequency(&value);
    return static_cast<double>(value.QuadPart);
  }();
  return frequency;
}

// Leaked on purpose: threads of this DLL may still run while the process
// exits and runs static destructors (the app calls exit(0)).
std::mutex& g_log_mutex = *new std::mutex();
HANDLE g_log_file = INVALID_HANDLE_VALUE;
bool g_log_tried = false;
int64_t g_log_written = 0;
constexpr int64_t kLogLimit = 1024 * 1024;

std::wstring LogDirectory() {
  wchar_t base[MAX_PATH];
  DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", base, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    return std::wstring();
  }
  std::wstring dir(base, length);
  dir += L"\\Whisper";
  CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\window_stream";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir;
}

// g_log_mutex held.
void OpenLogFile() {
  g_log_tried = true;
  std::wstring dir = LogDirectory();
  if (dir.empty()) {
    return;
  }
  std::wstring path = dir + L"\\native.log";
  WIN32_FILE_ATTRIBUTE_DATA info = {};
  if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) {
    int64_t size = (static_cast<int64_t>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    if (size > kLogLimit) {
      std::wstring previous = dir + L"\\native.1.log";
      MoveFileExW(path.c_str(), previous.c_str(), MOVEFILE_REPLACE_EXISTING);
    }
  }
  g_log_file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (g_log_file != INVALID_HANDLE_VALUE) {
    LARGE_INTEGER size = {};
    GetFileSizeEx(g_log_file, &size);
    g_log_written = size.QuadPart;
  }
}

}  // namespace

double NowSeconds() {
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  return static_cast<double>(now.QuadPart) / QpcFrequency();
}

int64_t NowMicros() { return static_cast<int64_t>(NowSeconds() * 1e6); }

void Log(const char* format, ...) {
  char message[1024];
  va_list args;
  va_start(args, format);
  int length = vsnprintf(message, sizeof(message), format, args);
  va_end(args);
  if (length < 0) {
    return;
  }
  SYSTEMTIME time;
  GetLocalTime(&time);
  char line[1200];
  int total = snprintf(line, sizeof(line), "%04u-%02u-%02u %02u:%02u:%02u.%03u [wsn %lu] %s\r\n", time.wYear,
                       time.wMonth, time.wDay, time.wHour, time.wMinute, time.wSecond, time.wMilliseconds,
                       GetCurrentThreadId(), message);
  if (total <= 0) {
    return;
  }
  total = std::min<int>(total, static_cast<int>(sizeof(line)) - 1);
  OutputDebugStringA(line);
  std::lock_guard<std::mutex> lock(g_log_mutex);
  if (!g_log_tried) {
    OpenLogFile();
  }
  if (g_log_file == INVALID_HANDLE_VALUE) {
    return;
  }
  if (g_log_written > kLogLimit) {
    CloseHandle(g_log_file);
    g_log_file = INVALID_HANDLE_VALUE;
    OpenLogFile();
    if (g_log_file == INVALID_HANDLE_VALUE) {
      return;
    }
  }
  DWORD written = 0;
  WriteFile(g_log_file, line, static_cast<DWORD>(total), &written, nullptr);
  g_log_written += written;
}

}  // namespace wsn
