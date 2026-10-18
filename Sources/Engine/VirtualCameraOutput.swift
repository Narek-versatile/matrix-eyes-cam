import CoreMediaIO
import CoreVideo
import Foundation
import Metal

enum VirtualCameraStatus: Equatable {
    case notInstalled       // the extension isn't installed/activated (needs signing, see PLAN.md)
    case ready              // found; no call is using it right now
    case streaming          // frames are going out
    case failed(String)

    var text: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .ready: return "Ready"
        case .streaming: return "Sending to your call"
        case .failed(let why): return "Problem: \(why)"
        }
    }
}

/// Pushes finished frames into the virtual camera's sink stream, where the extension picks them
/// up and serves them to Meet / Zoom / FaceTime. Uses the CoreMediaIO C API from the app side.
final class VirtualCameraOutput {
    var onStatus: ((VirtualCameraStatus) -> Void)?

    private let device: MTLDevice
    private var pool: CVPixelBufferPool?
    private var cache: CVMetalTextureCache?
    private let lock = NSLock()
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var queue: CMSimpleQueue?
    private var status: VirtualCameraStatus = .notInstalled
    private var poll: DispatchSourceTimer?
    private var frameCount: Int64 = 0

    init(device: MTLDevice) {
        self.device = device
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: VirtualCameraID.width,
            kCVPixelBufferHeightKey as String: VirtualCameraID.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        allowScreenCaptureDevices()
        // Look for the device now, and every couple of seconds until it shows up (e.g. right after
        // the extension is approved in System Settings).
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now(), repeating: .seconds(2))
        t.setEventHandler { [weak self] in self?.connectIfNeeded() }
        t.resume()
        poll = t
    }

    deinit {
        poll?.cancel()
        if deviceID != 0, sinkStreamID != 0 { CMIODeviceStopStream(deviceID, sinkStreamID) }
    }

    /// Copies the frame into a pixel buffer inside the same command buffer, then enqueues it.
    func send(_ texture: MTLTexture, in cmd: MTLCommandBuffer) {
        lock.lock()
        let queue = self.queue
        lock.unlock()
        guard let queue, let pool, let cache,
              texture.width == VirtualCameraID.width, texture.height == VirtualCameraID.height else { return }
        // Don't pile up frames if nobody is reading them.
        if CMSimpleQueueGetCount(queue) >= CMSimpleQueueGetCapacity(queue) - 1 { return }

        var pb: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess, let pb else { return }
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, .bgra8Unorm,
                                                        VirtualCameraID.width, VirtualCameraID.height, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let dst = CVMetalTextureGetTexture(cvTex),
              let blit = cmd.makeBlitCommandEncoder() else { return }
        blit.copy(from: texture, to: dst)
        blit.endEncoding()

        frameCount += 1
        let frame = frameCount
        cmd.addCompletedHandler { [weak self] _ in
            withExtendedLifetime(cvTex) {}
            self?.enqueue(pb, frame: frame, into: queue)
        }
    }

    private func enqueue(_ pb: CVPixelBuffer, frame: Int64, into queue: CMSimpleQueue) {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: VirtualCameraID.fps),
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        let status = CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
        if status != noErr {
            Unmanaged.passUnretained(sample).release()
            if frame % 90 == 1 { FileHandle.standardError.write(Data("virtual camera: enqueue failed (\(status))\n".utf8)) }
            return
        }
        if frame % 150 == 1 { FileHandle.standardError.write(Data("virtual camera: sent frame \(frame), queue \(CMSimpleQueueGetCount(queue))/\(CMSimpleQueueGetCapacity(queue))\n".utf8)) }
        setStatus(.streaming)
    }

    // MARK: - Finding the device

    private func connectIfNeeded() {
        lock.lock()
        let connected = queue != nil
        lock.unlock()
        if connected { return }
        guard let (dev, sink) = findSink() else {
            setStatus(.notInstalled)
            return
        }
        var q: Unmanaged<CMSimpleQueue>?
        let err = CMIOStreamCopyBufferQueue(sink, { _, _, _ in }, nil, &q)
        guard err == noErr, let q else {
            setStatus(.failed("couldn't open the camera's input (\(err))"))
            return
        }
        let startErr = CMIODeviceStartStream(dev, sink)
        guard startErr == noErr else {
            setStatus(.failed("couldn't start the camera's input (\(startErr))"))
            return
        }
        lock.lock()
        deviceID = dev
        sinkStreamID = sink
        queue = q.takeRetainedValue()
        lock.unlock()
        setStatus(.ready)
    }

    /// Our device, and its sink (input) stream.
    private func findSink() -> (CMIOObjectID, CMIOStreamID)? {
        for dev in objects(of: CMIOObjectID(kCMIOObjectSystemObject), selector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices)) {
            guard string(of: dev, selector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == VirtualCameraID.deviceUID else { continue }
            let streams = objects(of: dev, selector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams))
            // CoreMediaIO reports the stream video apps read as direction 1 and the sink we write
            // into as direction 0 (seen from the Mac, not from the device).
            if let sink = streams.first(where: { uint32(of: $0, selector: CMIOObjectPropertySelector(kCMIOStreamPropertyDirection)) == 0 }) {
                return (dev, sink)
            }
        }
        return nil
    }

    private func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector,
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func objects(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private func string(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func uint32(of object: CMIOObjectID, selector: CMIOObjectPropertySelector) -> UInt32? {
        var addr = address(selector)
        var value: UInt32 = 0
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &used, &value) == noErr else { return nil }
        return value
    }

    /// Lets this process see camera devices such as virtual cameras (CoreMediaIO hides some by default).
    private func allowScreenCaptureDevices() {
        var addr = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices))
        var allow: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    private func setStatus(_ s: VirtualCameraStatus) {
        lock.lock()
        let changed = status != s
        status = s
        lock.unlock()
        if changed {
            FileHandle.standardError.write(Data("virtual camera: \(s.text)\n".utf8))
            onStatus?(s)
        }
    }
}
