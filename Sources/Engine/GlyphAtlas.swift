import CoreGraphics
import CoreText
import Foundation
import Metal

/// Renders the Matrix character set into a single-channel texture atlas.
/// Like the film, the katakana are mirrored; digits and Latin symbols are not.
struct GlyphAtlas {
    let texture: MTLTexture
    let count: Int
    let cols: Int
    let rows: Int
    /// CPU copy of the atlas, handy for checking the glyph set.
    let image: CGImage?

    static let katakana = "ｦｱｲｳｴｵｶｷｸｹｺｻｼｽｾｿﾀﾁﾂﾃﾄﾅﾆﾇﾈﾉﾊﾋﾌﾍﾎﾏﾐﾑﾒﾓﾔﾕﾖﾗﾘﾙﾚﾛﾜﾝ"
    static let symbols = "012345789Z:.\"=*+-<>¦|"

    init(device: MTLDevice, queue: MTLCommandQueue, tile: Int = 64) {
        let glyphs: [(String, Bool)] = GlyphAtlas.katakana.map { (String($0), true) } + GlyphAtlas.symbols.map { (String($0), false) }
        cols = 8
        rows = (glyphs.count + cols - 1) / cols
        count = glyphs.count

        let width = cols * tile, height = rows * tile
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setShouldAntialias(true)

        let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, CGFloat(tile) * 0.8, nil)
        let white = CGColor(gray: 1, alpha: 1)
        let lines = glyphs.map { text, _ in
            CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): white,
            ]))
        }
        let allBounds = lines.map { CTLineGetBoundsWithOptions($0, .useGlyphPathBounds) }

        // One shared scale and vertical centre for the whole set, so dots stay dots and
        // dashes stay thin instead of being blown up to fill the cell.
        let inked = allBounds.filter { $0.height > 0 }
        let top = inked.map(\.maxY).max() ?? 1, bottom = inked.map(\.minY).min() ?? 0
        let scale = CGFloat(tile) * 0.8 / (top - bottom)
        let midY = (top + bottom) / 2

        for (i, (_, mirrored)) in glyphs.enumerated() {
            let bounds = allBounds[i]
            guard bounds.width > 0, bounds.height > 0 else { continue }

            // Half-width katakana are narrow; widen full-height glyphs a little so the
            // columns read as dense blocks of code like in the film.
            let fullHeight = bounds.height * scale > CGFloat(tile) * 0.45
            let widen = fullHeight ? min(max(CGFloat(tile) * 0.62 / (bounds.width * scale), 1), 1.35) : 1

            let tx = CGFloat((i % cols) * tile) + CGFloat(tile) / 2
            let ty = CGFloat(height - (i / cols + 1) * tile) + CGFloat(tile) / 2
            ctx.saveGState()
            ctx.translateBy(x: tx, y: ty)
            ctx.scaleBy(x: (mirrored ? -scale : scale) * widen, y: scale)
            ctx.translateBy(x: -bounds.midX, y: -midY)
            ctx.textPosition = .zero
            CTLineDraw(lines[i], ctx)
            ctx.restoreGState()
        }

        image = ctx.makeImage()

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: true)
        desc.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: desc)!
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: ctx.data!, bytesPerRow: ctx.bytesPerRow)

        let cmd = queue.makeCommandBuffer()!
        let blit = cmd.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }
}
