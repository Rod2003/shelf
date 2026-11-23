import AVFoundation
import OSLog
import ScreenCaptureKit
import VideoToolbox

/// Always-on screen capture that keeps only the last `windowSeconds` in memory.
///
/// Pipeline: ScreenCaptureKit hands over IOSurface-backed frames (zero copy) →
/// hardware HEVC encoder → ring buffer of *encoded* samples only. Raw frames are
/// released as soon as the encoder is done with them, so RAM stays at roughly
/// bitrate × 30 s (~45 MB on a 3K panel) and is hard-capped at `maxBufferBytes`.
/// Saving is a passthrough remux, no re-encode.
///
/// Lifetime: `wantsRunning` is the single source of truth and only `start()` /
/// `stop()` (driven by the Settings toggle) change it. Anything SCK or
/// VideoToolbox does — stream errors, display sleep/unplug, encoder invalidation
/// after wake — tears down the pipeline and rebuilds it while `wantsRunning` holds.
final class ReplayRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    static let windowSeconds: Double = 30
    private static let fps: Int32 = 60
    private static let maxBufferBytes = 200 * 1024 * 1024
    private static let maxRestartDelay: UInt64 = 10

    private let log = Logger(subsystem: "dev.rod.shelf", category: "replay")
    /// Serializes every access to the mutable state below.
    private let queue = DispatchQueue(label: "dev.rod.shelf.replay", qos: .userInitiated)
    private var wantsRunning = false
    /// Bumped on every rebuild so callbacks from a dead pipeline are ignored.
    private var generation = 0
    private var stream: SCStream?
    private var encoder: VTCompressionSession?
    private var samples: [CMSampleBuffer] = []
    private var bufferedBytes = 0
    private var isRestartScheduled = false

    /// Called when the user stops capture from the system's screen-recording menu.
    var onUserStopped: (() -> Void)?

    func start() async throws {
        queue.sync { wantsRunning = true }
        do {
            try await launch()
        } catch {
            // First launch failing is almost always missing permission; let the user retry.
            queue.sync { wantsRunning = false }
            throw error
        }
    }

    func stop() {
        queue.sync {
            wantsRunning = false
            teardownPipeline()
            samples = []
            bufferedBytes = 0
        }
        log.info("Replay capture stopped")
    }

    /// Writes the buffered window to `url` as an HEVC .mp4.
    func save(to url: URL) async throws {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        // Copies references only; the encoded data is shared, not duplicated.
        let snapshot = queue.sync { samples }
        guard let first = snapshot.first, let format = first.formatDescription else {
            throw ReplayError.nothingRecorded
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ReplayError.writeFailed }
        // Samples before the session start (back to the leading keyframe) are
        // decoded but trimmed by the edit list, so the clip is exactly the window.
        let start = CMTimeMaximum(first.presentationTimeStamp, now - CMTime(seconds: Self.windowSeconds, preferredTimescale: 600))
        writer.startSession(atSourceTime: start)

        let writeQueue = DispatchQueue(label: "dev.rod.shelf.replay.write")
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var index = 0
            input.requestMediaDataWhenReady(on: writeQueue) {
                while input.isReadyForMoreMediaData, index < snapshot.count {
                    input.append(snapshot[index])
                    index += 1
                }
                if index == snapshot.count {
                    input.markAsFinished()
                    done.resume()
                }
            }
        }
        writer.endSession(atSourceTime: now)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ReplayError.writeFailed }
        log.info("Saved replay (\(snapshot.count, privacy: .public) frames) to \(url.path, privacy: .public)")
    }

    // MARK: - Pipeline lifecycle

    private func launch() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // ponytail: main display only; capture each SCDisplay separately if multi-monitor matters.
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ReplayError.noDisplay
        }
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let width = mode?.pixelWidth ?? display.width
        let height = mode?.pixelHeight ?? display.height

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.fps)
        // The encoder's native input format, so no color conversion happens on our side.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 5

        // The purple recording dot ("StatusIndicator") doesn't exist until capture
        // starts, so there's nothing to exclude here yet; scheduleIndicatorExclusion
        // removes it once it appears. (It only lingers in content.windows across a
        // rebuild, so cover that case too.) ponytail: matches on a WindowServer
        // window title Apple could rename in a future macOS.
        let excluded = content.windows.filter { $0.title == "StatusIndicator" }
        let encoder = try Self.makeEncoder(width: width, height: height)
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: excluded), configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()

        let installed: Bool = queue.sync {
            guard wantsRunning else { return false }
            teardownPipeline()
            generation += 1
            self.encoder = encoder
            self.stream = stream
            return true
        }
        guard installed else {
            // The toggle went off while we were starting up.
            try? await stream.stopCapture()
            VTCompressionSessionInvalidate(encoder)
            return
        }
        scheduleIndicatorExclusion(stream: stream, display: display)
        log.info("Replay capture running \(width, privacy: .public)x\(height, privacy: .public)")
    }

    /// The recording-indicator window only appears a beat after capture starts, so
    /// poll briefly and exclude it from the stream once it's there — that keeps it
    /// out of the saved clip (it can't be hidden on the live screen on macOS 26).
    private func scheduleIndicatorExclusion(stream: SCStream, display: SCDisplay) {
        Task { [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self, self.queue.sync(execute: { stream === self.stream }) else { return }
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { continue }
                let excluded = content.windows.filter { $0.title == "StatusIndicator" }
                guard !excluded.isEmpty else { continue }
                try? await stream.updateContentFilter(SCContentFilter(display: display, excludingWindows: excluded))
                self.log.info("Excluded \(excluded.count, privacy: .public) recording-indicator window(s) from capture")
                return
            }
        }
    }

    /// Must run on `queue`. Keeps `samples` so a rebuild doesn't lose the buffer.
    private func teardownPipeline() {
        stream?.stopCapture { _ in }
        if let encoder { VTCompressionSessionInvalidate(encoder) }
        stream = nil
        encoder = nil
    }

    /// Must run on `queue`. Rebuilds with backoff until it sticks or the toggle goes off.
    private func restart(reason: String) {
        guard wantsRunning, !isRestartScheduled else { return }
        log.warning("Replay pipeline died (\(reason, privacy: .public)); rebuilding")
        teardownPipeline()
        isRestartScheduled = true
        Task { [weak self] in
            var delay: UInt64 = 1
            while let self, self.queue.sync(execute: { self.wantsRunning }) {
                try? await Task.sleep(nanoseconds: delay * NSEC_PER_SEC)
                do {
                    try await self.launch()
                    break
                } catch {
                    self.log.error("Replay rebuild failed: \(String(describing: error), privacy: .public)")
                    delay = min(delay * 2, Self.maxRestartDelay)
                }
            }
            self?.queue.async { self?.isRestartScheduled = false }
        }
    }

    // MARK: - Capture → encode → ring buffer (all on `queue`)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              stream === self.stream,
              let encoder,
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        let generation = generation
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, encoded in
            guard let self else { return }
            self.queue.async {
                guard generation == self.generation else { return }
                if status == kVTInvalidSessionErr {
                    self.restart(reason: "encoder invalidated")
                } else if status == noErr, let encoded {
                    self.append(encoded)
                }
            }
        }
        // The hardware encoder is torn down across sleep/wake; rebuild it.
        if status == kVTInvalidSessionErr {
            restart(reason: "encoder invalidated")
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async {
            guard stream === self.stream else { return }
            if (error as? SCStreamError)?.code == .userStopped {
                // The user hit Stop in the system menu bar: respect it and flip the toggle off.
                self.wantsRunning = false
                self.teardownPipeline()
                self.samples = []
                self.bufferedBytes = 0
                DispatchQueue.main.async { self.onUserStopped?() }
                return
            }
            self.restart(reason: String(describing: error))
        }
    }

    private func append(_ sample: CMSampleBuffer) {
        // A rebuilt pipeline at a new resolution can't share a file with old samples.
        if let last = samples.last, let old = last.formatDescription, let new = sample.formatDescription, !CMFormatDescriptionEqual(old, otherFormatDescription: new) {
            samples = []
            bufferedBytes = 0
        }
        samples.append(sample)
        bufferedBytes += sample.totalSampleSize

        // Drop whole GOPs older than the window; always keep the keyframe that
        // starts the window so the clip decodes from its first frame.
        let cutoff = sample.presentationTimeStamp - CMTime(seconds: Self.windowSeconds, preferredTimescale: 600)
        if let keep = samples.lastIndex(where: { $0.presentationTimeStamp <= cutoff && Self.isKeyframe($0) }), keep > 0 {
            dropFirst(keep)
        }
        // Hard memory ceiling: shed the oldest GOPs if a pathological bitrate blows past it.
        while bufferedBytes > Self.maxBufferBytes,
              let nextKey = samples.dropFirst().firstIndex(where: Self.isKeyframe) {
            dropFirst(nextKey)
        }
    }

    private func dropFirst(_ count: Int) {
        bufferedBytes -= samples[..<count].reduce(0) { $0 + $1.totalSampleSize }
        samples.removeFirst(count)
    }

    private static func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int
        else { return false }
        return SCFrameStatus(rawValue: raw) == .complete
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]])?.first else {
            return true
        }
        return info[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }

    private static func makeEncoder(width: Int, height: Int) throws -> VTCompressionSession {
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw ReplayError.encoder(status) }
        // ~2 bits/pixel/s: ~12 Mbps on a 3024x1964 panel, ~45 MB for 30 s. Screen content compresses well.
        let bitRate = width * height * 2
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
            kVTCompressionPropertyKey_AverageBitRate: bitRate,
            // Hard ceiling of 2x average per second, so bursts can't balloon the buffer.
            kVTCompressionPropertyKey_DataRateLimits: [bitRate / 4, 1] as CFArray,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_HEVC_Main_AutoLevel
        ]
        VTSessionSetProperties(session, propertyDictionary: props as CFDictionary)
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }
}

enum ReplayError: LocalizedError {
    case noDisplay
    case nothingRecorded
    case writeFailed
    case encoder(OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display available to record."
        case .nothingRecorded: return "Nothing recorded yet."
        case .writeFailed: return "Couldn't write the replay file."
        case .encoder(let status): return "Hardware encoder unavailable (\(status))."
        }
    }
}
