# Keyboard And Mouse Sharing Design

## Goal

Build keyboard and mouse sharing between the currently connected trusted desktop devices. The first version should feel like a lightweight Barrier or Synergy workflow: arrange devices visually, enable sharing, move the pointer through a configured screen edge, and have keyboard focus follow the pointer to the remote device.

## Confirmed Scope

- Use a dedicated screen arrangement canvas, similar to operating system multi-display settings.
- Support all four screen edges: left, right, top, and bottom.
- Keyboard input follows the remote pointer focus.
- Implement macOS, Windows, and Linux behind the same Dart-facing interface.
- First runtime version controls only the currently connected peer.
- Store layout data in a structure that can support multiple peers later.
- Default startup is manual. Per trusted peer, settings can enable automatic activation after connection.
- Only mutually trusted devices can use remote input. Trusted peers auto-accept by default, with visible status and a stop control on both devices.
- Release paths are required: reverse edge traversal, a force-release hotkey, connection loss, errors, and app shutdown.

## Recommended Approach

Reuse the existing audio-sharing architecture:

- Control messages use the existing chat WebSocket connection.
- Realtime input events use a dedicated `/input` WebSocket.
- Dart owns protocol objects, session state, layout persistence, trust checks, and UI state.
- Native platform code owns global input capture, input injection, pointer edge behavior, and release handling.

This fits the current project better than sending high-frequency events through the chat stream or building a separate native peer service. It keeps realtime traffic isolated without bypassing the app's existing device, trust, and connection model.

## User Experience

### Screen Arrangement

Add a keyboard and mouse sharing settings entry that opens a screen arrangement canvas. The canvas shows:

- The local device as the primary blue screen block.
- The currently connected peer as a draggable screen block.
- Existing saved peer layouts when available.
- Edge adjacency implied by screen block placement.

Users can drag a peer above, below, left, or right of the local screen, including partial offsets. Adjacent screen edges become traversal edges. Saving the layout persists the peer's placement and sharing preferences.

### Runtime Controls

Add a keyboard and mouse sharing button in the conversation header when the current peer is connected and both sides support remote input. The button states are:

- Idle: sharing is available but not active.
- Armed: edge detection is enabled, but focus is still local.
- Active source: this device is sending keyboard and mouse events to the peer.
- Active sink: this device is receiving and injecting keyboard and mouse events.
- Failed: the session stopped because of an error.

Both sides must provide a visible stop action while any remote input state is armed or active.

### Automatic Activation

By default, connecting to a peer does not enable edge traversal. In the peer settings screen, a trusted device can opt into automatic keyboard and mouse sharing activation after connection. Automatic activation means "armed", not immediately remote-controlled: focus stays local until the pointer crosses a configured edge.

## Persistence

Persist remote input settings separately from chat messages and file transfer records. The implementation will use Drift so the layout is queryable and stable across devices and app restarts.

Stored fields:

- `peerId`: stable peer uid.
- `peerName`: display-name snapshot for offline layout screens.
- `x`, `y`, `width`, `height`: peer screen rectangle in layout coordinates.
- `enabled`: whether edge traversal is enabled for the peer.
- `autoActivate`: whether sharing arms automatically after connection.
- `edgeThresholdPx`: pointer distance threshold for traversal.
- `releaseHotkey`: serialized force-release shortcut, defaulting to `Ctrl+Alt+Esc`.
- `updatedAt`: last modification timestamp.

The first runtime version uses only the current connected peer, even if the storage model contains multiple rows.

## Protocol

### Control

Add a new `MessageEnum.RemoteInputControl` value after existing enum values for backward compatibility.

Create `RemoteInputControlMessage` with:

- `action`: `offer`, `accept`, `reject`, `stop`, or `error`.
- `sessionId`: unique session id.
- `sourcePeerId`: peer capturing local input.
- `sinkPeerId`: peer injecting input.
- `transport`: `websocket`.
- `path`: default `/input`.
- `layoutEdge`: edge that started the session when relevant.
- `releaseHotkey`: force-release shortcut negotiated for status display.
- `errorMessage`: human-readable error text for `error`.

Only mutually trusted peers with `remoteInputSourceV1` and `remoteInputSinkV1` can create or accept remote input sessions.

### Realtime Packets

Create `RemoteInputPacketFrame` as a binary frame with:

- Magic header `WRI1`.
- Header JSON length.
- Header JSON with `sessionId`, `sequence`, `timestampMicros`, `eventType`, and `payloadLength`.
- Binary or JSON payload, depending on event type.

Event types:

- Mouse movement delta.
- Mouse button down and up.
- Mouse wheel delta.
- Key down and up.
- Modifier synchronization.
- Release.

Packet handling must ignore events for unknown or inactive sessions.

## Runtime State

Add `RemoteInputCoordinator`, modeled after `AudioShareCoordinator`.

Responsibilities:

- Start and stop local remote-input sessions.
- Send and handle control messages.
- Open `/input` WebSocket transports.
- Coordinate capture and injection platform objects.
- Track runtime state for UI.
- Release capture and injection on stop, errors, disconnects, and shutdown.

Runtime roles:

- `none`
- `source`
- `sink`

Runtime statuses:

- `idle`
- `offering`
- `armed`
- `connecting`
- `active`
- `failed`

`armed` means edge detection is live but events are still local. `active` means input events are flowing to the remote sink or being injected by the local sink.

## Platform Interface

Add `RemoteInputPlatform` using a MethodChannel, following the `AudioPlatform` pattern.

Capture-side methods:

- `startCapture(sessionId, layoutEdge, releaseHotkey)`
- `stopCapture(sessionId)`
- Native callback for input events.
- Native callback for edge activation and release hotkey.

Injection-side methods:

- `startInjection(sessionId)`
- `injectEvent(sessionId, event)`
- `stopInjection(sessionId)`

Platform behavior:

- macOS: use Quartz Event Tap or CGEvent APIs for capture and injection. Required permissions must produce friendly errors.
- Windows: use low-level keyboard and mouse hooks for capture and `SendInput` for injection.
- Linux: implement an X11 path with XRecord or equivalent capture and XTest injection. If the current session is Wayland and the required APIs are unavailable, return a clear unsupported-session error instead of failing silently.

Native code must treat the force-release hotkey as local-first. The hotkey should stop forwarding even when remote focus is active.

## Safety And Failure Handling

Required safety rules:

- Remote input only works for mutually trusted peers.
- Trusted peers auto-accept, but both ends show active status.
- Either side can stop the session.
- App shutdown stops capture and injection.
- Socket disconnect stops capture and injection.
- Packet parse errors stop the affected session or ignore the invalid packet without injecting it.
- Platform permission failures surface as friendly UI errors.
- The app does not persist raw key events or typed content.

The feature is not intended to be unattended remote desktop control. It is a local-network, current-connection input sharing feature.

## Testing Strategy

### Dart Protocol Tests

Cover:

- `RemoteInputControlMessage` JSON round trip.
- `MessageEnum.RemoteInputControl` appended after existing values.
- `RemoteInputPacketFrame` binary encode and decode.
- Invalid packet magic and truncated payload rejection.

### State Machine Tests

Cover:

- Source creates offer only for trusted capable peers.
- Sink auto-accepts trusted capable offers.
- Untrusted or incapable peers are rejected.
- Source transitions from idle to armed to active after edge activation.
- Reverse edge traversal releases remote focus.
- Force-release hotkey stops the session.
- Stop, error, disconnect, and app shutdown release platform capture and injection.
- Auto-activation arms sharing after connection only when enabled for that peer.

### Layout Tests

Cover:

- Peer screen rectangles persist and reload.
- Four-edge adjacency detection.
- Partial overlaps map to the correct traversal edge.
- Non-adjacent screens do not create traversal edges.
- First runtime version selects only the current connected peer.

### Platform Channel Tests

Use MethodChannel mocks to verify:

- Capture starts and stops with the expected session id.
- Injection starts before events are injected.
- Stop is called after errors and shutdown.
- Platform errors become friendly coordinator failures.

### Manual And Build Verification

Verify macOS and Windows with real devices in both directions. Implement Linux behind the same interface and run Linux build checks on a Linux host when available. Without Linux hardware, record the remaining X11 and Wayland runtime verification gap explicitly.

## Non-Goals For The First Version

- Multi-peer simultaneous traversal.
- Remote desktop video streaming.
- Clipboard forwarding as part of remote input.
- Per-application input routing.
- Mobile input capture or injection.
- Wayland bypasses or privileged workarounds.

## Open Follow-Up After This Spec

Implementation planning should break the work into protocol, persistence, layout UI, coordinator, transport, platform bridges, and verification tasks. Each behavior-changing task should use test-first development.
