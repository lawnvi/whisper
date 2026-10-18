#include "wsn_util.h"

#include <shlobj.h>

#include <cstdio>

namespace wsn {

std::wstring Widen(std::string_view text) {
  if (text.empty()) return std::wstring();
  int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), length);
  return out;
}

std::string Narrow(std::wstring_view text) {
  if (text.empty()) return std::string();
  int bytes = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr,
                                  nullptr);
  std::string out(static_cast<size_t>(bytes), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), bytes, nullptr, nullptr);
  return out;
}

namespace {
double TicksPerMs() {
  static double value = [] {
    LARGE_INTEGER frequency;
    QueryPerformanceFrequency(&frequency);
    return static_cast<double>(frequency.QuadPart) / 1000.0;
  }();
  return value;
}
}  // namespace

double NowMs() {
  LARGE_INTEGER now;
  QueryPerformanceCounter(&now);
  return static_cast<double>(now.QuadPart) / TicksPerMs();
}

int64_t NowUs() { return static_cast<int64_t>(NowMs() * 1000.0); }

std::string Format(const char* format, ...) {
  char stack[1024];
  va_list args;
  va_start(args, format);
  int needed = vsnprintf(stack, sizeof(stack), format, args);
  va_end(args);
  if (needed < 0) return std::string();
  if (needed < static_cast<int>(sizeof(stack))) return std::string(stack, static_cast<size_t>(needed));
  std::string out(static_cast<size_t>(needed) + 1, '\0');
  va_start(args, format);
  vsnprintf(out.data(), out.size(), format, args);
  va_end(args);
  out.resize(static_cast<size_t>(needed));
  return out;
}

std::string JsonEscape(std::string_view text) {
  std::string out;
  out.reserve(text.size() + 8);
  for (unsigned char c : text) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          out += Format("\\u%04x", c);
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out;
}

std::string HrText(HRESULT hr) { return Format("0x%08lx", static_cast<unsigned long>(hr)); }

bool WriteFileAtomic(const std::wstring& path, const std::string& data) {
  std::wstring temp = path + L".tmp";
  HANDLE file = CreateFileW(temp.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  DWORD written = 0;
  BOOL ok = WriteFile(file, data.data(), static_cast<DWORD>(data.size()), &written, nullptr) &&
            written == data.size();
  FlushFileBuffers(file);
  CloseHandle(file);
  if (!ok) {
    DeleteFileW(temp.c_str());
    return false;
  }
  if (!MoveFileExW(temp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    DeleteFileW(temp.c_str());
    return false;
  }
  return true;
}

bool ReadFileBytes(const std::wstring& path, std::string* out) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return false;
  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size) || size.QuadPart > 64 * 1024 * 1024) {
    CloseHandle(file);
    return false;
  }
  out->assign(static_cast<size_t>(size.QuadPart), '\0');
  DWORD read = 0;
  BOOL ok = out->empty() || (ReadFile(file, out->data(), static_cast<DWORD>(out->size()), &read, nullptr) &&
                             read == out->size());
  CloseHandle(file);
  return ok != FALSE;
}

std::wstring StateDirectory() {
  PWSTR base = nullptr;
  std::wstring dir;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr, &base)) && base != nullptr) {
    dir = base;
  }
  CoTaskMemFree(base);
  if (dir.empty()) return dir;
  dir += L"\\Whisper";
  CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\window_stream";
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir;
}

void PumpSleep(DWORD ms) {
  double end = NowMs() + ms;
  for (;;) {
    double left = end - NowMs();
    if (left <= 0) break;
    DWORD wait = static_cast<DWORD>(left) + 1;
    MsgWaitForMultipleObjectsEx(0, nullptr, wait, QS_ALLINPUT, MWMO_ALERTABLE | MWMO_INPUTAVAILABLE);
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
      TranslateMessage(&msg);
      DispatchMessageW(&msg);
    }
  }
}

}  // namespace wsn
