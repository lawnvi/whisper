import UIKit
import Flutter
import AVFoundation
import Network
import dnssd
import CoreMotion
import MediaPlayer

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

    private let audioSharePlugin = IOSAudioSharePlugin()
    private let localNetworkPermissionPlugin = IOSLocalNetworkPermissionPlugin()
    private let motionPlugin = IOSMobileMotionPlugin()

    func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
        GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
        let messenger = engineBridge.applicationRegistrar.messenger()
        let dirChannel = FlutterMethodChannel(name: "com.vireen.whisper/ios_dir", binaryMessenger: messenger)
        audioSharePlugin.register(binaryMessenger: messenger)
        localNetworkPermissionPlugin.register(binaryMessenger: messenger)
        motionPlugin.register(binaryMessenger: messenger)

        dirChannel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            guard let self = self else {
                result(FlutterError(code: "unavailable", message: "File services are unavailable", details: nil))
                return
            }
            switch call.method {
            case "openFolder":
                self.openDir(call: call, result: result)
            case "availableBytes":
                self.availableBytes(call: call, result: result)
            case "videoThumbnail":
                self.videoThumbnail(call: call, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private var presentingViewController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var controller = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func openDir(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String,
              !path.isEmpty else {
            result(FlutterError(code: "bad-arguments", message: "openFolder requires a path", details: nil))
            return
        }
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              fileManager.isReadableFile(atPath: path) else {
            result(FlutterError(code: "invalid-folder", message: "Folder is unavailable", details: nil))
            return
        }
        guard let controller = presentingViewController else {
            result(FlutterError(code: "unavailable", message: "No active window", details: nil))
            return
        }

        let activity = UIActivityViewController(
            activityItems: [URL(fileURLWithPath: path, isDirectory: true)],
            applicationActivities: nil
        )
        // iPad presents this as a popover and requires an anchor in its window.
        if let popover = activity.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        controller.present(activity, animated: true)
        result(nil)
    }

    private func videoThumbnail(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String else {
            result(nil)
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let asset = AVURLAsset(url: URL(fileURLWithPath: path))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 512, height: 512)
            let image = try? generator.copyCGImage(at: .zero, actualTime: nil)
            let bytes = image.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.8) }
            DispatchQueue.main.async {
                result(bytes.map { FlutterStandardTypedData(bytes: $0) })
            }
        }
    }

    private func availableBytes(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String else {
            result(nil)
            return
        }

        do {
            let values = try FileManager.default.attributesOfFileSystem(forPath: path)
            result(values[.systemFreeSize] as? NSNumber)
        } catch {
            result(nil)
        }
    }
}

final class IOSLocalNetworkPermissionPlugin {
    private var channel: FlutterMethodChannel?
    private var browser: NWBrowser?
    private var pendingResults: [FlutterResult] = []
    private var probeGeneration = 0
    private var backgroundObserver: NSObjectProtocol?

    deinit {
        if let backgroundObserver = backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    func register(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.vireen.whisper/local_network_permission",
            binaryMessenger: binaryMessenger
        )
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result("unknown")
                return
            }
            switch call.method {
            case "currentStatus":
                result("unknown")
            case "ensureGranted":
                self.ensureGranted(result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.finishProbe(status: "retryable")
        }
    }

    private func ensureGranted(result: @escaping FlutterResult) {
        guard UIApplication.shared.applicationState == .active else {
            result("unavailable")
            return
        }
        pendingResults.append(result)
        guard browser == nil else {
            return
        }

        probeGeneration += 1
        let generation = probeGeneration
        let browser = NWBrowser(
            for: .bonjour(type: "_whisper._tcp", domain: "local."),
            using: .tcp
        )
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self = self,
                  let browser = browser,
                  browser === self.browser else {
                return
            }
            switch state {
            case .ready:
                self.finishProbe(status: "granted")
            case .waiting(let error), .failed(let error):
                self.finishProbe(status: self.status(for: error))
            case .cancelled:
                self.finishProbe(status: "retryable")
            case .setup:
                break
            @unknown default:
                self.finishProbe(status: "unknown")
            }
        }
        browser.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self = self, self.probeGeneration == generation else {
                return
            }
            self.finishProbe(status: "retryable")
        }
    }

    private func status(for error: NWError) -> String {
        switch error {
        case .dns(let code):
            return Int32(code) == kDNSServiceErr_PolicyDenied
                ? "denied"
                : "retryable"
        case .posix(let code):
            switch code {
            case .ENETDOWN, .ENETUNREACH, .EHOSTUNREACH, .ENODEV, .ENXIO:
                return "unavailable"
            default:
                return "retryable"
            }
        default:
            return "retryable"
        }
    }

    private func finishProbe(status: String) {
        guard browser != nil || !pendingResults.isEmpty else {
            return
        }
        probeGeneration += 1
        let activeBrowser = browser
        browser = nil
        activeBrowser?.stateUpdateHandler = nil
        activeBrowser?.cancel()
        let results = pendingResults
        pendingResults.removeAll()
        results.forEach { $0(status) }
    }
}

final class IOSAudioSharePlugin {
    private var channel: FlutterMethodChannel?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var playbackChannels = 0
    private var playbackSessionId = ""
    private var queuedFrames = 0
    private var playbackGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private var commandTargets: [(MPRemoteCommand, Any)] = []

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        commandTargets.forEach { $0.0.removeTarget($0.1) }
    }

    func register(binaryMessenger: FlutterBinaryMessenger) {
        let channel = FlutterMethodChannel(
            name: "com.vireen.whisper/audio_share",
            binaryMessenger: binaryMessenger
        )
        self.channel = channel
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else {
                result(FlutterError(code: "unavailable", message: "Audio services are unavailable", details: nil))
                return
            }
            self.handle(call: call, result: result)
        }
        let commands = MPRemoteCommandCenter.shared()
        for (command, action) in [(commands.pauseCommand, "pause"),
                                  (commands.playCommand, "resume"),
                                  (commands.stopCommand, "disconnect")] {
            command.isEnabled = false
            let target = command.addTarget { [weak self] _ in
                DispatchQueue.main.async { self?.sendMediaControl(action) }
                return .success
            }
            commandTargets.append((command, target))
        }
        observe(AVAudioSession.interruptionNotification) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.pauseForSystemChange()
        }
        observe(AVAudioSession.routeChangeNotification) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            self?.pauseForSystemChange()
        }
        observe(AVAudioSession.mediaServicesWereResetNotification) { [weak self] _ in
            self?.pauseForSystemChange()
        }
        observe(.AVAudioEngineConfigurationChange) { [weak self] notification in
            guard let self = self, let engine = notification.object as? AVAudioEngine,
                  engine === self.engine else { return }
            self.pauseForSystemChange()
        }
    }

    private func observe(_ name: Notification.Name, handler: @escaping (Notification) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: handler))
    }

    private func sendMediaControl(_ action: String) {
        channel?.invokeMethod("mediaControl", arguments: ["action": action])
    }

    private func pauseForSystemChange() {
        guard !playbackSessionId.isEmpty else { return }
        stopPlayback()
        sendMediaControl("focusPauseTransient")
    }

    private func updateMediaState(_ args: [String: Any]) {
        let state = args["state"] as? String ?? "stopped"
        let commands = MPRemoteCommandCenter.shared()
        commands.pauseCommand.isEnabled = state == "playing" || state == "buffering"
        commands.playCommand.isEnabled = state == "paused" && args["canResume"] as? Bool == true
        commands.stopCommand.isEnabled = state != "stopped"
        guard state != "stopped" else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: args["title"] as? String ?? "Whisper",
            MPMediaItemPropertyArtist: args["subtitle"] as? String ?? "",
            MPNowPlayingInfoPropertyIsLiveStream: true,
            MPNowPlayingInfoPropertyPlaybackRate: state == "playing" ? 1.0 : 0.0,
        ]
    }

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startPlayback":
            guard let args = call.arguments as? [String: Any],
                  let sessionId = args["sessionId"] as? String,
                  let format = args["format"] as? [String: Any] else {
                result(FlutterError(
                    code: "bad-arguments",
                    message: "startPlayback requires sessionId and format",
                    details: nil
                ))
                return
            }
            do {
                try startPlayback(sessionId: sessionId, format: format)
                result(nil)
            } catch {
                result(FlutterError(
                    code: "audio-playback",
                    message: error.localizedDescription,
                    details: nil
                ))
            }

        case "writePcm":
            guard let args = call.arguments as? [String: Any],
                  let sessionId = args["sessionId"] as? String,
                  let pcm = pcmData(from: args["pcm"]) else {
                result(FlutterError(
                    code: "bad-arguments",
                    message: "writePcm requires sessionId and pcm",
                    details: nil
                ))
                return
            }
            writePcm(sessionId: sessionId, pcm: pcm,
                     targetMicros: (args["targetPlaybackTimeMicros"] as? NSNumber)?.int64Value ?? 0)
            result(nil)

        case "stopPlayback":
            let args = call.arguments as? [String: Any]
            stopPlayback(sessionId: args?["sessionId"] as? String ?? "")
            result(nil)

        case "updateMediaState":
            updateMediaState(call.arguments as? [String: Any] ?? [:])
            result(nil)

        case "startCapture", "stopCapture":
            result(FlutterMethodNotImplemented)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startPlayback(sessionId: String, format: [String: Any]) throws {
        stopPlayback()
        let sampleRate = Double(format["sampleRate"] as? Int ?? 48000)
        let channelCount = format["channels"] as? Int ?? 2
        guard !sessionId.isEmpty, sampleRate >= 8000, sampleRate <= 192000,
              channelCount >= 1, channelCount <= 2 else {
            throw NSError(domain: "IOSAudioSharePlugin", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid playback format"])
        }
        let channels = AVAudioChannelCount(channelCount)
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            throw NSError(
                domain: "IOSAudioSharePlugin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid playback format"]
            )
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFormat)
        do {
            try engine.start()
        } catch {
            try? session.setActive(false, options: [.notifyOthersOnDeactivation])
            throw error
        }

        self.engine = engine
        self.player = player
        playbackFormat = audioFormat
        playbackChannels = Int(audioFormat.channelCount)
        playbackSessionId = sessionId
    }

    private func writePcm(sessionId: String, pcm: Data, targetMicros: Int64) {
        guard sessionId == playbackSessionId,
              let player = player,
              let format = playbackFormat,
              pcm.count > 0 else {
            return
        }

        guard playbackChannels > 0 else {
            return
        }
        let sourceBytesPerFrame = playbackChannels * MemoryLayout<Int16>.size
        guard pcm.count % sourceBytesPerFrame == 0,
              pcm.count <= Int(format.sampleRate) * sourceBytesPerFrame / 4 else { return }
        let nowMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        // Dart supplies epoch microseconds; never compare it with the host clock.
        if targetMicros > 0 && (nowMicros - targetMicros > 120_000 || targetMicros - nowMicros > 500_000) { return }
        let frameCount = AVAudioFrameCount(pcm.count / sourceBytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: frameCount
              ) else {
            return
        }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData else {
            return
        }
        pcm.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for frame in 0..<Int(frameCount) {
                for channel in 0..<playbackChannels {
                    let byteIndex = (frame * playbackChannels + channel) * 2
                    let lo = UInt16(bytes[byteIndex])
                    let hi = UInt16(bytes[byteIndex + 1]) << 8
                    let sample = Int16(littleEndian: Int16(bitPattern: hi | lo))
                    channelData[channel][frame] = Float(sample) / 32768.0
                }
            }
        }
        // Bound native buffering as well as Dart's jitter buffer after a stall.
        if queuedFrames + Int(frameCount) > Int(format.sampleRate * 0.25) {
            playbackGeneration += 1
            player.stop()
            queuedFrames = 0
        }
        let generation = playbackGeneration
        queuedFrames += Int(frameCount)
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, generation == self.playbackGeneration else { return }
                self.queuedFrames = max(0, self.queuedFrames - Int(frameCount))
            }
        }
        if !player.isPlaying {
            let leadSeconds = Double(max(0, targetMicros - nowMicros)) / 1_000_000
            player.play(at: AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: leadSeconds)))
        }
    }

    private func stopPlayback(sessionId: String = "") {
        if !sessionId.isEmpty && sessionId != playbackSessionId {
            return
        }
        let wasPlaying = !playbackSessionId.isEmpty
        playbackGeneration += 1
        queuedFrames = 0
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        playbackFormat = nil
        playbackChannels = 0
        playbackSessionId = ""
        if wasPlaying {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }

    private func pcmData(from value: Any?) -> Data? {
        if let data = value as? FlutterStandardTypedData {
            return data.data
        }
        return value as? Data
    }
}

final class IOSMobileMotionPlugin: NSObject, FlutterStreamHandler {
    private let motion = CMMotionManager()
    private var sink: FlutterEventSink?
    private var backgroundObserver: NSObjectProtocol?

    deinit {
        motion.stopDeviceMotionUpdates()
        if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) }
    }

    func register(binaryMessenger: FlutterBinaryMessenger) {
        let methods = FlutterMethodChannel(name: "com.vireen.whisper/mobile_motion", binaryMessenger: binaryMessenger)
        methods.setMethodCallHandler { [weak self] call, result in
            if call.method == "available" {
                result(self?.motion.isDeviceMotionAvailable ?? false)
            } else {
                result(FlutterMethodNotImplemented)
            }
        }
        FlutterEventChannel(name: "com.vireen.whisper/mobile_motion/events", binaryMessenger: binaryMessenger)
            .setStreamHandler(self)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.sink != nil else { return }
            self.fail("inactive")
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        motion.stopDeviceMotionUpdates()
        sink = events
        guard motion.isDeviceMotionAvailable, UIApplication.shared.applicationState == .active else {
            fail("unavailable")
            return nil
        }
        motion.deviceMotionUpdateInterval = 0.01
        motion.startDeviceMotionUpdates(to: .main) { [weak self] sample, error in
            guard let self = self, self.sink != nil else { return }
            guard let sample = sample, error == nil else { self.fail("unavailable"); return }
            let gyro = [sample.rotationRate.x, sample.rotationRate.y, sample.rotationRate.z]
            // Core Motion reports gravity in g toward the ground; the shared
            // mapper uses Android's upward gravity vector in metres/second².
            let gravity = [sample.gravity.x, sample.gravity.y, sample.gravity.z].map { -$0 * 9.80665 }
            guard (gyro + gravity).allSatisfy({ $0.isFinite }) else { self.fail("invalid-sample"); return }
            self.sink?(["micros": Int64(sample.timestamp * 1_000_000), "gyro": gyro, "gravity": gravity])
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        motion.stopDeviceMotionUpdates()
        sink = nil
        return nil
    }

    private func fail(_ code: String) {
        motion.stopDeviceMotionUpdates()
        sink?(FlutterError(code: code, message: "Motion capture stopped", details: nil))
        sink = nil
    }
}
