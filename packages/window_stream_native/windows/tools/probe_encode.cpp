// W4: the H.264 encoder MFT. Lists every encoder, opens the hardware one
// (Microsoft software MFT as fallback), captures the test window, encodes
// 1080p60 CBR/low-delay with no B-frames, GOP = fps*4, a forced keyframe,
// and measures the time from a frame going in to its packet coming out.
// Writes the Annex-B stream to a .h264 file and checks that a config packet
// precedes each IDR, so the Mac side can decode it with ffprobe/ffmpeg.
#include "probe.h"

#include "core/wsn_convert.h"
#include "core/wsn_encoder.h"
#include "core/wsn_image.h"
#include "core/wsn_stage.h"
#include "core/wsn_wgc.h"
#include "core/wsn_window.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <deque>
#include <mutex>

namespace probe {

namespace {

struct Latency {
  std::mutex mutex;
  std::deque<double> in_times;  // when each frame was submitted
  std::vector<double> samples;  // in -> first packet out (ms)
};

}  // namespace

int RunW4(const Args& args) {
  for (const auto& e : wsn::ListH264Encoders()) {
    Log("encoder: %-55s hardware %d async %d adapter %s", wsn::Narrow(e.name).c_str(), e.hardware, e.async,
        e.luid.c_str());
  }
  wsn::D3D* d3d = wsn::D3D::Shared();
  if (!d3d) {
    Log("no D3D device");
    return 1;
  }
  Log("adapter %s", wsn::Narrow(d3d->adapter_name()).c_str());

  TestWindow tw;
  if (!LaunchTestWindow(L"w4", 1280, 720, &tw)) return 1;
  Sleep(500);
  HWND window = tw.hwnd;
  wsn::Placement home = wsn::SavePlacement(window);
  wsn::Borders borders = wsn::InvisibleBorders(window);
  RECT spot{};
  wsn::StageSpot(0, wsn::RectWidth(home.rect), wsn::RectHeight(home.rect), borders, &spot);
  wsn::StyleBackup style;
  wsn::ApplyStageStyle(window, &style);
  wsn::MoveWindowTo(window, spot);
  Sleep(400);

  bool software = args.Has(L"--software");
  int target_edge = args.Int(L"--edge", 1920);
  int fps = args.Int(L"--fps", 60);
  int bitrate = args.Int(L"--bitrate", 8000000);

  // Pipeline: WGC BGRA -> VideoProcessor NV12 (scaled to <= edge, even) ->
  // encoder. One encode in flight at a time; newest frame replaces an older
  // waiting one.
  wsn::Converter converter(d3d);
  std::mutex nv12_mutex;
  winrt::com_ptr<ID3D11Texture2D> nv12;
  SIZE encoded_size{};
  Latency latency;
  std::atomic<int> packets{0}, config_packets{0}, key_packets{0};
  std::atomic<bool> idr_had_config{true};
  bool expect_config = true;
  std::vector<uint8_t> stream;
  std::mutex stream_mutex;
  std::atomic<long long> total_bytes{0};
  std::atomic<bool> encoder_error{false};

  wsn::H264Encoder encoder;
  auto on_packet = [&](const uint8_t* data, size_t size, int64_t, int flags) {
    packets++;
    total_bytes += static_cast<long long>(size);
    bool is_config = (flags & wsn::kPacketConfig) != 0;
    bool is_key = (flags & wsn::kPacketKey) != 0;
    if (is_config) {
      config_packets++;
      expect_config = false;
    }
    if (is_key) {
      key_packets++;
      if (expect_config) idr_had_config = false;  // IDR without a config before it
      expect_config = true;                        // next IDR needs its own config
    }
    {
      std::lock_guard<std::mutex> lock(latency.mutex);
      if (!is_config && !latency.in_times.empty()) {
        latency.samples.push_back(wsn::NowMs() - latency.in_times.front());
        latency.in_times.pop_front();
      }
    }
    std::lock_guard<std::mutex> lock(stream_mutex);
    if (stream.size() < 24 * 1024 * 1024) stream.insert(stream.end(), data, data + size);
  };
  auto on_error = [&](HRESULT hr) {
    encoder_error = true;
    Log("encoder error %s", wsn::HrText(hr).c_str());
  };

  wsn::EncoderConfig config;
  config.width = 0;  // set after the first frame
  config.height = 0;
  config.fps = fps;
  config.bit_rate = bitrate;
  config.allow_hardware = !software;
  config.allow_software = true;

  std::atomic<bool> encoder_ready{false};
  std::atomic<int> frames_in{0};
  std::atomic<bool> forced_key{false};
  std::atomic<bool> stopping{false};

  wsn::WgcCapture capture;
  std::string error;
  auto on_frame = [&](ID3D11Texture2D* texture, SIZE content, int64_t time_us) {
    if (stopping) return;
    if (content.cx <= 0 || content.cy <= 0) return;
    SIZE want = wsn::EncodedSize(content.cx, content.cy, target_edge);
    if (!encoder_ready) {
      config.width = want.cx;
      config.height = want.cy;
      std::string why;
      if (!encoder.Open(d3d, config, on_packet, on_error, &why)) {
        Log("encoder open failed: %s", why.c_str());
        stopping = true;
        return;
      }
      Log("encoder: %s hardware %d d3dInput %d rate %s %dx%d", wsn::Narrow(encoder.info().name).c_str(),
          encoder.info().hardware, encoder.info().d3d_input, encoder.info().rate_control.c_str(), want.cx, want.cy);
      encoded_size = want;
      encoder_ready = true;
    }
    if (want.cx != encoded_size.cx || want.cy != encoded_size.cy) return;  // size change: ignore this run
    winrt::com_ptr<ID3D11Texture2D> target;
    {
      std::lock_guard<std::mutex> lock(nv12_mutex);
      if (!nv12) nv12 = d3d->CreateTexture(want.cx, want.cy, DXGI_FORMAT_NV12, D3D11_BIND_RENDER_TARGET);
      target = nv12;
    }
    if (!target) return;
    RECT src{0, 0, content.cx, content.cy};
    {
      wsn::D3DLock lock(d3d);
      if (!converter.Convert(texture, src, target.get())) return;
      d3d->context()->Flush();
    }
    if (!encoder.CanAccept()) return;  // still encoding the previous one
    bool key = !forced_key.exchange(true) ? false : false;  // (keyframe forced once, below)
    (void)key;
    {
      std::lock_guard<std::mutex> lock(latency.mutex);
      latency.in_times.push_back(wsn::NowMs());
      if (latency.in_times.size() > 8) latency.in_times.pop_front();
    }
    encoder.Encode(target.get(), time_us, false);
    frames_in++;
  };
  if (!capture.Start(window, {}, on_frame, nullptr, &error)) {
    Log("capture failed: %s", error.c_str());
    wsn::RestoreStageStyle(window, style);
    wsn::RestorePlacement(window, home);
    CloseTestWindow(&tw);
    return 1;
  }
  // Let the encoder settle, then force one keyframe mid-stream.
  Sleep(2000);
  encoder.Encode(nv12.get(), wsn::NowUs(), true);
  Sleep(3000);
  stopping = true;
  Sleep(200);
  capture.Stop();
  encoder.Close();

  double seconds = 5.0;
  double mbps = total_bytes.load() * 8.0 / 1e6 / seconds;
  std::vector<double> samples;
  {
    std::lock_guard<std::mutex> lock(latency.mutex);
    samples = latency.samples;
  }
  std::sort(samples.begin(), samples.end());
  double median = samples.empty() ? -1 : samples[samples.size() / 2];
  double p95 = samples.empty() ? -1 : samples[static_cast<size_t>(samples.size() * 0.95)];
  Log("frames in %d, packets %d (config %d, key %d), ~%.1f Mb/s, encode latency median %.1f ms p95 %.1f ms, "
      "every IDR had a config first: %d",
      frames_in.load(), packets.load(), config_packets.load(), key_packets.load(), mbps, median, p95,
      idr_had_config.load());

  std::wstring h264 = g_out + L"\\w4.h264";
  {
    std::lock_guard<std::mutex> lock(stream_mutex);
    FILE* file = _wfopen(h264.c_str(), L"wb");
    if (file) {
      fwrite(stream.data(), 1, stream.size(), file);
      fclose(file);
    }
    Log("wrote %zu bytes of Annex-B to w4.h264", stream.size());
  }
  WriteText(L"w4.json",
            wsn::Format("{\"encoder\":%s,\"hardware\":%d,\"d3dInput\":%d,\"rate\":%s,\"framesIn\":%d,\"packets\":%d,"
                        "\"configPackets\":%d,\"keyPackets\":%d,\"mbps\":%.1f,\"latencyMedianMs\":%.1f,"
                        "\"latencyP95Ms\":%.1f,\"everyIdrHadConfig\":%d,\"size\":\"%ldx%ld\",\"error\":%d}\n",
                        wsn::JsonString(encoder.info().name).c_str(), encoder.info().hardware,
                        encoder.info().d3d_input, wsn::JsonString(encoder.info().rate_control).c_str(),
                        frames_in.load(), packets.load(), config_packets.load(), key_packets.load(), mbps, median,
                        p95, idr_had_config.load(), encoded_size.cx, encoded_size.cy, encoder_error.load()));
  wsn::RestoreStageStyle(window, style);
  wsn::RestorePlacement(window, home);
  CloseTestWindow(&tw);
  return 0;
}

}  // namespace probe
