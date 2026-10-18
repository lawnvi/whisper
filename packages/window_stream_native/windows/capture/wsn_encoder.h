// H.264 through a Media Foundation encoder MFT: the GPU's own (asynchronous,
// fed with D3D11 NV12 textures) when there is one, else Microsoft's software
// encoder (fed through system memory). Output is Annex-B, split the way the
// stream protocol wants it: SPS/PPS as a separate config packet before every
// IDR picture, then the picture.
#pragma once

#include "wsn_d3d.h"

#include <codecapi.h>
#include <strmif.h>
#include <mftransform.h>

#include <condition_variable>
#include <functional>
#include <memory>
#include <string>
#include <vector>

namespace wsn {

constexpr int kPacketConfig = 0x1;
constexpr int kPacketKey = 0x2;

struct EncoderConfig {
  int width = 0;
  int height = 0;
  int fps = 60;
  int bit_rate = 8000000;
  bool allow_hardware = true;
  bool allow_software = true;
  // eAVEncCommonRateControlMode; -1 picks low-delay VBR, then CBR.
  int rate_control = -1;
};

struct EncoderInfo {
  std::wstring name;
  bool hardware = false;
  bool d3d_input = false;
  std::string rate_control;
  std::string notes;
};

// Splits an Annex-B buffer into NAL units (without start codes).
struct NalUnit {
  const uint8_t* data;
  size_t size;
  int type() const { return size > 0 ? (data[0] & 0x1f) : -1; }
};
std::vector<NalUnit> SplitAnnexB(const uint8_t* data, size_t size);

class H264Encoder {
 public:
  // [data] is valid during the call. flags: kPacketConfig / kPacketKey.
  using PacketFn = std::function<void(const uint8_t* data, size_t size, int64_t pts_us, int flags)>;
  // An asynchronous (hardware) encoder failed after it was opened.
  using ErrorFn = std::function<void(HRESULT hr)>;

  H264Encoder();
  ~H264Encoder();
  H264Encoder(const H264Encoder&) = delete;
  H264Encoder& operator=(const H264Encoder&) = delete;

  bool Open(D3D* d3d, const EncoderConfig& config, PacketFn on_packet, ErrorFn on_error, std::string* error);
  void Close();

  // Pictures handed in and not yet out.
  int in_flight() const;
  // Ready for another picture (asynchronous encoders ask for each one).
  bool CanAccept() const;
  // [nv12] must stay untouched until its packet is out. Packets may be
  // delivered before this returns (software) or on a Media Foundation
  // thread (hardware).
  bool Encode(ID3D11Texture2D* nv12, int64_t pts_us, bool keyframe);
  void SetBitRate(int bit_rate);

  const EncoderInfo& info() const;
  int width() const;
  int height() const;

  struct Impl;

 private:
  std::shared_ptr<Impl> impl_;
};

// What the probe prints: every H.264 encoder MFT on this machine.
struct EncoderListing {
  std::wstring name;
  bool hardware;
  bool async;
  std::string luid;
};
std::vector<EncoderListing> ListH264Encoders();

}  // namespace wsn
