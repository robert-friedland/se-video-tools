import AVFoundation
import ArgumentParser
import CoreMedia
import Foundation

struct CompositeBezelGPU: ParsableCommand {

    static let configuration = CommandConfiguration(
        commandName: "composite_bezel_gpu",
        abstract: "GPU-accelerated iPad bezel compositing (video-only output; shell does audio mux)"
    )

    // ── Positional arguments ────────────────────────────────────────────────────
    @Argument(help: "Background video file")
    var background: String

    @Argument(help: "Screen recording file")
    var screen: String

    // ── Required options ────────────────────────────────────────────────────────
    @Option(help: "Path to bezel PNG (required; shell passes --bezel \"$BEZEL\")")
    var bezel: String

    // ── Optional output ─────────────────────────────────────────────────────────
    @Option(help: "Output file path (default: derived from background filename)")
    var output: String?

    // ── Overlay options ─────────────────────────────────────────────────────────
    @Option(name: .customLong("overlay-scale"), help: "iPad height as fraction of output height (default: 0.7)")
    var overlayScale: Double = 0.7

    @Option(help: "Right/left edge margin when --x is not set (default: 40)")
    var margin: Int = 40

    @Option(help: "X pixel position of overlay (default: right side minus --margin)")
    var x: Int?

    @Option(help: "Y pixel position of overlay (default: vertically centered)")
    var y: Int?

    // ── Timing options ──────────────────────────────────────────────────────────
    @Option(name: .customLong("bg-start"), help: "Start time in seconds for background clip (default: 0)")
    var bgStart: Double = 0.0

    @Option(name: .customLong("scr-start"), help: "Start time in seconds for screen recording (default: 0)")
    var scrStart: Double = 0.0

    @Option(
        name: [.customLong("duration"), .customLong("test-seconds")],
        help: "Render N seconds of output (default: min of remaining clip lengths)"
    )
    var duration: Double?

    // ── Passthrough options (accepted, handled by shell wrapper) ────────────────
    @Option(help: "Audio mode: both|bg|screen|none (accepted; audio is done by the shell ffmpeg pass)")
    var audio: String = "both"

    @Option(help: "Parallel jobs (accepted; GPU uses single-pass pipeline)")
    var jobs: Int?

    @Option(name: .customLong("output-width"), help: "Scale output to this width (e.g. 1920)")
    var outputWidth: Int?

    @Option(name: .customLong("bg-rotation"),
            help: "Override background rotation in degrees CW (0/90/180/270); auto-detected from track metadata if omitted")
    var bgRotation: Int?

    @Option(name: .customLong("scr-rotation"),
            help: "Override screen recording rotation in degrees CW (0/90/180/270); auto-detected from track metadata if omitted")
    var scrRotation: Int?

    // ── Run ─────────────────────────────────────────────────────────────────────
    func run() throws {
        let bgURL    = URL(fileURLWithPath: background)
        let scrURL   = URL(fileURLWithPath: screen)
        let bezelURL = URL(fileURLWithPath: bezel)

        // Validate inputs
        guard FileManager.default.fileExists(atPath: bgURL.path) else {
            throw ValidationError("Background file not found: \(background)")
        }
        guard FileManager.default.fileExists(atPath: scrURL.path) else {
            throw ValidationError("Screen recording not found: \(screen)")
        }
        guard FileManager.default.fileExists(atPath: bezelURL.path) else {
            throw ValidationError("Bezel file not found: \(bezel)")
        }

        let outputPath: String
        if let out = output {
            outputPath = out
        } else {
            let base = bgURL.deletingPathExtension().lastPathComponent
            outputPath = bgURL.deletingLastPathComponent()
                .appendingPathComponent("\(base)_composite.mp4").path
        }
        let outputURL = URL(fileURLWithPath: outputPath)

        // ── Probe assets synchronously ─────────────────────────────────────────
        let bgAsset  = AVAsset(url: bgURL)
        let scrAsset = AVAsset(url: scrURL)

        guard let bgTrack = bgAsset.tracks(withMediaType: .video).first else {
            throw ValidationError("No video track found in background: \(background)")
        }
        guard let scrTrack = scrAsset.tracks(withMediaType: .video).first else {
            throw ValidationError("No video track found in screen recording: \(screen)")
        }

        // Rotation-adjusted effective dimensions
        let bgTransform  = bgTrack.preferredTransform
        let scrTransform = scrTrack.preferredTransform

        let bgNatSize  = bgTrack.naturalSize
        let scrNatSize = scrTrack.naturalSize

        let bgEffSize  = effectiveSize(naturalSize: bgNatSize,  transform: bgTransform)
        let scrEffSize = effectiveSize(naturalSize: scrNatSize, transform: scrTransform)

        // Apply rotation overrides: when specified, recompute effective size from the
        // override angle (90°/270° → transpose width/height; 0°/180° → keep as-is).
        let finalBgEffSize: CGSize = bgRotation.map { deg in
            deg % 180 != 0
                ? CGSize(width: bgNatSize.height, height: bgNatSize.width)
                : bgNatSize
        } ?? bgEffSize

        let finalScrEffSize: CGSize = scrRotation.map { deg in
            deg % 180 != 0
                ? CGSize(width: scrNatSize.height, height: scrNatSize.width)
                : scrNatSize
        } ?? scrEffSize

        // Background bitrate (stream → container → floor)
        var bgBitrate = Int(bgTrack.estimatedDataRate)
        if bgBitrate == 0 {
            bgBitrate = Int(bgAsset.tracks.reduce(0.0) { $0 + $1.estimatedDataRate })
        }
        if bgBitrate == 0 { bgBitrate = 10_000_000 }

        // Active duration
        let bgDuration  = bgAsset.duration.seconds
        let scrDuration = scrAsset.duration.seconds
        let bgRemaining  = bgDuration  - bgStart
        let scrRemaining = scrDuration - scrStart
        let activeDuration: Double
        if let d = duration {
            activeDuration = d
        } else {
            activeDuration = min(bgRemaining, scrRemaining)
        }

        guard activeDuration > 0 else {
            throw ValidationError("Active duration is zero or negative. Check --bg-start and --scr-start values.")
        }

        // Total frame count for progress display
        let fps = bgTrack.nominalFrameRate > 0 ? Double(bgTrack.nominalFrameRate) : 30.0
        let totalFrames = max(1, Int(fps * activeDuration + 0.5))

        // Dimension calculations
        let dims = DimensionCalc(
            bgEffW:       Int(finalBgEffSize.width),
            bgEffH:       Int(finalBgEffSize.height),
            outputWidth:  outputWidth,
            overlayScale: overlayScale,
            margin:       margin,
            xOverride:    x,
            yOverride:    y
        )

        // Summary
        fputs("Background:      \(Int(finalBgEffSize.width))x\(Int(finalBgEffSize.height)) — \(String(format: "%.1f", bgDuration))s @ \(bgBitrate)bps\n", stderr)
        fputs("Screen:          \(Int(finalScrEffSize.width))x\(Int(finalScrEffSize.height)) — \(String(format: "%.1f", scrDuration))s\n", stderr)
        fputs("Active duration: \(String(format: "%.2f", activeDuration))s\n", stderr)
        fputs("Output:          \(dims.outW)x\(dims.outH) → \(outputPath)\n", stderr)
        fputs("Overlay:         \(dims.ovlW)x\(dims.ovlH) at (\(dims.ovlX), \(dims.ovlY))\n", stderr)
        fputs("GPU compositing starting...\n", stderr)

        // ── Run compositor ─────────────────────────────────────────────────────
        let sema = DispatchSemaphore(value: 0)
        let compositor = Compositor(
            bgURL:                bgURL,
            scrURL:               scrURL,
            bezelURL:             bezelURL,
            outputURL:            outputURL,
            dims:                 dims,
            bgStart:              bgStart,
            scrStart:             scrStart,
            activeDuration:       activeDuration,
            bgBitrate:            bgBitrate,
            bgPreferredTransform: bgTransform,
            scrPreferredTransform: scrTransform,
            totalFrames:          totalFrames,
            bgRotationOverride:   bgRotation,
            scrRotationOverride:  scrRotation
        )
        compositor.start(sema: sema)
        sema.wait()

        fputs("\n", stderr)

        if compositor.failed {
            throw ExitCode(1)
        }

        fputs("Done: \(outputPath)\n", stderr)
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────

    /// Returns the effective (display) size of a video track after applying preferredTransform.
    /// For 90° / 270° rotations the width and height are swapped.
    private func effectiveSize(naturalSize: CGSize, transform: CGAffineTransform) -> CGSize {
        // Determine rotation angle from the transform
        let angle = atan2(transform.b, transform.a)
        let degrees = abs(angle * 180.0 / .pi)
        let isTransposed = (degrees > 45 && degrees < 135) || (degrees > 225 && degrees < 315)
        if isTransposed {
            return CGSize(width: naturalSize.height, height: naturalSize.width)
        }
        return naturalSize
    }
}

CompositeBezelGPU.main()
