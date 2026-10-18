#include "h264_decoder.h"

#include <codecapi.h>
#include <mferror.h>
#include <strmif.h>

#include <algorithm>
#include <cstring>

namespace wsn {
namespace {

// {62CE7E72-4C71-4D20-B15D-452831A87D9D}: Microsoft H.264 decoder MFT.
const GUID kH264DecoderClsid = {0x62CE7E72, 0x4C71, 0x4d20, {0xB1, 0x5D, 0x45, 0x28, 0x31, 0xA8, 0x7D, 0x9D}};

bool AreaToRect(const MFVideoArea& area, UINT32 width, UINT32 height, RECT* rect) {
  LONG left = area.OffsetX.value;
  LONG top = area.OffsetY.value;
  LONG right = left + area.Area.cx;
  LONG bottom = top + area.Area.cy;
  if (area.Area.cx <= 0 || area.Area.cy <= 0 || left < 0 || top < 0 || right > static_cast<LONG>(width) ||
      bottom > static_cast<LONG>(height)) {
    return false;
  }
  *rect = {left, top, right, bottom};
  return true;
}

}  // namespace

bool H264Decoder::Create(IMFDXGIDeviceManager* manager) {
  Release();
  HRESULT hr = CoCreateInstance(kH264DecoderClsid, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&transform_));
  if (FAILED(hr)) {
    Log("decoder: H.264 MFT unavailable (0x%08lx)", hr);
    transform_.Reset();
    return false;
  }
  ComPtr<IMFAttributes> attributes;
  if (SUCCEEDED(transform_->GetAttributes(&attributes)) && attributes != nullptr) {
    attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
    UINT32 d3d11_aware = 0;
    attributes->GetUINT32(MF_SA_D3D11_AWARE, &d3d11_aware);
    if (manager != nullptr && d3d11_aware) {
      hr = transform_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, reinterpret_cast<ULONG_PTR>(manager));
      hardware_ = SUCCEEDED(hr);
      if (!hardware_) {
        Log("decoder: D3D manager refused (0x%08lx), software decoding", hr);
      }
    }
  }
  ComPtr<ICodecAPI> codec_api;
  if (SUCCEEDED(transform_.As(&codec_api))) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_UI4;
    value.ulVal = 1;
    codec_api->SetValue(&CODECAPI_AVLowLatencyMode, &value);
  }
  ComPtr<IMFMediaType> input;
  MFCreateMediaType(&input);
  input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  hr = transform_->SetInputType(0, input.Get(), 0);
  if (FAILED(hr)) {
    Log("decoder: SetInputType failed (0x%08lx)", hr);
    Release();
    return false;
  }
  hr = NegotiateOutput();
  if (FAILED(hr)) {
    Log("decoder: no NV12 output (0x%08lx)", hr);
    if (hardware_) {
      // Retry in software rather than not decoding at all.
      Release();
      return Create(nullptr);
    }
    Release();
    return false;
  }
  if (hardware_) {
    ComPtr<IMFAttributes> output_attributes;
    if (SUCCEEDED(transform_->GetOutputStreamAttributes(0, &output_attributes)) && output_attributes != nullptr) {
      // The presenter holds the newest frame and the one on screen.
      output_attributes->SetUINT32(MF_SA_MINIMUM_OUTPUT_SAMPLE_COUNT, 3);
    }
  }
  transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  Log("decoder: created (%s)", hardware_ ? "D3D11 hardware" : "software");
  return true;
}

void H264Decoder::Release() {
  if (transform_ != nullptr) {
    transform_->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
    transform_->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    if (hardware_) {
      transform_->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, 0);
    }
  }
  transform_.Reset();
  hardware_ = false;
  provides_samples_ = false;
  coded_width_ = 0;
  coded_height_ = 0;
}

HRESULT H264Decoder::NegotiateOutput() {
  for (DWORD index = 0;; index++) {
    ComPtr<IMFMediaType> type;
    HRESULT hr = transform_->GetOutputAvailableType(0, index, &type);
    if (FAILED(hr)) {
      return hr;
    }
    GUID subtype = {};
    type->GetGUID(MF_MT_SUBTYPE, &subtype);
    if (subtype != MFVideoFormat_NV12) {
      continue;
    }
    hr = transform_->SetOutputType(0, type.Get(), 0);
    if (FAILED(hr)) {
      return hr;
    }
    UINT32 width = 0;
    UINT32 height = 0;
    MFGetAttributeSize(type.Get(), MF_MT_FRAME_SIZE, &width, &height);
    coded_width_ = width;
    coded_height_ = height;
    visible_ = {0, 0, static_cast<LONG>(width), static_cast<LONG>(height)};
    MFVideoArea area = {};
    UINT32 size = 0;
    if (SUCCEEDED(type->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8*>(&area), sizeof(area),
                                &size)) ||
        SUCCEEDED(type->GetBlob(MF_MT_GEOMETRIC_APERTURE, reinterpret_cast<UINT8*>(&area), sizeof(area), &size))) {
      RECT rect;
      if (AreaToRect(area, width, height, &rect)) visible_ = rect;
    }
    UINT32 stride = 0;
    default_stride_ = SUCCEEDED(type->GetUINT32(MF_MT_DEFAULT_STRIDE, &stride)) ? static_cast<LONG>(stride)
                                                                                 : static_cast<LONG>(width);
    UINT32 matrix = MFVideoTransferMatrix_Unknown;
    type->GetUINT32(MF_MT_YUV_MATRIX, &matrix);
    // Unsignalled: HD pictures are BT.709 by convention, SD ones BT.601.
    bt709_ = matrix == MFVideoTransferMatrix_BT709 ||
             (matrix != MFVideoTransferMatrix_BT601 && std::min(width, height) >= 720);
    UINT32 range = MFNominalRange_Unknown;
    type->GetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, &range);
    full_range_ = range == MFNominalRange_0_255;
    MFT_OUTPUT_STREAM_INFO info = {};
    transform_->GetOutputStreamInfo(0, &info);
    provides_samples_ = (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
    output_size_ = info.cbSize;
    Log("decoder: output %ux%u visible %ldx%ld+%ld+%ld matrix=%u range=%u", width, height,
        visible_.right - visible_.left, visible_.bottom - visible_.top, visible_.left, visible_.top, matrix, range);
    return S_OK;
  }
}

HRESULT H264Decoder::Decode(const uint8_t* data, size_t length, int64_t pts_us, bool key,
                            std::vector<DecodedFrame>* out) {
  if (transform_ == nullptr) {
    return E_UNEXPECTED;
  }
  ComPtr<IMFSample> sample;
  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = MFCreateSample(&sample);
  if (SUCCEEDED(hr)) hr = MFCreateMemoryBuffer(static_cast<DWORD>(length), &buffer);
  if (FAILED(hr)) return hr;
  BYTE* target = nullptr;
  hr = buffer->Lock(&target, nullptr, nullptr);
  if (FAILED(hr)) return hr;
  std::memcpy(target, data, length);
  buffer->Unlock();
  buffer->SetCurrentLength(static_cast<DWORD>(length));
  sample->AddBuffer(buffer.Get());
  sample->SetSampleTime(pts_us * 10);
  if (key) sample->SetUINT32(MFSampleExtension_CleanPoint, TRUE);
  const double started = NowSeconds();
  hr = transform_->ProcessInput(0, sample.Get(), 0);
  if (hr == MF_E_NOTACCEPTING) {
    // Output first, then the input fits.
    HRESULT drained = Drain(out);
    if (FAILED(drained)) return drained;
    hr = transform_->ProcessInput(0, sample.Get(), 0);
  }
  const double fed = NowSeconds();
  input_ms_ = (fed - started) * 1000;
  if (FAILED(hr)) {
    return hr;
  }
  hr = Drain(out);
  output_ms_ = (NowSeconds() - fed) * 1000;
  return hr;
}

HRESULT H264Decoder::Drain(std::vector<DecodedFrame>* out) {
  for (int guard = 0; guard < 64; guard++) {
    MFT_OUTPUT_DATA_BUFFER output = {};
    ComPtr<IMFSample> own;
    if (!provides_samples_) {
      ComPtr<IMFMediaBuffer> buffer;
      DWORD size = std::max<DWORD>(output_size_, coded_width_ * coded_height_ * 3 / 2 + 4096);
      if (FAILED(MFCreateSample(&own)) || FAILED(MFCreateMemoryBuffer(size, &buffer))) {
        return E_OUTOFMEMORY;
      }
      own->AddBuffer(buffer.Get());
      output.pSample = own.Get();
    }
    DWORD status = 0;
    HRESULT hr = transform_->ProcessOutput(0, 1, &output, &status);
    if (output.pEvents != nullptr) {
      output.pEvents->Release();
      output.pEvents = nullptr;
    }
    if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) {
      return S_OK;
    }
    if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
      HRESULT negotiated = NegotiateOutput();
      if (FAILED(negotiated)) return negotiated;
      continue;
    }
    if (FAILED(hr)) {
      return hr;
    }
    ComPtr<IMFSample> sample;
    if (provides_samples_) {
      sample.Attach(output.pSample);  // the MFT's reference is ours now
    } else {
      sample = own;
    }
    DecodedFrame frame;
    if (sample != nullptr && ToFrame(sample.Get(), &frame)) {
      out->push_back(std::move(frame));
    }
  }
  return S_OK;
}

bool H264Decoder::ToFrame(IMFSample* sample, DecodedFrame* frame) {
  frame->coded_width = static_cast<int>(coded_width_);
  frame->coded_height = static_cast<int>(coded_height_);
  frame->visible = visible_;
  frame->bt709 = bt709_;
  frame->full_range = full_range_;
  frame->decoded_at = NowSeconds();
  LONGLONG time = 0;
  if (SUCCEEDED(sample->GetSampleTime(&time))) frame->pts_us = time / 10;
  ComPtr<IMFMediaBuffer> buffer;
  if (FAILED(sample->GetBufferByIndex(0, &buffer))) {
    return false;
  }
  ComPtr<IMFDXGIBuffer> dxgi;
  if (SUCCEEDED(buffer.As(&dxgi))) {
    ComPtr<ID3D11Texture2D> texture;
    if (FAILED(dxgi->GetResource(IID_PPV_ARGS(&texture)))) return false;
    UINT subresource = 0;
    dxgi->GetSubresourceIndex(&subresource);
    frame->sample = sample;
    frame->texture = texture;
    frame->subresource = subresource;
    return true;
  }
  // Memory: copy out so the buffer can go back to the decoder.
  ComPtr<IMF2DBuffer2> buffer2d;
  BYTE* scan = nullptr;
  BYTE* start = nullptr;
  DWORD capacity = 0;
  LONG pitch = 0;
  auto bytes = std::make_shared<std::vector<uint8_t>>();
  const size_t rows = static_cast<size_t>(coded_height_) * 3 / 2;
  if (SUCCEEDED(buffer.As(&buffer2d)) &&
      SUCCEEDED(buffer2d->Lock2DSize(MF2DBuffer_LockFlags_Read, &scan, &pitch, &start, &capacity))) {
    const size_t needed = static_cast<size_t>(pitch > 0 ? pitch : 0) * rows;
    const size_t available = capacity - static_cast<size_t>(scan - start);
    if (pitch <= 0 || available < needed) {
      buffer2d->Unlock2D();
      return false;
    }
    bytes->resize(needed);
    std::memcpy(bytes->data(), scan, needed);
    buffer2d->Unlock2D();
  } else {
    BYTE* data = nullptr;
    DWORD length = 0;
    if (FAILED(buffer->Lock(&data, nullptr, &length))) return false;
    pitch = default_stride_ > 0 ? default_stride_ : static_cast<LONG>(coded_width_);
    size_t needed = static_cast<size_t>(pitch) * rows;
    if (length < needed) {
      buffer->Unlock();
      return false;
    }
    bytes->assign(data, data + needed);
    buffer->Unlock();
  }
  frame->nv12 = std::move(bytes);
  frame->pitch = static_cast<int>(pitch);
  return true;
}

}  // namespace wsn
