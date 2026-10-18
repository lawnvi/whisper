// PulseAudio's simple API (libpulse-simple), opened at run time. PipeWire
// desktops serve it through pipewire-pulse.

#ifndef WSN_COMMON_PULSE_H_
#define WSN_COMMON_PULSE_H_

#include <cstddef>
#include <cstdint>

namespace wsn {

struct PaSampleSpec {
  int format;  // PA_SAMPLE_S16LE = 3
  uint32_t rate;
  uint8_t channels;
};

struct PaBufferAttr {
  uint32_t maxlength;
  uint32_t tlength;
  uint32_t prebuf;
  uint32_t minreq;
  uint32_t fragsize;
};

constexpr int kPaSampleS16le = 3;
constexpr int kPaStreamPlayback = 1;

struct Pulse {
  void* (*create)(const char*, const char*, int, const char*, const char*, const PaSampleSpec*, const void*,
                  const PaBufferAttr*, int*) = nullptr;
  int (*write)(void*, const void*, size_t, int*) = nullptr;
  int (*flush)(void*, int*) = nullptr;
  uint64_t (*latency)(void*, int*) = nullptr;
  int (*drain)(void*, int*) = nullptr;
  void (*destroy)(void*) = nullptr;
  const char* (*strerror)(int) = nullptr;
  bool ok = false;
};

const Pulse& PulseApi();

}  // namespace wsn

#endif  // WSN_COMMON_PULSE_H_
