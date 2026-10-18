// Probe "xaml": why pointer input to the WinUI/XAML-hosted parts of a staged
// window (Explorer's command bar, address bar, search box, tabs) does
// nothing, and what does work.
//
// Stages a window off-screen the way the plugin does, dumps its HWND tree
// and UI Automation tree, and tries one input method at one point (window
// frame fractions). The window is put back afterwards.
//
//   wsn_probe xaml --match "out - " [--class CabinetWClass] --mode dump
//   wsn_probe xaml --match "out - " --mode try --x 0.3 --y 0.08 --method posted|uia|wmpointer
//   (--keep: stay staged afterwards; --unstage: only put the window back)
#include "probe.h"

#include "core/wsn_inject.h"
#include "core/wsn_window.h"

#include <objbase.h>
#include <ole2.h>
#include <UIAutomation.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdio>
#include <set>

namespace probe {

namespace {

using Microsoft::WRL::ComPtr;

std::string Utf8(BSTR text) { return text ? wsn::Narrow(std::wstring(text, SysStringLen(text))) : std::string(); }

HWND FindTarget(const std::wstring& cls, const std::wstring& match) {
  for (HWND w : TopLevelWindows()) {
    if (!IsWindowVisible(w)) continue;
    if (!cls.empty() && wsn::WindowClass(w) != cls) continue;
    std::wstring title = wsn::WindowTitle(w);
    if (!match.empty() && title.find(match) == std::wstring::npos) continue;
    return w;
  }
  return nullptr;
}

// The staging state of the probe's window, kept in a file so a later run
// can put it back.
struct Staged {
  wsn::Placement home;
  wsn::StyleBackup style;
};

std::wstring StatePath() { return g_out + L"\\..\\xaml_staged.bin"; }

bool StageWindow(HWND window, Staged* staged, int width, int height) {
  staged->home = wsn::SavePlacement(window);
  if (!wsn::ApplyStageStyle(window, &staged->style)) return false;
  FILE* f = _wfopen(StatePath().c_str(), L"wb");
  if (f) {
    fwrite(staged, sizeof(Staged), 1, f);
    fclose(f);
  }
  wsn::Borders borders = wsn::InvisibleBorders(window);
  RECT spot{};
  if (!wsn::StageSpot(0, width + borders.left + borders.right, height + borders.top + borders.bottom, borders,
                      &spot)) {
    return false;
  }
  return wsn::MoveWindowTo(window, spot, 800);
}

void UnstageWindow(HWND window) {
  Staged staged{};
  FILE* f = _wfopen(StatePath().c_str(), L"rb");
  if (!f) return;
  size_t n = fread(&staged, sizeof(Staged), 1, f);
  fclose(f);
  if (n != 1) return;
  wsn::RestoreStageStyle(window, staged.style);
  wsn::RestorePlacement(window, staged.home);
  DeleteFileW(StatePath().c_str());
}

const char* TypeName(CONTROLTYPEID id) {
  switch (id) {
    case UIA_ButtonControlTypeId: return "Button";
    case UIA_SplitButtonControlTypeId: return "SplitButton";
    case UIA_MenuItemControlTypeId: return "MenuItem";
    case UIA_MenuControlTypeId: return "Menu";
    case UIA_MenuBarControlTypeId: return "MenuBar";
    case UIA_EditControlTypeId: return "Edit";
    case UIA_TextControlTypeId: return "Text";
    case UIA_TabControlTypeId: return "Tab";
    case UIA_TabItemControlTypeId: return "TabItem";
    case UIA_ListControlTypeId: return "List";
    case UIA_ListItemControlTypeId: return "ListItem";
    case UIA_TreeControlTypeId: return "Tree";
    case UIA_TreeItemControlTypeId: return "TreeItem";
    case UIA_PaneControlTypeId: return "Pane";
    case UIA_GroupControlTypeId: return "Group";
    case UIA_ToolBarControlTypeId: return "ToolBar";
    case UIA_ComboBoxControlTypeId: return "ComboBox";
    case UIA_HyperlinkControlTypeId: return "Hyperlink";
    case UIA_WindowControlTypeId: return "Window";
    case UIA_CustomControlTypeId: return "Custom";
    case UIA_DocumentControlTypeId: return "Document";
    case UIA_ImageControlTypeId: return "Image";
    case UIA_CheckBoxControlTypeId: return "CheckBox";
    case UIA_RadioButtonControlTypeId: return "RadioButton";
    case UIA_ScrollBarControlTypeId: return "ScrollBar";
    case UIA_DataItemControlTypeId: return "DataItem";
    case UIA_HeaderControlTypeId: return "Header";
    case UIA_HeaderItemControlTypeId: return "HeaderItem";
    case UIA_TitleBarControlTypeId: return "TitleBar";
    case UIA_AppBarControlTypeId: return "AppBar";
    case UIA_SemanticZoomControlTypeId: return "SemanticZoom";
    default: return "?";
  }
}

struct Uia {
  ComPtr<IUIAutomation> uia;
  ComPtr<IUIAutomationTreeWalker> walker;
  bool Init() {
    if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia))))
      return false;
    ComPtr<IUIAutomation2> uia2;
    if (SUCCEEDED(uia.As(&uia2))) {
      uia2->put_ConnectionTimeout(2000);
      uia2->put_TransactionTimeout(2000);
    }
    return SUCCEEDED(uia->get_RawViewWalker(&walker));
  }
};

bool Has(IUIAutomationElement* e, PROPERTYID id) {
  VARIANT v;
  VariantInit(&v);
  bool yes = SUCCEEDED(e->GetCurrentPropertyValue(id, &v)) && v.vt == VT_BOOL && v.boolVal != VARIANT_FALSE;
  VariantClear(&v);
  return yes;
}

std::string Describe(IUIAutomationElement* e, const RECT& frame) {
  CONTROLTYPEID type = 0;
  e->get_CurrentControlType(&type);
  BSTR name = nullptr, aid = nullptr, cls = nullptr, fw = nullptr;
  e->get_CurrentName(&name);
  e->get_CurrentAutomationId(&aid);
  e->get_CurrentClassName(&cls);
  e->get_CurrentFrameworkId(&fw);
  RECT r{};
  e->get_CurrentBoundingRectangle(&r);
  UIA_HWND native = nullptr;
  e->get_CurrentNativeWindowHandle(&native);
  std::string patterns;
  if (Has(e, UIA_IsInvokePatternAvailablePropertyId)) patterns += "Invoke ";
  if (Has(e, UIA_IsTogglePatternAvailablePropertyId)) patterns += "Toggle ";
  if (Has(e, UIA_IsExpandCollapsePatternAvailablePropertyId)) patterns += "Expand ";
  if (Has(e, UIA_IsSelectionItemPatternAvailablePropertyId)) patterns += "SelItem ";
  if (Has(e, UIA_IsValuePatternAvailablePropertyId)) patterns += "Value ";
  if (Has(e, UIA_IsLegacyIAccessiblePatternAvailablePropertyId)) patterns += "Legacy ";
  if (Has(e, UIA_IsTextPatternAvailablePropertyId)) patterns += "Text ";
  std::string text = wsn::Format("%s name=%s id=%s class=%s fw=%s rect=%ld,%ld %ldx%ld hwnd=%p [%s]", TypeName(type),
                                 wsn::JsonString(Utf8(name)).c_str(), Utf8(aid).c_str(), Utf8(cls).c_str(),
                                 Utf8(fw).c_str(), r.left - frame.left, r.top - frame.top, r.right - r.left,
                                 r.bottom - r.top, native, patterns.c_str());
  SysFreeString(name);
  SysFreeString(aid);
  SysFreeString(cls);
  SysFreeString(fw);
  return text;
}

void DumpUia(Uia& u, IUIAutomationElement* e, const RECT& frame, int depth, int* count, std::string* out) {
  if (*count > 4000 || depth > 40) return;
  (*count)++;
  *out += std::string(static_cast<size_t>(depth) * 2, ' ') + Describe(e, frame) + "\n";
  ComPtr<IUIAutomationElement> child;
  u.walker->GetFirstChildElement(e, &child);
  while (child) {
    DumpUia(u, child.Get(), frame, depth + 1, count, out);
    ComPtr<IUIAutomationElement> next;
    u.walker->GetNextSiblingElement(child.Get(), &next);
    child = next;
  }
}

// Every element whose bounding rectangle holds [pt], outermost first.
void ElementsAt(Uia& u, IUIAutomationElement* e, POINT pt, int depth, int* visited,
                std::vector<ComPtr<IUIAutomationElement>>* chain) {
  if (*visited > 6000 || depth > 40) return;
  (*visited)++;
  ComPtr<IUIAutomationElement> child;
  u.walker->GetFirstChildElement(e, &child);
  while (child) {
    RECT r{};
    child->get_CurrentBoundingRectangle(&r);
    if (PtInRect(&r, pt)) {
      chain->push_back(child);
      ElementsAt(u, child.Get(), pt, depth + 1, visited, chain);
      return;  // the first child that holds the point (z-order: earlier wins in UIA's raw view)
    }
    ComPtr<IUIAutomationElement> next;
    u.walker->GetNextSiblingElement(child.Get(), &next);
    child = next;
  }
}

std::string DoUiaAction(IUIAutomationElement* e) {
  ComPtr<IUnknown> unknown;
  if (Has(e, UIA_IsInvokePatternAvailablePropertyId)) {
    ComPtr<IUIAutomationInvokePattern> p;
    if (SUCCEEDED(e->GetCurrentPatternAs(UIA_InvokePatternId, IID_PPV_ARGS(&p))) && p) {
      return SUCCEEDED(p->Invoke()) ? "Invoke ok" : "Invoke failed";
    }
  }
  if (Has(e, UIA_IsExpandCollapsePatternAvailablePropertyId)) {
    ComPtr<IUIAutomationExpandCollapsePattern> p;
    if (SUCCEEDED(e->GetCurrentPatternAs(UIA_ExpandCollapsePatternId, IID_PPV_ARGS(&p))) && p) {
      ExpandCollapseState state{};
      p->get_CurrentExpandCollapseState(&state);
      HRESULT hr = state == ExpandCollapseState_Expanded ? p->Collapse() : p->Expand();
      return SUCCEEDED(hr) ? "ExpandCollapse ok" : "ExpandCollapse failed";
    }
  }
  if (Has(e, UIA_IsTogglePatternAvailablePropertyId)) {
    ComPtr<IUIAutomationTogglePattern> p;
    if (SUCCEEDED(e->GetCurrentPatternAs(UIA_TogglePatternId, IID_PPV_ARGS(&p))) && p) {
      return SUCCEEDED(p->Toggle()) ? "Toggle ok" : "Toggle failed";
    }
  }
  if (Has(e, UIA_IsSelectionItemPatternAvailablePropertyId)) {
    ComPtr<IUIAutomationSelectionItemPattern> p;
    if (SUCCEEDED(e->GetCurrentPatternAs(UIA_SelectionItemPatternId, IID_PPV_ARGS(&p))) && p) {
      return SUCCEEDED(p->Select()) ? "Select ok" : "Select failed";
    }
  }
  if (Has(e, UIA_IsValuePatternAvailablePropertyId)) {
    return SUCCEEDED(e->SetFocus()) ? "SetFocus ok" : "SetFocus failed";
  }
  if (Has(e, UIA_IsLegacyIAccessiblePatternAvailablePropertyId)) {
    ComPtr<IUIAutomationLegacyIAccessiblePattern> p;
    if (SUCCEEDED(e->GetCurrentPatternAs(UIA_LegacyIAccessiblePatternId, IID_PPV_ARGS(&p))) && p) {
      return SUCCEEDED(p->DoDefaultAction()) ? "DoDefaultAction ok" : "DoDefaultAction failed";
    }
  }
  return "no action";
}

std::set<HWND> VisibleWindowsOf(DWORD pid) {
  std::set<HWND> out;
  for (HWND w : TopLevelWindows()) {
    if (IsWindowVisible(w) && wsn::WindowPid(w) == pid) out.insert(w);
  }
  return out;
}

int DiffPixels(const wsn::Bitmap& a, const wsn::Bitmap& b) {
  if (a.width != b.width || a.height != b.height) return -1;
  int diff = 0;
  for (size_t i = 0; i + 3 < a.bgra.size(); i += 4) {
    if (std::abs(a.bgra[i] - b.bgra[i]) + std::abs(a.bgra[i + 1] - b.bgra[i + 1]) +
            std::abs(a.bgra[i + 2] - b.bgra[i + 2]) > 24) {
      diff++;
    }
  }
  return diff;
}

void DumpHwnds(HWND top, const RECT& frame, std::string* out) {
  struct Ctx {
    HWND top;
    RECT frame;
    std::string* out;
  } ctx{top, frame, out};
  EnumChildWindows(
      top,
      [](HWND w, LPARAM p) -> BOOL {
        auto* c = reinterpret_cast<Ctx*>(p);
        int depth = 0;
        for (HWND x = GetParent(w); x && x != c->top; x = GetParent(x)) depth++;
        RECT r{};
        GetWindowRect(w, &r);
        *c->out += std::string(static_cast<size_t>(depth) * 2, ' ') +
                   wsn::Format("%p %s vis=%d rect=%ld,%ld %dx%d ex=0x%llx\n", w,
                               wsn::Narrow(wsn::WindowClass(w)).c_str(), IsWindowVisible(w) ? 1 : 0,
                               r.left - c->frame.left, r.top - c->frame.top, wsn::RectWidth(r), wsn::RectHeight(r),
                               static_cast<unsigned long long>(GetWindowLongPtrW(w, GWL_EXSTYLE)));
        return TRUE;
      },
      reinterpret_cast<LPARAM>(&ctx));
}

}  // namespace

int RunXaml(const Args& args) {
  std::wstring cls = args.Get(L"--class", L"CabinetWClass");
  std::wstring match = args.Get(L"--match", L"out - ");
  HWND window = FindTarget(cls, match);
  if (window == nullptr) {
    Log("no window of class %s matching %s", wsn::Narrow(cls).c_str(), wsn::Narrow(match).c_str());
    return 2;
  }
  Log("target %p %s", window, wsn::Narrow(wsn::WindowTitle(window)).c_str());
  if (args.Has(L"--unstage")) {
    UnstageWindow(window);
    return 0;
  }
  if (args.Has(L"--front-next")) {
    // Give the foreground to the next visible, on-screen window below ours
    // (what Windows would activate), so the user's typing is not going to
    // the staged window.
    for (HWND w = GetWindow(window, GW_HWNDNEXT); w; w = GetWindow(w, GW_HWNDNEXT)) {
      RECT r{};
      GetWindowRect(w, &r);
      LONG_PTR ex = GetWindowLongPtrW(w, GWL_EXSTYLE);
      if (!IsWindowVisible(w) || IsIconic(w) || (ex & WS_EX_TOOLWINDOW) || GetWindow(w, GW_OWNER) ||
          !wsn::OnAnyMonitor(r, 0.2) || wsn::WindowTitle(w).empty()) {
        continue;
      }
      std::string how;
      bool ok = wsn::BringToForeground(w, &how);
      Log("front -> %p %s (%s, %d)", w, wsn::Narrow(wsn::WindowTitle(w)).c_str(), how.c_str(), ok);
      break;
    }
    return 0;
  }
  bool staged_here = false;
  if (!wsn::HasStageStyle(window)) {
    Staged staged;
    if (!StageWindow(window, &staged, args.Int(L"--w", 1100), args.Int(L"--h", 720))) {
      Log("staging failed");
      UnstageWindow(window);
      return 1;
    }
    staged_here = true;
    Sleep(600);
  }
  RECT frame = wsn::FrameBounds(window);
  Log("staged frame %ld,%ld %dx%d", frame.left, frame.top, wsn::RectWidth(frame), wsn::RectHeight(frame));
  Uia u;
  if (!u.Init()) {
    Log("UIA init failed");
  }
  std::wstring mode = args.Get(L"--mode", L"dump");
  std::wstring tag = args.Get(L"--tag", mode);
  wsn::Bitmap before;
  wsn::PrintWindowBitmap(window, &before);
  wsn::SaveImage(g_out + L"\\" + tag + L"_before.png", before);
  if (mode == L"dump") {
    std::string hwnds;
    DumpHwnds(window, frame, &hwnds);
    WriteText(L"hwnds.txt", hwnds);
    if (u.uia) {
      ComPtr<IUIAutomationElement> root;
      u.uia->ElementFromHandle(window, &root);
      std::string tree;
      int count = 0;
      if (root) DumpUia(u, root.Get(), frame, 0, &count, &tree);
      WriteText(L"uia.txt", tree);
      Log("uia elements %d", count);
    }
  } else if (mode == L"try") {
    double fx = _wtof(args.Get(L"--x", L"0.5").c_str());
    double fy = _wtof(args.Get(L"--y", L"0.5").c_str());
    POINT pt{frame.left + static_cast<LONG>(fx * wsn::RectWidth(frame)),
             frame.top + static_cast<LONG>(fy * wsn::RectHeight(frame))};
    std::wstring method = args.Get(L"--method", L"posted");
    HWND target = wsn::ChildAt(window, pt);
    Log("point %ld,%ld (frame %+ld,%+ld): child %p %s", pt.x, pt.y, pt.x - frame.left, pt.y - frame.top, target,
        wsn::Narrow(wsn::WindowClass(target)).c_str());
    std::vector<ComPtr<IUIAutomationElement>> chain;
    if (u.uia) {
      ComPtr<IUIAutomationElement> root;
      u.uia->ElementFromHandle(window, &root);
      int visited = 0;
      if (root) ElementsAt(u, root.Get(), pt, 0, &visited, &chain);
      for (size_t i = 0; i < chain.size(); ++i) Log("  uia[%zu] %s", i, Describe(chain[i].Get(), frame).c_str());
    }
    DWORD pid = wsn::WindowPid(window);
    std::set<HWND> windows_before = VisibleWindowsOf(pid);
    POINT client = pt;
    ScreenToClient(target, &client);
    if (method == L"posted") {
      PostMessageW(target, WM_MOUSEMOVE, 0, MAKELPARAM(client.x, client.y));
      PostMessageW(target, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(client.x, client.y));
      Sleep(60);
      PostMessageW(target, WM_LBUTTONUP, 0, MAKELPARAM(client.x, client.y));
    } else if (method == L"wmpointer") {
      // A made-up pointer id: handlers that call GetPointerInfo will refuse it.
      WPARAM down = MAKEWPARAM(1, POINTER_MESSAGE_FLAG_INRANGE | POINTER_MESSAGE_FLAG_INCONTACT |
                                      POINTER_MESSAGE_FLAG_FIRSTBUTTON | POINTER_MESSAGE_FLAG_PRIMARY);
      LPARAM at = MAKELPARAM(pt.x, pt.y);
      PostMessageW(target, WM_POINTERUPDATE, MAKEWPARAM(1, POINTER_MESSAGE_FLAG_INRANGE), at);
      PostMessageW(target, WM_POINTERDOWN, down, at);
      Sleep(60);
      PostMessageW(target, WM_POINTERUP, MAKEWPARAM(1, POINTER_MESSAGE_FLAG_INRANGE), at);
    } else if (method == L"focus" || method == L"type" || method == L"setvalue") {
      // The innermost element with a value (an edit) at the point.
      ComPtr<IUIAutomationElement> edit;
      for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
        if (Has(it->Get(), UIA_IsValuePatternAvailablePropertyId)) {
          edit = *it;
          break;
        }
      }
      auto value_of = [&]() {
        std::string v = "?";
        ComPtr<IUIAutomationValuePattern> p;
        if (edit && SUCCEEDED(edit->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&p))) && p) {
          BSTR b = nullptr;
          p->get_CurrentValue(&b);
          v = Utf8(b);
          SysFreeString(b);
        }
        return v;
      };
      HWND front_before = GetForegroundWindow();
      if (!edit) {
        Log("no edit at the point");
      } else if (method == L"focus") {
        HRESULT hr = edit->SetFocus();
        Sleep(300);
        Log("SetFocus hr 0x%08lx; foreground before %p after %p (target %p); value %s", hr, front_before,
            GetForegroundWindow(), window, wsn::JsonString(value_of()).c_str());
      } else if (method == L"type") {
        edit->SetFocus();
        Sleep(200);
        if (args.Has(L"--refront") && GetForegroundWindow() != front_before) {
          std::string how;
          wsn::BringToForeground(front_before, &how);
          Log("front given back to %p (%s); now %p", front_before, how.c_str(), GetForegroundWindow());
        }
        GUITHREADINFO gui{sizeof(gui)};
        GetGUIThreadInfo(GetWindowThreadProcessId(window, nullptr), &gui);
        HWND to = args.Has(L"--to-focus") && gui.hwndFocus ? gui.hwndFocus : target;
        if (args.Has(L"--to-site")) {
          HWND site = FindWindowExW(target, nullptr, L"InputSiteWindowClass", nullptr);
          if (site) to = site;
        }
        Log("thread focus %p %s; typing into %p %s", gui.hwndFocus, wsn::Narrow(wsn::WindowClass(gui.hwndFocus)).c_str(),
            to, wsn::Narrow(wsn::WindowClass(to)).c_str());
        for (wchar_t c : std::wstring(L"abc")) PostMessageW(to, WM_CHAR, c, 1);
        Sleep(500);
        Log("foreground before %p after %p; value now %s", front_before, GetForegroundWindow(),
            wsn::JsonString(value_of()).c_str());
      } else {
        ComPtr<IUIAutomationValuePattern> p;
        std::wstring text = args.Get(L"--text", L"D:\\dev");
        if (SUCCEEDED(edit->GetCurrentPatternAs(UIA_ValuePatternId, IID_PPV_ARGS(&p))) && p) {
          BSTR b = SysAllocString(text.c_str());
          HRESULT hr = p->SetValue(b);
          SysFreeString(b);
          Sleep(300);
          Log("SetValue hr 0x%08lx; foreground before %p after %p; value now %s", hr, front_before,
              GetForegroundWindow(), wsn::JsonString(value_of()).c_str());
        }
      }
    } else if (method == L"uia") {
      // The innermost element that can act (walk outwards).
      std::string done = "no element";
      auto actionable = [](IUIAutomationElement* e) {
        return Has(e, UIA_IsInvokePatternAvailablePropertyId) ||
               Has(e, UIA_IsExpandCollapsePatternAvailablePropertyId) ||
               Has(e, UIA_IsTogglePatternAvailablePropertyId) ||
               Has(e, UIA_IsSelectionItemPatternAvailablePropertyId) || Has(e, UIA_IsValuePatternAvailablePropertyId);
      };
      bool acted = false;
      for (auto it = chain.rbegin(); it != chain.rend() && !acted; ++it) {
        if (!actionable(it->Get())) continue;
        done = DoUiaAction(it->Get()) + " on " + Describe(it->Get(), frame);
        acted = true;
      }
      for (auto it = chain.rbegin(); it != chain.rend() && !acted; ++it) {
        std::string result = DoUiaAction(it->Get());
        if (result != "no action") {
          done = result + " on " + Describe(it->Get(), frame);
          acted = true;
        }
      }
      Log("uia: %s", done.c_str());
    }
    Sleep(args.Int(L"--wait", 900));
    wsn::Bitmap after;
    wsn::PrintWindowBitmap(window, &after);
    wsn::SaveImage(g_out + L"\\" + tag + L"_after.png", after);
    std::set<HWND> windows_after = VisibleWindowsOf(pid);
    std::string fresh;
    for (HWND w : windows_after) {
      if (!windows_before.count(w)) {
        RECT r{};
        GetWindowRect(w, &r);
        fresh += wsn::Format("%p %s %ld,%ld %dx%d; ", w, wsn::Narrow(wsn::WindowClass(w)).c_str(), r.left, r.top,
                             wsn::RectWidth(r), wsn::RectHeight(r));
      }
    }
    Log("result %s: changed pixels %d, new windows: %s, title now %s", wsn::Narrow(method).c_str(),
        DiffPixels(before, after), fresh.empty() ? "none" : fresh.c_str(),
        wsn::Narrow(wsn::WindowTitle(window)).c_str());
    // Close whatever opened (menus) so the next try starts clean.
    if (!args.Has(L"--keep-open")) {
      for (HWND w : windows_after) {
        if (!windows_before.count(w)) PostMessageW(w, WM_KEYDOWN, VK_ESCAPE, 0);
      }
    }
  }
  if (staged_here && !args.Has(L"--keep")) {
    UnstageWindow(window);
  }
  return 0;
}

}  // namespace probe
