#!/usr/bin/env python3
"""Checks window-stream audio on Linux through the plugin's C ABI.

A test window plays a tone from a child process (pw-play) into a private
"speaker" null sink, so nothing is audible. The check starts a capture of
that window, turns audio on, records the WSN_CAPTURE_AUDIO PCM it delivers
and the speaker's own output, and compares:
  mode 1: delivered PCM has the tone, the speaker still plays it;
  mode 2: delivered PCM has the tone, the speaker is silent (routed away);
  stop:   the app's stream is routed back to the speaker exactly.
`--crash` instead turns mode 2 on and kills this process, for the
crash-recovery check (run again without --crash afterwards: the next load
puts the routes back).

usage: wsn_audio_check.py <plugin.so> <wsn_test_window> <out_dir> [--crash]
Runs in the desktop session; this interpreter must be in the GNOME Shell
helper's allowed-exe list.
"""

import json
import math
import os
import signal
import struct
import subprocess
import sys
import threading
import time
import wave

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wsn_capture_check as H  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402

AUDIO = 11
SPEAKER = "wsn-test-speaker"
TONE_HZ = 523


def pw_dump():
    out = subprocess.run(["pw-dump"], capture_output=True, text=True).stdout
    return json.loads(out or "[]")


def routing(app_pid_tree):
    """Where the test tone's stream goes: (node id, linked input nodes' names, metadata target)."""
    objs = pw_dump()
    byid = {o["id"]: o for o in objs}
    clients = {o["id"]: o["info"]["props"] for o in objs if o.get("type", "").endswith("Client")}
    streams = []
    for o in objs:
        p = o.get("info", {}).get("props", {})
        if p.get("media.class") != "Stream/Output/Audio":
            continue
        pid = p.get("application.process.id") or clients.get(p.get("client.id"), {}).get("application.process.id")
        if pid is None or int(pid) not in app_pid_tree:
            continue
        targets = sorted({byid.get(l["info"]["input-node-id"], {}).get("info", {}).get("props", {}).get("node.name", "?")
                          for l in objs if l.get("type", "").endswith("Link")
                          and l.get("info", {}).get("output-node-id") == o["id"]})
        streams.append({"node": o["id"], "linked_to": targets})
    meta = {}
    for o in objs:
        if o.get("type", "").endswith("Metadata") and o.get("props", {}).get("metadata.name") == "default":
            for entry in o.get("metadata", []):
                if entry.get("key") == "target.object":
                    meta[entry["subject"]] = entry.get("value")
    for s in streams:
        s["metadata_target"] = meta.get(s["node"])
    sinks = [o["info"]["props"].get("node.name") for o in objs
             if o.get("info", {}).get("props", {}).get("node.name", "").startswith("whisper-window-audio")]
    return {"streams": streams, "whisper_sinks": sinks}


def tree(root):
    out = {root}
    changed = True
    while changed:
        changed = False
        for name in os.listdir("/proc"):
            if not name.isdigit():
                continue
            try:
                stat = open(f"/proc/{name}/stat").read()
                ppid = int(stat.rsplit(")", 1)[1].split()[1])
            except (OSError, ValueError, IndexError):
                continue
            if ppid in out and int(name) not in out:
                out.add(int(name))
                changed = True
    return out


def analyse(pcm, rate=48000, channels=2):
    samples = struct.unpack("<%dh" % (len(pcm) // 2), pcm) if pcm else ()
    left = samples[::channels]
    if not left:
        return {"seconds": 0, "rms": 0, "hz": 0}
    rms = math.sqrt(sum(x * x for x in left) / len(left))
    crossings = sum(1 for i in range(1, len(left)) if (left[i - 1] < 0) != (left[i] < 0))
    return {"seconds": round(len(left) / rate, 2), "rms": round(rms), "hz": round(crossings / 2 / (len(left) / rate))}


def write_wav(path, pcm, rate=48000, channels=2):
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)


def record_speaker(seconds, path):
    subprocess.run(["timeout", str(seconds), "pw-record", "--target", SPEAKER, "-P", "{ stream.capture.sink=true }",
                    "--rate", "48000", "--channels", "2", "--format", "s16", path], capture_output=True)
    try:
        with wave.open(path) as w:
            return analyse(w.readframes(w.getnframes()))
    except (OSError, wave.Error):
        return {"seconds": 0, "rms": 0, "hz": 0}


class AudioPlugin(H.Plugin):
    def __init__(self, path):
        self.audio = []
        self.audio_lock = threading.Lock()
        super().__init__(path)

    def _on_event(self, id_, kind, data, length, pts, flags, width, height):
        if kind == AUDIO:
            import ctypes
            payload = ctypes.string_at(data, length) if data and length > 0 else b""
            if data:
                self.lib.wsn_free(data)
            with self.audio_lock:
                self.audio.append((time.monotonic(), id_, pts, width, height, payload))
            return
        super()._on_event(id_, kind, data, length, pts, flags, width, height)

    def take_audio(self, capture):
        with self.audio_lock:
            mine = [a for a in self.audio if a[1] == capture]
            self.audio = [a for a in self.audio if a[1] != capture]
        return mine


def main():
    plugin_path, tester, out = sys.argv[1:4]
    crash = "--crash" in sys.argv
    os.makedirs(out, exist_ok=True)
    H.LOG = open(os.path.join(out, "crash.log" if crash else "audio.log"), "w")
    Gtk.init([])
    lib = sys.argv[1]
    p = AudioPlugin(lib)
    p.lib.wsn_capture_set_audio.restype = None
    import ctypes
    p.lib.wsn_capture_set_audio.argtypes = [ctypes.c_int64, ctypes.c_int32]
    loop = GLib.MainLoop()
    result = {}

    def work():
        try:
            title = "WSN Audio %d" % os.getpid()
            env = dict(os.environ, WSN_TEST_SOUND=os.path.join(out, "tone.wav"), WSN_TEST_SOUND_TARGET=SPEAKER)
            if "--pulse" in sys.argv:
                env["WSN_TEST_SOUND_PULSE"] = "1"
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                            f"sine=frequency={TONE_HZ}:duration=600", "-ac", "2", "-ar", "48000",
                            os.path.join(out, "tone.wav")], check=True)
            proc = subprocess.Popen([tester, os.path.join(out, "window.log"), title, "plain"], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            win = None
            for _ in range(50):
                time.sleep(0.1)
                win = next((w for w in H.helper_windows() if w["title"] == title and w["width"] > 100), None)
                if win:
                    break
            time.sleep(1.5)  # the tone starts
            app = tree(proc.pid)
            result["before"] = routing(app)
            H.log("before: " + json.dumps(result["before"]))
            cid = p.lib.wsn_capture_start(win["id"], win["pid"], 2560, 60, 12000000)
            p.capture_id = cid
            p.lib.wsn_capture_set_screen(cid, 0x41)
            p.lib.wsn_capture_set_viewport(cid, 412.0, 915.0, 1.0)
            p.wait(cid, {H.SIZE}, 8)
            if crash:
                p.lib.wsn_capture_set_audio(cid, 2)
                time.sleep(2.0)
                result["moved"] = routing(app)
                H.log("moved: " + json.dumps(result["moved"]))
                json.dump({"pid": proc.pid, "moved": result["moved"]}, open(os.path.join(out, "crash.json"), "w"))
                os.kill(os.getpid(), signal.SIGKILL)

            long = int(sys.argv[sys.argv.index("--long") + 1]) if "--long" in sys.argv else 0
            if long:
                # Mode 2 for a while: is the sound continuous, the pts contiguous?
                p.lib.wsn_capture_set_audio(cid, 2)
                time.sleep(1.0)
                p.take_audio(cid)
                t0 = time.monotonic()
                cpu0 = os.times()
                time.sleep(long)
                cpu1 = os.times()
                chunks = p.take_audio(cid)
                elapsed = time.monotonic() - t0
                pcm = b"".join(c[5] for c in chunks)
                frames = len(pcm) // 4
                resyncs = sum(1 for i in range(1, len(chunks))
                              if abs(chunks[i][2] - (chunks[i - 1][2] + (len(chunks[i - 1][5]) // 4) * 1e6 / 48000)) > 100)
                left = struct.unpack("<%dh" % (len(pcm) // 2), pcm)[::2]
                # A dropout inside the tone shows up as a run of near-zero samples.
                longest_quiet = run = 0
                for v in left:
                    run = run + 1 if abs(v) < 50 else 0
                    longest_quiet = max(longest_quiet, run)
                write_wav(os.path.join(out, "delivered_long.wav"), pcm)
                result["long"] = {"seconds": long, "delivered_seconds": round(frames / 48000, 2),
                                  "elapsed": round(elapsed, 2), "chunks": len(chunks), "pts_resyncs": resyncs,
                                  "longest_quiet_ms": round(longest_quiet / 48, 1), "tone": analyse(pcm),
                                  "process_cpu_percent": round(((cpu1.user + cpu1.system) - (cpu0.user + cpu0.system))
                                                               / elapsed * 100, 1)}
                H.log("long: " + json.dumps(result["long"]))
            for mode in (1, 2):
                p.lib.wsn_capture_set_audio(cid, mode)
                time.sleep(1.0)
                p.take_audio(cid)
                t0 = time.monotonic()
                speaker = record_speaker(3, os.path.join(out, f"speaker_mode{mode}.wav"))
                chunks = p.take_audio(cid)
                pcm = b"".join(c[5] for c in chunks)
                write_wav(os.path.join(out, f"delivered_mode{mode}.wav"), pcm)
                frames = sorted({len(c[5]) // 4 for c in chunks})
                pts = [c[2] for c in chunks]
                gaps = [round((pts[i] - pts[i - 1]) / 1000, 1) for i in range(1, len(pts))]
                # Contiguous: each chunk starts where the previous one ended (±0.1 ms).
                overlaps = sum(1 for i in range(1, len(chunks))
                               if chunks[i][2] < chunks[i - 1][2] + (len(chunks[i - 1][5]) // 4) * 1e6 / 48000 - 100)
                lag = [round((c[0] * 1e6 - c[2]) / 1000, 1) for c in chunks]  # arrival - pts (ms), same clock
                result[f"mode{mode}"] = {
                    "delivered": analyse(pcm), "speaker": speaker, "chunks": len(chunks),
                    "chunk_frames": frames[:6], "format": sorted({(c[3], c[4]) for c in chunks}),
                    "pts_step_ms": sorted(set(gaps))[:8], "pts_monotonic": all(g > 0 for g in gaps),
                    "overlapping_chunks": overlaps,
                    "arrival_minus_pts_ms": [min(lag), max(lag)] if lag else None,
                    "routing": routing(app), "notes": p.notes_for(cid)}
                H.log(f"mode {mode}: " + json.dumps(result[f"mode{mode}"]))
            # Mode 2 back to 1: the stream returns to the speaker, still captured.
            p.lib.wsn_capture_set_audio(cid, 1)
            time.sleep(1.0)
            result["back_to_mode1"] = routing(app)
            p.lib.wsn_capture_set_audio(cid, 2)
            time.sleep(1.0)
            p.lib.wsn_capture_stop(cid)
            time.sleep(1.5)
            result["after_stop"] = routing(app)
            result["after_stop_speaker"] = record_speaker(2, os.path.join(out, "speaker_after_stop.wav"))
            H.log("after stop: " + json.dumps(result["after_stop"]))
            proc.terminate()
            subprocess.run(["pkill", "-f", os.path.join(out, "tone.wav")])
        except Exception:  # noqa: BLE001
            import traceback
            result["error"] = traceback.format_exc()
        finally:
            GLib.idle_add(loop.quit)

    threading.Thread(target=work, daemon=True).start()
    loop.run()
    json.dump(result, open(os.path.join(out, "audio_result.json"), "w"), indent=1)
    H.log(json.dumps(result, indent=1))
    os._exit(0)


if __name__ == "__main__":
    main()
