#include "d3d_device.h"

#include <mutex>

namespace wsn {
namespace {

// Leaked on purpose (see common/util.cpp).
std::mutex& g_device_mutex = *new std::mutex();
std::shared_ptr<D3DDevice>& g_device = *new std::shared_ptr<D3DDevice>();

std::shared_ptr<D3DDevice> CreateDevice() {
  const double started = NowSeconds();
  auto result = std::make_shared<D3DDevice>();
  const D3D_FEATURE_LEVEL levels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_1,
                                      D3D_FEATURE_LEVEL_10_0};
  const UINT flags = D3D11_CREATE_DEVICE_VIDEO_SUPPORT | D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels, ARRAYSIZE(levels),
                                 D3D11_SDK_VERSION, &result->device, &result->level, &result->context);
  if (hr == E_INVALIDARG) {
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, levels + 1, ARRAYSIZE(levels) - 1,
                           D3D11_SDK_VERSION, &result->device, &result->level, &result->context);
  }
  if (FAILED(hr)) {
    Log("device: D3D11CreateDevice failed (0x%08lx)", hr);
    return nullptr;
  }
  if (FAILED(result->device.As(&result->multithread)) || FAILED(result->device.As(&result->video_device)) ||
      FAILED(result->context.As(&result->video_context))) {
    Log("device: no D3D11 video support");
    return nullptr;
  }
  result->multithread->SetMultithreadProtected(TRUE);
  hr = MFCreateDXGIDeviceManager(&result->manager_token, &result->manager);
  if (SUCCEEDED(hr)) hr = result->manager->ResetDevice(result->device.Get(), result->manager_token);
  if (FAILED(hr)) {
    Log("device: DXGI device manager failed (0x%08lx)", hr);
    return nullptr;
  }
  ComPtr<IDXGIDevice> dxgi_device;
  ComPtr<IDXGIAdapter> adapter;
  if (SUCCEEDED(result->device.As(&dxgi_device)) && SUCCEEDED(dxgi_device->GetAdapter(&adapter))) {
    DXGI_ADAPTER_DESC desc = {};
    adapter->GetDesc(&desc);
    result->adapter = desc.Description;
  }
  D2D1_FACTORY_OPTIONS options = {};
  hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_MULTI_THREADED, __uuidof(ID2D1Factory1), &options,
                         reinterpret_cast<void**>(result->d2d_factory.GetAddressOf()));
  if (SUCCEEDED(hr)) hr = result->d2d_factory->CreateDevice(dxgi_device.Get(), &result->d2d_device);
  if (SUCCEEDED(hr)) {
    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                             reinterpret_cast<IUnknown**>(result->dwrite.GetAddressOf()));
  }
  if (FAILED(hr)) {
    Log("device: Direct2D unavailable (0x%08lx)", hr);
    return nullptr;
  }
  Log("device: D3D11 on %ls (feature level %x) in %.0f ms", result->adapter.c_str(), result->level,
      (NowSeconds() - started) * 1000);
  return result;
}

bool ForceGdi() { return EnvFlag(L"WSN_FORCE_GDI"); }

}  // namespace

bool D3DDevice::healthy() const { return device != nullptr && device->GetDeviceRemovedReason() == S_OK; }

std::shared_ptr<D3DDevice> AcquireD3DDevice() {
  if (ForceGdi()) return nullptr;
  std::lock_guard<std::mutex> lock(g_device_mutex);
  if (g_device != nullptr && g_device->healthy()) return g_device;
  if (g_device != nullptr) Log("device: previous device was removed, making a new one");
  g_device = CreateDevice();
  return g_device;
}

}  // namespace wsn
