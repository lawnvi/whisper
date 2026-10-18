// Annex-B H.264 → NV12 with the Media Foundation H.264 decoder MFT.
//
// Given a DXGI device manager the decoder runs on the GPU (DXVA) and hands
// out texture slices; without one, or when the MFT refuses it, it decodes
// in software into memory. Low-latency mode: no frame reordering delay.
// Not thread-safe: one decode thread owns it.

#pragma once

#include "frame.h"

#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>

#include <cstddef>
#include <cstdint>
#include <vector>

namespace wsn {

class H264Decoder {
 public:
  ~H264Decoder() { Release(); }

  // `manager` may be null (software). Returns false if no decoder could be
  // made at all.
  bool Create(IMFDXGIDeviceManager* manager);
  bool created() const { return transform_ != nullptr; }
  // The decoder took the device manager: frames come out as textures.
  bool hardware() const { return hardware_; }

  // Feeds one Annex-B access unit and collects every picture it produced.
  HRESULT Decode(const uint8_t* data, size_t length, int64_t pts_us, bool key, std::vector<DecodedFrame>* out);
  void Release();
  // Time spent in the last Decode: feeding input, collecting output.
  double input_ms() const { return input_ms_; }
  double output_ms() const { return output_ms_; }

 private:
  HRESULT NegotiateOutput();
  HRESULT Drain(std::vector<DecodedFrame>* out);
  bool ToFrame(IMFSample* sample, DecodedFrame* frame);

  ComPtr<IMFTransform> transform_;
  bool hardware_ = false;
  bool provides_samples_ = false;
  DWORD output_size_ = 0;
  UINT32 coded_width_ = 0;
  UINT32 coded_height_ = 0;
  LONG default_stride_ = 0;
  RECT visible_ = {};
  bool bt709_ = false;
  bool full_range_ = false;
  double input_ms_ = 0;
  double output_ms_ = 0;
};

}  // namespace wsn
