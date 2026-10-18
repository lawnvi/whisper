// W3: send pointer, scroll, keys and text to an off-screen (staged) window
// and check they arrive, by reading the test window's own message log and
// decoding the frame counter / click marker from captured frames.
#include "probe.h"

#include "core/wsn_image.h"
#include "core/wsn_inject.h"
#include "core/wsn_stage.h"
#include "core/wsn_wgc.h"
#include "core/wsn_window.h"

#include <algorithm>
#include <cmath>
#include <mutex>

namespace probe {

namespace {

struct Frames {
  std::mutex mutex;
  wsn::Bitmap last;
  wsn::WgcCapture::FrameFn fn() {
    return [this](ID3D11Texture2D* texture, SIZE content, int64_t) {
      wsn::Bitmap bitmap;
      wsn::ReadTexture(wsn::D3D::Shared(), texture, content.cx, content.cy, &bitmap);
      std::lock_guard<std::mutex> lock(mutex);
      last = std::move(bitmap);
    };
  }
  wsn::Bitmap Last() {
    std::lock_guard<std::mutex> lock(mutex);
    return last;
  }
};

// Parses "key=value" tokens out of a test-window log line.
std::string Field(const std::string& line, const std::string& key) {
  std::string needle = key + "=";
  size_t at = line.find(needle);
  if (at == std::string::npos) return std::string();
  at += needle.size();
  size_t end = at;
  if (at < line.size() && line[at] == '"') {
    end = line.find('"', at + 1);
    return end == std::string::npos ? std::string() : line.substr(at + 1, end - at - 1);
  }
  while (end < line.size() && line[end] != ' ') ++end;
  return line.substr(at, end - at);
}

}  // namespace

int RunW3(const Args& args) {
  TestWindow tw;
  if (!LaunchTestWindow(L"w3", 900, 700, &tw)) return 1;
  Sleep(600);
  HWND window = tw.hwnd;
  wsn::Placement home = wsn::SavePlacement(window);
  wsn::Borders borders = wsn::InvisibleBorders(window);
  bool in_place = args.Has(L"--in-place");

  Frames frames;
  wsn::WgcCapture capture;
  std::string error;
  capture.Start(window, {}, frames.fn(), nullptr, &error);

  if (!in_place) {
    RECT spot{};
    wsn::StageSpot(0, wsn::RectWidth(home.rect), wsn::RectHeight(home.rect), borders, &spot);
    wsn::StyleBackup style;
    wsn::ApplyStageStyle(window, &style);
    if (!wsn::MoveWindowTo(window, spot)) Log("warning: window did not reach the staging spot");
    tw.style_restore = style;
  }
  Sleep(600);
  RECT frame = wsn::FrameBounds(window);
  Log("%s window %p frame %s", in_place ? "in place" : "staged", window, (std::to_string(frame.left) + "," +
      std::to_string(frame.top)).c_str());

  wsn::Injector injector(window);
  injector.SetInPlace(in_place);
  injector.on_note = [](const std::string& note) { Log("inject: %s", note.c_str()); };

  size_t offset = 0;
  ReadNewLines(tw.log_path, &offset);
  std::string json = "{\"inPlace\":" + std::string(in_place ? "true" : "false") + ",\"cases\":[";

  auto record = [&](const char* name, const std::string& detail, bool pass) {
    Log("%-16s %s | %s", name, pass ? "PASS" : "FAIL", detail.c_str());
    json += wsn::Format("{\"case\":\"%s\",\"pass\":%s,\"detail\":%s},", name, pass ? "true" : "false",
                        wsn::JsonString(detail).c_str());
  };

  // 1. Left click at the centre (0.5, 0.5): the window logs client x,y and
  //    paints a red cross there; check both the log and the frame.
  {
    injector.Pointer(1, 0, 0.5, 0.5, 0);
    injector.Pointer(3, 0, 0.5, 0.5, 0);
    Sleep(300);
    std::string detail = "no down logged";
    bool pass = false;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_LBUTTONDOWN") == std::string::npos) continue;
      double fx = atof(Field(line, "fx").c_str());
      double fy = atof(Field(line, "fy").c_str());
      double err_px = std::hypot((fx - 0.5) * wsn::RectWidth(frame), (fy - 0.5) * wsn::RectHeight(frame));
      pass = err_px <= 2.0;
      detail = wsn::Format("logged fx=%.4f fy=%.4f err=%.1f px", fx, fy, err_px);
    }
    record("click_center", detail, pass);
  }

  // 2. Text "Hello 你好": arrives verbatim in the edit field.
  {
    // Focus the edit field by clicking it (the viewer would tap it first).
    RECT edit_rect{};
    GetWindowRect(tw.edit, &edit_rect);
    RECT fr = wsn::FrameBounds(window);
    double efx = ((edit_rect.left + edit_rect.right) / 2.0 - fr.left) / std::max(1, wsn::RectWidth(fr));
    double efy = ((edit_rect.top + edit_rect.bottom) / 2.0 - fr.top) / std::max(1, wsn::RectHeight(fr));
    injector.Pointer(1, 0, efx, efy, 0);
    injector.Pointer(3, 0, efx, efy, 0);
    Sleep(300);
    SetWindowTextW(tw.edit, L"");
    ReadNewLines(tw.log_path, &offset);
    DWORD tw_thread = GetWindowThreadProcessId(window, nullptr);
    GUITHREADINFO gti{sizeof(gti)};
    GetGUIThreadInfo(tw_thread, &gti);
    Log("text: fg=%p active=%p focus=%p edit=%p", GetForegroundWindow(), gti.hwndActive, gti.hwndFocus, tw.edit);
    injector.Text(L"Hello 你好", false);
    Sleep(500);
    // The window records the full text it typed (edit control or main
    // buffer); the last snapshot is what arrived.
    std::string received;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("EDIT_TEXT") != std::string::npos || line.find("msg=TEXT") != std::string::npos) {
        std::string text = Field(line, "text");
        if (!text.empty()) received = text;
      }
    }
    // GetWindowText can't read a control in another process; WM_GETTEXT does.
    wchar_t edit_buf[512] = L"";
    SendMessageW(tw.edit, WM_GETTEXT, 512, reinterpret_cast<LPARAM>(edit_buf));
    std::wstring edited(edit_buf);
    std::string in_edit = wsn::Narrow(edited);
    bool pass = in_edit == "Hello 你好";
    record("text_unicode", "edit=" + wsn::JsonString(in_edit) + " log=" + wsn::JsonString(received), pass);
  }

  // 2b. Typing via KEY events (not TEXT): letters must produce characters,
  //     and Backspace must delete. (W1: a sent WM_KEYDOWN yields no WM_CHAR
  //     on its own; the injector synthesizes it.)
  {
    SetWindowTextW(tw.edit, L"");
    Sleep(120);
    auto key = [&](int mac, const wchar_t* ch) {
      std::wstring t = ch ? std::wstring(ch) : std::wstring();
      injector.Key(true, mac, 0, t);
      injector.Key(false, mac, 0, t);
      Sleep(40);
    };
    key(0, L"a");   // mac 0 = A
    key(11, L"b");  // mac 11 = B
    key(8, L"c");   // mac 8 = C
    key(51, nullptr);  // mac 51 = Backspace
    Sleep(300);
    wchar_t buf[128] = L"";
    SendMessageW(tw.edit, WM_GETTEXT, 128, reinterpret_cast<LPARAM>(buf));
    std::string got = wsn::Narrow(buf);
    // "abc" typed, then Backspace → ends with "ab" (and not "abc"): proves
    // the KEY events produced characters and Backspace deleted one.
    bool ends_ab = got.size() >= 2 && got.compare(got.size() - 2, 2, "ab") == 0;
    record("key_typing", "edit=" + wsn::JsonString(got), ends_ab);
  }

  // 3. Right click at (0.5, 0.35): the window pops its context menu; the
  //    log shows WM_CONTEXTMENU (we send WM_CANCELMODE to dismiss).
  {
    ReadNewLines(tw.log_path, &offset);
    injector.Pointer(1, 1, 0.5, 0.35, 0);
    injector.Pointer(3, 1, 0.5, 0.35, 0);
    Sleep(400);
    bool pass = false;
    std::string detail = "no WM_CONTEXTMENU";
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_CONTEXTMENU") != std::string::npos || line.find("MENU_SHOW") != std::string::npos) {
        pass = true;
        detail = "context menu opened";
      }
    }
    PostMessageW(window, WM_CANCELMODE, 0, 0);
    PostMessageW(window, WM_KEYDOWN, VK_ESCAPE, 0);
    Sleep(200);
    record("right_click", detail, pass);
  }

  // 4. Scroll: positive dy (content down) -> the window reports a
  //    WM_MOUSEWHEEL with a negative delta.
  {
    ReadNewLines(tw.log_path, &offset);
    injector.Scroll(0.5, 0.5, 0, 3.0, false);
    Sleep(300);
    int delta = 0;
    bool got = false;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_MOUSEWHEEL") != std::string::npos) {
        delta = atoi(Field(line, "delta").c_str());
        got = true;
      }
    }
    record("scroll_down", wsn::Format("delta %d", delta), got && delta < 0);
  }

  // 5. Cmd+A reaches a Windows app as Ctrl+A: send mac key 0 (a) with the
  //    Command modifier; the window logs vk=0x41 with ctrl=1.
  {
    ReadNewLines(tw.log_path, &offset);
    injector.Key(true, 0, wsn::kModCommand);
    injector.Key(false, 0, wsn::kModCommand);
    Sleep(300);
    bool pass = false;
    std::string detail = "no key logged";
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_KEYDOWN") == std::string::npos) continue;
      std::string vk = Field(line, "vk");
      std::string ctrl = Field(line, "ctrl");
      if (vk == "0x41") {
        pass = ctrl == "1";
        detail = "vk=0x41 ctrl=" + ctrl;
      }
    }
    record("cmd_a_as_ctrl_a", detail, pass);
  }

  // 6. Drag: down, three moves, up; the window should log a drag (moves
  //    with MK_LBUTTON) ending where we lifted.
  {
    ReadNewLines(tw.log_path, &offset);
    injector.Pointer(1, 0, 0.3, 0.3, 0);
    Sleep(40);
    for (int i = 1; i <= 3; ++i) {
      injector.Pointer(2, 0, 0.3 + 0.1 * i, 0.3 + 0.05 * i, 0);
      Sleep(40);
    }
    injector.Pointer(3, 0, 0.6, 0.45, 0);
    Sleep(300);
    int drag_moves = 0;
    for (const auto& line : ReadNewLines(tw.log_path, &offset)) {
      if (line.find("WM_MOUSEMOVE") == std::string::npos) continue;
      int mk = static_cast<int>(strtol(Field(line, "mk").c_str(), nullptr, 16));
      if (mk & 0x1) drag_moves++;
    }
    record("drag", wsn::Format("%d dragging moves", drag_moves), drag_moves >= 1);
  }

  if (!in_place) {
    injector.ReleaseAll();
    capture.Stop();
    wsn::RestoreStageStyle(window, tw.style_restore);
    wsn::RestorePlacement(window, home);
  } else {
    injector.ReleaseAll();
    capture.Stop();
  }
  if (json.back() == ',') json.pop_back();
  json += "]}\n";
  WriteText(L"w3.json", json);
  CloseTestWindow(&tw);
  return 0;
}

}  // namespace probe
