import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import Metal

final class Compositor: @unchecked Sendable {

    // All mutable state is accessed exclusively on this queue.
    // requestMediaDataWhenReady runs its closure synchronously on the provided queue,
    // so this pattern is safe under Swift 6 strict concurrency.
    private let queue = DispatchQueue(
        label: "com.composite-bezel.compositor",
        qos: .userInitiated
    )

    // Set to true from queue; read after sema.wait() from main
    private(set) var failed = false

    // ── Init parameters ────────────────────────────────────────────────────────
    private let bgURL: URL?
    private let scrURL: URL
    private let bezelURL: URL
    private let outputURL: URL
    private let dims: DimensionCalc
    private let bgStart: Double
    private let scrStart: Double
    private let activeDuration: Double
    private let outputBitrate: Int
    private let bgBitrate: Int
    private let bgPreferredTransform: CGAffineTransform?
    private let scrPreferredTransform: CGAffineTransform
    private let totalFrames: Int    // for progress reporting
    private let bgRotationOverride: Int?
    private let scrRotationOverride: Int?
    private let bgColor: CGColor?

    init(
        bgURL: URL?,
        scrURL: URL,
        bezelURL: URL,
        outputURL: URL,
        dims: DimensionCalc,
        bgStart: Double,
        scrStart: Double,
        activeDuration: Double,
        bgBitrate: Int,
        outputBitrate: Int,
        bgPreferredTransform: CGAffineTransform?,
        scrPreferredTransform: CGAffineTransform,
        totalFrames: Int,
        bgRotationOverride: Int? = nil,
        scrRotationOverride: Int? = nil,
        bgColor: CGColor? = nil
    ) {
        self.bgURL                 = bgURL
        self.scrURL                = scrURL
        self.bezelURL              = bezelURL
        self.outputURL             = outputURL
        self.dims                  = dims
        self.bgStart               = bgStart
        self.scrStart              = scrStart
        self.activeDuration        = activeDuration
        self.bgBitrate             = bgBitrate
        self.outputBitrate         = outputBitrate
        self.bgPreferredTransform  = bgPreferredTransform
        self.scrPreferredTransform = scrPreferredTransform
        self.totalFrames           = totalFrames
        self.bgRotationOverride    = bgRotationOverride
        self.scrRotationOverride   = scrRotationOverride
        self.bgColor               = bgColor
    }

    // ── Public entry point ─────────────────────────────────────────────────────
    func start(sema: DispatchSemaphore) {
        queue.async { [self] in
            do {
                if let bgColor = self.bgColor {
                    try self.runSolid(sema: sema, bgColor: bgColor)
                } else {
                    try self.run(sema: sema)
                }
            } catch {
                fputs("Error: \(error)\n", stderr)
                self.failed = true
                sema.signal()
            }
        }
    }

    // ── Solid background mode ──────────────────────────────────────────────────
    private func runSolid(sema: DispatchSemaphore, bgColor: CGColor) throws {
        // ── Metal CIContext ────────────────────────────────────────────────────
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw CompositorError.noMetalDevice
        }
        let ciCtx = CIContext(mtlDevice: metalDevice, options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .outputPremultiplied: false,
            .cacheIntermediates: true,
        ])

        // ── Load bezel PNG (once) ──────────────────────────────────────────────
        guard let bezelCI = CIImage(
            contentsOf: bezelURL,
            options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]
        ) else {
            throw CompositorError.bezelLoadFailed(bezelURL.path)
        }

        // Pre-compute solid background — same image every frame
        let bgCI = CIImage(color: CIColor(cgColor: bgColor))
            .cropped(to: CGRect(x: 0, y: 0, width: dims.outW, height: dims.outH))

        // ── Configure screen reader ────────────────────────────────────────────
        let scrAsset = AVAsset(url: scrURL)
        let decodeOpts: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        let scrReader = try AVAssetReader(asset: scrAsset)
        guard let scrTrack = scrAsset.tracks(withMediaType: .video).first else {
            throw CompositorError.noVideoTrack
        }
        let scrOut = AVAssetReaderTrackOutput(track: scrTrack, outputSettings: decodeOpts)
        scrOut.alwaysCopiesSampleData = false
        scrReader.add(scrOut)

        let ts: CMTimeScale = 600
        scrReader.timeRange = CMTimeRange(
            start:    CMTime(seconds: scrStart,       preferredTimescale: ts),
            duration: CMTime(seconds: activeDuration, preferredTimescale: ts)
        )
        guard scrReader.startReading() else {
            throw CompositorError.readerFailed("scr", scrReader.error)
        }

        // ── Configure writer ───────────────────────────────────────────────────
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let colorProps: [String: Any] = [
            AVVideoColorPrimariesKey:       AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey:     AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey:          AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey:    AVVideoCodecType.hevc,
            AVVideoWidthKey:    dims.outW,
            AVVideoHeightKey:   dims.outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:   outputBitrate,
                AVVideoProfileLevelKey:     "HEVC_Main_AutoLevel",
            ],
            AVVideoColorPropertiesKey: colorProps,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey          as String: dims.outW,
            kCVPixelBufferHeightKey         as String: dims.outH,
            kCVPixelBufferPoolMinimumBufferCountKey as String: 16,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: poolAttrs
        )

        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let scrOrigin = scrReader.timeRange.start
        let wallStart = Date()
        var frameCount = 0

        // ── Frame loop ─────────────────────────────────────────────────────────
        videoInput.requestMediaDataWhenReady(on: queue) { [self] in
            while videoInput.isReadyForMoreMediaData {
                guard let scrSample = scrOut.copyNextSampleBuffer() else {
                    if scrReader.status == .completed {
                        videoInput.markAsFinished()
                        writer.finishWriting { sema.signal() }
                    } else {
                        fputs("Error: scr reader failed: \(scrReader.error?.localizedDescription ?? "unknown")\n", stderr)
                        self.failed = true
                        writer.cancelWriting()
                        sema.signal()
                    }
                    return
                }

                guard let scrBuf = CMSampleBufferGetImageBuffer(scrSample) else { continue }
                let rawScrPTS = CMSampleBufferGetPresentationTimeStamp(scrSample)
                let relScrPTS = CMTimeSubtract(rawScrPTS, scrOrigin)

                // ── GPU composite ──────────────────────────────────────────────
                var scrCI = CIImage(cvPixelBuffer: scrBuf)

                if let deg = self.scrRotationOverride {
                    scrCI = self.applyExplicitRotation(scrCI, degrees: deg)
                } else {
                    scrCI = self.applyRotation(scrCI, transform: self.scrPreferredTransform)
                }

                let d = self.dims

                // Scale screen content to fit bezel screen area
                let preScrW = scrCI.extent.width
                let preScrH = scrCI.extent.height
                let scrScaleX = Double(d.screenW) / Double(preScrW)
                let scrScaleY = Double(d.screenH) / Double(preScrH)
                let scrScale = min(scrScaleX, scrScaleY)
                let scaledScrW = CGFloat(Double(preScrW) * scrScale)
                let scaledScrH = CGFloat(Double(preScrH) * scrScale)
                scrCI = scrCI.applyingFilter("CIBicubicScaleTransform", parameters: [
                    "inputScale": scrScale,
                ])

                // Center screen on transparent bezel canvas
                let centeredXOff   = (CGFloat(DimensionCalc.bezelW) - scaledScrW) / 2
                let centeredYOffCI = (CGFloat(DimensionCalc.bezelH) - scaledScrH) / 2

                let canvas = CIImage(color: .clear).cropped(
                    to: CGRect(x: 0, y: 0, width: DimensionCalc.bezelW, height: DimensionCalc.bezelH)
                )
                let scrOnCanvas = scrCI
                    .transformed(by: CGAffineTransform(
                        translationX: centeredXOff,
                        y:            centeredYOffCI
                    ))
                    .composited(over: canvas)

                // Composite bezel PNG over screen
                let bezeled = bezelCI.composited(over: scrOnCanvas)

                // Scale bezeled iPad to overlay size
                let bezScaleX = Double(d.ovlW) / bezeled.extent.width
                let bezScaleY = Double(d.ovlH) / bezeled.extent.height
                let bezScaled = bezeled.applyingFilter("CIBicubicScaleTransform", parameters: [
                    "inputScale":       min(bezScaleX, bezScaleY),
                    "inputAspectRatio": bezScaleX / bezScaleY,
                ])

                // Position overlay over solid background
                let bezPos = bezScaled.transformed(by: CGAffineTransform(
                    translationX: CGFloat(d.ovlX),
                    y:            CGFloat(d.ovlYCI)
                ))
                let result = bezPos.composited(over: bgCI)

                // ── Render to output buffer ────────────────────────────────────
                var outBuf: CVPixelBuffer?
                let poolStatus = CVPixelBufferPoolCreatePixelBuffer(
                    nil, adaptor.pixelBufferPool!, &outBuf
                )
                guard poolStatus == kCVReturnSuccess, let outBuf else {
                    fputs("Error: pixel buffer pool exhausted\n", stderr)
                    self.failed = true
                    writer.cancelWriting()
                    sema.signal()
                    return
                }

                ciCtx.render(
                    result,
                    to: outBuf,
                    bounds: CGRect(x: 0, y: 0, width: d.outW, height: d.outH),
                    colorSpace: nil
                )

                adaptor.append(outBuf, withPresentationTime: relScrPTS)

                frameCount += 1
                if frameCount % 30 == 0 {
                    let elapsed = -wallStart.timeIntervalSinceNow
                    let fps = elapsed > 0 ? Double(frameCount) / elapsed : 0
                    let totalF = self.totalFrames
                    let pct = totalF > 0 ? Int(Double(frameCount) * 100 / Double(totalF)) : 0
                    let rtMultiplier = self.activeDuration > 0
                        ? fps / (Double(totalF) / self.activeDuration) : 0
                    let etaSecs = fps > 0 && totalF > frameCount
                        ? Double(totalF - frameCount) / fps : 0
                    fputs(
                        "\rFrame \(frameCount)/\(totalF) (\(pct)%) — \(String(format: "%.1f", fps)) fps" +
                        " — \(String(format: "%.1f", rtMultiplier))× real-time" +
                        " — elapsed \(Int(elapsed))s / ETA \(Int(etaSecs))s   ",
                        stderr
                    )
                }
            }
        }
    }

    // ── Main compositing loop ──────────────────────────────────────────────────
    private func run(sema: DispatchSemaphore) throws {
        guard let bgURL = bgURL, let bgPreferredTransform = bgPreferredTransform else {
            throw CompositorError.missingBgInputs
        }

        // ── Metal CIContext ────────────────────────────────────────────────────
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw CompositorError.noMetalDevice
        }
        let ciCtx = CIContext(mtlDevice: metalDevice, options: [
            .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
            .outputPremultiplied: false,
            .cacheIntermediates: true,
        ])

        // ── Load bezel PNG (once) ──────────────────────────────────────────────
        guard let bezelCI = CIImage(
            contentsOf: bezelURL,
            options: [.colorSpace: CGColorSpaceCreateDeviceRGB()]
        ) else {
            throw CompositorError.bezelLoadFailed(bezelURL.path)
        }

        // ── Configure readers ──────────────────────────────────────────────────
        let bgAsset  = AVAsset(url: bgURL)
        let scrAsset = AVAsset(url: scrURL)

        let decodeOpts: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]

        let bgReader  = try AVAssetReader(asset: bgAsset)
        let scrReader = try AVAssetReader(asset: scrAsset)

        guard let bgTrack  = bgAsset.tracks(withMediaType: .video).first,
              let scrTrack = scrAsset.tracks(withMediaType: .video).first
        else {
            throw CompositorError.noVideoTrack
        }

        let bgOut  = AVAssetReaderTrackOutput(track: bgTrack,  outputSettings: decodeOpts)
        let scrOut = AVAssetReaderTrackOutput(track: scrTrack, outputSettings: decodeOpts)
        bgOut.alwaysCopiesSampleData  = false
        scrOut.alwaysCopiesSampleData = false

        bgReader.add(bgOut)
        scrReader.add(scrOut)

        // Set timeRange before startReading
        let ts: CMTimeScale = 600
        bgReader.timeRange = CMTimeRange(
            start:    CMTime(seconds: bgStart,    preferredTimescale: ts),
            duration: CMTime(seconds: activeDuration, preferredTimescale: ts)
        )
        scrReader.timeRange = CMTimeRange(
            start:    CMTime(seconds: scrStart,   preferredTimescale: ts),
            duration: CMTime(seconds: activeDuration, preferredTimescale: ts)
        )

        guard bgReader.startReading()  else { throw CompositorError.readerFailed("bg",  bgReader.error)  }
        guard scrReader.startReading() else { throw CompositorError.readerFailed("scr", scrReader.error) }

        // ── Configure writer ───────────────────────────────────────────────────
        // Remove any pre-existing output file
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let colorProps: [String: Any] = [
            AVVideoColorPrimariesKey:       AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey:     AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey:          AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        let videoSettings: [String: Any] = [
            AVVideoCodecKey:    AVVideoCodecType.hevc,
            AVVideoWidthKey:    dims.outW,
            AVVideoHeightKey:   dims.outH,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey:   outputBitrate,
                AVVideoProfileLevelKey:     "HEVC_Main_AutoLevel",
            ],
            AVVideoColorPropertiesKey: colorProps,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let poolAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey          as String: dims.outW,
            kCVPixelBufferHeightKey         as String: dims.outH,
            kCVPixelBufferPoolMinimumBufferCountKey as String: 16,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: poolAttrs
        )

        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // ── Screen ring buffer (2 slots) ───────────────────────────────────────
        // Stores last two decoded screen frames; we pick the newest whose PTS ≤ current BG PTS.
        var scrRing: [(pts: CMTime, buf: CVPixelBuffer)] = []
        var scrEOF = false

        let bgOrigin = bgReader.timeRange.start
        let scrOrigin = scrReader.timeRange.start

        // Progress state
        let wallStart = Date()
        var frameCount = 0

        // ── Frame loop ─────────────────────────────────────────────────────────
        videoInput.requestMediaDataWhenReady(on: queue) { [self] in
            while videoInput.isReadyForMoreMediaData {
                // Decode next BG frame
                guard let bgSample = bgOut.copyNextSampleBuffer() else {
                    // BG stream ended
                    if bgReader.status == .completed {
                        videoInput.markAsFinished()
                        writer.finishWriting { sema.signal() }
                    } else {
                        fputs("Error: bg reader failed: \(bgReader.error?.localizedDescription ?? "unknown")\n", stderr)
                        self.failed = true
                        writer.cancelWriting()
                        sema.signal()
                    }
                    return
                }

                guard let bgBuf = CMSampleBufferGetImageBuffer(bgSample) else { continue }
                let rawBgPTS = CMSampleBufferGetPresentationTimeStamp(bgSample)
                let relBgPTS = CMTimeSubtract(rawBgPTS, bgOrigin)

                // Drain screen ring buffer: advance while next frame PTS ≤ current BG PTS
                if !scrEOF {
                    while true {
                        // Peek: is next scr frame still ≤ relBgPTS?
                        // Decode speculatively; keep in ring
                        if let scrSample = scrOut.copyNextSampleBuffer() {
                            guard let scrBuf = CMSampleBufferGetImageBuffer(scrSample) else { continue }
                            let rawScrPTS = CMSampleBufferGetPresentationTimeStamp(scrSample)
                            let relScrPTS = CMTimeSubtract(rawScrPTS, scrOrigin)
                            scrRing.append((pts: relScrPTS, buf: scrBuf))
                            if scrRing.count > 2 { scrRing.removeFirst() }
                            // Keep reading ahead until we overshoot bg PTS
                            if CMTimeCompare(relScrPTS, relBgPTS) > 0 { break }
                        } else {
                            // Screen EOF
                            if scrReader.status == .completed || scrReader.status == .reading {
                                scrEOF = true
                            } else {
                                fputs("Error: scr reader failed: \(scrReader.error?.localizedDescription ?? "unknown")\n", stderr)
                                self.failed = true
                                writer.cancelWriting()
                                sema.signal()
                                return
                            }
                            break
                        }
                    }
                }

                // Pick best screen frame: newest in ring with PTS ≤ relBgPTS
                guard let scrEntry = (scrRing.last(where: { CMTimeCompare($0.pts, relBgPTS) <= 0 }) ?? scrRing.last) else {
                    // No screen frame yet — skip this bg frame
                    continue
                }
                let scrBuf = scrEntry.buf

                // ── GPU composite ──────────────────────────────────────────────
                var bgCI  = CIImage(cvPixelBuffer: bgBuf)
                var scrCI = CIImage(cvPixelBuffer: scrBuf)

                if let deg = self.bgRotationOverride {
                    bgCI = self.applyExplicitRotation(bgCI, degrees: deg)
                } else {
                    bgCI = self.applyRotation(bgCI, transform: bgPreferredTransform)
                }
                if let deg = self.scrRotationOverride {
                    scrCI = self.applyExplicitRotation(scrCI, degrees: deg)
                } else {
                    scrCI = self.applyRotation(scrCI, transform: self.scrPreferredTransform)
                }

                let d = self.dims

                // Scale bg to output size (only needed if outputWidth set, but do always for safety)
                let bgScaleX = Double(d.outW) / bgCI.extent.width
                let bgScaleY = Double(d.outH) / bgCI.extent.height
                if abs(bgScaleX - 1.0) > 0.001 || abs(bgScaleY - 1.0) > 0.001 {
                    bgCI = bgCI.applyingFilter("CIBicubicScaleTransform", parameters: [
                        "inputScale":     min(bgScaleX, bgScaleY),
                        "inputAspectRatio": bgScaleX / bgScaleY,
                    ])
                }

                // Scale screen content to fit bezel screen area — preserve aspect ratio (no stretch).
                // Matches CPU path: scale=force_original_aspect_ratio=decrease + centered pad.
                let preScrW = scrCI.extent.width
                let preScrH = scrCI.extent.height
                let scrScaleX = Double(d.screenW) / Double(preScrW)
                let scrScaleY = Double(d.screenH) / Double(preScrH)
                let scrScale = min(scrScaleX, scrScaleY)
                // Compute expected output dimensions before applying filter (avoids relying on
                // post-filter extent which may not update in CIImage's lazy evaluation model)
                let scaledScrW = CGFloat(Double(preScrW) * scrScale)
                let scaledScrH = CGFloat(Double(preScrH) * scrScale)
                scrCI = scrCI.applyingFilter("CIBicubicScaleTransform", parameters: [
                    "inputScale": scrScale,
                ])

                // Center the fit content within the bezel canvas (CIImage Y-up)
                let centeredXOff   = (CGFloat(DimensionCalc.bezelW) - scaledScrW) / 2
                let centeredYOffCI = (CGFloat(DimensionCalc.bezelH) - scaledScrH) / 2

                // Place screen onto transparent bezel-sized canvas
                let canvas = CIImage(color: .clear).cropped(
                    to: CGRect(x: 0, y: 0, width: DimensionCalc.bezelW, height: DimensionCalc.bezelH)
                )
                let scrOnCanvas = scrCI
                    .transformed(by: CGAffineTransform(
                        translationX: centeredXOff,
                        y:            centeredYOffCI
                    ))
                    .composited(over: canvas)

                // Composite bezel PNG over screen
                let bezeled = bezelCI.composited(over: scrOnCanvas)

                // Scale bezeled iPad to overlay size
                let bezScaleX = Double(d.ovlW) / bezeled.extent.width
                let bezScaleY = Double(d.ovlH) / bezeled.extent.height
                let bezScaled = bezeled.applyingFilter("CIBicubicScaleTransform", parameters: [
                    "inputScale":       min(bezScaleX, bezScaleY),
                    "inputAspectRatio": bezScaleX / bezScaleY,
                ])

                // Position overlay over background (CI bottom-left origin)
                let bezPos = bezScaled.transformed(by: CGAffineTransform(
                    translationX: CGFloat(d.ovlX),
                    y:            CGFloat(d.ovlYCI)
                ))
                let result = bezPos.composited(over: bgCI)

                // ── Render to output buffer ────────────────────────────────────
                var outBuf: CVPixelBuffer?
                let poolStatus = CVPixelBufferPoolCreatePixelBuffer(
                    nil, adaptor.pixelBufferPool!, &outBuf
                )
                guard poolStatus == kCVReturnSuccess, let outBuf else {
                    fputs("Error: pixel buffer pool exhausted\n", stderr)
                    self.failed = true
                    writer.cancelWriting()
                    sema.signal()
                    return
                }

                ciCtx.render(
                    result,
                    to: outBuf,
                    bounds: CGRect(x: 0, y: 0, width: d.outW, height: d.outH),
                    colorSpace: nil
                )

                adaptor.append(outBuf, withPresentationTime: relBgPTS)

                frameCount += 1
                if frameCount % 30 == 0 {
                    let elapsed = -wallStart.timeIntervalSinceNow
                    let fps = elapsed > 0 ? Double(frameCount) / elapsed : 0
                    let totalF = self.totalFrames
                    let pct = totalF > 0 ? Int(Double(frameCount) * 100 / Double(totalF)) : 0
                    let rtMultiplier = self.activeDuration > 0
                        ? fps / (Double(totalF) / self.activeDuration) : 0
                    let etaSecs = fps > 0 && totalF > frameCount
                        ? Double(totalF - frameCount) / fps : 0
                    fputs(
                        "\rFrame \(frameCount)/\(totalF) (\(pct)%) — \(String(format: "%.1f", fps)) fps" +
                        " — \(String(format: "%.1f", rtMultiplier))× real-time" +
                        " — elapsed \(Int(elapsed))s / ETA \(Int(etaSecs))s   ",
                        stderr
                    )
                }
            }
        }
    }

    // ── Rotation helpers ───────────────────────────────────────────────────────

    // Applies AVAssetTrack.preferredTransform (designed for UIKit Y-down coords) to a
    // CIImage (Y-up coords). For 90°/270° rotations the Y-axis difference causes a 180°
    // error in the result; this is corrected by the additional flip below.
    // For 0°/180° rotations no correction is needed (symmetric under Y-flip).
    private func applyRotation(_ image: CIImage, transform: CGAffineTransform) -> CIImage {
        let rotated = image.transformed(by: transform)
        let normalized = rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.origin.x,
            y:            -rotated.extent.origin.y
        ))

        // atan2(b, a) gives the rotation angle embedded in the UIKit transform.
        // For 90°/270° rotations, apply a compensating 180° flip.
        let angle = atan2(transform.b, transform.a)
        let absAngleDeg = abs(angle * 180.0 / .pi)
        let needsFlip = (absAngleDeg > 44 && absAngleDeg < 136) ||
                        (absAngleDeg > 224 && absAngleDeg < 316)

        guard needsFlip else { return normalized }

        let w = normalized.extent.width
        let h = normalized.extent.height
        // 180° rotation: (a:-1, d:-1, tx:w, ty:h) keeps origin at (0,0)
        return normalized.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
    }

    // Applies an explicit CW rotation in CIImage (Y-up) coordinate space.
    // Used when the caller specifies --bg-rotation or --scr-rotation to override
    // auto-detection. Since this operates directly in CIImage coords, no Y-axis
    // compensation is needed.
    private func applyExplicitRotation(_ image: CIImage, degrees: Int) -> CIImage {
        let norm = ((degrees % 360) + 360) % 360
        guard norm != 0 else { return image }
        // Negative radians = CW in CIImage (Y-up, where positive angle = CCW)
        let radians = -Double(norm) * .pi / 180.0
        let cosA = CGFloat(cos(radians))
        let sinA = CGFloat(sin(radians))
        let rotated = image.transformed(by: CGAffineTransform(a: cosA, b: sinA, c: -sinA, d: cosA, tx: 0, ty: 0))
        return rotated.transformed(by: CGAffineTransform(
            translationX: -rotated.extent.origin.x,
            y:            -rotated.extent.origin.y
        ))
    }
}

// ── Errors ─────────────────────────────────────────────────────────────────────
enum CompositorError: Error, CustomStringConvertible {
    case noMetalDevice
    case bezelLoadFailed(String)
    case noVideoTrack
    case readerFailed(String, Error?)
    case missingBgInputs

    var description: String {
        switch self {
        case .noMetalDevice:            return "No Metal device found"
        case .bezelLoadFailed(let p):   return "Failed to load bezel image: \(p)"
        case .noVideoTrack:             return "No video track found in asset"
        case .readerFailed(let s, let e):
            return "Asset reader (\(s)) failed: \(e?.localizedDescription ?? "unknown")"
        case .missingBgInputs:          return "Background URL and transform required in normal mode"
        }
    }
}
