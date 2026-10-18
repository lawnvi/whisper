#include "wsn_d3d.h"

#include <windows.graphics.directx.direct3d11.interop.h>

namespace wsn {

namespace {
std::mutex g_shared_mutex;
D3D* g_shared = nullptr;
}  // namespace

D3D* D3D::Shared() {
  std::lock_guard<std::mutex> lock(g_shared_mutex);
  if (g_shared != nullptr && g_shared->Lost()) {
    // Leak the old one on purpose: users may still hold raw pointers to it,
    // and a removed device only fails calls, it does not crash.
    g_shared = nullptr;
  }
  if (g_shared == nullptr) {
    auto* created = new D3D();
    if (!created->Init()) {
      delete created;
      return nullptr;
    }
    g_shared = created;
  }
  return g_shared;
}

bool D3D::Init() {
  static std::once_flag mf_started;
  std::call_once(mf_started, [] { MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET); });

  // The adapter with the most video memory (the discrete GPU on hybrid
  // laptops): the one with the hardware encoder worth having.
  winrt::com_ptr<IDXGIFactory1> factory;
  winrt::com_ptr<IDXGIAdapter1> best;
  if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), factory.put_void()))) {
    SIZE_T best_memory = 0;
    for (UINT index = 0;; ++index) {
      winrt::com_ptr<IDXGIAdapter1> adapter;
      if (factory->EnumAdapters1(index, adapter.put()) == DXGI_ERROR_NOT_FOUND) break;
      DXGI_ADAPTER_DESC1 desc{};
      adapter->GetDesc1(&desc);
      if (desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
      if (best == nullptr || desc.DedicatedVideoMemory > best_memory) {
        best = adapter;
        best_memory = desc.DedicatedVideoMemory;
      }
    }
  }
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                      D3D_FEATURE_LEVEL_10_0};
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
  HRESULT hr = D3D11CreateDevice(best.get(), best ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE, nullptr,
                                 flags, levels, ARRAYSIZE(levels), D3D11_SDK_VERSION, device_.put(), nullptr,
                                 context_.put());
  if (FAILED(hr)) {
    // Some drivers have no video support on the device: capture still
    // works, the encoder then copies through system memory.
    flags &= ~D3D11_CREATE_DEVICE_VIDEO_SUPPORT;
    hr = D3D11CreateDevice(best.get(), best ? D3D_DRIVER_TYPE_UNKNOWN : D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                           levels, ARRAYSIZE(levels), D3D11_SDK_VERSION, device_.put(), nullptr, context_.put());
  }
  if (FAILED(hr)) return false;
  multithread_ = device_.try_as<ID3D10Multithread>();
  if (!multithread_) return false;
  multithread_->SetMultithreadProtected(TRUE);
  video_device_ = device_.try_as<ID3D11VideoDevice>();
  video_context_ = context_.try_as<ID3D11VideoContext>();

  auto dxgi_device = device_.try_as<IDXGIDevice>();
  if (!dxgi_device) return false;
  winrt::com_ptr<IDXGIAdapter> adapter;
  if (SUCCEEDED(dxgi_device->GetAdapter(adapter.put()))) {
    DXGI_ADAPTER_DESC desc{};
    adapter->GetDesc(&desc);
    adapter_name_ = desc.Description;
    adapter_luid_ = desc.AdapterLuid;
  }
  winrt::com_ptr<::IInspectable> inspectable;
  if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.get(), inspectable.put()))) return false;
  winrt_device_ = inspectable.as<winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice>();

  if (SUCCEEDED(MFCreateDXGIDeviceManager(&reset_token_, manager_.put()))) {
    if (FAILED(manager_->ResetDevice(device_.get(), reset_token_))) manager_ = nullptr;
  }
  return true;
}

bool D3D::Lost() const { return device_ == nullptr || device_->GetDeviceRemovedReason() != S_OK; }

winrt::com_ptr<ID3D11Texture2D> D3D::CreateTexture(UINT width, UINT height, DXGI_FORMAT format, UINT bind,
                                                   D3D11_USAGE usage, UINT cpu) {
  D3D11_TEXTURE2D_DESC desc{};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = format;
  desc.SampleDesc.Count = 1;
  desc.Usage = usage;
  desc.BindFlags = bind;
  desc.CPUAccessFlags = cpu;
  winrt::com_ptr<ID3D11Texture2D> texture;
  if (FAILED(device_->CreateTexture2D(&desc, nullptr, texture.put()))) return nullptr;
  return texture;
}

}  // namespace wsn
