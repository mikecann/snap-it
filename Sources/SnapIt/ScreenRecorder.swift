import AVFoundation
import ScreenCaptureKit
import SnapItCore

/// Records part of one display to an H.264 MP4 with ScreenCaptureKit and AVAssetWriter.
/// Frames arrive only when something on screen changes, so a still screen costs nothing and the file
/// has a variable frame rate. Everything after `start` runs on one serial queue.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Result {
        let url: URL
        /// Host-clock time of the first frame: video time 0.
        let startTime: TimeInterval
        let duration: TimeInterval
        let size: CGSize
        let frames: Int
    }

    enum RecorderError: Error {
        case cannotWrite(String)
        case noFrames
    }

    let url: URL
    let outputSize: CGSize
    private let queue = DispatchQueue(label: "snap-it.recorder", qos: .userInteractive)
    private let stream: SCStream
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    // Only touched on `queue`.
    private var firstTime: CMTime?
    private var frames = 0
    private var stopping = false
    private var streamError: Error?

    /// `sourceRect` is in the display's points, top-left origin; `pixelSize` is that area in pixels.
    init(filter: SCContentFilter, sourceRect: CGRect, pixelSize: CGSize, url: URL) throws {
        self.url = url
        outputSize = VideoGeometry.outputSize(for: pixelSize)
        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = Int(outputSize.width)
        config.height = Int(outputSize.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = false
        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(outputSize.width),
            AVVideoHeightKey: Int(outputSize.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                // Screen text needs more bits than camera footage to stay crisp.
                AVVideoAverageBitRateKey: max(2_000_000, Int(outputSize.width * outputSize.height * 4)),
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.cannotWrite("the writer won't take a video track") }
        writer.add(input)
        super.init()
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    }

    func start() async throws {
        guard writer.startWriting() else {
            throw RecorderError.cannotWrite(writer.error?.localizedDescription ?? "startWriting failed")
        }
        try await stream.startCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, !stopping, sampleBuffer.isValid, Self.isCompleteFrame(sampleBuffer) else { return }
        let time = sampleBuffer.presentationTimeStamp
        if firstTime == nil {
            firstTime = time
            writer.startSession(atSourceTime: time)
        }
        guard input.isReadyForMoreMediaData else { return } // drop a frame rather than block the stream
        if input.append(sampleBuffer) { frames += 1 }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { self.streamError = error }
        Log.info("Recording stream stopped: \(error.localizedDescription)")
    }

    /// Idle and blank buffers carry no picture.
    private static func isCompleteFrame(_ buffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// Stops capture and finishes the file. The video runs until now, even if the screen sat still at the end.
    func stop() async throws -> Result {
        try? await stream.stopCapture()
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.stopping = true
                guard let first = self.firstTime else {
                    self.writer.cancelWriting()
                    continuation.resume(throwing: self.streamError ?? RecorderError.noFrames)
                    return
                }
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: max(end, first + CMTime(value: 1, timescale: 30)))
                self.writer.finishWriting {
                    if self.writer.status == .completed {
                        continuation.resume(returning: Result(url: self.url, startTime: first.seconds, duration: (max(end, first) - first).seconds,
                                                              size: self.outputSize, frames: self.frames))
                    } else {
                        continuation.resume(throwing: RecorderError.cannotWrite(self.writer.error?.localizedDescription ?? "finishWriting failed"))
                    }
                }
            }
        }
    }
}
