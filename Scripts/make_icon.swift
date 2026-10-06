import AppKit

// Uso: swift Scripts/make_icon.swift <salida.png>   (genera 1024x1024)
let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let ctx = gctx.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}

// Base: squircle de macOS (824 pt centrado) con degradado diagonal.
let base = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: base, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
ctx.addPath(squircle); ctx.setFillColor(color(0x0B3D2A)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let grad = CGGradient(colorsSpace: cs, colors: [color(0x2EE67A), color(0x12A150), color(0x0A4D3C)] as CFArray, locations: [0, 0.5, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])
// Brillo suave superior
let gloss = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])

// Elementos blancos con sombra suave.
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: color(0x03281B, 0.45))
ctx.setFillColor(color(0xFFFFFF))

// Líneas de lista (a la izquierda).
for (i, w) in [300, 260, 210].enumerated() {
    let y = 640 - CGFloat(i) * 105
    ctx.addPath(CGPath(roundedRect: CGRect(x: 215, y: y, width: CGFloat(w), height: 52), cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.fillPath()
}

// Nota musical (corchea) como una sola forma, para que la sombra no marque costuras.
let note = CGMutablePath()
var xf = CGAffineTransform(translationX: 650, y: 300).rotated(by: .pi / 9)
note.addEllipse(in: CGRect(x: -95, y: -70, width: 190, height: 140), transform: xf)
note.addRect(CGRect(x: 694, y: 290, width: 44, height: 360))
note.move(to: CGPoint(x: 738, y: 650))
note.addCurve(to: CGPoint(x: 830, y: 470), control1: CGPoint(x: 746, y: 560), control2: CGPoint(x: 860, y: 560))
note.addCurve(to: CGPoint(x: 738, y: 560), control1: CGPoint(x: 820, y: 510), control2: CGPoint(x: 776, y: 540))
note.closeSubpath()
ctx.addPath(note); ctx.fillPath()

// Destello de 4 puntas (la parte "generada").
func sparkle(_ c: CGPoint, _ r: CGFloat) {
    let p = CGMutablePath(), k = r * 0.2
    p.move(to: CGPoint(x: c.x, y: c.y + r))
    p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y + k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x + k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y - k))
    p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x - k, y: c.y + k))
    ctx.addPath(p); ctx.fillPath()
}
ctx.setFillColor(color(0xFFF3A8))
sparkle(CGPoint(x: 700, y: 760), 105)
sparkle(CGPoint(x: 560, y: 840), 45)
ctx.restoreGState()

NSGraphicsContext.current = nil
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
