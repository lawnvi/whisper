// The sound of a streamed window's app, from PipeWire (window-stream audio,
// WSN_CAPTURE_AUDIO).
//
// The app is a process and its children (a browser's audio service, a player
// spawned by the app). Its output streams are found in the PipeWire graph by
// the owning process. Whisper adds a private null sink per app and captures
// that sink's monitor as 48 kHz stereo s16le:
//   mode 1 (on): the app's streams keep playing where they did; extra links
//     feed the private sink too.
//   mode 2 (on, silent here): the app's streams are moved to the private sink
//     (WirePlumber's "target.object" in the default metadata), so only the
//     viewer hears them. Their previous target is put back exactly on stop.
// New streams the app opens later follow the same rule. A run that dies with
// streams moved leaves a journal; the next run restores those routes. No
// root, no new build dependencies: libpipewire is opened at run time and the
// headers' inline helpers do the rest.

#ifndef WSN_CAPTURE_AUDIO_TAP_H_
#define WSN_CAPTURE_AUDIO_TAP_H_

#include <cstdint>

namespace wsn::capture {

// Any thread. `mode`: WSN_CAPTURE_AUDIO_OFF / _ON / _ON_SILENT_HERE. Chunks of
// PCM go to `capture` through the capture callback until it is turned off.
// Several captures of one app share one tap (silent if any asks for it).
void SetAudio(int64_t capture, int pid, int mode);

// Puts back routes a previous run left moved (once per process; cheap).
void RecoverAudioRoutes();

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_AUDIO_TAP_H_
