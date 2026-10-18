#include "wsn_xaml.h"

#include "wsn_inject.h"

#include <objbase.h>
#include <ole2.h>
#include <UIAutomation.h>
#include <wrl/client.h>

#include <cwchar>

namespace wsn {

using Microsoft::WRL::ComPtr;

bool IsXamlHost(HWND hwnd) {
  if (hwnd == nullptr) return false;
  wchar_t cls[96] = {};
  GetClassNameW(hwnd, cls, 96);
  // WinUI 3 / Windows App SDK islands and their popup windows
  // (Microsoft.UI.Content.DesktopChildSiteBridge, ...PopupWindowSiteBridge),
  // system XAML islands, UWP core windows, and the input sites of these.
  return wcsncmp(cls, L"Microsoft.UI.Content.", 21) == 0 ||
         wcscmp(cls, L"Windows.UI.Composition.DesktopWindowContentBridge") == 0 ||
         wcscmp(cls, L"Windows.UI.Core.CoreWindow") == 0 ||  // UWP apps (Settings, Calculator)
         wcscmp(cls, L"InputSiteWindowClass") == 0 || wcscmp(cls, L"Windows.UI.Input.InputSite.WindowClass") == 0;
}

namespace {

bool CachedBool(IUIAutomationElement* e, PROPERTYID id) {
  VARIANT v;
  VariantInit(&v);
  bool yes = SUCCEEDED(e->GetCachedPropertyValue(id, &v)) && v.vt == VT_BOOL && v.boolVal != VARIANT_FALSE;
  VariantClear(&v);
  return yes;
}

std::string CachedName(IUIAutomationElement* e) {
  BSTR name = nullptr;
  e->get_CachedName(&name);
  std::string text = name ? Narrow(std::wstring(name, SysStringLen(name))) : std::string();
  SysFreeString(name);
  return text;
}

const char* TypeName(CONTROLTYPEID id) {
  switch (id) {
    case UIA_ButtonControlTypeId: return "Button";
    case UIA_SplitButtonControlTypeId: return "SplitButton";
    case UIA_MenuItemControlTypeId: return "MenuItem";
    case UIA_EditControlTypeId: return "Edit";
    case UIA_TabItemControlTypeId: return "TabItem";
    case UIA_ListItemControlTypeId: return "ListItem";
    case UIA_TreeItemControlTypeId: return "TreeItem";
    case UIA_ComboBoxControlTypeId: return "ComboBox";
    case UIA_CheckBoxControlTypeId: return "CheckBox";
    case UIA_RadioButtonControlTypeId: return "RadioButton";
    case UIA_HyperlinkControlTypeId: return "Hyperlink";
    case UIA_GroupControlTypeId: return "Group";
    default: return "Element";
  }
}

// The island's input site: where keyboard messages for its XAML go.
HWND InputSiteOf(HWND host) {
  for (const wchar_t* cls : {L"InputSiteWindowClass", L"Windows.UI.Input.InputSite.WindowClass"}) {
    if (HWND site = FindWindowExW(host, nullptr, cls, nullptr)) return site;
  }
  return host;
}

}  // namespace

struct XamlInput::Impl {
  ComPtr<IUIAutomation> uia;
  ComPtr<IUIAutomationCondition> all;
  ComPtr<IUIAutomationCacheRequest> cache;
  bool ready = false;
  bool tried = false;

  bool Ensure() {
    if (tried) return ready;
    tried = true;
    if (FAILED(CoCreateInstance(__uuidof(CUIAutomation8), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia))) &&
        FAILED(CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&uia)))) {
      return false;
    }
    ComPtr<IUIAutomation2> uia2;
    if (SUCCEEDED(uia.As(&uia2))) {
      uia2->put_ConnectionTimeout(1000);
      uia2->put_TransactionTimeout(1000);
    }
    if (FAILED(uia->get_RawViewCondition(&all)) || FAILED(uia->CreateCacheRequest(&cache))) return false;
    for (PROPERTYID id : {UIA_BoundingRectanglePropertyId, UIA_ControlTypePropertyId, UIA_IsEnabledPropertyId,
                          UIA_NamePropertyId, UIA_IsInvokePatternAvailablePropertyId,
                          UIA_IsTogglePatternAvailablePropertyId, UIA_IsExpandCollapsePatternAvailablePropertyId,
                          UIA_IsSelectionItemPatternAvailablePropertyId, UIA_IsValuePatternAvailablePropertyId,
                          UIA_ValueIsReadOnlyPropertyId, UIA_IsLegacyIAccessiblePatternAvailablePropertyId}) {
      cache->AddProperty(id);
    }
    ready = true;
    return true;
  }
};

XamlInput::XamlInput() : impl_(std::make_unique<Impl>()) {}
XamlInput::~XamlInput() = default;

bool XamlInput::ContentRect(HWND popup, RECT* out) {
  if (!impl_->Ensure()) return false;
  RECT window{};
  if (!GetWindowRect(popup, &window)) return false;
  long long window_area = 1LL * (window.right - window.left) * (window.bottom - window.top);
  ComPtr<IUIAutomationElement> root;
  if (FAILED(impl_->uia->ElementFromHandle(popup, &root)) || !root) return false;
  ComPtr<IUIAutomationElementArray> elements;
  if (FAILED(root->FindAllBuildCache(TreeScope_Descendants, impl_->all.Get(), impl_->cache.Get(), &elements)) ||
      !elements) {
    return false;
  }
  int count = 0;
  elements->get_Length(&count);
  // The biggest element that is clearly smaller than the window (the
  // menu or list presenter inside its shadow/animation margins).
  bool found = false;
  long long best = 0;
  for (int i = 0; i < count; ++i) {
    ComPtr<IUIAutomationElement> e;
    if (FAILED(elements->GetElement(i, &e)) || !e) continue;
    RECT r{};
    if (FAILED(e->get_CachedBoundingRectangle(&r)) || r.right <= r.left || r.bottom <= r.top) continue;
    long long area = 1LL * (r.right - r.left) * (r.bottom - r.top);
    if (area * 100 < window_area * 95 && area > best) {
      best = area;
      *out = r;
      found = true;
    }
  }
  return found;
}

XamlInput::Result XamlInput::Click(HWND host, POINT screen, const POINT* alternate) {
  Result result;
  {
    wchar_t cls[64] = {};
    GetClassNameW(host, cls, 64);
    result.uwp = wcscmp(cls, L"Windows.UI.Core.CoreWindow") == 0;
  }
  if (!impl_->Ensure()) {
    result.what = "no UI Automation";
    return result;
  }
  ComPtr<IUIAutomationElement> root;
  if (FAILED(impl_->uia->ElementFromHandle(host, &root)) || !root) {
    result.what = "no element for the window";
    return result;
  }
  ComPtr<IUIAutomationElementArray> elements;
  if (FAILED(root->FindAllBuildCache(TreeScope_Subtree, impl_->all.Get(), impl_->cache.Get(), &elements)) ||
      !elements) {
    result.what = "element search failed";
    return result;
  }
  int count = 0;
  elements->get_Length(&count);
  // The smallest element under the point that does something when clicked;
  // among equal ones the later (inner, drawn on top) one. Failing that, the
  // smallest one with a default action.
  ComPtr<IUIAutomationElement> best, fallback;
  long long best_area = 0, fallback_area = 0;
  for (int pass = 0; pass < 2 && !best; ++pass) {
    if (pass == 1) {
      if (alternate == nullptr) break;
      screen = *alternate;
      fallback = nullptr;
    }
    for (int i = 0; i < count; ++i) {
      ComPtr<IUIAutomationElement> e;
      if (FAILED(elements->GetElement(i, &e)) || !e) continue;
      RECT r{};
      if (FAILED(e->get_CachedBoundingRectangle(&r)) || r.right <= r.left || r.bottom <= r.top) continue;
      if (!PtInRect(&r, screen)) continue;
      long long area = 1LL * (r.right - r.left) * (r.bottom - r.top);
      CONTROLTYPEID type = 0;
      e->get_CachedControlType(&type);
      bool text_box = CachedBool(e.Get(), UIA_IsValuePatternAvailablePropertyId) &&
                      (type == UIA_EditControlTypeId || type == UIA_ComboBoxControlTypeId) &&
                      !CachedBool(e.Get(), UIA_ValueIsReadOnlyPropertyId);
      // Things one clicks — not their containers (a click on a command
      // bar's empty part must not toggle the bar).
      bool clickable = type == UIA_ButtonControlTypeId || type == UIA_SplitButtonControlTypeId ||
                       type == UIA_MenuItemControlTypeId || type == UIA_TabItemControlTypeId ||
                       type == UIA_ListItemControlTypeId || type == UIA_TreeItemControlTypeId ||
                       type == UIA_CheckBoxControlTypeId || type == UIA_RadioButtonControlTypeId ||
                       type == UIA_HyperlinkControlTypeId || type == UIA_ComboBoxControlTypeId ||
                       type == UIA_DataItemControlTypeId || type == UIA_HeaderItemControlTypeId ||
                       type == UIA_CustomControlTypeId || type == UIA_EditControlTypeId;
      bool acts = clickable && (text_box || CachedBool(e.Get(), UIA_IsInvokePatternAvailablePropertyId) ||
                                CachedBool(e.Get(), UIA_IsTogglePatternAvailablePropertyId) ||
                                CachedBool(e.Get(), UIA_IsExpandCollapsePatternAvailablePropertyId) ||
                                CachedBool(e.Get(), UIA_IsSelectionItemPatternAvailablePropertyId));
      if (acts && (!best || area <= best_area)) {
        best = e;  // may be disabled: then the click does nothing, as on screen
        best_area = area;
      } else if (!acts && clickable && CachedBool(e.Get(), UIA_IsEnabledPropertyId) &&
                 CachedBool(e.Get(), UIA_IsLegacyIAccessiblePatternAvailablePropertyId) &&
                 (!fallback || area <= fallback_area)) {
        fallback = e;
        fallback_area = area;
      }
    }
  }
  result.used_alternate = alternate != nullptr && screen.x == alternate->x && screen.y == alternate->y;
  IUIAutomationElement* target = best ? best.Get() : fallback.Get();
  if (target == nullptr) {
    result.what = "nothing under the point";
    return result;
  }
  target->get_CachedBoundingRectangle(&result.element);
  CONTROLTYPEID type = 0;
  target->get_CachedControlType(&type);
  std::string label = std::string(TypeName(type)) + " " + JsonString(CachedName(target));
  if (!CachedBool(target, UIA_IsEnabledPropertyId)) {
    result.what = "disabled " + label;
    return result;
  }
  auto has = [&](PROPERTYID id) { return CachedBool(target, id); };
  if (has(UIA_IsValuePatternAvailablePropertyId) && (type == UIA_EditControlTypeId || type == UIA_ComboBoxControlTypeId) &&
      !has(UIA_ValueIsReadOnlyPropertyId)) {
    // A text box: focus it. UI Automation activates the window for that;
    // give the foreground straight back (the window is off-screen, nothing
    // is seen) — XAML keeps its focused element and takes typed characters
    // through its input site while inactive.
    HWND root_window = GetAncestor(host, GA_ROOTOWNER);
    HWND previous = GetForegroundWindow();
    HRESULT hr = target->SetFocus();
    if (previous != nullptr && previous != root_window && GetForegroundWindow() != previous) {
      BringToForeground(previous, nullptr);
    }
    result.acted = SUCCEEDED(hr);
    result.focused_text = result.acted;
    result.input_site = InputSiteOf(host);
    result.what = "focus " + label;
    return result;
  }
  HRESULT hr = E_FAIL;
  const char* how = "";
  if (has(UIA_IsInvokePatternAvailablePropertyId)) {
    ComPtr<IUIAutomationInvokePattern> p;
    if (SUCCEEDED(target->GetCurrentPatternAs(UIA_InvokePatternId, IID_PPV_ARGS(&p))) && p) hr = p->Invoke();
    how = "Invoke";
  } else if (has(UIA_IsTogglePatternAvailablePropertyId)) {
    ComPtr<IUIAutomationTogglePattern> p;
    if (SUCCEEDED(target->GetCurrentPatternAs(UIA_TogglePatternId, IID_PPV_ARGS(&p))) && p) hr = p->Toggle();
    how = "Toggle";
  } else if (has(UIA_IsExpandCollapsePatternAvailablePropertyId)) {
    ComPtr<IUIAutomationExpandCollapsePattern> p;
    if (SUCCEEDED(target->GetCurrentPatternAs(UIA_ExpandCollapsePatternId, IID_PPV_ARGS(&p))) && p) {
      ExpandCollapseState state = ExpandCollapseState_Collapsed;
      p->get_CurrentExpandCollapseState(&state);
      hr = state == ExpandCollapseState_Expanded ? p->Collapse() : p->Expand();
    }
    how = "ExpandCollapse";
  } else if (has(UIA_IsSelectionItemPatternAvailablePropertyId)) {
    ComPtr<IUIAutomationSelectionItemPattern> p;
    if (SUCCEEDED(target->GetCurrentPatternAs(UIA_SelectionItemPatternId, IID_PPV_ARGS(&p))) && p) hr = p->Select();
    how = "Select";
  } else {
    ComPtr<IUIAutomationLegacyIAccessiblePattern> p;
    if (SUCCEEDED(target->GetCurrentPatternAs(UIA_LegacyIAccessiblePatternId, IID_PPV_ARGS(&p))) && p) {
      hr = p->DoDefaultAction();
    }
    how = "DefaultAction";
  }
  result.acted = SUCCEEDED(hr);
  result.what = std::string(how) + (result.acted ? " " : " failed ") + label;
  return result;
}

}  // namespace wsn
