// Whisper window stream helper for GNOME Shell (Wayland).
//
// Whisper shows this computer's windows on the user's other devices. On
// GNOME the window it streams runs on a virtual monitor that Whisper asks
// Mutter for (ScreenCast RecordVirtual), so it leaves the user's screen and
// keeps running in the background. Moving windows, synthesising input and
// reading which field has the keyboard focus can only be done inside the
// compositor; this extension offers exactly those operations to the Whisper
// app over D-Bus and nothing else.
//
// Every call is checked: the caller must run as this user, outside any
// sandbox (Flatpak, Snap or another mount namespace), as one of the
// executables listed in the `allowed-exe` file the Whisper installer writes
// next to this file. Input is refused while the session is locked. When the
// caller goes away (quits or crashes) every window it moved goes back exactly
// where it was, and its pointer fences and virtual devices are removed.

import Clutter from 'gi://Clutter';
import GdkPixbuf from 'gi://GdkPixbuf';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as Config from 'resource:///org/gnome/shell/misc/config.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const PROTOCOL_VERSION = 1;
const BUS_NAME = 'com.vireen.Whisper.Shell';
const OBJECT_PATH = '/com/vireen/Whisper/Shell';
const IFACE_NAME = 'com.vireen.Whisper.Shell1';
const ERROR = 'com.vireen.Whisper.Shell1.Error.';

const IFACE_XML = `
<node>
  <interface name="${IFACE_NAME}">
    <method name="GetInfo">
      <arg type="a{sv}" name="info" direction="out"/>
    </method>
    <method name="ListWindows">
      <arg type="aa{sv}" name="windows" direction="out"/>
      <arg type="a{sv}" name="state" direction="out"/>
    </method>
    <method name="Stage">
      <arg type="u" name="id" direction="in"/>
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="i" name="width" direction="in"/>
      <arg type="i" name="height" direction="in"/>
      <arg type="i" name="frameX" direction="out"/>
      <arg type="i" name="frameY" direction="out"/>
      <arg type="i" name="frameWidth" direction="out"/>
      <arg type="i" name="frameHeight" direction="out"/>
      <arg type="i" name="monitor" direction="out"/>
    </method>
    <method name="Unstage">
      <arg type="u" name="id" direction="in"/>
      <arg type="b" name="restored" direction="out"/>
    </method>
    <method name="Activate">
      <arg type="u" name="id" direction="in"/>
      <arg type="b" name="changed" direction="out"/>
    </method>
    <method name="Unminimize">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="Close">
      <arg type="u" name="id" direction="in"/>
    </method>
    <method name="EvictStrangers">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="i" name="width" direction="in"/>
      <arg type="i" name="height" direction="in"/>
      <arg type="u" name="keepId" direction="in"/>
      <arg type="u" name="moved" direction="out"/>
    </method>
    <method name="SetFence">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
      <arg type="i" name="width" direction="in"/>
      <arg type="i" name="height" direction="in"/>
      <arg type="b" name="on" direction="in"/>
    </method>
    <method name="Pointer">
      <arg type="u" name="kind" direction="in"/>
      <arg type="u" name="button" direction="in"/>
      <arg type="d" name="x" direction="in"/>
      <arg type="d" name="y" direction="in"/>
    </method>
    <method name="Scroll">
      <arg type="d" name="x" direction="in"/>
      <arg type="d" name="y" direction="in"/>
      <arg type="d" name="dx" direction="in"/>
      <arg type="d" name="dy" direction="in"/>
      <arg type="u" name="source" direction="in"/>
      <arg type="b" name="finish" direction="in"/>
    </method>
    <method name="Key">
      <arg type="u" name="evdev" direction="in"/>
      <arg type="b" name="down" direction="in"/>
    </method>
    <method name="Keyval">
      <arg type="u" name="keysym" direction="in"/>
      <arg type="b" name="down" direction="in"/>
    </method>
    <method name="Text">
      <arg type="s" name="text" direction="in"/>
      <arg type="s" name="method" direction="out"/>
    </method>
    <method name="WarpHome"/>
    <method name="ReleaseInput"/>
    <method name="Thumbnail">
      <arg type="u" name="id" direction="in"/>
      <arg type="i" name="maxEdge" direction="in"/>
      <arg type="ay" name="jpeg" direction="out"/>
    </method>
    <signal name="WindowsChanged"/>
    <signal name="WindowGone">
      <arg type="u" name="id"/>
    </signal>
    <signal name="TextFocus">
      <arg type="u" name="id"/>
      <arg type="b" name="focused"/>
    </signal>
  </interface>
</node>`;

// Pointer event kinds (Pointer.kind), as in window_stream_native.h.
const POINTER_DOWN = 1;
const POINTER_MOVE = 2;
const POINTER_UP = 3;
const POINTER_CANCEL = 8;

// Clutter button numbers (notify_button maps them to evdev itself).
const BUTTON_PRIMARY = 1;
const BUTTON_MIDDLE = 2;
const BUTTON_SECONDARY = 3;

// evdev key codes used for paste.
const KEY_LEFTCTRL = 29;
const KEY_V = 47;
const KEY_ENTER = 28;

const SETTLE_POLL_MS = 20;
const FENCE_SETTLE_MS = 30;
const CLIPBOARD_READ_MS = 300;
const TEXT_FOCUS_POLL_MS = 250;
const CHANGED_DEBOUNCE_MS = 300;

class DBusError extends Error {
    constructor(name, message) {
        super(message);
        this.dbusName = ERROR + name;
    }
}

function now() {
    return GLib.get_monotonic_time();
}

function delay(ms) {
    return new Promise(resolve => {
        GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => {
            resolve();
            return GLib.SOURCE_REMOVE;
        });
    });
}

function frameOf(win) {
    const r = win.get_frame_rect();
    return {x: r.x, y: r.y, width: r.width, height: r.height};
}

function close(a, b, tolerance = 2) {
    return Math.abs(a.x - b.x) <= tolerance && Math.abs(a.y - b.y) <= tolerance &&
        Math.abs(a.width - b.width) <= tolerance && Math.abs(a.height - b.height) <= tolerance;
}

function same(a, b) {
    return a.x === b.x && a.y === b.y && a.width === b.width && a.height === b.height;
}

function contains(rect, x, y) {
    return x >= rect.x && y >= rect.y && x < rect.x + rect.width && y < rect.y + rect.height;
}

function intersects(a, b) {
    return a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;
}

function centre(rect) {
    return [rect.x + rect.width / 2, rect.y + rect.height / 2];
}

function rectKey(rect) {
    return `${rect.x},${rect.y},${rect.width},${rect.height}`;
}

// Maximize state across Mutter versions: 49 replaced get_maximized() and
// maximize(flags) with is_maximized()/get_maximize_flags() and maximize().
function maximizeFlags(win) {
    if (typeof win.get_maximize_flags === 'function')
        return win.get_maximize_flags();
    if (typeof win.get_maximized === 'function')
        return win.get_maximized();
    return (win.maximized_horizontally ? Meta.MaximizeFlags.HORIZONTAL : 0) |
        (win.maximized_vertically ? Meta.MaximizeFlags.VERTICAL : 0);
}

function unmaximize(win) {
    if (typeof win.set_unmaximize_flags === 'function')
        win.set_unmaximize_flags(Meta.MaximizeFlags.BOTH);
    else if (win.unmaximize.length > 0)
        win.unmaximize(Meta.MaximizeFlags.BOTH);
    else
        win.unmaximize();
}

function maximize(win, flags) {
    if (flags === Meta.MaximizeFlags.BOTH && win.maximize.length === 0) {
        win.maximize();
    } else if (typeof win.set_maximize_flags === 'function') {
        win.set_maximize_flags(flags);
    } else {
        win.maximize(flags);
    }
}

// GNOME 47 and later reach the seat through the stage's context; 45 and 46
// through Clutter's default backend.
function defaultSeat() {
    const backend = global.stage.context?.get_backend?.() ?? Clutter.get_default_backend();
    return backend.get_default_seat();
}

// Monitors Mutter made for a screen cast (RecordVirtual). Before GNOME 49
// monitors are not introspectable; virtual ones are the "Meta-<n>" connectors.
function virtualMonitors() {
    const manager = global.backend.get_monitor_manager();
    const virtual = new Set();
    if (typeof manager.get_logical_monitors === 'function') {
        for (const logical of manager.get_logical_monitors()) {
            if (logical.get_monitors().every(m => m.is_virtual()))
                virtual.add(logical.get_number());
        }
        return virtual;
    }
    for (let id = 0; id < 16; id++) {
        const index = manager.get_monitor_for_connector(`Meta-${id}`);
        if (index >= 0)
            virtual.add(index);
    }
    return virtual;
}

function isListed(win) {
    if (!win || win.is_override_redirect() || win.is_skip_taskbar())
        return false;
    const type = win.get_window_type();
    return type === Meta.WindowType.NORMAL || type === Meta.WindowType.DIALOG ||
        type === Meta.WindowType.MODAL_DIALOG || type === Meta.WindowType.UTILITY;
}

function allWindows() {
    return global.display.list_all_windows().filter(w => !w.is_override_redirect());
}

function findWindow(id) {
    for (const win of global.display.list_all_windows()) {
        if (win.get_stable_sequence() === id)
            return win;
    }
    return null;
}

function readLink(path) {
    try {
        return GLib.file_read_link(path);
    } catch {
        return null;
    }
}

function fileIdentity(path) {
    try {
        const info = Gio.File.new_for_path(path).query_info(
            'unix::device,unix::inode', Gio.FileQueryInfoFlags.NONE, null);
        return `${info.get_attribute_uint32('unix::device')}:${info.get_attribute_uint64('unix::inode')}`;
    } catch {
        return null;
    }
}

function readText(path) {
    try {
        const [ok, bytes] = GLib.file_get_contents(path);
        return ok ? new TextDecoder().decode(bytes) : null;
    } catch {
        return null;
    }
}

function callAsync(proxyCall) {
    return new Promise((resolve, reject) => {
        proxyCall((source, result) => {
            try {
                resolve(source.call_finish(result));
            } catch (e) {
                reject(e);
            }
        });
    });
}

/** One process that passed the caller check, and what it changed. */
class Caller {
    constructor(service, name, pid) {
        this.service = service;
        this.name = name;
        this.pid = pid;
        this.fences = new Map();
        this.fencesLifted = false;
        this.home = null;
        this.pointer = null;
        this.keyboard = null;
        this.buttons = new Set();
        this.keys = new Set();
        this.keyvals = new Set();
        this.textFocus = {id: 0, focused: false};
        this.queue = Promise.resolve();
        this.armTimer = 0;
        this.watchId = Gio.bus_watch_name_on_connection(Gio.DBus.session, name,
            Gio.BusNameWatcherFlags.NONE, null, () => service.callerVanished(name));
    }

    pointerDevice() {
        if (!this.pointer) {
            const seat = defaultSeat();
            this.pointer = seat.create_virtual_device(Clutter.InputDeviceType.POINTER_DEVICE);
        }
        return this.pointer;
    }

    keyboardDevice() {
        if (!this.keyboard) {
            const seat = defaultSeat();
            this.keyboard = seat.create_virtual_device(Clutter.InputDeviceType.KEYBOARD_DEVICE);
        }
        return this.keyboard;
    }

    /** Lets go of every button and key this caller holds down. */
    releaseInput() {
        if (this.pointer) {
            for (const button of this.buttons)
                this.pointer.notify_button(now(), button, Clutter.ButtonState.RELEASED);
        }
        if (this.keyboard) {
            for (const key of this.keys)
                this.keyboard.notify_key(now(), key, Clutter.KeyState.RELEASED);
            for (const keyval of this.keyvals)
                this.keyboard.notify_keyval(now(), keyval, Clutter.KeyState.RELEASED);
        }
        this.buttons.clear();
        this.keys.clear();
        this.keyvals.clear();
    }

    destroy() {
        this.releaseInput();
        if (this.armTimer) {
            GLib.source_remove(this.armTimer);
            this.armTimer = 0;
        }
        if (this.watchId) {
            Gio.bus_unwatch_name(this.watchId);
            this.watchId = 0;
        }
        for (const barriers of this.fences.values())
            barriers.forEach(b => b.destroy());
        this.fences.clear();
        this.pointer = null;
        this.keyboard = null;
    }
}

class WindowStreamService {
    constructor(extension) {
        this._extension = extension;
        this._callers = new Map();
        // Unique bus name → credentials, so each call costs no extra round trip.
        this._credentials = new Map();
        this._staged = new Map();
        this._allowed = {mtime: -1, list: []};
        this._changedId = 0;
        this._textFocusId = 0;
        this._clipboardRestore = null;
        this._ownIdentity = fileIdentity('/');
        this._ownUid = new Gio.Credentials().get_unix_user();
        this._journalPath = GLib.build_filenamev([GLib.get_user_state_dir(), 'whisper', 'gnome-shell-staged.json']);

        this._dbus = Gio.DBusExportedObject.wrapJSObject(IFACE_XML, this);
        this._dbus.export(Gio.DBus.session, OBJECT_PATH);
        this._ownerId = Gio.bus_own_name_on_connection(Gio.DBus.session, BUS_NAME,
            Gio.BusNameOwnerFlags.NONE, null, null);

        global.display.connectObject(
            'window-created', (_d, win) => {
                this._watchWindow(win);
                this._windowsChanged();
            },
            'notify::focus-window', () => this._checkTextFocus(),
            this);
        for (const win of allWindows())
            this._watchWindow(win);
        Main.inputMethod.connectObject(
            'notify::content-purpose', () => this._checkTextFocus(),
            'input-panel-state', () => this._checkTextFocus(),
            this);
        Main.sessionMode.connectObject('updated', () => {
            if (Main.sessionMode.isLocked) {
                for (const caller of this._callers.values())
                    caller.releaseInput();
            }
        }, this);
        this._recoverJournal();
    }

    destroy() {
        global.display.disconnectObject(this);
        Main.inputMethod.disconnectObject(this);
        Main.sessionMode.disconnectObject(this);
        for (const win of allWindows())
            win.disconnectObject(this);
        if (this._changedId)
            GLib.source_remove(this._changedId);
        if (this._textFocusId)
            GLib.source_remove(this._textFocusId);
        this._changedId = this._textFocusId = 0;
        // Everything goes back now, synchronously: the shell may be on its
        // way out.
        for (const entry of [...this._staged.values()])
            this._restoreNow(entry);
        this._staged.clear();
        this._writeJournal();
        for (const caller of this._callers.values())
            caller.destroy();
        this._callers.clear();
        this._restoreClipboardNow();
        Gio.bus_unown_name(this._ownerId);
        this._dbus.unexport();
    }

    // ------------------------------------------------------------ caller check

    _allowedExecutables() {
        const path = GLib.build_filenamev([this._extension.path, 'allowed-exe']);
        let mtime = -2;
        try {
            const info = Gio.File.new_for_path(path).query_info('time::modified',
                Gio.FileQueryInfoFlags.NONE, null);
            mtime = info.get_attribute_uint64('time::modified');
        } catch {
            this._allowed = {mtime: -2, list: []};
            return [];
        }
        if (mtime !== this._allowed.mtime) {
            const text = readText(path) ?? '';
            const list = text.split('\n').map(l => l.trim()).filter(l => l.startsWith('/'));
            this._allowed = {mtime, list};
        }
        return this._allowed.list;
    }

    async _credentialsOf(sender) {
        const cached = this._credentials.get(sender);
        if (cached)
            return cached;
        const reply = await callAsync(done => Gio.DBus.session.call(
            'org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
            'GetConnectionCredentials', new GLib.Variant('(s)', [sender]),
            new GLib.VariantType('(a{sv})'), Gio.DBusCallFlags.NONE, 2000, null, done));
        const [dict] = reply.deepUnpack();
        const uid = dict.UnixUserID?.deepUnpack();
        const pid = dict.ProcessID?.deepUnpack();
        const credentials = {uid, pid};
        if (this._credentials.size > 64)
            this._credentials.clear();
        this._credentials.set(sender, credentials);
        return credentials;
    }

    /** Throws unless [sender] may use this service; returns its Caller. */
    async _caller(sender) {
        const {uid, pid} = await this._credentialsOf(sender);
        if (uid !== this._ownUid || !pid)
            throw new DBusError('Denied', 'caller runs as another user');
        const root = `/proc/${pid}/root`;
        if (fileIdentity(`${root}/`) !== this._ownIdentity ||
            GLib.file_test(`${root}/.flatpak-info`, GLib.FileTest.EXISTS))
            throw new DBusError('Denied', 'caller runs in a sandbox');
        const cgroup = readText(`/proc/${pid}/cgroup`) ?? '';
        if (/\bsnap\.|\/snap\./.test(cgroup) || /(^|\/)app-flatpak-/.test(cgroup))
            throw new DBusError('Denied', 'caller runs in a sandbox');
        const exe = readLink(`/proc/${pid}/exe`);
        if (!exe || exe.endsWith(' (deleted)') || !this._allowedExecutables().includes(exe))
            throw new DBusError('Denied', `caller ${exe ?? '?'} is not allowed`);
        let caller = this._callers.get(sender);
        if (!caller) {
            caller = new Caller(this, sender, pid);
            this._callers.set(sender, caller);
        }
        return caller;
    }

    callerVanished(name) {
        this._credentials.delete(name);
        const caller = this._callers.get(name);
        if (!caller)
            return;
        this._callers.delete(name);
        const monitors = [...(caller.fenceRects?.values() ?? [])];
        caller.destroy();
        const entries = [...this._staged.values()].filter(entry => entry.caller === caller);
        if (this._callers.size === 0)
            this._restoreClipboardNow();
        if (entries.length === 0)
            return;
        // Mutter takes the caller's virtual monitors away by itself and drops
        // the windows on them anywhere; they go home once the monitors are gone.
        this._monitorsGone(monitors).then(() => {
            for (const entry of entries) {
                if (this._staged.get(entry.id) === entry)
                    this._unstage(entry).catch(logError);
            }
        }).catch(logError);
    }

    /** Waits (up to [timeout] ms) until no virtual monitor covers [rects]. */
    async _monitorsGone(rects, timeout = 1500) {
        const start = now();
        while (rects.length > 0 && (now() - start) / 1000 < timeout) {
            let present = false;
            const n = global.display.get_n_monitors();
            for (let i = 0; i < n && !present; i++) {
                const geometry = global.display.get_monitor_geometry(i);
                present = this._monitorIsVirtual(i) && rects.some(rect => intersects(rect, geometry));
            }
            if (!present)
                return;
            // eslint-disable-next-line no-await-in-loop
            await delay(50);
        }
    }

    _requireUnlocked() {
        if (Main.sessionMode.isLocked)
            throw new DBusError('Locked', 'the session is locked');
    }

    /** Runs [work] for a checked caller and answers the invocation. */
    _serve(invocation, work) {
        const sender = invocation.get_sender();
        this._caller(sender).then(caller => work(caller)).then(result => {
            invocation.return_value(result ?? null);
        }).catch(e => {
            if (e instanceof DBusError) {
                invocation.return_dbus_error(e.dbusName, e.message);
            } else {
                logError(e, 'Whisper window stream');
                invocation.return_dbus_error(`${ERROR}Failed`, `${e}`);
            }
        });
    }

    /** Like _serve, but input from one caller runs strictly in order. */
    _serveInput(invocation, work) {
        this._serve(invocation, caller => {
            const run = caller.queue.then(() => work(caller));
            caller.queue = run.catch(() => {});
            return run;
        });
    }

    _emitTo(caller, name, variant) {
        try {
            Gio.DBus.session.emit_signal(caller.name, OBJECT_PATH, IFACE_NAME, name, variant);
        } catch (e) {
            logError(e, 'Whisper window stream signal');
        }
    }

    // ------------------------------------------------------------ windows

    _watchWindow(win) {
        win.connectObject(
            'unmanaged', () => {
                const id = win.get_stable_sequence();
                const entry = this._staged.get(id);
                if (entry) {
                    this._staged.delete(id);
                    this._writeJournal();
                }
                for (const caller of this._callers.values())
                    this._emitTo(caller, 'WindowGone', new GLib.Variant('(u)', [id]));
                this._windowsChanged();
            },
            'notify::title', () => this._windowsChanged(),
            'notify::minimized', () => this._windowsChanged(),
            this);
    }

    _windowsChanged() {
        if (this._changedId || this._callers.size === 0)
            return;
        this._changedId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, CHANGED_DEBOUNCE_MS, () => {
            this._changedId = 0;
            for (const caller of this._callers.values())
                this._emitTo(caller, 'WindowsChanged', null);
            return GLib.SOURCE_REMOVE;
        });
    }

    _describe(win) {
        const tracker = Shell.WindowTracker.get_default();
        const app = tracker.get_window_app(win);
        const frame = frameOf(win);
        const workspace = win.get_workspace();
        const active = global.workspace_manager.get_active_workspace();
        const v = (type, value) => new GLib.Variant(type, value);
        return {
            id: v('u', win.get_stable_sequence()),
            windowId: v('t', win.get_id()),
            title: v('s', win.get_title() ?? ''),
            appId: v('s', app && !app.is_window_backed() ? app.get_id() ?? '' : ''),
            appName: v('s', app?.get_name() ?? win.get_wm_class() ?? ''),
            wmClass: v('s', win.get_wm_class() ?? ''),
            sandboxedAppId: v('s', win.get_sandboxed_app_id() ?? ''),
            pid: v('i', win.get_pid()),
            x: v('i', frame.x),
            y: v('i', frame.y),
            width: v('i', frame.width),
            height: v('i', frame.height),
            monitor: v('i', win.get_monitor()),
            minimized: v('b', win.minimized),
            focused: v('b', win.has_focus()),
            maximized: v('b', maximizeFlags(win) === Meta.MaximizeFlags.BOTH),
            fullscreen: v('b', win.is_fullscreen()),
            onCurrentWorkspace: v('b', win.is_on_all_workspaces() || workspace === active),
            staged: v('b', this._staged.has(win.get_stable_sequence())),
            type: v('i', win.get_window_type()),
            transientFor: v('u', win.get_transient_for()?.get_stable_sequence() ?? 0),
        };
    }

    _monitorIsVirtual(index) {
        return virtualMonitors().has(index);
    }

    /** The work area of a real monitor that [rect] overlaps, or the primary one. */
    _homeArea(rect) {
        const n = global.display.get_n_monitors();
        for (let i = 0; i < n; i++) {
            if (this._monitorIsVirtual(i))
                continue;
            const area = Main.layoutManager.getWorkAreaForMonitor(i);
            if (rect && intersects(rect, area))
                return area;
        }
        return Main.layoutManager.getWorkAreaForMonitor(global.display.get_primary_monitor());
    }

    _onRealMonitor(rect) {
        const n = global.display.get_n_monitors();
        for (let i = 0; i < n; i++) {
            if (this._monitorIsVirtual(i))
                continue;
            if (intersects(rect, Main.layoutManager.getWorkAreaForMonitor(i)))
                return true;
        }
        return false;
    }

    _centredIn(area, frame) {
        const width = Math.min(frame.width, area.width);
        const height = Math.min(frame.height, area.height);
        return {
            x: Math.round(area.x + (area.width - width) / 2),
            y: Math.round(area.y + (area.height - height) / 2),
            width, height,
        };
    }

    /**
     * Waits until [win]'s frame is [target] (±2 px) or has stopped changing
     * (an app with a minimum size settles elsewhere), up to [timeout] ms.
     */
    async _settle(win, target, timeout = 1000) {
        const start = now();
        let last = frameOf(win);
        let still = 0;
        let moved = false;
        while ((now() - start) / 1000 < timeout) {
            // eslint-disable-next-line no-await-in-loop
            await delay(SETTLE_POLL_MS);
            if (!win.get_compositor_private())
                return null;
            const frame = frameOf(win);
            if (target && same(frame, target))
                return frame;
            if (!same(frame, last))
                moved = true;
            still = same(frame, last) ? still + 1 : 0;
            last = frame;
            // Close enough and no longer changing, or stopped elsewhere (an
            // app with a minimum size).
            if ((moved || !target || close(frame, target)) && still >= 3)
                break;
        }
        return frameOf(win);
    }

    /**
     * Moves [win] to [rect] and waits; asks again while it lands a pixel or
     * two off (a client changing its buffer scale on the way, a monitor
     * removed under it), so a restore is exact.
     */
    async _moveExactly(win, rect, timeout = 800) {
        let frame = null;
        for (let attempt = 0; attempt < 3; attempt++) {
            win.move_resize_frame(false, rect.x, rect.y, rect.width, rect.height);
            // eslint-disable-next-line no-await-in-loop
            frame = await this._settle(win, rect, attempt === 0 ? timeout : 400);
            if (!frame || same(frame, rect))
                break;
            // eslint-disable-next-line no-await-in-loop
            await delay(60);
        }
        return frame;
    }

    _clampToWorkArea(rect) {
        const [cx, cy] = centre(rect);
        const n = global.display.get_n_monitors();
        for (let i = 0; i < n; i++) {
            const area = Main.layoutManager.getWorkAreaForMonitor(i);
            if (!contains(area, cx, cy))
                continue;
            const x = Math.max(rect.x, area.x);
            const y = Math.max(rect.y, area.y);
            return {
                x, y,
                width: Math.max(1, Math.min(rect.x + rect.width, area.x + area.width) - x),
                height: Math.max(1, Math.min(rect.y + rect.height, area.y + area.height) - y),
            };
        }
        throw new DBusError('InvalidArgs', 'the rectangle is on no monitor');
    }

    async _stage(caller, id, rect) {
        const win = findWindow(id);
        if (!win || !isListed(win))
            throw new DBusError('NotFound', `no window ${id}`);
        if (!win.allows_move())
            throw new DBusError('Refused', 'the window cannot be moved');
        const target = this._clampToWorkArea(rect);
        let entry = this._staged.get(id);
        if (entry && entry.caller !== caller)
            throw new DBusError('Busy', 'the window is staged by another caller');
        if (!entry) {
            const flags = maximizeFlags(win);
            const workspace = win.get_workspace();
            entry = {
                id, win, caller,
                original: {
                    frame: frameOf(win),
                    floating: frameOf(win),
                    maximized: flags,
                    fullscreen: win.is_fullscreen(),
                    minimized: win.minimized,
                    sticky: win.is_on_all_workspaces(),
                    workspace: workspace ? workspace.index() : -1,
                    above: win.is_above(),
                },
            };
            this._staged.set(id, entry);
            this._writeJournal();
            if (entry.original.minimized)
                win.unminimize();
            if (entry.original.fullscreen) {
                win.unmake_fullscreen();
                await this._settle(win, null, 1500);
            }
            if (flags !== 0) {
                unmaximize(win);
                await this._settle(win, null, 1000);
            }
            // The size it has when not maximized: where it goes back to
            // before being maximized again.
            entry.original.floating = frameOf(win);
            if (!this._onRealMonitor(entry.original.floating))
                entry.original.floating = this._centredIn(this._homeArea(null), entry.original.floating);
            if (entry.original.above)
                win.unmake_above();
            // On every workspace while away, so switching workspaces on the
            // real screen never hides (and freezes) it.
            if (!entry.original.sticky)
                win.stick();
            this._writeJournal();
        }
        if (!this._staged.has(id))
            throw new DBusError('NotFound', 'the window went away');
        // The devices exist before the first event: a keyboard added to the
        // seat at the moment of a key press loses that key.
        caller.pointerDevice();
        caller.keyboardDevice();
        entry.target = target;
        // Asked again when it lands short: a GTK 4 window keeps the size
        // bounds of the monitor it came from for its first configure.
        const settled = await this._moveExactly(win, target, 1000);
        if (!settled)
            throw new DBusError('NotFound', 'the window went away');
        return new GLib.Variant('(iiiii)',
            [settled.x, settled.y, settled.width, settled.height, win.get_monitor()]);
    }

    /** Puts a staged window back exactly as it was. */
    async _unstage(entry) {
        this._staged.delete(entry.id);
        this._writeJournal();
        const win = entry.win;
        if (!win.get_compositor_private())
            return false;
        const o = entry.original;
        if (!o.sticky) {
            win.unstick();
            const count = global.workspace_manager.get_n_workspaces();
            if (o.workspace >= 0 && o.workspace < count)
                win.change_workspace_by_index(o.workspace, false);
        }
        const home = this._onRealMonitor(o.floating) ? o.floating : this._centredIn(this._homeArea(null), o.floating);
        await this._moveExactly(win, home, 800);
        if (!win.get_compositor_private())
            return false;
        if (o.maximized)
            maximize(win, o.maximized);
        if (o.fullscreen)
            win.make_fullscreen();
        if (o.above)
            win.make_above();
        if (o.minimized)
            win.minimize();
        return true;
    }

    /** Synchronous variant for shutdown: no waiting for the client. */
    _restoreNow(entry) {
        const win = entry.win;
        if (!win.get_compositor_private())
            return;
        const o = entry.original;
        if (!o.sticky)
            win.unstick();
        const home = this._onRealMonitor(o.floating) ? o.floating : this._centredIn(this._homeArea(null), o.floating);
        win.move_resize_frame(false, home.x, home.y, home.width, home.height);
        if (o.maximized)
            maximize(win, o.maximized);
        if (o.fullscreen)
            win.make_fullscreen();
        if (o.above)
            win.make_above();
        if (o.minimized)
            win.minimize();
    }

    _writeJournal() {
        const windows = {};
        for (const [id, entry] of this._staged)
            windows[id] = entry.original;
        try {
            const dir = GLib.path_get_dirname(this._journalPath);
            GLib.mkdir_with_parents(dir, 0o700);
            const text = JSON.stringify({shellPid: new Gio.Credentials().get_unix_pid(), windows});
            GLib.file_set_contents(this._journalPath, text);
        } catch (e) {
            logError(e, 'Whisper window stream journal');
        }
    }

    /** Windows a previous instance of this extension (same shell) left staged. */
    _recoverJournal() {
        const text = readText(this._journalPath);
        if (!text)
            return;
        try {
            const journal = JSON.parse(text);
            if (journal.shellPid !== new Gio.Credentials().get_unix_pid())
                return;
            for (const [id, original] of Object.entries(journal.windows ?? {})) {
                const win = findWindow(Number(id));
                if (win)
                    this._restoreNow({id: Number(id), win, original});
            }
        } catch (e) {
            logError(e, 'Whisper window stream journal');
        }
        this._writeJournal();
    }

    _evict(rect, keepId) {
        const keep = findWindow(keepId);
        const keepPid = keep?.get_pid() ?? -1;
        const area = this._homeArea(null);
        let moved = 0;
        for (const win of allWindows()) {
            if (!isListed(win) || win === keep || this._staged.has(win.get_stable_sequence()))
                continue;
            if (win.get_pid() === keepPid || (keep && keep.is_ancestor_of_transient(win)))
                continue;
            const frame = frameOf(win);
            const [cx, cy] = centre(frame);
            if (!contains(rect, cx, cy))
                continue;
            if (win.minimized)
                continue;
            const dest = this._centredIn(area, frame);
            win.move_resize_frame(false, dest.x, dest.y, dest.width, dest.height);
            moved++;
        }
        return moved;
    }

    // ------------------------------------------------------------ fences

    _barriersAround(rect) {
        const backend = global.backend;
        const make = (x1, y1, x2, y2, directions) => new Meta.Barrier({backend, x1, y1, x2, y2, directions});
        const {x, y, width: w, height: h} = rect;
        // Each edge lets the pointer leave the rectangle but not come in. A
        // blocked pointer stops on the barrier's line, so the left and top
        // lines sit one pixel outside: the cursor stays on the user's screen.
        const barriers = [
            make(x + w, y, x + w, y + h, Meta.BarrierDirection.POSITIVE_X),
            make(x, y + h, x + w, y + h, Meta.BarrierDirection.POSITIVE_Y),
        ];
        // (Coordinates cannot be negative; nothing lies beyond 0 anyway.)
        if (x > 0)
            barriers.push(make(x - 1, y, x - 1, y + h, Meta.BarrierDirection.NEGATIVE_X));
        if (y > 0)
            barriers.push(make(x, y - 1, x + w, y - 1, Meta.BarrierDirection.NEGATIVE_Y));
        return barriers;
    }

    _setFence(caller, rect, on) {
        const key = rectKey(rect);
        const existing = caller.fences.get(key);
        if (on) {
            if (existing)
                return;
            caller.fences.set(key, caller.fencesLifted ? [] : this._barriersAround(rect));
            caller.fenceRects = caller.fenceRects ?? new Map();
            caller.fenceRects.set(key, rect);
        } else if (existing) {
            existing.forEach(b => b.destroy());
            caller.fences.delete(key);
            caller.fenceRects?.delete(key);
        }
    }

    /**
     * Barriers stop the synthetic pointer too (in both directions): they
     * are off while it works. The input thread drops them a moment later,
     * so the first event waits for that.
     */
    async _liftFences(caller) {
        if (caller.armTimer) {
            GLib.source_remove(caller.armTimer);
            caller.armTimer = 0;
        }
        if (caller.fencesLifted)
            return;
        caller.fencesLifted = true;
        let any = false;
        for (const [key, barriers] of caller.fences) {
            any ||= barriers.length > 0;
            barriers.forEach(b => b.destroy());
            caller.fences.set(key, []);
        }
        if (any)
            await delay(FENCE_SETTLE_MS);
    }

    _armFences(caller) {
        if (!caller.fencesLifted)
            return;
        caller.fencesLifted = false;
        for (const key of caller.fences.keys())
            caller.fences.set(key, this._barriersAround(caller.fenceRects.get(key)));
    }

    _insideFence(caller, x, y) {
        for (const rect of caller.fenceRects?.values() ?? []) {
            if (contains(rect, x, y))
                return true;
        }
        return false;
    }

    // ------------------------------------------------------------ input

    async _pointer(caller, kind, button, x, y) {
        this._requireUnlocked();
        const device = caller.pointerDevice();
        const [px, py] = global.get_pointer();
        if (!caller.home && !this._insideFence(caller, px, py))
            caller.home = [px, py];
        await this._liftFences(caller);
        device.notify_absolute_motion(now(), x, y);
        const code = button === 1 ? BUTTON_SECONDARY : button === 2 ? BUTTON_MIDDLE : BUTTON_PRIMARY;
        if (kind === POINTER_DOWN) {
            if (!caller.buttons.has(code)) {
                device.notify_button(now(), code, Clutter.ButtonState.PRESSED);
                caller.buttons.add(code);
            }
        } else if (kind === POINTER_UP || kind === POINTER_CANCEL) {
            for (const held of [...caller.buttons]) {
                device.notify_button(now(), held, Clutter.ButtonState.RELEASED);
                caller.buttons.delete(held);
            }
        } else if (kind !== POINTER_MOVE) {
            throw new DBusError('InvalidArgs', `pointer kind ${kind}`);
        }
    }

    async _scroll(caller, x, y, dx, dy, source, finish) {
        this._requireUnlocked();
        const device = caller.pointerDevice();
        const [px, py] = global.get_pointer();
        if (!caller.home && !this._insideFence(caller, px, py))
            caller.home = [px, py];
        await this._liftFences(caller);
        device.notify_absolute_motion(now(), x, y);
        if (source === Clutter.ScrollSource.WHEEL) {
            // Clicks of the wheel; positive dy scrolls down.
            const steps = (count, positive, negative) => {
                for (let i = 0; i < Math.min(Math.abs(count), 20); i++)
                    device.notify_discrete_scroll(now(), count > 0 ? positive : negative, source);
            };
            steps(Math.round(dy), Clutter.ScrollDirection.DOWN, Clutter.ScrollDirection.UP);
            steps(Math.round(dx), Clutter.ScrollDirection.RIGHT, Clutter.ScrollDirection.LEFT);
        } else {
            // Pixels; positive dy scrolls down. The end of a gesture goes
            // as its own event, after the last movement.
            const kind = source === Clutter.ScrollSource.FINGER ? Clutter.ScrollSource.FINGER
                : Clutter.ScrollSource.CONTINUOUS;
            if (dx !== 0 || dy !== 0)
                device.notify_scroll_continuous(now(), dx, dy, kind, Clutter.ScrollFinishFlags.NONE);
            if (finish) {
                device.notify_scroll_continuous(now(), 0, 0, kind,
                    Clutter.ScrollFinishFlags.HORIZONTAL | Clutter.ScrollFinishFlags.VERTICAL);
            }
        }
    }

    _key(caller, evdev, down) {
        this._requireUnlocked();
        const device = caller.keyboardDevice();
        if (down) {
            caller.keys.add(evdev);
        } else {
            if (!caller.keys.has(evdev))
                return;
            caller.keys.delete(evdev);
        }
        device.notify_key(now(), evdev, down ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED);
    }

    _keyval(caller, keysym, down) {
        this._requireUnlocked();
        const device = caller.keyboardDevice();
        if (down) {
            caller.keyvals.add(keysym);
        } else {
            if (!caller.keyvals.has(keysym))
                return;
            caller.keyvals.delete(keysym);
        }
        device.notify_keyval(now(), keysym, down ? Clutter.KeyState.PRESSED : Clutter.KeyState.RELEASED);
    }

    async _text(caller, text) {
        this._requireUnlocked();
        const value = text.replace(/\r\n?/g, '\n');
        if (!value)
            return 'none';
        // A text field has the focus: hand the text over the way the input
        // method does; any script and any keyboard layout.
        if (Main.inputMethod.currentFocus) {
            const lines = value.split('\n');
            const device = caller.keyboardDevice();
            lines.forEach((line, index) => {
                if (index > 0) {
                    device.notify_key(now(), KEY_ENTER, Clutter.KeyState.PRESSED);
                    device.notify_key(now(), KEY_ENTER, Clutter.KeyState.RELEASED);
                }
                if (line)
                    Main.inputMethod.commit(line);
            });
            return 'commit';
        }
        // No input-method client (a terminal, an X11 app): plain ASCII goes
        // as keys, anything else is pasted.
        // eslint-disable-next-line no-control-regex
        if (/^[\x20-\x7e\n\t]*$/.test(value)) {
            const device = caller.keyboardDevice();
            for (const ch of value) {
                const keyval = ch === '\n' ? Clutter.KEY_Return
                    : ch === '\t' ? Clutter.KEY_Tab : Clutter.unicode_to_keysym(ch.codePointAt(0));
                device.notify_keyval(now(), keyval, Clutter.KeyState.PRESSED);
                device.notify_keyval(now(), keyval, Clutter.KeyState.RELEASED);
            }
            return 'keys';
        }
        await this._paste(caller, value);
        return 'paste';
    }

    _clipboardContent(type) {
        const clipboard = St.Clipboard.get_default();
        const mimetypes = clipboard.get_mimetypes(type);
        const mimetype = mimetypes.find(m => m.startsWith('text/plain')) ?? mimetypes[0];
        if (!mimetype)
            return Promise.resolve(null);
        return new Promise(resolve => {
            clipboard.get_content(type, mimetype, (_c, bytes) => resolve(bytes ? {mimetype, bytes} : null));
        });
    }

    async _paste(caller, value) {
        const clipboard = St.Clipboard.get_default();
        const type = St.ClipboardType.CLIPBOARD;
        if (!this._clipboardRestore) {
            // What the user had copied, to put back afterwards; an owner that
            // does not answer quickly is left alone (nothing is restored).
            const previous = await Promise.race([
                this._clipboardContent(type).catch(() => null),
                delay(CLIPBOARD_READ_MS).then(() => ({unknown: true})),
            ]);
            this._clipboardRestore = {previous, timer: 0};
        }
        clipboard.set_text(type, value);
        const device = caller.keyboardDevice();
        device.notify_key(now(), KEY_LEFTCTRL, Clutter.KeyState.PRESSED);
        device.notify_key(now(), KEY_V, Clutter.KeyState.PRESSED);
        device.notify_key(now(), KEY_V, Clutter.KeyState.RELEASED);
        device.notify_key(now(), KEY_LEFTCTRL, Clutter.KeyState.RELEASED);
        // The app reads the clipboard after the key: give it a moment, then
        // put back what the user had copied.
        const restore = this._clipboardRestore;
        if (restore.timer)
            GLib.source_remove(restore.timer);
        restore.timer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 800, () => {
            restore.timer = 0;
            this._restoreClipboardNow();
            return GLib.SOURCE_REMOVE;
        });
    }

    _restoreClipboardNow() {
        const restore = this._clipboardRestore;
        if (!restore)
            return;
        this._clipboardRestore = null;
        if (restore.timer)
            GLib.source_remove(restore.timer);
        const clipboard = St.Clipboard.get_default();
        if (restore.previous?.unknown)
            return;
        if (restore.previous)
            clipboard.set_content(St.ClipboardType.CLIPBOARD, restore.previous.mimetype, restore.previous.bytes);
        else
            clipboard.set_text(St.ClipboardType.CLIPBOARD, '');
    }

    _warpHome(caller) {
        if (caller.buttons.size > 0)
            return;
        const home = caller.home;
        caller.home = null;
        if (home) {
            const [px, py] = global.get_pointer();
            if (this._insideFence(caller, px, py)) {
                const seat = defaultSeat();
                seat.warp_pointer(home[0], home[1]);
            }
        }
        // Fences return once the warp has gone through (barriers would
        // catch it on the way out).
        if (caller.armTimer)
            GLib.source_remove(caller.armTimer);
        caller.armTimer = GLib.timeout_add(GLib.PRIORITY_DEFAULT, FENCE_SETTLE_MS * 3, () => {
            caller.armTimer = 0;
            if (caller.buttons.size === 0 && this._callers.get(caller.name) === caller)
                this._armFences(caller);
            return GLib.SOURCE_REMOVE;
        });
    }

    // ------------------------------------------------------------ text focus

    _checkTextFocus() {
        if (this._callers.size === 0)
            return;
        const focus = global.display.focus_window;
        let staged = null;
        for (let win = focus; win && !staged; win = win.get_transient_for())
            staged = this._staged.get(win.get_stable_sequence()) ?? null;
        const typing = !!staged && !!Main.inputMethod.currentFocus;
        for (const caller of this._callers.values()) {
            const mine = staged && staged.caller === caller;
            const state = {id: mine ? staged.id : 0, focused: mine ? typing : false};
            if (state.id === caller.textFocus.id && state.focused === caller.textFocus.focused)
                continue;
            const previous = caller.textFocus;
            caller.textFocus = state;
            if (previous.id && previous.id !== state.id && previous.focused)
                this._emitTo(caller, 'TextFocus', new GLib.Variant('(ub)', [previous.id, false]));
            if (state.id)
                this._emitTo(caller, 'TextFocus', new GLib.Variant('(ub)', [state.id, state.focused]));
        }
        this._scheduleTextFocusPoll();
    }

    /** The input method says little when focus moves inside a window: poll while anything is staged. */
    _scheduleTextFocusPoll() {
        if (this._textFocusId || this._staged.size === 0)
            return;
        this._textFocusId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, TEXT_FOCUS_POLL_MS, () => {
            this._textFocusId = 0;
            this._checkTextFocus();
            return GLib.SOURCE_REMOVE;
        });
    }

    // ------------------------------------------------------------ thumbnails

    async _thumbnail(id, maxEdge) {
        const win = findWindow(id);
        const actor = win?.get_compositor_private();
        // Only windows the list offers (no menus, tooltips or shell surfaces).
        if (!win || !actor || !isListed(win))
            throw new DBusError('NotFound', `no window ${id}`);
        const content = actor.paint_to_content(null);
        const texture = content?.get_texture();
        if (!texture)
            throw new DBusError('Failed', 'the window has no picture (minimized?)');
        // The texture is the client's buffer (shadows included) at its own
        // scale: crop it to the frame.
        const buffer = win.get_buffer_rect();
        const frame = win.get_frame_rect();
        const scale = buffer.width > 0 ? texture.get_width() / buffer.width : 1;
        const crop = [
            Math.round((frame.x - buffer.x) * scale), Math.round((frame.y - buffer.y) * scale),
            Math.round(frame.width * scale), Math.round(frame.height * scale),
        ];
        const stream = Gio.MemoryOutputStream.new_resizable();
        const pixbuf = await new Promise((resolve, reject) => {
            Shell.Screenshot.composite_to_stream(texture, ...crop, 1, null, 0, 0, 1, stream,
                (_o, result) => {
                    try {
                        resolve(Shell.Screenshot.composite_to_stream_finish(result));
                    } catch (e) {
                        reject(e);
                    }
                });
        });
        stream.close(null);
        let image = pixbuf;
        const edge = Math.max(pixbuf.get_width(), pixbuf.get_height());
        if (maxEdge > 0 && edge > maxEdge) {
            const ratio = maxEdge / edge;
            image = pixbuf.scale_simple(Math.max(1, Math.round(pixbuf.get_width() * ratio)),
                Math.max(1, Math.round(pixbuf.get_height() * ratio)), GdkPixbuf.InterpType.BILINEAR);
        }
        if (image.get_has_alpha()) {
            // JPEG has no alpha: flatten onto white.
            const flat = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, false, 8,
                image.get_width(), image.get_height());
            flat.fill(0xffffffff);
            image.composite(flat, 0, 0, image.get_width(), image.get_height(), 0, 0, 1, 1,
                GdkPixbuf.InterpType.NEAREST, 255);
            image = flat;
        }
        const [ok, bytes] = image.save_to_bufferv('jpeg', ['quality'], ['80']);
        if (!ok)
            throw new DBusError('Failed', 'could not encode the thumbnail');
        return new GLib.Variant('(ay)', [bytes]);
    }

    // ------------------------------------------------------------ D-Bus methods

    GetInfoAsync(_params, invocation) {
        this._serve(invocation, () => new GLib.Variant('(a{sv})', [{
            version: new GLib.Variant('u', PROTOCOL_VERSION),
            shell: new GLib.Variant('s', Config.PACKAGE_VERSION),
            locked: new GLib.Variant('b', Main.sessionMode.isLocked),
            pid: new GLib.Variant('u', new Gio.Credentials().get_unix_pid()),
            pointer: new GLib.Variant('(ii)', global.get_pointer().slice(0, 2)),
            focusWindow: new GLib.Variant('u', global.display.focus_window?.get_stable_sequence() ?? 0),
            textInput: new GLib.Variant('b', !!Main.inputMethod.currentFocus),
        }]));
    }

    ListWindowsAsync(_params, invocation) {
        this._serve(invocation, () => {
            // Window titles are the desktop's content too: none while locked
            // (the error tells Whisper the session is locked).
            this._requireUnlocked();
            const windows = allWindows().filter(isListed).map(w => this._describe(w));
            return new GLib.Variant('(aa{sv}a{sv})', [windows, {
                locked: new GLib.Variant('b', Main.sessionMode.isLocked),
                activeWorkspace: new GLib.Variant('i', global.workspace_manager.get_active_workspace_index()),
            }]);
        });
    }

    StageAsync([id, x, y, width, height], invocation) {
        this._serve(invocation, caller => {
            this._requireUnlocked();
            if (width <= 0 || height <= 0)
                throw new DBusError('InvalidArgs', 'empty rectangle');
            return this._stage(caller, id, {x, y, width, height}).then(result => {
                this._checkTextFocus();
                return result;
            });
        });
    }

    UnstageAsync([id], invocation) {
        this._serve(invocation, async caller => {
            const entry = this._staged.get(id);
            if (!entry || entry.caller !== caller)
                return new GLib.Variant('(b)', [false]);
            const restored = await this._unstage(entry);
            this._checkTextFocus();
            return new GLib.Variant('(b)', [restored]);
        });
    }

    ActivateAsync([id], invocation) {
        this._serve(invocation, () => {
            this._requireUnlocked();
            const win = findWindow(id);
            if (!win)
                throw new DBusError('NotFound', `no window ${id}`);
            if (win.has_focus())
                return new GLib.Variant('(b)', [false]);
            if (win.minimized)
                win.unminimize();
            win.activate(global.display.get_current_time_roundtrip());
            return new GLib.Variant('(b)', [true]);
        });
    }

    UnminimizeAsync([id], invocation) {
        this._serve(invocation, () => {
            const win = findWindow(id);
            if (!win)
                throw new DBusError('NotFound', `no window ${id}`);
            win.unminimize();
        });
    }

    CloseAsync([id], invocation) {
        this._serve(invocation, () => {
            this._requireUnlocked();
            const win = findWindow(id);
            if (!win || !isListed(win))
                throw new DBusError('NotFound', `no window ${id}`);
            if (win.can_close())
                win.delete(global.display.get_current_time_roundtrip());
        });
    }

    EvictStrangersAsync([x, y, width, height, keepId], invocation) {
        this._serve(invocation, () =>
            new GLib.Variant('(u)', [this._evict({x, y, width, height}, keepId)]));
    }

    SetFenceAsync([x, y, width, height, on], invocation) {
        this._serve(invocation, caller => {
            if (width <= 0 || height <= 0)
                throw new DBusError('InvalidArgs', 'empty rectangle');
            this._setFence(caller, {x, y, width, height}, on);
        });
    }

    PointerAsync([kind, button, x, y], invocation) {
        this._serveInput(invocation, caller => this._pointer(caller, kind, button, x, y));
    }

    ScrollAsync([x, y, dx, dy, source, finish], invocation) {
        this._serveInput(invocation, caller => this._scroll(caller, x, y, dx, dy, source, finish));
    }

    KeyAsync([evdev, down], invocation) {
        this._serveInput(invocation, caller => this._key(caller, evdev, down));
    }

    KeyvalAsync([keysym, down], invocation) {
        this._serveInput(invocation, caller => this._keyval(caller, keysym, down));
    }

    TextAsync([text], invocation) {
        this._serveInput(invocation, async caller =>
            new GLib.Variant('(s)', [await this._text(caller, text)]));
    }

    WarpHomeAsync(_params, invocation) {
        this._serveInput(invocation, caller => this._warpHome(caller));
    }

    ReleaseInputAsync(_params, invocation) {
        this._serveInput(invocation, caller => {
            caller.releaseInput();
            this._warpHome(caller);
        });
    }

    ThumbnailAsync([id, maxEdge], invocation) {
        this._serve(invocation, () => {
            // Nothing of the desktop leaves it while it is locked.
            this._requireUnlocked();
            return this._thumbnail(id, maxEdge);
        });
    }
}

export default class WhisperWindowStreamExtension extends Extension {
    enable() {
        this._service = new WindowStreamService(this);
    }

    disable() {
        this._service?.destroy();
        this._service = null;
    }
}
