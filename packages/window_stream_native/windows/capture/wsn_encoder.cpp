#include "wsn_encoder.h"

#include <mferror.h>

#include <algorithm>
#include <atomic>
#include <mutex>

namespace wsn {

std::vector<NalUnit> SplitAnnexB(const uint8_t* data, size_t size) {
  std::vector<NalUnit> out;
  auto find_start = [&](size_t from, size_t* code_length) -> size_t {
    for (size_t j = from; j + 3 <= size; ++j) {
      if (data[j] != 0 || data[j + 1] != 0) continue;
      if (data[j + 2] == 1) {
        *code_length = 3;
        return j;
      }
      if (j + 4 <= size && data[j + 2] == 0 && data[j + 3] == 1) {
        *code_length = 4;
        return j;
      }
    }
    return size;
  };
  size_t length = 0;
  size_t start = find_start(0, &length);
  while (start < size) {
    size_t begin = start + length;
    size_t next_length = 0;
    size_t next = find_start(begin, &next_length);
    size_t end = next;
    // A NAL unit never ends in a zero byte (its stop bit); zeros before the
    // next start code are padding.
    while (end > begin && data[end - 1] == 0) --end;
    if (end > begin) out.push_back(NalUnit{data + begin, end - begin});
    start = next;
    length = next_length;
  }
  return out;
}

namespace {

constexpr uint8_t kStartCode[4] = {0, 0, 0, 1};

void AppendNal(std::vector<uint8_t>* out, const NalUnit& nal) {
  out->insert(out->end(), kStartCode, kStartCode + 4);
  out->insert(out->end(), nal.data, nal.data + nal.size);
}

bool SetCodecValue(ICodecAPI* codec, const GUID& api, UINT32 value) {
  if (codec == nullptr || codec->IsSupported(&api) != S_OK) return false;
  VARIANT variant;
  VariantInit(&variant);
  variant.vt = VT_UI4;
  variant.ulVal = value;
  return SUCCEEDED(codec->SetValue(&api, &variant));
}

bool SetCodecBool(ICodecAPI* codec, const GUID& api, bool value) {
  if (codec == nullptr || codec->IsSupported(&api) != S_OK) return false;
  VARIANT variant;
  VariantInit(&variant);
  variant.vt = VT_BOOL;
  variant.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
  return SUCCEEDED(codec->SetValue(&api, &variant));
}

std::string LuidText(const LUID& luid) { return Format("%08lx:%08lx", luid.HighPart, luid.LowPart); }

}  // namespace

struct H264Encoder::Impl : std::enable_shared_from_this<H264Encoder::Impl> {
  struct Packet {
    std::vector<uint8_t> bytes;
    int64_t pts_us;
    int flags;
  };

  D3D* d3d = nullptr;
  EncoderConfig config;
  EncoderInfo info;
  PacketFn on_packet;
  ErrorFn on_error;
  winrt::com_ptr<IMFTransform> mft;
  winrt::com_ptr<ICodecAPI> codec;
  winrt::com_ptr<IMFMediaEventGenerator> events;
  winrt::com_ptr<IMFAsyncCallback> callback;
  DWORD input_id = 0;
  DWORD output_id = 0;
  bool async = false;
  bool provides_samples = false;
  DWORD output_size = 0;

  mutable std::mutex mutex;
  int need_input = 0;
  int in_flight = 0;
  bool closed = false;
  std::vector<uint8_t> parameter_sets;
  winrt::com_ptr<ID3D11Texture2D> staging;

  bool Configure(std::string* error);
  bool SetTypes(std::string* error);
  winrt::com_ptr<IMFSample> MakeSample(ID3D11Texture2D* texture, int64_t pts_us);
  // Pulls one output (lock held). Returns S_OK with packets appended,
  // MF_E_TRANSFORM_NEED_MORE_INPUT when there is none.
  HRESULT PullOutput(std::vector<Packet>* packets);
  void Split(const uint8_t* data, size_t size, int64_t pts_us, std::vector<Packet>* packets);
  void Deliver(std::vector<Packet>& packets);
  void OnEvent(IMFAsyncResult* result);
  void Shutdown();
};

namespace {

class EventCallback : public winrt::implements<EventCallback, IMFAsyncCallback> {
 public:
  explicit EventCallback(std::weak_ptr<H264Encoder::Impl> owner) : owner_(std::move(owner)) {}
  HRESULT STDMETHODCALLTYPE GetParameters(DWORD*, DWORD*) noexcept override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE Invoke(IMFAsyncResult* result) noexcept override {
    if (auto owner = owner_.lock()) {
      try {
        owner->OnEvent(result);
      } catch (...) {
      }
    }
    return S_OK;
  }

 private:
  std::weak_ptr<H264Encoder::Impl> owner_;
};

}  // namespace

bool H264Encoder::Impl::Configure(std::string* error) {
  codec = mft.try_as<ICodecAPI>();
  winrt::com_ptr<IMFAttributes> attributes;
  if (SUCCEEDED(mft->GetAttributes(attributes.put())) && attributes) {
    UINT32 value = 0;
    if (SUCCEEDED(attributes->GetUINT32(MF_TRANSFORM_ASYNC, &value)) && value) {
      async = true;
      attributes->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
    }
    attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
    UINT32 d3d11_aware = 0;
    attributes->GetUINT32(MF_SA_D3D11_AWARE, &d3d11_aware);
    if (info.hardware && d3d11_aware && d3d->manager() != nullptr) {
      if (SUCCEEDED(mft->ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER,
                                        reinterpret_cast<ULONG_PTR>(d3d->manager())))) {
        info.d3d_input = true;
      }
    }
  }
  if (info.hardware && !info.d3d_input) {
    if (error) *error = "hardware encoder without Direct3D 11 input";
    return false;
  }
  DWORD inputs = 0, outputs = 0;
  mft->GetStreamCount(&inputs, &outputs);
  if (inputs >= 1 && outputs >= 1) {
    DWORD in_ids[1] = {0}, out_ids[1] = {0};
    if (SUCCEEDED(mft->GetStreamIDs(1, in_ids, 1, out_ids))) {
      input_id = in_ids[0];
      output_id = out_ids[0];
    }
  }

  // Rate control first: some encoders only take it before the media types.
  bool rate_set = false;
  if (config.rate_control >= 0) {
    rate_set = SetCodecValue(codec.get(), CODECAPI_AVEncCommonRateControlMode, config.rate_control);
    info.rate_control = Format("mode %d%s", config.rate_control, rate_set ? "" : " (refused)");
  } else {
    if (SetCodecValue(codec.get(), CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_LowDelayVBR)) {
      info.rate_control = "low-delay VBR";
      rate_set = true;
    } else if (SetCodecValue(codec.get(), CODECAPI_AVEncCommonRateControlMode, eAVEncCommonRateControlMode_CBR)) {
      info.rate_control = "CBR";
      rate_set = true;
    } else {
      info.rate_control = "default";
    }
  }
  SetCodecValue(codec.get(), CODECAPI_AVEncCommonMeanBitRate, static_cast<UINT32>(config.bit_rate));
  SetCodecValue(codec.get(), CODECAPI_AVEncCommonMaxBitRate, static_cast<UINT32>(config.bit_rate * 3 / 2));
  SetCodecBool(codec.get(), CODECAPI_AVLowLatencyMode, true);
  SetCodecValue(codec.get(), CODECAPI_AVEncMPVDefaultBPictureCount, 0);
  SetCodecValue(codec.get(), CODECAPI_AVEncMPVGOPSize, static_cast<UINT32>(config.fps * 4));
  // Favour speed: a picture late is worse than a slightly softer one.
  SetCodecValue(codec.get(), CODECAPI_AVEncCommonQualityVsSpeed, 33);
  (void)rate_set;
  return SetTypes(error);
}

bool H264Encoder::Impl::SetTypes(std::string* error) {
  auto color = [](IMFMediaType* type) {
    type->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
    type->SetUINT32(MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709);
    type->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
    type->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
  };
  winrt::com_ptr<IMFMediaType> output;
  MFCreateMediaType(output.put());
  output->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  output->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  output->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(config.bit_rate));
  MFSetAttributeSize(output.get(), MF_MT_FRAME_SIZE, config.width, config.height);
  MFSetAttributeRatio(output.get(), MF_MT_FRAME_RATE, config.fps, 1);
  MFSetAttributeRatio(output.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  output->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  output->SetUINT32(MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
  color(output.get());
  HRESULT hr = mft->SetOutputType(output_id, output.get(), 0);
  if (FAILED(hr)) {
    if (error) *error = "SetOutputType " + HrText(hr);
    return false;
  }
  winrt::com_ptr<IMFMediaType> input;
  MFCreateMediaType(input.put());
  input->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  input->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  MFSetAttributeSize(input.get(), MF_MT_FRAME_SIZE, config.width, config.height);
  MFSetAttributeRatio(input.get(), MF_MT_FRAME_RATE, config.fps, 1);
  MFSetAttributeRatio(input.get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  input->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  color(input.get());
  hr = mft->SetInputType(input_id, input.get(), 0);
  if (FAILED(hr)) {
    // Take the encoder's own NV12 type, with our size and rate.
    for (DWORD index = 0;; ++index) {
      winrt::com_ptr<IMFMediaType> offered;
      if (FAILED(mft->GetInputAvailableType(input_id, index, offered.put()))) break;
      GUID subtype{};
      offered->GetGUID(MF_MT_SUBTYPE, &subtype);
      if (subtype != MFVideoFormat_NV12) continue;
      MFSetAttributeSize(offered.get(), MF_MT_FRAME_SIZE, config.width, config.height);
      MFSetAttributeRatio(offered.get(), MF_MT_FRAME_RATE, config.fps, 1);
      hr = mft->SetInputType(input_id, offered.get(), 0);
      if (SUCCEEDED(hr)) break;
    }
  }
  if (FAILED(hr)) {
    if (error) *error = "SetInputType " + HrText(hr);
    return false;
  }
  MFT_OUTPUT_STREAM_INFO stream{};
  if (SUCCEEDED(mft->GetOutputStreamInfo(output_id, &stream))) {
    provides_samples = (stream.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
                                          MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
    output_size = stream.cbSize;
  }
  // Parameter sets known up front (some encoders only put them here).
  winrt::com_ptr<IMFMediaType> current;
  if (SUCCEEDED(mft->GetOutputCurrentType(output_id, current.put()))) {
    UINT32 size = 0;
    if (SUCCEEDED(current->GetBlobSize(MF_MT_MPEG_SEQUENCE_HEADER, &size)) && size > 0) {
      std::vector<uint8_t> header(size);
      if (SUCCEEDED(current->GetBlob(MF_MT_MPEG_SEQUENCE_HEADER, header.data(), size, nullptr))) {
        std::vector<uint8_t> sets;
        for (const auto& nal : SplitAnnexB(header.data(), header.size())) {
          if (nal.type() == 7 || nal.type() == 8) AppendNal(&sets, nal);
        }
        if (!sets.empty()) parameter_sets = std::move(sets);
      }
    }
  }
  mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  HRESULT begin = mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  HRESULT start = mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  if (FAILED(begin) || FAILED(start)) {
    // A hardware MFT with no free session typically fails here
    // (MF_E_HW_MFT_FAILED_START_STREAMING); fall through to the next encoder.
    if (error) *error = Format("start streaming %s/%s", HrText(begin).c_str(), HrText(start).c_str());
    return false;
  }
  return true;
}

winrt::com_ptr<IMFSample> H264Encoder::Impl::MakeSample(ID3D11Texture2D* texture, int64_t pts_us) {
  winrt::com_ptr<IMFSample> sample;
  if (FAILED(MFCreateSample(sample.put()))) return nullptr;
  winrt::com_ptr<IMFMediaBuffer> buffer;
  if (info.d3d_input) {
    if (FAILED(MFCreateDXGISurfaceBuffer(__uuidof(ID3D11Texture2D), texture, 0, FALSE, buffer.put()))) {
      return nullptr;
    }
    DWORD length = 0;
    if (auto two_d = buffer.try_as<IMF2DBuffer>()) {
      two_d->GetContiguousLength(&length);
    }
    buffer->SetCurrentLength(length);
  } else {
    // Software encoder: through system memory.
    D3D11_TEXTURE2D_DESC desc{};
    texture->GetDesc(&desc);
    D3D11_TEXTURE2D_DESC have{};
    if (staging) staging->GetDesc(&have);
    if (!staging || have.Width != desc.Width || have.Height != desc.Height) {
      staging = d3d->CreateTexture(desc.Width, desc.Height, DXGI_FORMAT_NV12, 0, D3D11_USAGE_STAGING,
                                   D3D11_CPU_ACCESS_READ);
      if (!staging) return nullptr;
    }
    const DWORD width = desc.Width, height = desc.Height;
    const DWORD bytes = width * height * 3 / 2;
    if (FAILED(MFCreateMemoryBuffer(bytes, buffer.put()))) return nullptr;
    BYTE* target = nullptr;
    if (FAILED(buffer->Lock(&target, nullptr, nullptr))) return nullptr;
    bool copied = false;
    {
      D3DLock lock(d3d);
      d3d->context()->CopyResource(staging.get(), texture);
      D3D11_MAPPED_SUBRESOURCE mapped{};
      if (SUCCEEDED(d3d->context()->Map(staging.get(), 0, D3D11_MAP_READ, 0, &mapped))) {
        const BYTE* source = static_cast<const BYTE*>(mapped.pData);
        for (DWORD row = 0; row < height; ++row) {
          memcpy(target + row * width, source + row * mapped.RowPitch, width);
        }
        const BYTE* chroma = source + mapped.RowPitch * height;
        BYTE* chroma_target = target + width * height;
        for (DWORD row = 0; row < height / 2; ++row) {
          memcpy(chroma_target + row * width, chroma + row * mapped.RowPitch, width);
        }
        d3d->context()->Unmap(staging.get(), 0);
        copied = true;
      }
    }
    buffer->Unlock();
    if (!copied) return nullptr;
    buffer->SetCurrentLength(bytes);
  }
  sample->AddBuffer(buffer.get());
  sample->SetSampleTime(pts_us * 10);
  sample->SetSampleDuration(10000000LL / std::max(1, config.fps));
  return sample;
}

void H264Encoder::Impl::Split(const uint8_t* data, size_t size, int64_t pts_us, std::vector<Packet>* packets) {
  std::vector<uint8_t> sets;
  std::vector<uint8_t> picture;
  bool idr = false;
  for (const auto& nal : SplitAnnexB(data, size)) {
    switch (nal.type()) {
      case 7:
      case 8:
        AppendNal(&sets, nal);
        break;
      case 9:  // access unit delimiter
        break;
      case 5:
        idr = true;
        AppendNal(&picture, nal);
        break;
      default:
        AppendNal(&picture, nal);
    }
  }
  if (!sets.empty()) parameter_sets = sets;
  if (idr && !parameter_sets.empty()) {
    packets->push_back(Packet{parameter_sets, 0, kPacketConfig});
  }
  if (!picture.empty()) {
    packets->push_back(Packet{std::move(picture), pts_us, idr ? kPacketKey : 0});
  }
}

HRESULT H264Encoder::Impl::PullOutput(std::vector<Packet>* packets) {
  MFT_OUTPUT_DATA_BUFFER output{};
  output.dwStreamID = output_id;
  winrt::com_ptr<IMFSample> own;
  if (!provides_samples) {
    MFCreateSample(own.put());
    winrt::com_ptr<IMFMediaBuffer> buffer;
    DWORD size = output_size > 0 ? output_size : static_cast<DWORD>(config.width * config.height * 3 / 2 + 65536);
    MFCreateMemoryBuffer(size, buffer.put());
    own->AddBuffer(buffer.get());
    output.pSample = own.get();
  }
  DWORD status = 0;
  HRESULT hr = mft->ProcessOutput(0, 1, &output, &status);
  if (output.pEvents != nullptr) output.pEvents->Release();
  winrt::com_ptr<IMFSample> sample;
  if (provides_samples) {
    sample.attach(output.pSample);
  } else {
    sample = own;
  }
  if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
    // The encoder settled its output type (often the first picture).
    winrt::com_ptr<IMFMediaType> type;
    if (SUCCEEDED(mft->GetOutputAvailableType(output_id, 0, type.put()))) {
      mft->SetOutputType(output_id, type.get(), 0);
    }
    MFT_OUTPUT_STREAM_INFO stream{};
    if (SUCCEEDED(mft->GetOutputStreamInfo(output_id, &stream))) {
      provides_samples = (stream.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES |
                                            MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
      output_size = stream.cbSize;
    }
    return hr;
  }
  if (FAILED(hr)) return hr;
  if (!sample) return E_UNEXPECTED;
  LONGLONG time = 0;
  sample->GetSampleTime(&time);
  winrt::com_ptr<IMFMediaBuffer> buffer;
  if (FAILED(sample->ConvertToContiguousBuffer(buffer.put()))) return E_FAIL;
  BYTE* data = nullptr;
  DWORD length = 0;
  if (FAILED(buffer->Lock(&data, nullptr, &length))) return E_FAIL;
  Split(data, length, time / 10, packets);
  buffer->Unlock();
  if (in_flight > 0) in_flight--;
  return S_OK;
}

void H264Encoder::Impl::Deliver(std::vector<Packet>& packets) {
  if (!on_packet) return;
  for (auto& packet : packets) {
    on_packet(packet.bytes.data(), packet.bytes.size(), packet.pts_us, packet.flags);
  }
}

void H264Encoder::Impl::OnEvent(IMFAsyncResult* result) {
  winrt::com_ptr<IMFMediaEvent> event;
  HRESULT hr;
  {
    std::lock_guard<std::mutex> lock(mutex);
    if (closed || !events) return;
    hr = events->EndGetEvent(result, event.put());
  }
  if (FAILED(hr)) {
    if (hr != MF_E_SHUTDOWN && on_error) on_error(hr);
    return;
  }
  MediaEventType type = MEUnknown;
  event->GetType(&type);
  HRESULT status = S_OK;
  event->GetStatus(&status);
  std::vector<Packet> packets;
  bool failed = FAILED(status) || type == MEError;
  {
    std::lock_guard<std::mutex> lock(mutex);
    if (closed) return;
    if (type == METransformNeedInput) {
      need_input++;
    } else if (type == METransformHaveOutput) {
      HRESULT pulled = PullOutput(&packets);
      if (FAILED(pulled) && pulled != MF_E_TRANSFORM_NEED_MORE_INPUT && pulled != MF_E_TRANSFORM_STREAM_CHANGE) {
        failed = true;
        status = pulled;
      }
    }
  }
  Deliver(packets);
  if (failed) {
    if (on_error) on_error(FAILED(status) ? status : E_FAIL);
    return;
  }
  std::lock_guard<std::mutex> lock(mutex);
  if (!closed && events) events->BeginGetEvent(callback.get(), nullptr);
}

void H264Encoder::Impl::Shutdown() {
  winrt::com_ptr<IMFTransform> transform;
  {
    std::lock_guard<std::mutex> lock(mutex);
    if (closed) return;
    closed = true;
    transform = mft;
  }
  if (!transform) return;
  transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
  transform->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
  transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
  if (auto shutdown = transform.try_as<IMFShutdown>()) shutdown->Shutdown();
  std::lock_guard<std::mutex> lock(mutex);
  events = nullptr;
  codec = nullptr;
  mft = nullptr;
  staging = nullptr;
}

H264Encoder::H264Encoder() = default;
H264Encoder::~H264Encoder() { Close(); }

bool H264Encoder::Open(D3D* d3d, const EncoderConfig& config, PacketFn on_packet, ErrorFn on_error,
                       std::string* error) {
  Close();
  std::string reasons;
  auto attempt = [&](winrt::com_ptr<IMFTransform> transform, const std::wstring& name, bool hardware) -> bool {
    auto impl = std::make_shared<Impl>();
    impl->d3d = d3d;
    impl->config = config;
    impl->info.name = name;
    impl->info.hardware = hardware;
    impl->on_packet = on_packet;
    impl->on_error = on_error;
    impl->mft = transform;
    std::string why;
    bool ok = false;
    try {
      ok = impl->Configure(&why);
    } catch (...) {
      why = "exception";
    }
    if (!ok) {
      reasons += Narrow(name) + ": " + why + "; ";
      impl->Shutdown();
      return false;
    }
    if (impl->async) {
      impl->events = transform.try_as<IMFMediaEventGenerator>();
      if (!impl->events) {
        reasons += Narrow(name) + ": no event generator; ";
        impl->Shutdown();
        return false;
      }
      impl->callback = winrt::make<EventCallback>(std::weak_ptr<Impl>(impl));
      HRESULT hr = impl->events->BeginGetEvent(impl->callback.get(), nullptr);
      if (FAILED(hr)) {
        reasons += Narrow(name) + ": BeginGetEvent " + HrText(hr) + "; ";
        impl->Shutdown();
        return false;
      }
      // An async hardware MFT that got no session often opens but never asks
      // for input. Wait briefly for the first METransformNeedInput; if it
      // doesn't come, this encoder is dead — try the next one.
      double deadline = NowMs() + 500;
      bool ready = false;
      while (NowMs() < deadline) {
        {
          std::lock_guard<std::mutex> lock(impl->mutex);
          if (impl->need_input > 0) ready = true;
          if (impl->closed) break;
        }
        if (ready) break;
        Sleep(10);
      }
      if (!ready) {
        reasons += Narrow(name) + ": no input request in 500 ms; ";
        impl->Shutdown();
        return false;
      }
    }
    impl->info.notes = reasons;
    impl_ = impl;
    return true;
  };

  const MFT_REGISTER_TYPE_INFO in_info{MFMediaType_Video, MFVideoFormat_NV12};
  const MFT_REGISTER_TYPE_INFO out_info{MFMediaType_Video, MFVideoFormat_H264};
  for (int pass = 0; pass < 2 && !impl_; ++pass) {
    bool hardware = pass == 0;
    if (hardware && (!config.allow_hardware || d3d == nullptr || d3d->manager() == nullptr)) continue;
    if (!hardware && !config.allow_software) continue;
    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    UINT32 flags = (hardware ? MFT_ENUM_FLAG_HARDWARE : MFT_ENUM_FLAG_SYNCMFT) | MFT_ENUM_FLAG_SORTANDFILTER;
    if (FAILED(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags, &in_info, &out_info, &activates, &count))) count = 0;
    for (UINT32 i = 0; i < count; ++i) {
      if (!impl_) {
        WCHAR* name = nullptr;
        UINT32 length = 0;
        std::wstring friendly = L"?";
        if (SUCCEEDED(activates[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &length))) {
          friendly = name;
          CoTaskMemFree(name);
        }
        bool same_adapter = true;
        if (hardware) {
          UINT64 luid_value = 0;
          if (SUCCEEDED(activates[i]->GetUINT64(MFT_ENUM_ADAPTER_LUID, &luid_value))) {
            LUID luid = d3d->adapter_luid();
            UINT64 ours = (static_cast<UINT64>(static_cast<UINT32>(luid.HighPart)) << 32) | luid.LowPart;
            same_adapter = luid_value == ours;
          }
        }
        if (!same_adapter) {
          reasons += Narrow(friendly) + ": other adapter; ";
        } else {
          winrt::com_ptr<IMFTransform> transform;
          HRESULT hr = activates[i]->ActivateObject(__uuidof(IMFTransform), transform.put_void());
          if (SUCCEEDED(hr) && transform) {
            attempt(transform, friendly, hardware);
          } else {
            reasons += Narrow(friendly) + ": activate " + HrText(hr) + "; ";
          }
        }
      }
      activates[i]->Release();
    }
    CoTaskMemFree(activates);
  }
  if (!impl_) {
    if (error) *error = reasons.empty() ? std::string("no H.264 encoder") : reasons;
    return false;
  }
  return true;
}

void H264Encoder::Close() {
  if (impl_) {
    impl_->Shutdown();
    impl_ = nullptr;
  }
}

int H264Encoder::in_flight() const {
  if (!impl_) return 0;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  return impl_->in_flight;
}

bool H264Encoder::CanAccept() const {
  if (!impl_) return false;
  std::lock_guard<std::mutex> lock(impl_->mutex);
  return !impl_->closed && (!impl_->async || impl_->need_input > 0);
}

bool H264Encoder::Encode(ID3D11Texture2D* nv12, int64_t pts_us, bool keyframe) {
  auto impl = impl_;
  if (!impl) return false;
  std::vector<Impl::Packet> packets;
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    if (impl->closed || (impl->async && impl->need_input <= 0)) return false;
    auto sample = impl->MakeSample(nv12, pts_us);
    if (!sample) return false;
    if (keyframe) {
      SetCodecValue(impl->codec.get(), CODECAPI_AVEncVideoForceKeyFrame, 1);
    }
    HRESULT hr = impl->mft->ProcessInput(impl->input_id, sample.get(), 0);
    if (hr == MF_E_NOTACCEPTING && !impl->async) {
      while (SUCCEEDED(impl->PullOutput(&packets))) {
      }
      hr = impl->mft->ProcessInput(impl->input_id, sample.get(), 0);
    }
    if (FAILED(hr)) return false;
    impl->in_flight++;
    if (impl->async) {
      impl->need_input--;
    } else {
      for (int guard = 0; guard < 8; ++guard) {
        HRESULT pulled = impl->PullOutput(&packets);
        if (pulled == MF_E_TRANSFORM_STREAM_CHANGE) continue;
        if (FAILED(pulled)) break;
      }
    }
  }
  impl->Deliver(packets);
  return true;
}

void H264Encoder::SetBitRate(int bit_rate) {
  auto impl = impl_;
  if (!impl) return;
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->config.bit_rate = bit_rate;
  SetCodecValue(impl->codec.get(), CODECAPI_AVEncCommonMeanBitRate, static_cast<UINT32>(bit_rate));
  SetCodecValue(impl->codec.get(), CODECAPI_AVEncCommonMaxBitRate, static_cast<UINT32>(bit_rate * 3 / 2));
}

const EncoderInfo& H264Encoder::info() const {
  static const EncoderInfo empty;
  return impl_ ? impl_->info : empty;
}

int H264Encoder::width() const { return impl_ ? impl_->config.width : 0; }
int H264Encoder::height() const { return impl_ ? impl_->config.height : 0; }

std::vector<EncoderListing> ListH264Encoders() {
  std::vector<EncoderListing> out;
  const MFT_REGISTER_TYPE_INFO out_info{MFMediaType_Video, MFVideoFormat_H264};
  for (int pass = 0; pass < 2; ++pass) {
    IMFActivate** activates = nullptr;
    UINT32 count = 0;
    UINT32 flags = pass == 0 ? MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_ASYNCMFT
                             : MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT;
    if (FAILED(MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, flags | MFT_ENUM_FLAG_SORTANDFILTER, nullptr, &out_info,
                         &activates, &count))) {
      continue;
    }
    for (UINT32 i = 0; i < count; ++i) {
      EncoderListing entry;
      WCHAR* name = nullptr;
      UINT32 length = 0;
      if (SUCCEEDED(activates[i]->GetAllocatedString(MFT_FRIENDLY_NAME_Attribute, &name, &length))) {
        entry.name = name;
        CoTaskMemFree(name);
      }
      UINT32 mft_flags = 0;
      activates[i]->GetUINT32(MF_TRANSFORM_FLAGS_Attribute, &mft_flags);
      entry.hardware = (mft_flags & MFT_ENUM_FLAG_HARDWARE) != 0;
      entry.async = (mft_flags & MFT_ENUM_FLAG_ASYNCMFT) != 0;
      UINT64 luid = 0;
      if (SUCCEEDED(activates[i]->GetUINT64(MFT_ENUM_ADAPTER_LUID, &luid))) {
        LUID value{};
        value.HighPart = static_cast<LONG>(luid >> 32);
        value.LowPart = static_cast<DWORD>(luid & 0xffffffff);
        entry.luid = LuidText(value);
      }
      out.push_back(entry);
      activates[i]->Release();
    }
    CoTaskMemFree(activates);
  }
  return out;
}

}  // namespace wsn
