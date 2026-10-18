import CoreMediaIO
import CoreText
import CoreVideo
import Foundation
import IOKit.audio
import os.log
import QuartzCore

// The "Matrix Eyes Cam" virtual camera. It has two streams:
//  - a source stream that video apps (Meet, Zoom, FaceTime...) read from, and
//  - a sink stream that the Matrix Eyes Cam studio app writes finished frames into.
// While the studio app isn't sending, the camera shows a card asking you to open it.

private let log = Logger(subsystem: VirtualCameraID.extensionBundleID, category: "camera")

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: VirtualCameraID.name)
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Couldn't add the camera device: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "Matrix Eyes" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: SourceStream!
    private var sink: SinkStream!

    private var videoFormat: CMFormatDescription!
    private var pool: CVPixelBufferPool!
    private let poolAux = [kCVPixelBufferPoolAllocationThresholdKey: 8] as NSDictionary

    private let timerQueue = DispatchQueue(label: "matrix-eyes-cam.timer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var streamingClients = 0

    private let lock = NSLock()
    private var latestFromApp: CMSampleBuffer?
    private var latestFromAppTime: CFTimeInterval = 0
    private var sinkClient: CMIOExtensionClient?
    private var placeholder: CVPixelBuffer?

    init(localizedName: String) {
        super.init()
        let uuid = UUID(uuidString: VirtualCameraID.deviceUUID)!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: uuid,
                                     legacyDeviceID: VirtualCameraID.deviceUID, source: self)

        let w = Int32(VirtualCameraID.width), h = Int32(VirtualCameraID.height)
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: w, height: h, extensions: nil, formatDescriptionOut: &videoFormat)
        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: w,
            kCVPixelBufferHeightKey: h,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs, &pool)

        let frame = CMTime(value: 1, timescale: VirtualCameraID.fps)
        let format = CMIOExtensionStreamFormat(formatDescription: videoFormat, maxFrameDuration: frame,
                                               minFrameDuration: frame, validFrameDurations: nil)
        source = SourceStream(localizedName: "\(localizedName).Video", streamID: UUID(), format: format, device: self)
        sink = SinkStream(localizedName: "\(localizedName).Input", streamID: UUID(), format: format, device: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Couldn't add the camera streams: \(error)")
        }
        placeholder = makePlaceholder()
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = kIOAudioDeviceTransportTypeVirtual }
        if properties.contains(.deviceModel) { p.model = VirtualCameraID.name }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: - What the call sees

    func startStreaming() {
        streamingClients += 1
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        t.schedule(deadline: .now(), repeating: 1.0 / Double(VirtualCameraID.fps), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.emitFrame() }
        t.resume()
        timer = t
    }

    func stopStreaming() {
        streamingClients = max(streamingClients - 1, 0)
        if streamingClients == 0 {
            timer?.cancel()
            timer = nil
        }
    }

    /// Sends the studio app's newest frame, or the placeholder card if the app isn't sending.
    private func emitFrame() {
        let now = CACurrentMediaTime()
        lock.lock()
        let fromApp = now - latestFromAppTime < 0.5 ? latestFromApp : nil
        lock.unlock()

        let pixelBuffer: CVPixelBuffer?
        if let fromApp, let pb = CMSampleBufferGetImageBuffer(fromApp) {
            pixelBuffer = pb
        } else {
            pixelBuffer = placeholder
        }
        guard let pixelBuffer else { return }

        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: VirtualCameraID.fps),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let err = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescription: videoFormat, sampleTiming: &timing,
                                                           sampleBufferOut: &sample)
        guard err == noErr, let sample else { return }
        let host = UInt64(timing.presentationTimeStamp.seconds * Double(NSEC_PER_SEC))
        source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: host)
    }

    // MARK: - What the studio app sends

    func startSink(client: CMIOExtensionClient) {
        lock.lock()
        sinkClient = client
        lock.unlock()
        consume(from: client)
    }

    func stopSink() {
        lock.lock()
        sinkClient = nil
        latestFromApp = nil
        lock.unlock()
    }

    private func consume(from client: CMIOExtensionClient) {
        sink.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, _, error in
            guard let self else { return }
            if let buffer {
                self.lock.lock()
                self.latestFromApp = buffer
                self.latestFromAppTime = CACurrentMediaTime()
                self.lock.unlock()
                let output = CMIOExtensionScheduledOutput(sequenceNumber: sequence,
                                                          hostTimeInNanoseconds: UInt64(CACurrentMediaTime() * Double(NSEC_PER_SEC)))
                self.sink.stream.notifyScheduledOutputChanged(output)
            }
            if let error { log.error("sink: \(error.localizedDescription, privacy: .public)") }
            self.lock.lock()
            let stillConnected = self.sinkClient === client
            self.lock.unlock()
            if stillConnected {
                // Keep pulling; back off a little if nothing was waiting.
                if buffer == nil {
                    self.timerQueue.asyncAfter(deadline: .now() + 0.005) { self.consume(from: client) }
                } else {
                    self.consume(from: client)
                }
            }
        }
    }

    /// A calm card shown while the studio app is closed.
    private func makePlaceholder() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, poolAux, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return pb }
        let colors = [CGColor(red: 0.02, green: 0.03, blue: 0.06, alpha: 1), CGColor(red: 0.06, green: 0.1, blue: 0.16, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        }
        func draw(_ text: String, size: CGFloat, y: CGFloat, alpha: CGFloat) {
            let font = CTFontCreateWithName("Menlo-Bold" as CFString, size, nil)
            let attr = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.55, green: 1, blue: 0.65, alpha: alpha),
            ])
            let line = CTLineCreateWithAttributedString(attr)
            let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textPosition = CGPoint(x: (CGFloat(w) - bounds.width) / 2, y: y)
            CTLineDraw(line, ctx)
        }
        draw("MATRIX EYES CAM", size: 54, y: CGFloat(h) * 0.52, alpha: 1)
        draw("Open the Matrix Eyes Cam app to start your look", size: 22, y: CGFloat(h) * 0.42, alpha: 0.7)
        return pb
    }
}

/// The stream video apps read.
final class SourceStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> { [.streamActiveFormatIndex, .streamFrameDuration] }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: VirtualCameraID.fps) }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let i = streamProperties.activeFormatIndex { activeFormatIndex = i }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }
    func startStream() throws { device.startStreaming() }
    func stopStream() throws { device.stopStreaming() }
}

/// The stream the studio app writes into.
final class SinkStream: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private unowned let device: DeviceSource
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, format: CMIOExtensionStreamFormat, device: DeviceSource) {
        self.format = format
        self.device = device
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: .sink,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }
    var activeFormatIndex: Int = 0

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount, .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: VirtualCameraID.fps) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 4 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let i = streamProperties.activeFormatIndex { activeFormatIndex = i }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        if let client { device.startSink(client: client) }
    }

    func stopStream() throws { device.stopSink() }
}
