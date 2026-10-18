#include "wsn_textfocus.h"

#include "wsn_window.h"

#include <objbase.h>
#include <ole2.h>
#include <UIAutomation.h>
#include <wrl/client.h>

#include <cwchar>

namespace wsn {

namespace {

using Microsoft::WRL::ComPtr;

enum class Verdict { kNo, kYes, kAsk };

bool ClassIs(const wchar_t* cls, const wchar_t* name) { return _wcsicmp(cls, name) == 0; }
bool ClassStarts(const wchar_t* cls, const wchar_t* prefix) {
  return _wcsnicmp(cls, prefix, wcslen(prefix)) == 0;
}

// What the focused control's window class says, if it says anything.
Verdict ClassVerdict(HWND hwnd) {
  wchar_t cls[256] = {};
  GetClassNameW(hwnd, cls, 256);
  if (!IsWindowEnabled(hwnd)) return Verdict::kNo;
  bool read_only = (GetWindowLongW(hwnd, GWL_STYLE) & ES_READONLY) != 0;
  // Win32, WinForms and rich-edit text controls (Notepad's is RichEditD2DPT).
  if (ClassIs(cls, L"Edit") || ClassStarts(cls, L"RichEdit") || ClassStarts(cls, L"WindowsForms10.EDIT") ||
      ClassStarts(cls, L"WindowsForms10.RichEdit") || ClassStarts(cls, L"WindowsForms10.RICHEDIT")) {
    return read_only ? Verdict::kNo : Verdict::kYes;
  }
  static const wchar_t* const kTyped[] = {L"Scintilla", L"TEdit",           L"TMemo",
                                          L"TRichEdit", L"TMaskEdit",       L"ThunderRT6TextBox",
                                          L"ConsoleWindowClass", L"PseudoConsoleWindow"};
  for (const wchar_t* name : kTyped) {
    if (ClassIs(cls, name)) return Verdict::kYes;
  }
  // Web content: never asked (it would switch on its accessibility tree).
  static const wchar_t* const kWeb[] = {L"Chrome_", L"MozillaWindowClass", L"Intermediate D3D Window"};
  for (const wchar_t* prefix : kWeb) {
    if (ClassStarts(cls, prefix)) return Verdict::kNo;
  }
  static const wchar_t* const kPlain[] = {L"Button",          L"Static",           L"ListBox",
                                          L"ScrollBar",       L"SysListView32",    L"SysTreeView32",
                                          L"SysTabControl32", L"ToolbarWindow32",  L"msctls_trackbar32",
                                          L"msctls_progress32", L"SysLink",        L"SysHeader32",
                                          L"#32770"};
  for (const wchar_t* name : kPlain) {
    if (ClassIs(cls, name)) return Verdict::kNo;
  }
  return Verdict::kAsk;
}

bool VariantTrue(const VARIANT& v) { return v.vt == VT_BOOL && v.boolVal != VARIANT_FALSE; }

// The watch's state; lives on the watcher thread only.
struct FocusState {
  HWND window = nullptr;
  HWND core = nullptr;  // a UWP app's CoreWindow inside the frame
  const std::function<void(HWND)>* on_popup = nullptr;
  ComPtr<IUIAutomation> uia;
  ComPtr<IUIAutomationCondition> focused;
  ComPtr<IUIAutomationCacheRequest> cache;
  double due = 0;         // a check asked for by input / a focus event (NowMs)
  bool triggered = false;
  double last_uia_ms = 0;
  HWND last_uia_hwnd = nullptr;
  bool last_uia = false;

  bool Belongs(HWND h) const {
    if (h == nullptr || !IsWindow(h)) return false;
    if (h == window || IsChild(window, h)) return true;
    return core != nullptr && (h == core || IsChild(core, h));
  }

  void InitUia() {
    if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia))) &&
        FAILED(CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia)))) {
      uia = nullptr;
      return;
    }
    // A hung app must not hold the watch (or the stop) for long.
    ComPtr<IUIAutomation2> uia2;
    if (SUCCEEDED(uia.As(&uia2))) {
      uia2->put_ConnectionTimeout(500);
      uia2->put_TransactionTimeout(500);
    }
    VARIANT yes;
    VariantInit(&yes);
    yes.vt = VT_BOOL;
    yes.boolVal = VARIANT_TRUE;
    if (FAILED(uia->CreatePropertyCondition(UIA_HasKeyboardFocusPropertyId, yes, &focused)) ||
        FAILED(uia->CreateCacheRequest(&cache))) {
      uia = nullptr;
      return;
    }
    cache->AddProperty(UIA_ControlTypePropertyId);
    cache->AddProperty(UIA_IsEnabledPropertyId);
    cache->AddProperty(UIA_IsValuePatternAvailablePropertyId);
    cache->AddProperty(UIA_ValueIsReadOnlyPropertyId);
  }

  // The focused element inside [focus], by UI Automation.
  bool AskUia(HWND focus) {
    ComPtr<IUIAutomationElement> root;
    if (FAILED(uia->ElementFromHandle(focus, &root)) || !root) return false;
    ComPtr<IUIAutomationElement> found;
    if (FAILED(root->FindFirstBuildCache(TreeScope_Subtree, focused.Get(), cache.Get(), &found)) || !found) {
      return false;
    }
    CONTROLTYPEID type = 0;
    found->get_CachedControlType(&type);
    BOOL enabled = TRUE;
    found->get_CachedIsEnabled(&enabled);
    if (!enabled) return false;
    VARIANT v;
    VariantInit(&v);
    bool has_value = SUCCEEDED(found->GetCachedPropertyValue(UIA_IsValuePatternAvailablePropertyId, &v)) &&
                     VariantTrue(v);
    VariantClear(&v);
    bool read_only = SUCCEEDED(found->GetCachedPropertyValue(UIA_ValueIsReadOnlyPropertyId, &v)) && VariantTrue(v);
    VariantClear(&v);
    if (type == UIA_EditControlTypeId) return !(has_value && read_only);
    if ((type == UIA_DocumentControlTypeId || type == UIA_ComboBoxControlTypeId) && has_value && !read_only) {
      return true;
    }
    return false;
  }

  // True when the window's focus is somewhere to type.
  bool Check(HWND hint, bool triggered_now) {
    HWND input = core != nullptr ? core : window;
    DWORD thread = GetWindowThreadProcessId(input, nullptr);
    GUITHREADINFO gui{sizeof(gui)};
    HWND focus = nullptr;
    HWND caret = nullptr;
    if (thread != 0 && GetGUIThreadInfo(thread, &gui)) {
      focus = gui.hwndFocus;
      caret = gui.hwndCaret;
    }
    // The thread's own focus; when it reports none, the control the viewer
    // last pressed on (where the keys go).
    if (!Belongs(focus)) focus = Belongs(hint) ? hint : nullptr;
    if (focus == nullptr) return false;
    // A caret in the focused control is a place where text is typed.
    if (caret != nullptr && caret == focus) return true;
    wchar_t root_class[128] = {};
    GetClassNameW(GetAncestor(focus, GA_ROOT), root_class, 128);
    if (ClassIs(root_class, L"CASCADIA_HOSTING_WINDOW_CLASS")) return true;  // Windows Terminal
    Verdict verdict = ClassVerdict(focus);
    if (verdict != Verdict::kAsk) return verdict == Verdict::kYes;
    if (!uia) return false;
    // UI Automation goes into the app: only after input or a focus change,
    // at most every 100 ms; otherwise the last answer for this control.
    bool ask = triggered_now || focus != last_uia_hwnd;
    double now = NowMs();
    if (!ask || now - last_uia_ms < 100) return focus == last_uia_hwnd && last_uia;
    last_uia_ms = now;
    last_uia_hwnd = focus;
    last_uia = AskUia(focus);
    return last_uia;
  }
};

thread_local FocusState* t_state = nullptr;

void CALLBACK OnFocusEvent(HWINEVENTHOOK, DWORD, HWND hwnd, LONG, LONG, DWORD, DWORD) {
  FocusState* state = t_state;
  if (state == nullptr || !state->Belongs(hwnd)) return;
  double soon = NowMs() + 60;
  if (state->due == 0 || state->due > soon) state->due = soon;
  state->triggered = true;
}

// A top-level window the app showed or moved (a menu, a flyout, a dialog).
// WinUI keeps its popup windows visible and only moves them into place, so
// a move of a window owned by ours counts as well.
void CALLBACK OnShowEvent(HWINEVENTHOOK, DWORD event, HWND hwnd, LONG id_object, LONG id_child, DWORD, DWORD) {
  FocusState* state = t_state;
  if (state == nullptr || state->on_popup == nullptr || !*state->on_popup || hwnd == nullptr) return;
  if (event != EVENT_SYSTEM_MENUPOPUPSTART && (id_object != OBJID_WINDOW || id_child != CHILDID_SELF)) return;
  if (GetAncestor(hwnd, GA_ROOT) != hwnd || state->Belongs(hwnd)) return;
  if (event == EVENT_OBJECT_LOCATIONCHANGE) {
    HWND owner = GetWindow(hwnd, GW_OWNER);
    if (owner == nullptr || GetAncestor(owner, GA_ROOT) != state->window || !IsWindowVisible(hwnd)) return;
  }
  (*state->on_popup)(hwnd);
}

}  // namespace

TextFocusWatcher::TextFocusWatcher(HWND window, std::function<void(bool)> on_change)
    : window_(window), on_change_(std::move(on_change)), kick_event_(CreateEventW(nullptr, FALSE, FALSE, nullptr)) {}

TextFocusWatcher::~TextFocusWatcher() {
  Stop();
  if (kick_event_ != nullptr) CloseHandle(kick_event_);
}

void TextFocusWatcher::Start() {
  if (thread_.joinable() || kick_event_ == nullptr) return;
  thread_ = std::thread([this] { Run(); });
}

void TextFocusWatcher::Stop() {
  stop_ = true;
  if (kick_event_ != nullptr) SetEvent(kick_event_);
  if (thread_.joinable() && thread_.get_id() != std::this_thread::get_id()) thread_.join();
}

void TextFocusWatcher::Kick(HWND hint) {
  hint_ = hint;
  if (kick_event_ != nullptr) SetEvent(kick_event_);
}

void TextFocusWatcher::Run() {
  HRESULT com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  {
    FocusState state;
    state.window = window_;
    state.core = HostedCoreWindow(window_);
    state.InitUia();
    t_state = &state;
    DWORD pid = WindowPid(state.core != nullptr ? state.core : window_);
    state.on_popup = &on_popup;
    HWINEVENTHOOK hook = SetWinEventHook(EVENT_OBJECT_FOCUS, EVENT_OBJECT_FOCUS, nullptr, OnFocusEvent, pid, 0,
                                         WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    HWINEVENTHOOK show_hook = nullptr;
    HWINEVENTHOOK menu_hook = nullptr;
    HWINEVENTHOOK move_hook = nullptr;
    if (on_popup) {
      move_hook = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_LOCATIONCHANGE, nullptr, OnShowEvent, pid,
                                  0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
      show_hook = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, nullptr, OnShowEvent, pid, 0,
                                  WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
      menu_hook = SetWinEventHook(EVENT_SYSTEM_MENUPOPUPSTART, EVENT_SYSTEM_MENUPOPUPSTART, nullptr, OnShowEvent, pid,
                                  0, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
    }
    bool have_last = false;
    bool last = false;
    state.due = NowMs() + 300;  // a first look shortly after the start
    double next_poll = NowMs() + 1000;
    while (!stop_) {
      double now = NowMs();
      double until = next_poll;
      if (state.due > 0 && state.due < until) until = state.due;
      DWORD wait = until > now ? static_cast<DWORD>(until - now) + 1 : 0;
      DWORD woke = MsgWaitForMultipleObjectsEx(1, &kick_event_, wait, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
      MSG msg;
      while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) DispatchMessageW(&msg);  // runs OnFocusEvent
      if (stop_) break;
      now = NowMs();
      if (woke == WAIT_OBJECT_0) {  // input: give the app a moment to move its focus
        double soon = now + 120;
        if (state.due == 0 || state.due > soon) state.due = soon;
        state.triggered = true;
      }
      bool due = state.due > 0 && now >= state.due;
      if (!due && now < next_poll) continue;
      bool triggered = due && state.triggered;
      state.due = 0;
      state.triggered = false;
      next_poll = now + 1000;
      if (!IsWindow(window_)) break;
      bool typing = state.Check(hint_.load(), triggered);
      if (!have_last || typing != last) {
        have_last = true;
        last = typing;
        if (on_change_) on_change_(typing);
      }
    }
    if (hook != nullptr) UnhookWinEvent(hook);
    if (show_hook != nullptr) UnhookWinEvent(show_hook);
    if (menu_hook != nullptr) UnhookWinEvent(menu_hook);
    if (move_hook != nullptr) UnhookWinEvent(move_hook);
    t_state = nullptr;
  }  // UI Automation objects released before COM goes
  if (SUCCEEDED(com)) CoUninitialize();
}

}  // namespace wsn
