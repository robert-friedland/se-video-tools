import Foundation

// Per-bezel intrinsic dimensions and screen cutout. Discriminator is the bezel
// PNG's pixel size — adding a new bezel means appending one entry here.
struct BezelSpec {
    let bezelW: Int
    let bezelH: Int
    // Cutout = visible screen rectangle inside the bezel PNG (top-left origin, Y-down).
    let cutoutX: Int
    let cutoutY: Int
    let cutoutW: Int
    let cutoutH: Int
    // Pixels to inflate the centered fit region beyond the cutout. The screen
    // recording is fit-aspect-preserved into (cutoutW + 2*inflate) × (cutoutH + 2*inflate);
    // anything past the cutout edge falls behind the opaque chassis and hides
    // sub-pixel seams. 4 px reproduces the slop the legacy `scale=0.89` mini path had.
    let inflate: Int

    static let knownSpecs: [BezelSpec] = [
        // iPad mini — Starlight — Portrait
        BezelSpec(bezelW: 1780, bezelH: 2550,
                  cutoutX: 146, cutoutY: 142, cutoutW: 1488, cutoutH: 2266,
                  inflate: 4),
        // iPad (A16) — Silver — Portrait
        // cutoutW=1639 is the max horizontal transparent run at the cutout's
        // mid-row. Native iPad A16 recording is 1640×2360; the 4 px inflate
        // makes the fit region 1647×2368, so the recording fits without scaling.
        BezelSpec(bezelW: 2040, bezelH: 2760,
                  cutoutX: 200, cutoutY: 200, cutoutW: 1639, cutoutH: 2360,
                  inflate: 4),
    ]

    static func match(width: Int, height: Int) -> BezelSpec? {
        knownSpecs.first { $0.bezelW == width && $0.bezelH == height }
    }

    static func describeKnown() -> String {
        knownSpecs.map { "\($0.bezelW)x\($0.bezelH)" }.joined(separator: ", ")
    }
}

struct DimensionCalc {
    // Bezel PNG intrinsic dimensions (per-instance, varies by model)
    let bezelW: Int
    let bezelH: Int

    // Output dimensions
    let outW: Int
    let outH: Int

    // Screen content area within bezel canvas (cutout inflated by `inflate`)
    let screenW: Int
    let screenH: Int
    let xOff: Int   // screen left offset inside bezel canvas
    let yOff: Int   // screen top offset inside bezel canvas (ffmpeg coords, top-left origin)
    let yOffCI: Int // screen bottom offset inside bezel canvas (CI coords, bottom-left origin)

    // Overlay (scaled bezel) dimensions
    let ovlW: Int
    let ovlH: Int

    // Overlay position over bg (top-left origin)
    let ovlX: Int
    let ovlY: Int
    // Overlay position (CI bottom-left origin)
    let ovlYCI: Int

    init(
        bezel: BezelSpec,
        bgEffW: Int,
        bgEffH: Int,
        outputWidth: Int?,
        overlayScale: Double,
        margin: Int,
        xOverride: Int?,
        yOverride: Int?
    ) {
        bezelW = bezel.bezelW
        bezelH = bezel.bezelH

        // Output resolution
        if let ow = outputWidth {
            outW = Self.even(ow)
            outH = Self.even(Int(Double(ow) * Double(bgEffH) / Double(bgEffW)))
        } else {
            outW = bgEffW
            outH = bgEffH
        }

        // Screen area within bezel canvas: cutout + inflate margin, even integers.
        // Cutouts are centered in the bezel for both known specs, so xOff/yOff
        // computed as (bezelW - screenW)/2 equals (cutoutX - inflate).
        screenW = Self.even(bezel.cutoutW + 2 * bezel.inflate)
        screenH = Self.even(bezel.cutoutH + 2 * bezel.inflate)
        xOff    = (bezelW - screenW) / 2
        yOff    = (bezelH - screenH) / 2
        yOffCI  = bezelH - yOff - screenH

        // Overlay scaled to output height * overlayScale (even integers)
        ovlH = Self.even(Int(Double(outH) * overlayScale))
        ovlW = Self.even(Int(Double(ovlH) * Double(bezelW) / Double(bezelH)))

        // Overlay position
        if let x = xOverride {
            ovlX = x
        } else {
            ovlX = outW - ovlW - margin
        }
        if let y = yOverride {
            ovlY = y
        } else {
            ovlY = (outH - ovlH) / 2
        }
        // CI bottom-left origin Y
        ovlYCI = outH - ovlY - ovlH
    }

    // Round to nearest even integer
    private static func even(_ v: Int) -> Int {
        return (v / 2) * 2
    }
}
