#!/usr/bin/env python3
"""Checks the Linux window-stream source through the plugin's C ABI.

Loads libwindow_stream_native.so with ctypes, opens a test window
(wsn_test_window, which draws a frame counter and logs every input event),
and runs the per-cell checklist: catalog (thumbnail, icon), start and frame
rate, decodable stream with a readable counter, click accuracy, text, scroll
sign, right click, Cmd+A, the window not on the real screen, viewport and
keyboard-inset resizes, pause/park/resume, stop restoring the window, the app
killed and relaunched, remote close.

Runs inside the desktop session (as its user, with its environment). This
interpreter must be in the GNOME Shell helper's allowed-exe list (the checks
also read the window list through the helper).

usage: wsn_capture_check.py <plugin.so> <wsn_test_window> <out_dir> [--quick] [--park]
"""

import ctypes
import json
import os
import queue
import struct
import subprocess
import sys
import threading
import time
import zlib

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gst", "1.0")
from gi.repository import Gio, GLib, Gst, Gtk  # noqa: E402

PACKET, FAILED, SIZE, CATALOG, THUMBNAIL, ICON, STOPPED, LAUNCHED, NOTE, TEXT_FOCUS = range(1, 11)
KIND_NAMES = {1: "packet", 2: "failed", 3: "size", 4: "catalog", 5: "thumbnail", 6: "icon", 7: "stopped",
              8: "launched", 9: "note", 10: "text_focus"}
CONFIG, KEY = 1, 2
DOWN, MOVE, UP, SCROLL, KEY_DOWN, KEY_UP, TEXT = 1, 2, 3, 4, 5, 6, 7
MOD_COMMAND = 0x8

CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_int64, ctypes.c_int32, ctypes.c_void_p, ctypes.c_int32, ctypes.c_int64,
                            ctypes.c_int32, ctypes.c_int32, ctypes.c_int32)


class Plugin:
    def __init__(self, path):
        lib = ctypes.CDLL(path)
        self.lib = lib
        i64, i32, u32, dbl = ctypes.c_int64, ctypes.c_int32, ctypes.c_uint32, ctypes.c_double
        sig = {
            "wsn_api_version": (i32, []), "wsn_free": (None, [ctypes.c_void_p]),
            "wsn_set_capture_callback": (None, [CALLBACK]),
            "wsn_capture_supported": (i32, []), "wsn_capture_input_permission": (i32, []),
            "wsn_capture_request_catalog": (i64, []), "wsn_capture_request_icon": (i64, [ctypes.c_char_p, i32]),
            "wsn_capture_request_thumbnail": (i64, [u32, i32]), "wsn_capture_launch_app": (i64, [ctypes.c_char_p]),
            "wsn_capture_start": (i64, [u32, i32, i32, i32, i32]), "wsn_capture_stop": (None, [i64]),
            "wsn_capture_close_window": (None, [u32, i32]), "wsn_capture_set_screen": (None, [i64, i64]),
            "wsn_capture_set_viewport": (None, [i64, dbl, dbl, dbl]), "wsn_capture_set_inset": (None, [i64, dbl]),
            "wsn_capture_request_keyframe": (None, [i64]), "wsn_capture_set_busy": (None, [i64, i32]),
            "wsn_capture_set_paused": (None, [i64, i32]), "wsn_capture_set_bit_rate": (None, [i64, i32]),
            "wsn_capture_input": (None, [i64, i32, i32, i32, dbl, dbl, dbl, dbl, i32, ctypes.c_char_p]),
        }
        for name, (res, args) in sig.items():
            fn = getattr(lib, name)
            fn.restype = res
            fn.argtypes = args
        self.events = queue.Queue()
        self.packets = []
        self.packet_lock = threading.Lock()
        self.capture_id = None
        self.notes = []
        self.callback = CALLBACK(self._on_event)
        lib.wsn_set_capture_callback(self.callback)

    def _on_event(self, id_, kind, data, length, pts, flags, width, height):
        payload = ctypes.string_at(data, length) if data and length > 0 else b""
        if data:
            self.lib.wsn_free(data)
        now = time.monotonic()
        if kind == NOTE:
            text = payload.decode("utf-8", "replace")
            self.notes.append((now, id_, text))
            log("  note[%d]: %s" % (id_, text))
            return
        if kind == PACKET and id_ == self.capture_id:
            with self.packet_lock:
                self.packets.append((now, flags, pts, payload, width, height))
            return
        self.events.put((now, id_, kind, payload, flags, width, height))

    def wait(self, id_, kinds, timeout):
        """Next event for id_ of one of kinds; others are kept in a side list."""
        deadline = time.monotonic() + timeout
        kept = []
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                try:
                    event = self.events.get(timeout=left)
                except queue.Empty:
                    return None
                if event[1] == id_ and event[2] in kinds:
                    return event
                kept.append(event)
        finally:
            for e in kept:
                self.events.put(e)

    def notes_for(self, id_):
        return [n[2] for n in self.notes if n[1] == id_]

    def input(self, kind, code=0, mods=0, x=0.0, y=0.0, dx=0.0, dy=0.0, phase=0, text=None):
        self.lib.wsn_capture_input(self.capture_id, kind, code, mods, x, y, dx, dy, phase,
                                   text.encode() if text is not None else None)


LOG = None


def log(msg):
    print(msg, flush=True)
    if LOG:
        LOG.write(msg + "\n")
        LOG.flush()


bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def helper_windows():
    r = bus.call_sync("com.vireen.Whisper.Shell", "/com/vireen/Whisper/Shell", "com.vireen.Whisper.Shell1",
                      "ListWindows", None, None, Gio.DBusCallFlags.NONE, 5000, None)
    return r.unpack()[0]


def display_state():
    r = bus.call_sync("org.gnome.Mutter.DisplayConfig", "/org/gnome/Mutter/DisplayConfig",
                      "org.gnome.Mutter.DisplayConfig", "GetCurrentState", None, None, 0, 5000, None).unpack()
    _serial, monitors, logical, _props = r
    out = []
    for l in logical:
        out.append({"x": l[0], "y": l[1], "scale": l[2], "connectors": [m[0] for m in l[5]]})
    return out


def write_png(path, w, h, rgb):
    stride = len(rgb) // h
    raw = b"".join(b"\0" + rgb[y * stride:y * stride + w * 3] for y in range(h))

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
                           chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def real_screen_frame(out_png):
    """One frame of each real monitor (RecordMonitor), to prove the window left it."""
    Gst.init(None)
    real = [c for m in display_state() for c in m["connectors"] if not c.startswith("Meta-")]
    if not real:
        return None
    connector = real[0]
    call = lambda path, iface, method, params, rt=None: bus.call_sync(  # noqa: E731
        "org.gnome.Mutter.ScreenCast", path, iface, method, params, GLib.VariantType(rt) if rt else None, 0, 5000, None)
    sess = call("/org/gnome/Mutter/ScreenCast", "org.gnome.Mutter.ScreenCast", "CreateSession",
                GLib.Variant("(a{sv})", ({},)), "(o)").unpack()[0]
    stream = call(sess, "org.gnome.Mutter.ScreenCast.Session", "RecordMonitor",
                  GLib.Variant("(sa{sv})", (connector, {"cursor-mode": GLib.Variant("u", 0)})), "(o)").unpack()[0]
    node = {}
    ev = threading.Event()

    def on_added(c, s, p, i, n, params):
        node["id"] = params.unpack()[0]
        ev.set()
    sub = bus.signal_subscribe(None, "org.gnome.Mutter.ScreenCast.Stream", "PipeWireStreamAdded", stream, None, 0,
                               on_added)
    call(sess, "org.gnome.Mutter.ScreenCast.Session", "Start", None)
    ev.wait(5)
    bus.signal_unsubscribe(sub)
    result = None
    if "id" in node:
        pipe = Gst.parse_launch(f"pipewiresrc path={node['id']} num-buffers=3 ! videoconvert ! "
                                f"video/x-raw,format=RGB ! appsink name=sink sync=false")
        sink = pipe.get_by_name("sink")
        pipe.set_state(Gst.State.PLAYING)
        sample = sink.emit("try-pull-sample", 5 * Gst.SECOND)
        if sample:
            buf = sample.get_buffer()
            st = sample.get_caps().get_structure(0)
            ok, info = buf.map(Gst.MapFlags.READ)
            w, h = st.get_value("width"), st.get_value("height")
            data = bytes(info.data)
            buf.unmap(info)
            write_png(out_png, w, h, data)
            result = (w, h, data)
        pipe.set_state(Gst.State.NULL)
    call(sess, "org.gnome.Mutter.ScreenCast.Session", "Stop", None)
    return result


def input_log(path, since=0):
    events = []
    try:
        for line in open(path):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            events.append(e)
    except OSError:
        pass
    return events[since:]


class Checks:
    def __init__(self, plugin, tester, out, quick, park):
        self.p = plugin
        self.tester = tester
        self.out = out
        self.quick = quick
        self.park = park
        self.results = []
        self.log_path = os.path.join(out, "test_window_input.log")
        self.proc = None
        self.window = None

    def result(self, name, ok, detail=""):
        self.results.append({"check": name, "ok": bool(ok), "detail": detail})
        log(("PASS " if ok else "FAIL ") + name + (": " + detail if detail else ""))

    def launch_window(self, title):
        # A colour of its own, so the real-screen check cannot mistake another window for it.
        self.proc = subprocess.Popen([self.tester, self.log_path, title, "plain", "C8F0B4"], stdout=subprocess.DEVNULL,
                                     stderr=subprocess.DEVNULL)
        for _ in range(50):
            time.sleep(0.1)
            for w in helper_windows():
                if w["title"] == title and w["pid"] == self.proc.pid and w["width"] > 100:
                    time.sleep(0.3)  # mapped and settled
                    return [v for v in helper_windows() if v["id"] == w["id"]][0]
        return None

    def catalog(self, title):
        rid = self.p.lib.wsn_capture_request_catalog()
        e = self.p.wait(rid, {CATALOG, FAILED}, 6)
        if e is None or e[2] != CATALOG:
            return None, e
        data = json.loads(e[3])
        return data, [w for w in data["windows"] if w["title"] == title]

    def frames_between(self, t0, t1):
        with self.p.packet_lock:
            return [pk for pk in self.p.packets if t0 <= pk[0] <= t1 and not pk[1] & CONFIG]

    def write_stream(self, path):
        """The whole stream, plus one file per picture size (a decoder starts
        over at each size change, which raw-stream tools handle badly)."""
        with self.p.packet_lock:
            packets = list(self.p.packets)
        open(path, "wb").write(b"".join(pk[3] for pk in packets))
        segments = []
        for pk in packets:
            size = (pk[4], pk[5])
            if not segments or segments[-1][0] != size:
                segments.append((size, []))
            segments[-1][1].append(pk)
        files = []
        for i, (size, pks) in enumerate(segments):
            name = path.replace(".h264", f".{i}.{size[0]}x{size[1]}.h264")
            open(name, "wb").write(b"".join(pk[3] for pk in pks))
            files.append((name, len([pk for pk in pks if not pk[1] & CONFIG])))
        return path, files

    def decode_counter(self, h264, png):
        """Last frame of the stream: the 16 counter blocks across the window's top."""
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", h264, "-update", "1", "-frames:v", "100000",
                        png], check=False)
        try:
            from PIL import Image
            img = Image.open(png).convert("L")
        except Exception as e:  # noqa: BLE001
            return None, str(e)
        w, h = img.size
        layout = [e for e in input_log(self.log_path) if e.get("ev") == "layout"]
        area = layout[-1] if layout else {"area_x": 0, "area_y": 0, "area_w": self.mon_w}
        scale = w / max(1, self.mon_w)
        value = 0
        for bit in range(16):
            x = int((area["area_x"] + (bit + 0.5) * area["area_w"] / 16) * scale)
            y = int((area["area_y"] + 20) * scale)
            value = (value << 1) | (1 if img.getpixel((min(x, w - 1), min(y, h - 1))) < 128 else 0)
        return value, f"{w}x{h}, area at {area['area_x']},{area['area_y']}"

    def run(self):
        p = self.p
        log(f"api {p.lib.wsn_api_version()} supported {p.lib.wsn_capture_supported()} "
            f"input {p.lib.wsn_capture_input_permission()}")
        self.result("supported (GNOME Wayland)", p.lib.wsn_capture_supported() == 1)
        self.result("helper ready (input permission)", p.lib.wsn_capture_input_permission() == 1)

        title = "WSN Harness %d" % os.getpid()
        hw = self.launch_window(title)
        self.result("test window opened", hw is not None, json.dumps(hw and {k: hw[k] for k in ("id", "x", "y", "width", "height")}))
        if hw is None:
            return
        original = (hw["x"], hw["y"], hw["width"], hw["height"])
        data, mine = self.catalog(title)
        self.result("catalog lists the test window", bool(mine), f"{len(data['windows']) if data else 0} windows, "
                    f"{len(data['apps']) if data else 0} apps, locked={data and data.get('locked')}")
        if not mine:
            return
        win = mine[0]
        rid = p.lib.wsn_capture_request_thumbnail(win["id"], 360)
        e = p.wait(rid, {THUMBNAIL, FAILED}, 6)
        ok = e is not None and e[2] == THUMBNAIL and e[3][:2] == b"\xff\xd8"
        if ok:
            open(os.path.join(self.out, "thumbnail.jpg"), "wb").write(e[3])
        self.result("thumbnail (JPEG)", ok, f"{len(e[3]) if e else 0} bytes")
        app = next((a for a in data["apps"] if a["bundleId"] in ("org.gnome.TextEditor.desktop",
                                                                  "org.gnome.Nautilus.desktop")), None)
        app = app or (data["apps"][0] if data["apps"] else None)
        if app:
            rid = p.lib.wsn_capture_request_icon(app["bundleId"].encode(), 128)
            e = p.wait(rid, {ICON, FAILED}, 6)
            ok = e is not None and e[2] == ICON and e[3][:4] == b"\x89PNG"
            if ok:
                open(os.path.join(self.out, "icon.png"), "wb").write(e[3])
            self.result("app icon (PNG)", ok, app["bundleId"])

        # ---- start: a phone-shaped viewer (412x915 pt)
        t_start = time.monotonic()
        cid = p.lib.wsn_capture_start(win["id"], win["pid"], 2560, 60, 12000000)
        p.capture_id = cid
        p.lib.wsn_capture_set_screen(cid, 0x5753)
        p.lib.wsn_capture_set_viewport(cid, 412.0, 915.0, 1.0)
        size = p.wait(cid, {SIZE, FAILED, STOPPED}, 10)
        time.sleep(0.2)
        notes = p.notes_for(cid)
        if size is None or size[2] != SIZE:
            self.result("capture started", False, f"event {size and KIND_NAMES[size[2]]} flags {size and size[4]}")
            return
        first = None
        for _ in range(100):
            with p.packet_lock:
                if p.packets:
                    first = p.packets[0][0]
                    break
            time.sleep(0.02)
        self.result("first frame < 2 s", first is not None and first - t_start < 2.0,
                    f"{(first - t_start) if first else -1:.2f} s, size {size[5]}x{size[6]}")
        staged = next((n for n in notes if n.startswith("staged on its own monitor")), "")
        self.result("staged on a virtual monitor", bool(staged), staged)
        time.sleep(0.6)
        cur = [w for w in helper_windows() if w["id"] == win["id"]][0]
        monitors = display_state()
        vm = [m for m in monitors if any(c.startswith("Meta-") for c in m["connectors"])]
        self.mon_w, self.mon_h = cur["width"], cur["height"]
        log(f"  window now {cur['x']},{cur['y']} {cur['width']}x{cur['height']} monitors {monitors}")
        t0 = time.monotonic()
        time.sleep(5)
        frames = self.frames_between(t0, time.monotonic())
        self.result("≥ 20 fps over 5 s", len(frames) / 5 >= 20, f"{len(frames) / 5:.1f} fps")
        kbps = sum(len(f[3]) for f in frames) * 8 / 5 / 1000
        log(f"  {kbps:.0f} kbit/s")

        # ---- input
        n0 = len(input_log(self.log_path))
        p.input(DOWN, 0, 0, 0.5, 0.5)
        p.input(UP, 0, 0, 0.5, 0.5)
        time.sleep(0.6)
        ev = [e for e in input_log(self.log_path, n0) if e.get("ev") == "button" and e.get("type") == "down"]
        if ev:
            ex, ey = (self.mon_w - 0.5) * 0.5, (self.mon_h - 0.5) * 0.5
            dx, dy = ev[0]["wx"] - ex, ev[0]["wy"] - ey
            self.result("click at (0.5, 0.5) within ±2 px", abs(dx) <= 2 and abs(dy) <= 2,
                        f"got {ev[0]['wx']},{ev[0]['wy']} expected {ex:.1f},{ey:.1f}")
        else:
            self.result("click at (0.5, 0.5) within ±2 px", False, "no click reached the window")
        # Right click.
        n0 = len(input_log(self.log_path))
        p.input(DOWN, 1, 0, 0.3, 0.3)
        p.input(UP, 1, 0, 0.3, 0.3)
        time.sleep(0.5)
        ev = [e for e in input_log(self.log_path, n0) if e.get("ev") == "button" and e.get("type") == "down"]
        self.result("right click", bool(ev) and ev[0]["button"] == 3, json.dumps(ev[:1]))
        # Scroll: positive dy (the shared model's "up") must reach the app as up.
        n0 = len(input_log(self.log_path))
        p.input(SCROLL, 0, 0, 0.5, 0.4, 0.0, 1.0, 0)
        time.sleep(0.4)
        p.input(SCROLL, 0, 0, 0.5, 0.4, 0.0, -0.05, 4 | (1 << 16))
        p.input(SCROLL, 0, 0, 0.5, 0.4, 0.0, 0.0, 8 | (1 << 16))
        time.sleep(0.5)
        ev = [e for e in input_log(self.log_path, n0) if e.get("ev") == "scroll"]
        wheel_up = any(e["dy"] < 0 or e["direction"] == 0 for e in ev[:1])
        precise_down = any(e["dy"] > 0 for e in ev[1:])
        self.result("scroll sign (wheel up, trackpad down)", wheel_up and precise_down, json.dumps(ev[:4]))
        # Text into the entry at the bottom of the window.
        entry_y = (self.mon_h - 17) / self.mon_h
        p.input(DOWN, 0, 0, 0.5, entry_y)
        p.input(UP, 0, 0, 0.5, entry_y)
        focus = p.wait(cid, {TEXT_FOCUS}, 3)
        self.result("text focus reported", focus is not None and focus[4] == 1,
                    f"{focus and (focus[0] - t0):.2f}" if focus else "none")
        n0 = len(input_log(self.log_path))
        p.input(TEXT, text="Hello 你好")
        time.sleep(0.8)
        ev = [e for e in input_log(self.log_path, n0) if e.get("ev") == "text"]
        self.result("text 'Hello 你好' exact", bool(ev) and ev[-1]["value"] == "Hello 你好",
                    json.dumps(ev[-1:], ensure_ascii=False))
        # Cmd+A → Ctrl+A (mac kVK_ANSI_A = 0).
        n0 = len(input_log(self.log_path))
        p.input(KEY_DOWN, 0, MOD_COMMAND)
        p.input(KEY_UP, 0, MOD_COMMAND)
        time.sleep(0.5)
        ev = [e for e in input_log(self.log_path, n0) if e.get("ev") == "key" and e.get("name") == "a"]
        ok = bool(ev) and ev[0]["ctrl"]
        ctrl_up = [e for e in input_log(self.log_path, n0) if e.get("ev") == "key" and e.get("name") == "Control_L"
                   and e.get("type") == "up"]
        self.result("Cmd+A arrives as Ctrl+A (and Ctrl is released)", ok and bool(ctrl_up), json.dumps(ev[:1]))
        # Delete the selection with Backspace (mac 51) → entry empty.
        p.input(KEY_DOWN, 51)
        p.input(KEY_UP, 51)
        time.sleep(0.4)
        ev = [e for e in input_log(self.log_path, n0) if e.get("ev") == "text"]
        self.result("Backspace after Ctrl+A clears the field", bool(ev) and ev[-1]["value"] == "", json.dumps(ev[-1:]))

        # ---- real screen: the window is not there
        shot = real_screen_frame(os.path.join(self.out, "real_screen.png"))
        if shot:
            w, h, rgb = shot
            stride = len(rgb) // h
            hits = 0
            for y in range(0, h, 4):
                row = rgb[y * stride:y * stride + w * 3]
                for x in range(0, w * 3, 12):
                    r, g, b = row[x], row[x + 1], row[x + 2]
                    if abs(r - 0xC8) < 4 and abs(g - 0xF0) < 4 and abs(b - 0xB4) < 4:
                        hits += 1
            self.result("window not on the real screen", hits < 20, f"{hits} sampled pixels of its colour")
        else:
            self.result("window not on the real screen", False, "no real-screen frame")

        # ---- rotate (viewport) and keyboard inset
        n_sizes = p.events.qsize()
        p.lib.wsn_capture_set_viewport(cid, 915.0, 412.0, 1.0)
        size2 = p.wait(cid, {SIZE}, 6)
        time.sleep(0.8)
        cur = [w for w in helper_windows() if w["id"] == win["id"]][0]
        self.result("rotated viewport resizes monitor and window", size2 is not None and size2[5] > size2[6],
                    f"stream {size2 and size2[5]}x{size2 and size2[6]}, window {cur['width']}x{cur['height']}")
        before_h = cur["height"]
        p.lib.wsn_capture_set_inset(cid, 0.4)
        time.sleep(1.0)
        cur = [w for w in helper_windows() if w["id"] == win["id"]][0]
        self.result("keyboard inset shortens the window", cur["height"] < before_h * 0.7,
                    f"{before_h} -> {cur['height']}")
        p.lib.wsn_capture_set_inset(cid, 0.0)
        p.lib.wsn_capture_set_viewport(cid, 412.0, 915.0, 1.0)
        time.sleep(1.5)
        log(f"  monitors {display_state()}")

        # ---- stream file and counter
        h264, segments = self.write_stream(os.path.join(self.out, "stream.h264"))
        all_ok = True
        details = []
        for name, sent in segments:
            probe = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
                                    "-show_entries", "stream=nb_read_frames,width,height,profile", "-of", "json", name],
                                   capture_output=True, text=True)
            info = json.loads(probe.stdout or "{}").get("streams", [{}])
            decoded = int(info[0].get("nb_read_frames", 0)) if info else 0
            all_ok = all_ok and decoded > 0 and decoded >= sent - 1
            details.append(f"{os.path.basename(name)}: {decoded}/{sent} ({info[0].get('profile') if info else '?'})")
        self.result("stream decodes (ffprobe, per size)", all_ok, "; ".join(details))
        value, detail = self.decode_counter(segments[-1][0], os.path.join(self.out, "last_frame.png"))
        self.result("frame counter readable from the picture", value is not None and value > 0, f"{value} ({detail})")

        # ---- pause → park → resume
        if self.park:
            p.lib.wsn_capture_set_paused(cid, 1)
            park = int(os.environ.get("WHISPER_WSN_PARK_SECONDS", "60"))
            log(f"  paused; waiting {park + 3} s for the window to go home")
            time.sleep(park + 3)
            cur = [w for w in helper_windows() if w["id"] == win["id"]][0]
            vms = [m for m in display_state() if any(c.startswith("Meta-") for c in m["connectors"])]
            self.result("paused 60 s: window home, monitor gone",
                        (cur["x"], cur["y"], cur["width"], cur["height"]) == original and not vms,
                        f"{(cur['x'], cur['y'], cur['width'], cur['height'])} vs {original}, virtual monitors {len(vms)}")
            with p.packet_lock:
                count = len(p.packets)
            t_resume = time.monotonic()
            p.lib.wsn_capture_set_paused(cid, 0)
            moved_at = None
            for _ in range(60):
                time.sleep(0.05)
                cur = [w for w in helper_windows() if w["id"] == win["id"]][0]
                if (cur["x"], cur["y"]) != original[:2]:
                    moved_at = time.monotonic()
                    break
            time.sleep(0.5)
            with p.packet_lock:
                fresh = len([pk for pk in p.packets if pk[0] > (moved_at or t_resume)])
            self.result("resume: staged again and streaming", moved_at is not None and fresh > 0,
                        f"window {cur['x']},{cur['y']} after {((moved_at or t_resume) - t_resume):.2f} s, "
                        f"{fresh} packets since")

        # ---- stop restores exactly
        p.lib.wsn_capture_stop(cid)
        time.sleep(1.5)
        cur = [w for w in helper_windows() if w["id"] == win["id"]][0]
        now = (cur["x"], cur["y"], cur["width"], cur["height"])
        vms = [m for m in display_state() if any(c.startswith("Meta-") for c in m["connectors"])]
        self.result("stop: window back exactly, monitor gone", now == original and not vms,
                    f"{now} vs {original}, virtual monitors {len(vms)}")

        # ---- kill and relaunch
        p.packets.clear()
        cid = p.lib.wsn_capture_start(win["id"], win["pid"], 2560, 60, 12000000)
        p.capture_id = cid
        p.lib.wsn_capture_set_screen(cid, 0x5753)
        p.lib.wsn_capture_set_viewport(cid, 412.0, 915.0, 1.0)
        p.wait(cid, {SIZE}, 8)
        self.proc.kill()
        gone = p.wait(cid, {STOPPED}, 5)
        self.result("app killed: capture reports the window gone", gone is not None and gone[4] == 4,
                    f"flags {gone and gone[4]}")
        p.lib.wsn_capture_stop(cid)
        time.sleep(0.5)
        hw = self.launch_window(title)
        data, mine = self.catalog(title)
        if not mine:
            log(f"  relaunch: window {hw}, catalog {'failed' if data is None else [w['title'] for w in data['windows']]}")
        ok = bool(mine) and data is not None
        if ok:
            p.packets.clear()
            cid = p.lib.wsn_capture_start(mine[0]["id"], mine[0]["pid"], 2560, 60, 12000000)
            p.capture_id = cid
            p.lib.wsn_capture_set_screen(cid, 0x5753)
            p.lib.wsn_capture_set_viewport(cid, 412.0, 915.0, 1.0)
            ok = p.wait(cid, {SIZE}, 8) is not None
        self.result("relaunched app streams again", ok)
        # ---- remote close
        if ok:
            p.lib.wsn_capture_close_window(mine[0]["id"], mine[0]["pid"])
            gone = p.wait(cid, {STOPPED}, 5)
            closed = [e for e in input_log(self.log_path) if e.get("ev") == "close"]
            self.result("remote close closes the window", gone is not None and bool(closed))
            p.lib.wsn_capture_stop(cid)
        time.sleep(1)
        vms = [m for m in display_state() if any(c.startswith("Meta-") for c in m["connectors"])]
        self.result("nothing left behind (no virtual monitors)", not vms, f"{len(vms)}")


def main():
    global LOG
    plugin_path, tester, out = sys.argv[1:4]
    quick = "--quick" in sys.argv
    park = "--park" in sys.argv
    os.makedirs(out, exist_ok=True)
    LOG = open(os.path.join(out, "check.log"), "w")
    Gtk.init([])
    plugin = Plugin(plugin_path)
    loop = GLib.MainLoop()
    checks = Checks(plugin, tester, out, quick, park)

    def worker():
        try:
            checks.run()
        except Exception as e:  # noqa: BLE001
            import traceback
            log("ERROR " + traceback.format_exc())
            checks.result("harness", False, str(e))
        finally:
            try:
                if checks.proc and checks.proc.poll() is None:
                    checks.proc.terminate()
            except Exception:  # noqa: BLE001
                pass
            GLib.idle_add(loop.quit)

    threading.Thread(target=worker, daemon=True).start()
    loop.run()
    json.dump(checks.results, open(os.path.join(out, "results.json"), "w"), indent=1, ensure_ascii=False)
    failed = [r for r in checks.results if not r["ok"]]
    log(f"{len(checks.results) - len(failed)}/{len(checks.results)} passed")
    os._exit(1 if failed else 0)


if __name__ == "__main__":
    main()
