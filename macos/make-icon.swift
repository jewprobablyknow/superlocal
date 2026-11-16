// Draws the Superlocal app icon (1024 px PNG). Usage: swift make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.98, alpha: 1),
                    NSColor(calibratedRed: 0.42, green: 0.25, blue: 0.92, alpha: 1)])!.draw(in: shape, angle: -60)

// Envelope.
NSColor.white.setFill()
NSColor.white.setStroke()
let env = NSRect(x: 262, y: 330, width: 500, height: 360)
let body = NSBezierPath(roundedRect: env, xRadius: 48, yRadius: 48)
body.fill()
let flap = NSBezierPath()
flap.move(to: NSPoint(x: env.minX + 40, y: env.maxY - 30))
flap.line(to: NSPoint(x: env.midX, y: env.midY - 10))
flap.line(to: NSPoint(x: env.maxX - 40, y: env.maxY - 30))
flap.lineWidth = 34
flap.lineCapStyle = .round
flap.lineJoinStyle = .round
NSColor(calibratedRed: 0.30, green: 0.34, blue: 0.95, alpha: 1).setStroke()
flap.stroke()

// Spark (AI sort).
let spark = NSBezierPath()
let c = NSPoint(x: 740, y: 700), r: CGFloat = 92, w: CGFloat = 24
spark.move(to: NSPoint(x: c.x, y: c.y + r))
spark.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + w, y: c.y + w), controlPoint2: NSPoint(x: c.x + w, y: c.y + w))
spark.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + w, y: c.y - w), controlPoint2: NSPoint(x: c.x + w, y: c.y - w))
spark.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - w, y: c.y - w), controlPoint2: NSPoint(x: c.x - w, y: c.y - w))
spark.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - w, y: c.y + w), controlPoint2: NSPoint(x: c.x - w, y: c.y + w))
NSColor(calibratedRed: 1, green: 0.82, blue: 0.30, alpha: 1).setFill()
spark.fill()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
