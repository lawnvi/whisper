// The KWin script capture/kwin_helper.cc loads into KWin: KWin's half of
// window flow on KDE Plasma. Only a KWin script may move, resize and focus
// other apps' windows there.
//
// It holds no D-Bus service of its own (scripts cannot): it calls Whisper's
// Poll with the answer to the last command and gets the next one back, so
// commands flow with one round trip each (about 2 ms). Events (a window
// closed or became active) go to Event. `%SERVICE%` becomes the capture
// side's bus name.
//
// Values are D-Bus a{sv} both ways; nothing here may be null or undefined
// (KWin could not send it).
//
// Windows Whisper moved onto its virtual outputs are remembered with how
// they were; they go back when asked, and when such an output disappears
// without asking (Whisper quit or crashed: KWin moves the window back onto
// a real output, this puts its borders, desktops and state back too).

#ifndef WSN_CAPTURE_KWIN_SCRIPT_H_
#define WSN_CAPTURE_KWIN_SCRIPT_H_

namespace wsn::capture {

constexpr int kKWinScriptVersion = 1;

constexpr const char* kKWinScript = R"JS(
const service = "%SERVICE%";
const path = "/com/vireen/Whisper/KWin";
const iface = "com.vireen.Whisper.KWin1";
const ours = "Virtual-Whisper-";

let nextId = 1;
const ids = new Map();      // internalId -> id
const windows = new Map();  // id -> window
const staged = new Map();   // id -> how it was

function idOf(w) {
    const key = w.internalId.toString();
    let id = ids.get(key);
    if (id === undefined) {
        id = nextId++;
        ids.set(key, id);
        windows.set(id, w);
    }
    return id;
}

function listed(w) {
    return w.managed && !w.deleted && (w.normalWindow || w.dialog || w.utility);
}

function rectOf(r) {
    return {x: Math.round(r.x), y: Math.round(r.y), width: Math.round(r.width), height: Math.round(r.height)};
}

function centre(r) {
    return [r.x + r.width / 2, r.y + r.height / 2];
}

function contains(r, x, y) {
    return x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
}

function isOurs(output) {
    return !!output && output.name.indexOf(ours) === 0;
}

function screenAt(x, y) {
    return workspace.screens.find(s => contains(s.geometry, x, y)) || null;
}

function realScreens() {
    return workspace.screens.filter(s => !isOurs(s));
}

function onReal(r) {
    const [cx, cy] = centre(r);
    return realScreens().some(s => contains(s.geometry, cx, cy));
}

function homeArea() {
    const active = workspace.activeScreen;
    if (active && !isOurs(active))
        return active.geometry;
    const real = realScreens();
    return real.length ? real[0].geometry : {x: 0, y: 0, width: 1280, height: 800};
}

function centredIn(area, r) {
    const width = Math.min(r.width, area.width);
    const height = Math.min(r.height, area.height);
    return {
        x: Math.round(area.x + (area.width - width) / 2),
        y: Math.round(area.y + (area.height - height) / 2),
        width, height,
    };
}

function typeOf(w) {
    if (w.normalWindow)
        return 0;
    if (w.dialog)
        return w.modal ? 4 : 3;
    return 7;
}

function describe(w) {
    const f = rectOf(w.frameGeometry);
    const desktop = workspace.currentDesktop;
    return {
        id: idOf(w),
        uuid: w.internalId.toString(),
        title: w.caption || "",
        desktopFile: w.desktopFileName || "",
        resourceClass: w.resourceClass || "",
        pid: w.pid,
        x: f.x, y: f.y, width: f.width, height: f.height,
        output: w.output ? w.output.name : "",
        minimized: w.minimized,
        focused: w.active,
        maximized: w.maximizeMode === 3,
        fullscreen: w.fullScreen,
        onCurrentDesktop: w.onAllDesktops || w.desktops.indexOf(desktop) >= 0,
        staged: staged.has(idOf(w)),
        type: typeOf(w),
        transientFor: w.transient && w.transientFor ? idOf(w.transientFor) : 0,
    };
}

function find(id) {
    const w = windows.get(id);
    return w && !w.deleted ? w : null;
}

function restore(w, o) {
    w.noBorder = o.noBorder;
    w.onAllDesktops = o.allDesktops;
    if (!o.allDesktops && o.desktops.length)
        w.desktops = o.desktops;
    w.frameGeometry = onReal(o.frame) ? o.frame : centredIn(homeArea(), o.frame);
    if (o.maximize)
        w.setMaximize((o.maximize & 1) !== 0, (o.maximize & 2) !== 0);
    if (o.fullScreen)
        w.fullScreen = true;
    if (o.keepAbove)
        w.keepAbove = true;
    if (o.minimized)
        w.minimized = true;
}

function stage(c) {
    const w = find(c.id);
    if (!w || !listed(w))
        return {error: "NotFound"};
    if (!w.moveable)
        return {error: "Refused"};
    let o = staged.get(c.id);
    if (!o) {
        const f = rectOf(w.frameGeometry);
        const target = screenAt(c.x + c.width / 2, c.y + c.height / 2);
        o = {
            frame: f,
            maximize: w.maximizeMode,
            fullScreen: w.fullScreen,
            minimized: w.minimized,
            noBorder: w.noBorder,
            allDesktops: w.onAllDesktops,
            desktops: w.desktops,
            keepAbove: w.keepAbove,
            output: target ? target.name : "",
        };
        staged.set(c.id, o);
        if (w.minimized)
            w.minimized = false;
        if (w.fullScreen)
            w.fullScreen = false;
        if (w.maximizeMode)
            w.setMaximize(false, false);
        if (w.keepAbove)
            w.keepAbove = false;
        // On every desktop while away, so switching desktops here never
        // hides (and freezes) it; no border, the viewer has its own frame.
        if (!w.onAllDesktops)
            w.onAllDesktops = true;
        w.noBorder = true;
    }
    w.frameGeometry = {x: c.x, y: c.y, width: c.width, height: c.height};
    return rectOf(w.frameGeometry);
}

function unstage(c) {
    const o = staged.get(c.id);
    staged.delete(c.id);
    const w = find(c.id);
    if (!o || !w)
        return {restored: false};
    restore(w, o);
    return {restored: true};
}

function evict(c) {
    const keep = find(c.keep);
    const area = homeArea();
    let moved = 0;
    for (const w of workspace.windowList()) {
        if (!listed(w) || w === keep || staged.has(idOf(w)) || w.minimized)
            continue;
        if (keep && w.pid === keep.pid)
            continue;
        let parent = w.transientFor;
        let mine = false;
        while (parent && !mine) {
            mine = parent === keep;
            parent = parent.transientFor;
        }
        if (mine)
            continue;
        const f = rectOf(w.frameGeometry);
        const [cx, cy] = centre(f);
        if (!contains(c, cx, cy))
            continue;
        w.frameGeometry = centredIn(area, f);
        moved++;
    }
    return {moved};
}

function run(c) {
    switch (c.op) {
    case "hello":
        return {version: %VERSION%};
    case "list":
        return {windows: workspace.windowList().filter(listed).map(describe)};
    case "get": {
        const w = find(c.id);
        return w ? describe(w) : {error: "NotFound"};
    }
    case "stage":
        return stage(c);
    case "unstage":
        return unstage(c);
    case "activate": {
        const w = find(c.id);
        if (!w)
            return {error: "NotFound"};
        if (workspace.activeWindow !== w)
            workspace.activeWindow = w;
        return {active: workspace.activeWindow === w};
    }
    case "unminimize": {
        const w = find(c.id);
        if (w)
            w.minimized = false;
        return {};
    }
    case "close": {
        const w = find(c.id);
        if (w)
            w.closeWindow();
        return {};
    }
    case "evict":
        return evict(c);
    case "cursor": {
        const p = workspace.cursorPos;
        return {x: p.x, y: p.y, ours: isOurs(screenAt(p.x, p.y))};
    }
    case "restoreAll":
        for (const [id, o] of staged) {
            const w = find(id);
            if (w)
                restore(w, o);
        }
        staged.clear();
        return {};
    case "nop":
        return {};
    }
    return {error: "UnknownOp"};
}

function poll(reply) {
    callDBus(service, path, iface, "Poll", reply, function (command) {
        let answer;
        try {
            answer = run(command);
        } catch (e) {
            answer = {error: String(e)};
        }
        answer.re = command.seq || 0;
        poll(answer);
    });
}

function send(event) {
    callDBus(service, path, iface, "Event", event);
}

workspace.windowRemoved.connect(w => {
    const key = w.internalId.toString();
    const id = ids.get(key);
    if (id === undefined)
        return;
    ids.delete(key);
    windows.delete(id);
    staged.delete(id);
    send({type: "gone", id});
});

workspace.windowActivated.connect(w => {
    send({type: "active", id: w ? idOf(w) : 0});
});

// Our output went away with windows still on it: Whisper is gone (KWin
// has moved them back to a real output by now, or does so next).
workspace.screensChanged.connect(() => {
    const names = workspace.screens.map(s => s.name);
    for (const [id, o] of staged) {
        if (names.indexOf(o.output) >= 0)
            continue;
        const w = find(id);
        staged.delete(id);
        if (w)
            restore(w, o);
    }
});

poll({hello: true, re: 0});
)JS";

}  // namespace wsn::capture

#endif  // WSN_CAPTURE_KWIN_SCRIPT_H_
