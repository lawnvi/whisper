// One Direct3D 11 device for all captures: Windows.Graphics.Capture frames,
// the video processor that scales and converts them, and the Media
// Foundation encoders (through one IMFDXGIDeviceManager) all live on it, so a
// frame never leaves the GPU on the hardware path.
#pragma once

#include "wsn_util.h"

#include <d3d11_4.h>
#include <dxgi1_6.h>
#include <mfapi.h>
#include <mfidl.h>

#include <mutex>
#include <string>

#include <winrt/base.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>

namespace wsn {

class D3D {
 public:
  // Created on first use; nullptr when no hardware device can be made.
  static D3D* Shared();

  ID3D11Device* device() const { return device_.get(); }
  ID3D11DeviceContext* context() const { return context_.get(); }
  ID3D11VideoDevice* video_device() const { return video_device_.get(); }
  ID3D11VideoContext* video_context() const { return video_context_.get(); }
  IMFDXGIDeviceManager* manager() const { return manager_.get(); }
  const winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice& winrt_device() const { return winrt_device_; }
  const std::wstring& adapter_name() const { return adapter_name_; }
  LUID adapter_luid() const { return adapter_luid_; }

  // Serialises multi-call sequences on the immediate context with Media
  // Foundation's own use of the device (same lock: ID3D10Multithread).
  void Lock() { multithread_->Enter(); }
  void Unlock() { multithread_->Leave(); }

  // The device was removed (driver update, TDR): every user must start over.
  bool Lost() const;

  winrt::com_ptr<ID3D11Texture2D> CreateTexture(UINT width, UINT height, DXGI_FORMAT format, UINT bind,
                                                D3D11_USAGE usage = D3D11_USAGE_DEFAULT, UINT cpu = 0);

 private:
  D3D() = default;
  bool Init();

  winrt::com_ptr<ID3D11Device> device_;
  winrt::com_ptr<ID3D11DeviceContext> context_;
  winrt::com_ptr<ID3D11VideoDevice> video_device_;
  winrt::com_ptr<ID3D11VideoContext> video_context_;
  winrt::com_ptr<ID3D10Multithread> multithread_;
  winrt::com_ptr<IMFDXGIDeviceManager> manager_;
  UINT reset_token_ = 0;
  winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice winrt_device_{nullptr};
  std::wstring adapter_name_;
  LUID adapter_luid_{};
};

class D3DLock {
 public:
  explicit D3DLock(D3D* d3d) : d3d_(d3d) { d3d_->Lock(); }
  ~D3DLock() { d3d_->Unlock(); }
  D3DLock(const D3DLock&) = delete;
  D3DLock& operator=(const D3DLock&) = delete;

 private:
  D3D* d3d_;
};

}  // namespace wsn
