import Foundation

struct DimensionCalc {
    // Bezel PNG intrinsic dimensions
    static let bezelW: Int = 1780
    static let bezelH: Int = 2550
    // Screen content occupies 89% of bezel canvas (matches ipad_bezel.sh / shell script)
    static let scale: Double = 0.89

    // Output dimensions
    let outW: Int
    let outH: Int

    // Screen content area within bezel canvas
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
        bgEffW: Int,
        bgEffH: Int,
        outputWidth: Int?,
        overlayScale: Double,
        margin: Int,
        xOverride: Int?,
        yOverride: Int?
    ) {
        // Output resolution
        if let ow = outputWidth {
            outW = Self.even(ow)
            outH = Self.even(Int(Double(ow) * Double(bgEffH) / Double(bgEffW)))
        } else {
            outW = bgEffW
            outH = bgEffH
        }

        // Screen area within bezel canvas (89% of bezel, even integers)
        screenW = Self.even(Int(Double(Self.bezelW) * Self.scale))
        screenH = Self.even(Int(Double(Self.bezelH) * Self.scale))
        xOff    = (Self.bezelW - screenW) / 2
        yOff    = (Self.bezelH - screenH) / 2
        yOffCI  = Self.bezelH - yOff - screenH

        // Overlay scaled to output height * overlayScale (even integers)
        ovlH = Self.even(Int(Double(outH) * overlayScale))
        ovlW = Self.even(Int(Double(ovlH) * Double(Self.bezelW) / Double(Self.bezelH)))

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
