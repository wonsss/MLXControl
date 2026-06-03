import AppKit

// 그라데이션 라운드 사각형 + 흰 번개 아이콘 PNG 생성
func makeIcon(_ px: Int) -> Data {
    let size = CGFloat(px)
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let bg = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)
    let grad = NSGradient(colors: [
        NSColor(red: 0.46, green: 0.37, blue: 0.97, alpha: 1),
        NSColor(red: 0.29, green: 0.19, blue: 0.64, alpha: 1),
    ])!
    grad.draw(in: bg, angle: -90)
    let pts: [(CGFloat, CGFloat)] = [
        (0.56, 0.93), (0.30, 0.46), (0.46, 0.46),
        (0.40, 0.07), (0.70, 0.58), (0.52, 0.58),
    ]
    let bolt = NSBezierPath()
    for (i, p) in pts.enumerated() {
        let pt = NSPoint(x: p.0 * size, y: p.1 * size)
        if i == 0 { bolt.move(to: pt) } else { bolt.line(to: pt) }
    }
    bolt.close()
    NSColor.white.setFill()
    bolt.fill()
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let iconset = "MLXControl.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let map: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in map {
    try! makeIcon(px).write(to: URL(fileURLWithPath: "\(iconset)/\(name)"))
}
print("✓ iconset written")
