#include "audio_share_plugin.h"

#include <flutter_linux/flutter_linux.h>

#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#if HAVE_PULSE_AUDIO
#include <pulse/context.h>
#include <pulse/error.h>
#include <pulse/introspect.h>
#include <pulse/mainloop.h>
#include <pulse/simple.h>
#include <pulse/thread-mainloop.h>
#endif

namespace {

constexpr char kAudioShareChannel[] = "com.vireen.whisper/audio_share";

#if HAVE_PULSE_AUDIO
constexpr int kDefaultAudioFrameDurationMs = 20;
constexpr int kPulseTargetLatencyMs = 30;
constexpr uint32_t kPulseBufferAttrUnset = static_cast<uint32_t>(-1);
#endif

FlValue* Lookup(FlValue* map, const char* key) {
  if (map == nullptr || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(map, key);
}

std::string StringValue(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return "";
  }
  const gchar* text = fl_value_get_string(value);
  return text == nullptr ? "" : text;
}

#if HAVE_PULSE_AUDIO
int IntValue(FlValue* map, const char* key, int fallback) {
  FlValue* value = Lookup(map, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return fallback;
  }
  return static_cast<int>(fl_value_get_int(value));
}
#endif

std::vector<uint8_t> BytesValue(FlValue* map, const char* key) {
  FlValue* value = Lookup(map, key);
  if (value == nullptr ||
      fl_value_get_type(value) != FL_VALUE_TYPE_UINT8_LIST) {
    return {};
  }
  const uint8_t* bytes = fl_value_get_uint8_list(value);
  const size_t length = fl_value_get_length(value);
  if (bytes == nullptr || length == 0) {
    return {};
  }
  return std::vector<uint8_t>(bytes, bytes + length);
}

void RespondSuccess(FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  fl_method_call_respond(method_call, response, nullptr);
}

void RespondError(FlMethodCall* method_call,
                  const char* code,
                  const std::string& message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code, message.c_str(), nullptr));
  fl_method_call_respond(method_call, response, nullptr);
}

#if HAVE_PULSE_AUDIO
struct MainThreadEvent {
  FlMethodChannel* channel = nullptr;
  std::string method;
  std::string session_id;
  std::string message;
  int64_t sequence = 0;
  int64_t capture_time_micros = 0;
  int sample_rate = 48000;
  int channels = 2;
  std::vector<uint8_t> pcm;
};

gboolean InvokeMainThreadEvent(gpointer user_data) {
  auto* event = static_cast<MainThreadEvent*>(user_data);
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(
      args, "sessionId", fl_value_new_string(event->session_id.c_str()));
  if (event->method == "onCapturePcm") {
    fl_value_set_string_take(args, "sequence",
                             fl_value_new_int(event->sequence));
    fl_value_set_string_take(
        args, "captureTimeMicros",
        fl_value_new_int(event->capture_time_micros));
    fl_value_set_string_take(args, "sampleRate",
                             fl_value_new_int(event->sample_rate));
    fl_value_set_string_take(args, "channels",
                             fl_value_new_int(event->channels));
    fl_value_set_string_take(
        args, "pcm",
        fl_value_new_uint8_list(event->pcm.data(), event->pcm.size()));
  } else {
    fl_value_set_string_take(args, "message",
                             fl_value_new_string(event->message.c_str()));
  }
  fl_method_channel_invoke_method(event->channel, event->method.c_str(), args,
                                  nullptr, nullptr, nullptr);
  g_object_unref(event->channel);
  delete event;
  return G_SOURCE_REMOVE;
}

int64_t NowMicros() {
  return static_cast<int64_t>(g_get_real_time());
}

int FrameDurationMs(FlValue* format) {
  return std::max(
      1, std::min(100,
                  IntValue(format, "frameDurationMs",
                           kDefaultAudioFrameDurationMs)));
}

uint32_t BytesForDurationMs(int sample_rate,
                            int channels,
                            int duration_ms) {
  const int safe_rate = std::max(1, sample_rate);
  const int safe_channels = std::max(1, std::min(2, channels));
  const int safe_duration = std::max(1, duration_ms);
  const int64_t bytes =
      static_cast<int64_t>(safe_rate) * safe_channels * sizeof(int16_t) *
      safe_duration / 1000;
  return static_cast<uint32_t>(
      std::max<int64_t>(sizeof(int16_t) * safe_channels, bytes));
}

pa_buffer_attr LowLatencyPlaybackBufferAttr(int sample_rate,
                                            int channels,
                                            int frame_duration_ms) {
  const uint32_t frame_bytes =
      BytesForDurationMs(sample_rate, channels, frame_duration_ms);
  const uint32_t latency_bytes =
      BytesForDurationMs(sample_rate, channels, kPulseTargetLatencyMs);
  pa_buffer_attr attr;
  attr.maxlength = kPulseBufferAttrUnset;
  attr.tlength = std::max(frame_bytes, latency_bytes);
  attr.prebuf = frame_bytes;
  attr.minreq = frame_bytes;
  attr.fragsize = kPulseBufferAttrUnset;
  return attr;
}

pa_buffer_attr LowLatencyCaptureBufferAttr(int sample_rate,
                                           int channels,
                                           int frame_duration_ms) {
  const uint32_t frame_bytes =
      BytesForDurationMs(sample_rate, channels, frame_duration_ms);
  const uint32_t latency_bytes =
      BytesForDurationMs(sample_rate, channels, kPulseTargetLatencyMs);
  pa_buffer_attr attr;
  attr.maxlength = kPulseBufferAttrUnset;
  attr.tlength = kPulseBufferAttrUnset;
  attr.prebuf = kPulseBufferAttrUnset;
  attr.minreq = kPulseBufferAttrUnset;
  attr.fragsize = std::max(frame_bytes, latency_bytes);
  return attr;
}
#endif

class AudioSharePlugin {
 public:
  explicit AudioSharePlugin(FlMethodChannel* channel)
      : channel_(FL_METHOD_CHANNEL(g_object_ref(channel))) {}

  ~AudioSharePlugin() {
    StopCapture("");
    StopPlayback("");
    g_object_unref(channel_);
  }

  void HandleMethodCall(FlMethodCall* method_call) {
    const gchar* method = fl_method_call_get_name(method_call);
    FlValue* args = fl_method_call_get_args(method_call);

    if (std::strcmp(method, "startPlayback") == 0) {
      std::string error;
      if (!StartPlayback(args, &error)) {
        RespondError(method_call, "audio-playback", error);
        return;
      }
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "writePcm") == 0) {
      std::string error;
      if (!WritePcm(args, &error)) {
        RespondError(method_call, "audio-playback", error);
        return;
      }
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "stopPlayback") == 0) {
      StopPlayback(StringValue(args, "sessionId"));
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "startCapture") == 0) {
      std::string error;
      if (!StartCapture(args, &error)) {
        RespondError(method_call, "audio-capture", error);
        return;
      }
      RespondSuccess(method_call);
      return;
    }

    if (std::strcmp(method, "stopCapture") == 0) {
      StopCapture(StringValue(args, "sessionId"));
      RespondSuccess(method_call);
      return;
    }

    fl_method_call_respond_not_implemented(method_call, nullptr);
  }

 private:
  bool StartPlayback(FlValue* args, std::string* error) {
    const std::string session_id = StringValue(args, "sessionId");
    FlValue* format = Lookup(args, "format");
    if (session_id.empty() || format == nullptr) {
      *error = "startPlayback requires sessionId and format";
      return false;
    }

#if HAVE_PULSE_AUDIO
    StopPlayback("");
    const int sample_rate = IntValue(format, "sampleRate", 48000);
    const int channels =
        std::max(1, std::min(2, IntValue(format, "channels", 2)));
    const int frame_duration_ms = FrameDurationMs(format);
    pa_sample_spec spec;
    spec.format = PA_SAMPLE_S16LE;
    spec.rate = static_cast<uint32_t>(sample_rate);
    spec.channels = static_cast<uint8_t>(channels);
    const pa_buffer_attr buffer_attr = LowLatencyPlaybackBufferAttr(
        sample_rate, channels, frame_duration_ms);

    int pulse_error = 0;
    pa_simple* stream = pa_simple_new(nullptr, "whisper",
                                      PA_STREAM_PLAYBACK, nullptr,
                                      "Audio Share Playback", &spec, nullptr,
                                      &buffer_attr, &pulse_error);
    if (stream == nullptr) {
      *error = pa_strerror(pulse_error);
      return false;
    }
    g_print("Audio Share Playback buffer target=%u minreq=%u frameMs=%d\n",
            buffer_attr.tlength, buffer_attr.minreq, frame_duration_ms);

    std::lock_guard<std::mutex> lock(playback_mutex_);
    playback_stream_ = stream;
    playback_session_id_ = session_id;
    return true;
#else
    *error = "PulseAudio support is not available in this Linux build";
    return false;
#endif
  }

  bool WritePcm(FlValue* args, std::string* error) {
    const std::string session_id = StringValue(args, "sessionId");
    const std::vector<uint8_t> pcm = BytesValue(args, "pcm");
    if (session_id.empty()) {
      *error = "writePcm requires sessionId";
      return false;
    }
    if (pcm.empty()) {
      return true;
    }

#if HAVE_PULSE_AUDIO
    std::lock_guard<std::mutex> lock(playback_mutex_);
    if (playback_stream_ == nullptr || session_id != playback_session_id_) {
      return true;
    }
    int pulse_error = 0;
    if (pa_simple_write(playback_stream_, pcm.data(), pcm.size(),
                        &pulse_error) < 0) {
      *error = pa_strerror(pulse_error);
      return false;
    }
    return true;
#else
    *error = "PulseAudio support is not available in this Linux build";
    return false;
#endif
  }

  void StopPlayback(const std::string& session_id) {
#if HAVE_PULSE_AUDIO
    std::lock_guard<std::mutex> lock(playback_mutex_);
    if (!session_id.empty() && session_id != playback_session_id_) {
      return;
    }
    if (playback_stream_ != nullptr) {
      pa_simple_free(playback_stream_);
      playback_stream_ = nullptr;
    }
    playback_session_id_.clear();
#else
    (void)session_id;
#endif
  }

  bool StartCapture(FlValue* args, std::string* error) {
    const std::string session_id = StringValue(args, "sessionId");
    FlValue* format = Lookup(args, "format");
    if (session_id.empty() || format == nullptr) {
      *error = "startCapture requires sessionId and format";
      return false;
    }

#if HAVE_PULSE_AUDIO
    StopCapture("");
    capture_running_.store(true);
    const int sample_rate = IntValue(format, "sampleRate", 48000);
    const int channels =
        std::max(1, std::min(2, IntValue(format, "channels", 2)));
    const int frame_duration_ms = FrameDurationMs(format);
    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      capture_session_id_ = session_id;
    }
    capture_thread_ =
        std::thread([this, session_id, sample_rate, channels,
                     frame_duration_ms] {
          CaptureLoop(session_id, sample_rate, channels, frame_duration_ms);
        });
    return true;
#else
    *error = "PulseAudio support is not available in this Linux build";
    return false;
#endif
  }

  void StopCapture(const std::string& session_id) {
#if HAVE_PULSE_AUDIO
    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      if (!session_id.empty() && session_id != capture_session_id_) {
        return;
      }
      capture_running_.store(false);
      if (capture_stream_ != nullptr) {
        pa_simple_flush(capture_stream_, nullptr);
      }
    }
    if (capture_thread_.joinable()) {
      capture_thread_.join();
    }
    std::lock_guard<std::mutex> lock(capture_mutex_);
    capture_session_id_.clear();
#else
    (void)session_id;
#endif
  }

#if HAVE_PULSE_AUDIO
  void CaptureLoop(const std::string& session_id,
                   int sample_rate,
                   int channels,
                   int frame_duration_ms) {
    pa_sample_spec spec;
    spec.format = PA_SAMPLE_S16LE;
    spec.rate = static_cast<uint32_t>(sample_rate);
    spec.channels = static_cast<uint8_t>(channels);
    const pa_buffer_attr buffer_attr =
        LowLatencyCaptureBufferAttr(sample_rate, channels, frame_duration_ms);

    int pulse_error = 0;
    const std::string monitor = DefaultMonitorSource();
    if (monitor.empty()) {
      SendCaptureError(session_id,
                       "Default PulseAudio monitor source is unavailable");
      capture_running_.store(false);
      return;
    }
    pa_simple* stream = pa_simple_new(
        nullptr, "whisper", PA_STREAM_RECORD,
        monitor.c_str(), "Audio Share Capture",
        &spec, nullptr, &buffer_attr, &pulse_error);
    if (stream == nullptr) {
      SendCaptureError(session_id, pa_strerror(pulse_error));
      capture_running_.store(false);
      return;
    }
    g_print("Audio Share Capture buffer fragment=%u frameMs=%d\n",
            buffer_attr.fragsize, frame_duration_ms);

    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      capture_stream_ = stream;
    }

    const size_t frame_bytes =
        BytesForDurationMs(sample_rate, channels, frame_duration_ms);
    std::vector<uint8_t> buffer(frame_bytes);
    int64_t sequence = 0;
    while (capture_running_.load()) {
      pulse_error = 0;
      if (pa_simple_read(stream, buffer.data(), buffer.size(), &pulse_error) <
          0) {
        SendCaptureError(session_id, pa_strerror(pulse_error));
        break;
      }
      SendCapturePcm(session_id, sequence++, sample_rate, channels, buffer);
    }

    {
      std::lock_guard<std::mutex> lock(capture_mutex_);
      if (capture_stream_ == stream) {
        capture_stream_ = nullptr;
      }
    }
    pa_simple_free(stream);
    capture_running_.store(false);
  }

  static void ContextStateCallback(pa_context* context, void* userdata) {
    auto* mainloop = static_cast<pa_threaded_mainloop*>(userdata);
    if (pa_context_get_state(context) == PA_CONTEXT_READY ||
        pa_context_get_state(context) == PA_CONTEXT_FAILED ||
        pa_context_get_state(context) == PA_CONTEXT_TERMINATED) {
      pa_threaded_mainloop_signal(mainloop, 0);
    }
  }

  struct MonitorLookup {
    pa_threaded_mainloop* mainloop = nullptr;
    pa_context* context = nullptr;
    std::string default_sink;
    std::string monitor_source;
    bool done = false;
  };

  static void SinkInfoCallback(pa_context*,
                               const pa_sink_info* info,
                               int eol,
                               void* userdata) {
    auto* lookup = static_cast<MonitorLookup*>(userdata);
    if (eol != 0) {
      lookup->done = true;
      pa_threaded_mainloop_signal(lookup->mainloop, 0);
      return;
    }
    if (info != nullptr && info->monitor_source_name != nullptr) {
      lookup->monitor_source = info->monitor_source_name;
    }
  }

  static void ServerInfoCallback(pa_context* context,
                                 const pa_server_info* info,
                                 void* userdata) {
    auto* lookup = static_cast<MonitorLookup*>(userdata);
    if (info == nullptr || info->default_sink_name == nullptr) {
      lookup->done = true;
      pa_threaded_mainloop_signal(lookup->mainloop, 0);
      return;
    }
    lookup->default_sink = info->default_sink_name;
    pa_operation* operation = pa_context_get_sink_info_by_name(
        context, lookup->default_sink.c_str(), SinkInfoCallback, lookup);
    if (operation != nullptr) {
      pa_operation_unref(operation);
    } else {
      lookup->done = true;
      pa_threaded_mainloop_signal(lookup->mainloop, 0);
    }
  }

  std::string DefaultMonitorSource() {
    pa_threaded_mainloop* mainloop = pa_threaded_mainloop_new();
    if (mainloop == nullptr) {
      return "";
    }
    pa_mainloop_api* api = pa_threaded_mainloop_get_api(mainloop);
    pa_context* context = pa_context_new(api, "whisper");
    if (context == nullptr) {
      pa_threaded_mainloop_free(mainloop);
      return "";
    }

    MonitorLookup lookup;
    lookup.mainloop = mainloop;
    lookup.context = context;
    pa_context_set_state_callback(context, ContextStateCallback, mainloop);
    if (pa_context_connect(context, nullptr, PA_CONTEXT_NOFLAGS, nullptr) < 0 ||
        pa_threaded_mainloop_start(mainloop) < 0) {
      pa_context_unref(context);
      pa_threaded_mainloop_free(mainloop);
      return "";
    }

    pa_threaded_mainloop_lock(mainloop);
    while (true) {
      pa_context_state_t state = pa_context_get_state(context);
      if (state == PA_CONTEXT_READY) {
        break;
      }
      if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
        pa_threaded_mainloop_unlock(mainloop);
        pa_threaded_mainloop_stop(mainloop);
        pa_context_unref(context);
        pa_threaded_mainloop_free(mainloop);
        return "";
      }
      pa_threaded_mainloop_wait(mainloop);
    }

    pa_operation* operation =
        pa_context_get_server_info(context, ServerInfoCallback, &lookup);
    if (operation != nullptr) {
      pa_operation_unref(operation);
    }
    while (!lookup.done) {
      pa_threaded_mainloop_wait(mainloop);
    }
    pa_threaded_mainloop_unlock(mainloop);

    pa_threaded_mainloop_stop(mainloop);
    pa_context_disconnect(context);
    pa_context_unref(context);
    pa_threaded_mainloop_free(mainloop);
    return lookup.monitor_source;
  }

  void SendCapturePcm(const std::string& session_id,
                      int64_t sequence,
                      int sample_rate,
                      int channels,
                      const std::vector<uint8_t>& pcm) {
    auto* event = new MainThreadEvent();
    event->channel = FL_METHOD_CHANNEL(g_object_ref(channel_));
    event->method = "onCapturePcm";
    event->session_id = session_id;
    event->sequence = sequence;
    event->capture_time_micros = NowMicros();
    event->sample_rate = sample_rate;
    event->channels = channels;
    event->pcm = pcm;
    g_main_context_invoke(nullptr, InvokeMainThreadEvent, event);
  }

  void SendCaptureError(const std::string& session_id,
                        const std::string& message) {
    auto* event = new MainThreadEvent();
    event->channel = FL_METHOD_CHANNEL(g_object_ref(channel_));
    event->method = "onCaptureError";
    event->session_id = session_id;
    event->message = message;
    g_main_context_invoke(nullptr, InvokeMainThreadEvent, event);
  }
#endif

  FlMethodChannel* channel_ = nullptr;
#if HAVE_PULSE_AUDIO
  std::mutex playback_mutex_;
  pa_simple* playback_stream_ = nullptr;
  std::string playback_session_id_;

  std::mutex capture_mutex_;
  pa_simple* capture_stream_ = nullptr;
  std::string capture_session_id_;
  std::atomic<bool> capture_running_{false};
  std::thread capture_thread_;
#endif
};

AudioSharePlugin* g_plugin = nullptr;

void MethodCallCallback(FlMethodChannel*,
                        FlMethodCall* method_call,
                        gpointer user_data) {
  auto* plugin = static_cast<AudioSharePlugin*>(user_data);
  plugin->HandleMethodCall(method_call);
}

}  // namespace

void audio_share_plugin_register(FlPluginRegistry* registry) {
  FlPluginRegistrar* registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AudioSharePlugin");
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  FlMethodChannel* channel = fl_method_channel_new(
      fl_plugin_registrar_get_messenger(registrar), kAudioShareChannel,
      FL_METHOD_CODEC(codec));
  g_plugin = new AudioSharePlugin(channel);
  fl_method_channel_set_method_call_handler(channel, MethodCallCallback,
                                            g_plugin, nullptr);
  g_object_unref(channel);
}
