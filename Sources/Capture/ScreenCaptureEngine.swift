import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

/// A frame that survived both perceptual gates and is worth reading.
struct ScreenFrame: Sendable {
    let image: CGImage
    let timestamp: Date
    let displayIdentifier: UInt32
    let pixelWidth: Int
    let pixelHeight: Int
    let frameDelta: Double
    let hashSimilarity: Double
}

/// Live counters describing what the perceptual gate did.
struct FrameGateStatistics: Sendable {
    var framesReceived = 0
    var framesBaseline = 0
    var framesDroppedAsStatic = 0
    var framesDroppedAsSuppressed = 0
    var framesDroppedAsUnconvertible = 0
    var averageDelta = 0.0

    var summary: String {
        """
        received=\(framesReceived) baseline=\(framesBaseline) static=\(framesDroppedAsStatic) \
        suppressed=\(framesDroppedAsSuppressed) unconvertible=\(framesDroppedAsUnconvertible) \
        avgDelta=\(String(format: "%.3f", averageDelta))
        """
    }
}

/// Captures the main display and hands off only the frames that changed.
///
/// Cadence is set on the capture stream itself (`minimumFrameInterval`), so
/// ScreenCaptureKit's scheduler decides when frames happen. There is no polling
/// timer and the capture queue sleeps for the other ~14.9 seconds of every
/// interval — that is the entire battery story of this app.
@MainActor
final class ScreenCaptureEngine: NSObject {

    private let logger = Logger(subsystem: AppInfo.identifier, category: "capture")

    /// Serial `.utility` queue that receives frames. Deliberately not the main
    /// queue: pixel sampling, gating, and CGImage decoding all happen here so
    /// the UI thread never does a single byte of capture work.
    private let captureQueue = DispatchQueue(
        label: "com.daypilot.capture.frames",
        qos: .utility,
        attributes: []
    )

    private let suppression = ThreadSafeBox(false)
    private let statistics = ThreadSafeBox(FrameGateStatistics())

    private var stream: SCStream?
    private var output: FrameSampleHandler?

    /// Called on the main actor with a frame that cleared both gates.
    var onFrame: (@MainActor (ScreenFrame) -> Void)?

    /// Called on the main actor when the stream dies: permission revoked,
    /// display disconnected, shutdown.
    var onFailure: (@MainActor (String) -> Void)?

    /// Live gate counters. Main-actor reads only.
    var gateStatistics: FrameGateStatistics { statistics.value }

    /// Arms or disarms the privacy shield.
    ///
    /// Set by `SessionCoordinator` from the Accessibility-derived frontmost
    /// application, so the flag is already correct by the time the next frame
    /// lands — including the one that follows a switch into a password manager.
    func setSuppressed(_ suppressed: Bool) {
        guard suppression.value != suppressed else { return }
        suppression.set(suppressed)
        logger.info("Capture suppression \(suppressed ? "armed" : "disarmed")")
    }

    /// Starts sampling the main display.
    func start() async throws {
        guard stream == nil else { throw ScreenCaptureError.alreadyRunning }

        let shareableContent = try await SCShareableContent.current
        guard let display = Self.preferredDisplay(in: shareableContent) else {
            throw ScreenCaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )

        let configuration = Self.configuration(
            for: display,
            interval: DayPilotConfiguration.captureIntervalSeconds
        )

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: nil
        )

        let handler = FrameSampleHandler(
            displayIdentifier: display.displayID,
            suppression: suppression,
            statistics: statistics,
            onSignificantFrame: { [weak self] frame in
                Task { @MainActor in self?.onFrame?(frame) }
            },
            onFailure: { [weak self] message in
                Task { @MainActor in self?.onFailure?(message) }
            }
        )

        try stream.addStreamOutput(
            handler,
            type: .screen,
            sampleHandlerQueue: captureQueue
        )
        try await stream.startCapture()
        self.stream = stream
        self.output = handler

        let cadence = Int(DayPilotConfiguration.captureIntervalSeconds)
        let message =
            "Capture started on display \(display.displayID) — \(cadence)s cadence, "
            + "\(configuration.width)x\(configuration.height)"
        logger.notice("\(message, privacy: .public)")
    }

    /// Stops sampling and releases the stream.
    func stop() async {
        guard let stream else { return }

        if let output {
            try? stream.removeStreamOutput(output, type: .screen)
        }
        try? await stream.stopCapture()

        self.stream = nil
        self.output = nil

        let finalSummary = statistics.value.summary
        logger.notice("Capture stopped — \(finalSummary, privacy: .public)")
    }

    /// Clears the gate counters and re-baselines the perceptual comparison.
    func resetGate() {
        statistics.set(FrameGateStatistics())
        output?.resetBaseline()
    }

    // MARK: - Configuration

    private static func preferredDisplay(in content: SCShareableContent) -> SCDisplay? {
        let mainDisplayID = CGMainDisplayID()
        return content.displays.first { $0.displayID == mainDisplayID }
            ?? content.displays.first
    }

    private static func configuration(
        for display: SCDisplay,
        interval: TimeInterval
    ) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()

        // Native pixel size. `SCDisplay.width` is in points, so multiply by the
        // screen's backing scale — hardcoding 2 would be wrong on a 1x display.
        let scale = backingScaleFactor(for: display.displayID)
        configuration.width = max(1, Int((Double(display.width) * scale).rounded()))
        configuration.height = max(1, Int((Double(display.height) * scale).rounded()))
        configuration.scalesToFit = false

        // Cadence lives on the stream, not in a timer.
        configuration.minimumFrameInterval = CMTime(seconds: interval, preferredTimescale: 1)

        // Deep enough to absorb one slow OCR pass, shallow enough that a stalled
        // consumer can never accumulate frames in memory.
        configuration.queueDepth = 3

        configuration.showsCursor = false

        // BGRA gives the thumbprint sampler and CIContext one stable layout.
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        return configuration
    }

    private static func backingScaleFactor(for displayID: CGDirectDisplayID) -> CGFloat {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? CGDirectDisplayID,
               number == displayID {
                return screen.backingScaleFactor
            }
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }
}

// MARK: - Frame handling

/// Receives frames from ScreenCaptureKit.
///
/// Every frame for one stream arrives in order on a single serial queue, so the
/// mutable state below (the previous thumbnail, the rolling gate statistics) is
/// single-writer and needs no locking of its own. The type is `Sendable`
/// because it crosses isolation domains when the stream retains it.
private final class FrameSampleHandler: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    private let displayIdentifier: CGDirectDisplayID
    private let suppression: ThreadSafeBox<Bool>
    private let statistics: ThreadSafeBox<FrameGateStatistics>
    private let onSignificantFrame: @Sendable (ScreenFrame) -> Void
    private let onFailure: @Sendable (String) -> Void

    /// One `CIContext` for the process. Core Image contexts are expensive to
    /// build and safe to render with from any thread; building one per frame
    /// would be by far the largest per-frame cost in the pipeline.
    private let renderContext = ThreadSafeBox<CIContext?>(nil)

    private var previousThumbnail: PerceptualThumbnail?
    private let logger = Logger(subsystem: AppInfo.identifier, category: "capture")

    init(
        displayIdentifier: CGDirectDisplayID,
        suppression: ThreadSafeBox<Bool>,
        statistics: ThreadSafeBox<FrameGateStatistics>,
        onSignificantFrame: @escaping @Sendable (ScreenFrame) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.displayIdentifier = displayIdentifier
        self.suppression = suppression
        self.statistics = statistics
        self.onSignificantFrame = onSignificantFrame
        self.onFailure = onFailure
    }

    /// Drops the stored baseline so the next frame is compared against nothing
    /// and always read as significant.
    func resetBaseline() {
        previousThumbnail = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        statistics.update { $0.framesReceived += 1 }

        guard let snapshot = PerceptualThumbnail.sample(
            from: pixelBuffer,
            resolution: DayPilotConfiguration.thumbnailResolution
        ) else {
            statistics.update { $0.framesDroppedAsUnconvertible += 1 }
            return
        }

        // The first frame of a session only establishes what "unchanged" looks
        // like; there is nothing yet to diff against.
        guard let previous = previousThumbnail else {
            previousThumbnail = snapshot
            statistics.update { $0.framesBaseline += 1 }
            return
        }
        previousThumbnail = snapshot

        let delta = snapshot.delta(from: previous)
        let similarity = snapshot.differenceHashSimilarity(to: previous)

        statistics.update { gate in
            gate.averageDelta = gate.averageDelta == 0
                ? delta
                : (gate.averageDelta * 0.8) + (delta * 0.2)
        }

        // Gate 1: the screen barely moved. Reading static text is not work.
        guard delta >= DayPilotConfiguration.maximumSignificantFrameDelta else {
            statistics.update { $0.framesDroppedAsStatic += 1 }
            return
        }

        // Gate 2: perceptually identical despite pixel churn (caret, clock,
        // progress bar).
        guard similarity < DayPilotConfiguration.perceptualHashSimilarityThreshold else {
            statistics.update { $0.framesDroppedAsStatic += 1 }
            return
        }

        // Privacy shield, checked before any pixels are decoded or handed on.
        guard !suppression.value else {
            statistics.update { $0.framesDroppedAsSuppressed += 1 }
            return
        }

        guard let image = makeCGImage(from: pixelBuffer) else {
            statistics.update { $0.framesDroppedAsUnconvertible += 1 }
            return
        }

        onSignificantFrame(
            ScreenFrame(
                image: image,
                timestamp: Date(),
                displayIdentifier: displayIdentifier,
                pixelWidth: CVPixelBufferGetWidth(pixelBuffer),
                pixelHeight: CVPixelBufferGetHeight(pixelBuffer),
                frameDelta: delta,
                hashSimilarity: similarity
            )
        )
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("ScreenCaptureKit stream stopped: \(error.localizedDescription, privacy: .public)")
        onFailure("Screen capture stopped: \(error.localizedDescription)")
    }

    /// Decodes the frame to a CGImage, or not at all.
    ///
    /// The pixel buffer is never retained: `CGImage` materializes its own copy,
    /// so the `CMSampleBuffer` is released the moment this call returns and no
    /// frame is held in memory a moment longer than it takes to read it.
    private func makeCGImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)

        if renderContext.value == nil {
            let context = CIContext(options: [
                .useSoftwareRenderer: false,
                .cacheIntermediates: false
            ])
            renderContext.set(context)
        }
        guard let context = renderContext.value else { return nil }

        return context.createCGImage(image, from: image.extent)
    }
}

enum ScreenCaptureError: LocalizedError {
    case alreadyRunning
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Screen capture is already running."
        case .noDisplayAvailable:
            "DayPilot could not find a display to capture."
        }
    }
}
