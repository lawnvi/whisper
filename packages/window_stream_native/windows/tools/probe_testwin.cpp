// The test window: paints a 16-bit frame counter as black/white blocks at
// 60 Hz (readable from any picture of it), and logs every input message it
// gets with a QPC timestamp, so a stream's input can be checked exactly.
//
// Layout (client area W x H): blocks in [0.02H, 0.14H), 18 across, block 0
// white, block 17 black, blocks 1..16 the counter, most significant first.
// An edit control (bottom left) and a combo box (bottom right) give text
// focus and a drop-down to test with.
#include "probe.h"

#include <mmsystem.h>

#include "core/wsn_window.h"

#include <commctrl.h>
#include <commdlg.h>
#include <dwmapi.h>

#include <atomic>
#include <cstdio>
#include <thread>

namespace probe {

namespace {

constexpr UINT kTick = WM_APP + 1;
constexpr UINT kOpenDialog = WM_APP + 5;
constexpr int kEditId = 100;
constexpr int kComboId = 101;

FILE* g_input_log = nullptr;
HWND g_window = nullptr;
HWND g_edit = nullptr;
HWND g_combo = nullptr;
std::atomic<int> g_counter{0};
bool g_animate = true;
bool g_modal_on_close = false;
std::wstring g_play_wav;
int g_clicks = 0;
int g_keys = 0;
POINT g_last_click{-1, -1};
std::wstring g_text;
std::wstring g_tag;

void Line(const char* format, ...) {
  if (!g_input_log) return;
  char buffer[2048];
  va_list args;
  va_start(args, format);
  vsnprintf(buffer, sizeof(buffer), format, args);
  va_end(args);
  fprintf(g_input_log, "t=%.3f %s\n", wsn::NowMs(), buffer);
  fflush(g_input_log);
}

const char* Name(UINT message) {
  switch (message) {
    case WM_MOUSEMOVE: return "WM_MOUSEMOVE";
    case WM_LBUTTONDOWN: return "WM_LBUTTONDOWN";
    case WM_LBUTTONUP: return "WM_LBUTTONUP";
    case WM_LBUTTONDBLCLK: return "WM_LBUTTONDBLCLK";
    case WM_RBUTTONDOWN: return "WM_RBUTTONDOWN";
    case WM_RBUTTONUP: return "WM_RBUTTONUP";
    case WM_RBUTTONDBLCLK: return "WM_RBUTTONDBLCLK";
    case WM_MBUTTONDOWN: return "WM_MBUTTONDOWN";
    case WM_MBUTTONUP: return "WM_MBUTTONUP";
    case WM_MOUSEWHEEL: return "WM_MOUSEWHEEL";
    case WM_MOUSEHWHEEL: return "WM_MOUSEHWHEEL";
    case WM_KEYDOWN: return "WM_KEYDOWN";
    case WM_KEYUP: return "WM_KEYUP";
    case WM_SYSKEYDOWN: return "WM_SYSKEYDOWN";
    case WM_SYSKEYUP: return "WM_SYSKEYUP";
    case WM_CHAR: return "WM_CHAR";
    case WM_SYSCHAR: return "WM_SYSCHAR";
    case WM_UNICHAR: return "WM_UNICHAR";
    case WM_IME_CHAR: return "WM_IME_CHAR";
    default: return nullptr;
  }
}

void LogMouse(const char* who, HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  POINT client{static_cast<short>(LOWORD(lparam)), static_cast<short>(HIWORD(lparam))};
  POINT screen = client;
  bool wheel = message == WM_MOUSEWHEEL || message == WM_MOUSEHWHEEL;
  if (wheel) {
    ScreenToClient(hwnd, &client);
  } else {
    ClientToScreen(hwnd, &screen);
  }
  RECT frame = wsn::FrameBounds(g_window);
  double fx = (screen.x - frame.left + 0.5) / std::max(1, wsn::RectWidth(frame));
  double fy = (screen.y - frame.top + 0.5) / std::max(1, wsn::RectHeight(frame));
  int delta = wheel ? GET_WHEEL_DELTA_WPARAM(wparam) : 0;
  WORD keys = wheel ? GET_KEYSTATE_WPARAM(wparam) : static_cast<WORD>(wparam);
  Line("who=%s msg=%s x=%ld y=%ld sx=%ld sy=%ld fx=%.4f fy=%.4f mk=0x%x delta=%d", who, Name(message), client.x,
       client.y, screen.x, screen.y, fx, fy, keys, delta);
}

void LogKey(const char* who, UINT message, WPARAM wparam, LPARAM lparam) {
  UINT scan = (lparam >> 16) & 0xff;
  bool extended = (lparam >> 24) & 1;
  bool repeat = (lparam >> 30) & 1;
  bool ctrl = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
  bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
  bool alt = (GetKeyState(VK_MENU) & 0x8000) != 0;
  bool win = ((GetKeyState(VK_LWIN) | GetKeyState(VK_RWIN)) & 0x8000) != 0;
  if (message == WM_CHAR || message == WM_SYSCHAR || message == WM_UNICHAR || message == WM_IME_CHAR) {
    Line("who=%s msg=%s char=U+%04X ctrl=%d shift=%d alt=%d", who, Name(message), static_cast<unsigned>(wparam),
         ctrl, shift, alt);
  } else {
    Line("who=%s msg=%s vk=0x%02X scan=0x%02X ext=%d rep=%d ctrl=%d shift=%d alt=%d win=%d", who, Name(message),
         static_cast<unsigned>(wparam), scan, extended, repeat, ctrl, shift, alt, win);
  }
}

LRESULT CALLBACK ChildProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam, UINT_PTR id, DWORD_PTR) {
  const char* who = id == kEditId ? "edit" : "combo";
  if (Name(message) != nullptr) {
    if (message >= WM_KEYFIRST && message <= WM_KEYLAST) {
      LogKey(who, message, wparam, lparam);
    } else if (message != WM_MOUSEMOVE) {
      LogMouse(who, hwnd, message, wparam, lparam);
    }
  } else if (message == WM_SETFOCUS || message == WM_KILLFOCUS) {
    Line("who=%s msg=%s", who, message == WM_SETFOCUS ? "WM_SETFOCUS" : "WM_KILLFOCUS");
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

int g_paints = 0;

void Paint(HWND hwnd) {
  if (++g_paints % 30 == 0) Line("who=main msg=PAINTS n=%d counter=%d", g_paints, g_counter.load());
  PAINTSTRUCT ps;
  HDC target = BeginPaint(hwnd, &ps);
  RECT client;
  GetClientRect(hwnd, &client);
  int w = client.right, h = client.bottom;
  HDC dc = CreateCompatibleDC(target);
  HBITMAP bitmap = CreateCompatibleBitmap(target, std::max(w, 1), std::max(h, 1));
  HGDIOBJ old = SelectObject(dc, bitmap);
  HBRUSH gray = CreateSolidBrush(RGB(128, 128, 128));
  FillRect(dc, &client, gray);
  DeleteObject(gray);
  int counter = g_counter.load() & 0xffff;
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, RGB(255, 255, 255));
  HFONT font = CreateFontW(-std::max(12, h / 30), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0,
                           CLEARTYPE_QUALITY, 0, L"Segoe UI");
  HGDIOBJ old_font = SelectObject(dc, font);
  std::wstring status = L"WSN test " + g_tag + L"  frame " + std::to_wstring(counter) + L"  clicks " +
                        std::to_wstring(g_clicks) + L"  keys " + std::to_wstring(g_keys);
  RECT line{16, static_cast<LONG>(0.16 * h), w, static_cast<LONG>(0.24 * h)};
  DrawTextW(dc, status.c_str(), -1, &line, DT_LEFT | DT_SINGLELINE);
  RECT text{16, static_cast<LONG>(0.25 * h), w, static_cast<LONG>(0.6 * h)};
  DrawTextW(dc, g_text.c_str(), -1, &text, DT_LEFT | DT_WORDBREAK);
  SelectObject(dc, old_font);
  DeleteObject(font);
  if (g_last_click.x >= 0) {
    HPEN pen = CreatePen(PS_SOLID, 1, RGB(255, 0, 0));
    HGDIOBJ old_pen = SelectObject(dc, pen);
    MoveToEx(dc, g_last_click.x - 12, g_last_click.y, nullptr);
    LineTo(dc, g_last_click.x + 13, g_last_click.y);
    MoveToEx(dc, g_last_click.x, g_last_click.y - 12, nullptr);
    LineTo(dc, g_last_click.x, g_last_click.y + 13);
    SelectObject(dc, old_pen);
    DeleteObject(pen);
  }
  // The canonical frame counter (agent E's spec, decoded by
  // tool/frame_probe.dart), drawn last so nothing covers it. cell = 16
  // logical px scaled by the window DPI; grey quiet zone 22x4 cells at
  // (16,16); code 20x2 cells at cell (1,1); row 0 = guard W B W B then
  // bits 15..0 (1=white); row 1 = row 0 inverted.
  {
    UINT dpi = GetDpiForWindow(hwnd);
    int cell = std::max(3, MulDiv(16, dpi, 96));
    int qx = 16, qy = 16;
    RECT quiet{qx, qy, qx + 22 * cell, qy + 4 * cell};
    FillRect(dc, &quiet, static_cast<HBRUSH>(GetStockObject(GRAY_BRUSH)));
    HBRUSH q = CreateSolidBrush(RGB(128, 128, 128));
    FillRect(dc, &quiet, q);
    DeleteObject(q);
    int cx = qx + cell, cy = qy + cell;  // code top-left (cell (1,1))
    auto fill = [&](int col, int row, bool white) {
      RECT r{cx + col * cell, cy + row * cell, cx + (col + 1) * cell, cy + (row + 1) * cell};
      FillRect(dc, &r, static_cast<HBRUSH>(GetStockObject(white ? WHITE_BRUSH : BLACK_BRUSH)));
    };
    const bool guard[4] = {true, false, true, false};
    for (int col = 0; col < 20; ++col) {
      bool white = col < 4 ? guard[col] : ((counter >> (15 - (col - 4))) & 1) != 0;
      fill(col, 0, white);
      fill(col, 1, !white);
    }
  }
  BitBlt(target, 0, 0, w, h, dc, 0, 0, SRCCOPY);
  SelectObject(dc, old);
  DeleteObject(bitmap);
  DeleteDC(dc);
  EndPaint(hwnd, &ps);
}

void Layout(HWND hwnd) {
  RECT client;
  GetClientRect(hwnd, &client);
  int w = client.right, h = client.bottom;
  if (g_edit) MoveWindow(g_edit, w * 5 / 100, h * 62 / 100, w * 55 / 100, h * 33 / 100, TRUE);
  if (g_combo) MoveWindow(g_combo, w * 65 / 100, h * 62 / 100, w * 30 / 100, h * 40 / 100, TRUE);
}

void ShowMenu(HWND hwnd, POINT at) {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, 1, L"First item");
  AppendMenuW(menu, MF_STRING, 2, L"Second item");
  AppendMenuW(menu, MF_STRING, 3, L"Open dialog...");
  Line("who=main msg=MENU_SHOW x=%ld y=%ld", at.x, at.y);
  int choice = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, at.x, at.y, 0, hwnd, nullptr);
  Line("who=main msg=MENU_DONE choice=%d", choice);
  DestroyMenu(menu);
  if (choice == 3) PostMessageW(hwnd, kOpenDialog, 0, 0);
}

LRESULT CALLBACK WindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_CREATE: {
      g_edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                               WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_WANTRETURN,
                               0, 0, 10, 10, hwnd, reinterpret_cast<HMENU>(kEditId), nullptr, nullptr);
      g_combo = CreateWindowExW(0, L"COMBOBOX", L"", WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0,
                                10, 200, hwnd, reinterpret_cast<HMENU>(kComboId), nullptr, nullptr);
      for (const wchar_t* item : {L"Apple", L"Banana", L"Cherry", L"Durian", L"Elderberry"}) {
        SendMessageW(g_combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(item));
      }
      SendMessageW(g_combo, CB_SETCURSEL, 0, 0);
      HFONT font = CreateFontW(-18, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0,
                               L"Segoe UI");
      SendMessageW(g_edit, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
      SendMessageW(g_combo, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
      SetWindowSubclass(g_edit, ChildProc, kEditId, 0);
      SetWindowSubclass(g_combo, ChildProc, kComboId, 0);
      Layout(hwnd);
      return 0;
    }
    case WM_SIZE:
      Layout(hwnd);
      Line("who=main msg=WM_SIZE w=%d h=%d type=%d", LOWORD(lparam), HIWORD(lparam), static_cast<int>(wparam));
      InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    case WM_WINDOWPOSCHANGED: {
      RECT rect;
      GetWindowRect(hwnd, &rect);
      Line("who=main msg=WM_WINDOWPOSCHANGED l=%ld t=%ld r=%ld b=%ld", rect.left, rect.top, rect.right,
           rect.bottom);
      break;
    }
    case WM_DPICHANGED:
      Line("who=main msg=WM_DPICHANGED dpi=%d", LOWORD(wparam));
      break;
    case kTick:
      g_counter++;
      if (!IsIconic(hwnd)) {
        RECT client;
        GetClientRect(hwnd, &client);
        RECT band{0, 0, client.right, static_cast<LONG>(0.25 * client.bottom)};
        InvalidateRect(hwnd, &band, FALSE);
      }
      return 0;
    case WM_PAINT:
      Paint(hwnd);
      return 0;
    case WM_ERASEBKGND:
      return 1;
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_LBUTTONDBLCLK:
      g_clicks++;
      g_last_click = POINT{static_cast<short>(LOWORD(lparam)), static_cast<short>(HIWORD(lparam))};
      LogMouse("main", hwnd, message, wparam, lparam);
      SetFocus(hwnd);
      InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    case WM_MOUSEMOVE:
    case WM_LBUTTONUP:
    case WM_RBUTTONUP:
    case WM_MBUTTONUP:
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
      LogMouse("main", hwnd, message, wparam, lparam);
      break;
    case WM_CONTEXTMENU: {
      POINT at{static_cast<short>(LOWORD(lparam)), static_cast<short>(HIWORD(lparam))};
      Line("who=main msg=WM_CONTEXTMENU x=%ld y=%ld", at.x, at.y);
      if (lparam == -1) {
        RECT rect;
        GetWindowRect(hwnd, &rect);
        at = POINT{(rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2};
      }
      ShowMenu(hwnd, at);
      return 0;
    }
    case kOpenDialog: {
      wchar_t file[MAX_PATH] = L"";
      OPENFILENAMEW ofn{sizeof(ofn)};
      ofn.hwndOwner = hwnd;
      ofn.lpstrFile = file;
      ofn.nMaxFile = MAX_PATH;
      ofn.Flags = OFN_EXPLORER | OFN_FILEMUSTEXIST;
      Line("who=main msg=OPEN_DIALOG_SHOW");
      BOOL chosen = GetOpenFileNameW(&ofn);
      Line("who=main msg=OPEN_DIALOG_DONE chosen=%d", chosen);
      return 0;
    }
    case WM_KEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYDOWN:
    case WM_SYSKEYUP:
      if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) g_keys++;
      LogKey("main", message, wparam, lparam);
      break;
    case WM_CHAR: {
      LogKey("main", message, wparam, lparam);
      wchar_t c = static_cast<wchar_t>(wparam);
      if (c == 8) {
        if (!g_text.empty()) g_text.pop_back();
      } else if (c == 13) {
        g_text += L"\n";
      } else if (c >= 0x20 || c == 9) {
        g_text += c;
      }
      Line("who=main msg=TEXT text=%s", wsn::JsonString(g_text).c_str());
      InvalidateRect(hwnd, nullptr, FALSE);
      return 0;
    }
    case WM_SYSCHAR:
    case WM_UNICHAR:
      LogKey("main", message, wparam, lparam);
      if (message == WM_UNICHAR) return wparam == UNICODE_NOCHAR ? TRUE : FALSE;
      break;
    case WM_COMMAND:
      if (HIWORD(wparam) == 1 && lparam == 0) {
        // From the accelerator table (TranslateAccelerator in the loop).
        const char* name = LOWORD(wparam) == 0x7101   ? "ctrl+s"
                           : LOWORD(wparam) == 0x7102 ? "f5"
                           : LOWORD(wparam) == 0x7103 ? "alt+x"
                                                      : "ctrl+shift+n";
        Line("who=main msg=ACCEL id=0x%04x name=%s", LOWORD(wparam), name);
        return 0;
      }
      if (LOWORD(wparam) == kEditId && HIWORD(wparam) == EN_CHANGE) {
        int length = GetWindowTextLengthW(g_edit);
        std::wstring text(static_cast<size_t>(length) + 1, L'\0');
        GetWindowTextW(g_edit, text.data(), length + 1);
        text.resize(static_cast<size_t>(length));
        Line("who=edit msg=EDIT_TEXT text=%s", wsn::JsonString(text).c_str());
      } else if (LOWORD(wparam) == kComboId) {
        Line("who=combo msg=COMBO_NOTIFY code=%d sel=%d", HIWORD(wparam),
             static_cast<int>(SendMessageW(g_combo, CB_GETCURSEL, 0, 0)));
      }
      break;
    case WM_SETFOCUS:
    case WM_KILLFOCUS:
      Line("who=main msg=%s", message == WM_SETFOCUS ? "WM_SETFOCUS" : "WM_KILLFOCUS");
      break;
    case WM_ACTIVATE:
      Line("who=main msg=WM_ACTIVATE state=%d", LOWORD(wparam));
      break;
    case WM_MOUSEACTIVATE:
      Line("who=main msg=WM_MOUSEACTIVATE");
      break;
    case WM_SYSCOMMAND:
      Line("who=main msg=WM_SYSCOMMAND cmd=0x%04X", static_cast<unsigned>(wparam & 0xfff0));
      break;
    case WM_DISPLAYCHANGE:
      Line("who=main msg=WM_DISPLAYCHANGE");
      break;
    case WM_CLOSE:
      Line("who=main msg=WM_CLOSE");
      if (g_modal_on_close) {
        // Ask like "Save changes?": an owned, modal message box. The window
        // stays open and should report modal until the box is answered.
        Line("who=main msg=MODAL_SHOW");
        int choice = MessageBoxW(hwnd, L"Save changes?", L"WSN Test", MB_YESNOCANCEL | MB_ICONWARNING);
        Line("who=main msg=MODAL_DONE choice=%d", choice);
        if (choice == IDCANCEL) return 0;  // stay open
      }
      DestroyWindow(hwnd);
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

}  // namespace

int RunTestWindow(const Args& args) {
  g_tag = args.Get(L"--tag", L"t");
  g_animate = !args.Has(L"--static");
  g_modal_on_close = args.Has(L"--modal-on-close");
  g_play_wav = args.Get(L"--play-wav");
  std::wstring log = args.Get(L"--log");
  std::wstring info = args.Get(L"--info");
  int width = args.Int(L"--w", 800);
  int height = args.Int(L"--h", 600);
  int x = args.Int(L"--x", 120);
  int y = args.Int(L"--y", 120);
  if (!log.empty()) g_input_log = _wfopen(log.c_str(), L"ab");
  INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES};
  InitCommonControlsEx(&controls);

  WNDCLASSEXW wc{sizeof(wc)};
  wc.style = CS_DBLCLKS;
  wc.lpfnWndProc = WindowProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.lpszClassName = L"WsnProbeTestWindow";
  RegisterClassExW(&wc);
  std::wstring title = L"WSN Test " + g_tag;
  // The size is the client area at the window's DPI.
  UINT dpi = GetDpiForSystem();
  RECT frame{0, 0, MulDiv(width, dpi, 96), MulDiv(height, dpi, 96)};
  AdjustWindowRectExForDpi(&frame, WS_OVERLAPPEDWINDOW, FALSE, 0, dpi);
  g_window = CreateWindowExW(0, wc.lpszClassName, title.c_str(), WS_OVERLAPPEDWINDOW, x, y,
                             frame.right - frame.left, frame.bottom - frame.top, nullptr, nullptr, wc.hInstance,
                             nullptr);
  if (!g_window) return 1;
  ShowWindow(g_window, args.Has(L"--minimized") ? SW_SHOWMINNOACTIVE
                       : args.Has(L"--maximized") ? SW_SHOWMAXIMIZED
                                                  : SW_SHOWNOACTIVATE);
  UpdateWindow(g_window);
  if (!info.empty()) {
    std::string json = wsn::Format("{\"hwnd\":%lld,\"edit\":%lld,\"combo\":%lld,\"pid\":%lu}",
                                   static_cast<long long>(reinterpret_cast<intptr_t>(g_window)),
                                   static_cast<long long>(reinterpret_cast<intptr_t>(g_edit)),
                                   static_cast<long long>(reinterpret_cast<intptr_t>(g_combo)),
                                   GetCurrentProcessId());
    wsn::WriteFileAtomic(info, json);
  }
  Line("who=main msg=READY hwnd=%p", g_window);

  std::atomic<bool> running{true};
  std::thread ticker([&running] {
    HANDLE timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
    double next = wsn::NowMs();
    while (running) {
      next += 1000.0 / 60.0;
      double wait = next - wsn::NowMs();
      if (wait > 0 && timer) {
        LARGE_INTEGER due;
        due.QuadPart = -static_cast<LONGLONG>(wait * 10000.0);
        SetWaitableTimerEx(timer, &due, 0, nullptr, nullptr, nullptr, 0);
        WaitForSingleObject(timer, 100);
      } else if (wait < -100) {
        next = wsn::NowMs();
      }
      if (g_animate) PostMessageW(g_window, kTick, 0, 0);
    }
    if (timer) CloseHandle(timer);
  });
  // An accelerator table, translated in the loop like a real app's (a sent
  // WM_KEYDOWN never reaches it): Ctrl+S, F5, Alt+X, Ctrl+Shift+N.
  ACCEL accels[] = {{FVIRTKEY | FCONTROL, 'S', 0x7101},
                    {FVIRTKEY, VK_F5, 0x7102},
                    {FVIRTKEY | FALT, 'X', 0x7103},
                    {FVIRTKEY | FCONTROL | FSHIFT, 'N', 0x7104}};
  HACCEL accel_table = CreateAcceleratorTableW(accels, ARRAYSIZE(accels));
  if (!g_play_wav.empty()) {
    // Loop the WAV in THIS process (so process loopback of the window's pid
    // captures it, and muting this pid's session silences it).
    PlaySoundW(g_play_wav.c_str(), nullptr, SND_FILENAME | SND_ASYNC | SND_LOOP);
  }
  MSG msg;
  while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
    if (accel_table && TranslateAcceleratorW(g_window, accel_table, &msg)) continue;
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  if (accel_table) DestroyAcceleratorTable(accel_table);
  running = false;
  if (!g_play_wav.empty()) PlaySoundW(nullptr, nullptr, 0);
  ticker.join();
  Line("who=main msg=EXIT");
  if (g_input_log) fclose(g_input_log);
  return 0;
}

}  // namespace probe
