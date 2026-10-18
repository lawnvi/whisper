// Small helpers shared by the Windows capture code and its probe.
#pragma once

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <cstdarg>
#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace wsn {

std::wstring Widen(std::string_view text);
std::string Narrow(std::wstring_view text);

// Monotonic clock (QueryPerformanceCounter).
double NowMs();
int64_t NowUs();

std::string Format(const char* format, ...);
std::string JsonEscape(std::string_view text);
inline std::string JsonString(std::string_view text) { return "\"" + JsonEscape(text) + "\""; }
inline std::string JsonString(std::wstring_view text) { return JsonString(Narrow(text)); }

std::string HrText(HRESULT hr);

// Writes [data] to [path] through a temporary file and an atomic rename.
bool WriteFileAtomic(const std::wstring& path, const std::string& data);
bool ReadFileBytes(const std::wstring& path, std::string* out);

// %LOCALAPPDATA%\Whisper\window_stream (created on demand).
std::wstring StateDirectory();

// Sleeps while still dispatching sent messages and APCs on this thread.
void PumpSleep(DWORD ms);

}  // namespace wsn
