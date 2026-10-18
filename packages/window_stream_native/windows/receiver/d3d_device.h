// One D3D11 device (video support, multithread protected) shared by every
// streamed window: their decoders (through its DXGI device manager) and
// their presenters. Made once and reused while healthy, so a second window
// opens without paying for device creation again.

#pragma once

#include "../common/com.h"

#include <d2d1_1.h>
#include <d3d11_1.h>
#include <dwrite.h>
#include <mfapi.h>
#include <mfidl.h>

#include <memory>
#include <string>

namespace wsn {

struct D3DDevice {
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<ID3D10Multithread> multithread;
  ComPtr<ID3D11VideoDevice> video_device;
  ComPtr<ID3D11VideoContext> video_context;
  ComPtr<IMFDXGIDeviceManager> manager;
  UINT manager_token = 0;
  ComPtr<ID2D1Factory1> d2d_factory;
  ComPtr<ID2D1Device> d2d_device;
  ComPtr<IDWriteFactory> dwrite;
  std::wstring adapter;
  D3D_FEATURE_LEVEL level = {};

  bool healthy() const;
};

// Any thread. Null when this PC has no usable D3D11 video device (or
// WSN_FORCE_GDI=1 is set).
std::shared_ptr<D3DDevice> AcquireD3DDevice();

}  // namespace wsn
