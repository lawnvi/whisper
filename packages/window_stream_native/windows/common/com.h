// COM helpers shared by both halves.

#pragma once

#include "wsn_common.h"

#include <objbase.h>
#include <wrl/client.h>

namespace wsn {

using Microsoft::WRL::ComPtr;

// Initialises COM on the current thread for as long as it lives in scope.
class ScopedCom {
 public:
  explicit ScopedCom(DWORD model = COINIT_MULTITHREADED)
      : hr_(CoInitializeEx(nullptr, model)) {}
  ~ScopedCom() {
    if (SUCCEEDED(hr_)) CoUninitialize();
  }
  ScopedCom(const ScopedCom&) = delete;
  ScopedCom& operator=(const ScopedCom&) = delete;
  bool ok() const { return SUCCEEDED(hr_) || hr_ == RPC_E_CHANGED_MODE; }

 private:
  HRESULT hr_;
};

}  // namespace wsn
