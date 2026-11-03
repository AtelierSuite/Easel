// Draws the custom tool symbols in Shared/Support/Assets.xcassets: the tools
// SF Symbols has no glyph for. Each is built from round-capped strokes at
// every weight and scale, so it sits beside the system symbols.
//
//     swift Scripts/ToolSymbols.swift
import CoreGraphics
import Foundation

// MARK: geometry helpers (design space: 100x100, y down)
func stroke(_ p: CGPath, _ w: CGFloat) -> CGPath {
    p.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10).normalized(using: .winding)
}
func unite(_ ps: [CGPath]) -> CGPath {
    var r = ps[0].normalized(using: .winding)
    for p in ps.dropFirst() { r = r.union(p.normalized(using: .winding), using: .winding) }
    return r
}
func line(_ pts: [CGPoint], closed: Bool = false) -> CGPath {
    let p = CGMutablePath(); p.addLines(between: pts); if closed { p.closeSubpath() }; return p
}
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
    CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2*r, height: 2*r), transform: nil)
}
func rrect(_ r: CGRect, _ c: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: min(c, r.width/2), cornerHeight: min(c, r.height/2), transform: nil)
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

// MARK: icons. `w` is the stroke width for the weight.
typealias Icon = (CGFloat) -> CGPath

let gradient: Icon = { w in
    let frameRect = CGRect(x: 7, y: 17, width: 86, height: 66)
    let frame = stroke(rrect(frameRect, 15), w)
    let inner = rrect(frameRect.insetBy(dx: w/2 - 0.01, dy: w/2 - 0.01), 15 - w/2)
    var parts = [frame]
    let bands: [(CGFloat, CGFloat)] = [(0, 40), (47, 54), (61, 65), (72, 74.5)]
    for (a, b) in bands {
        parts.append(CGPath(rect: CGRect(x: a, y: 0, width: b - a, height: 100), transform: nil).intersection(inner))
    }
    return unite(parts)
}

let censor: Icon = { w in
    let cx: CGFloat = 46, r: CGFloat = 33
    let half = circle(P(cx, 50), r).intersection(CGPath(rect: CGRect(x: 0, y: 0, width: cx + 1, height: 100), transform: nil))
    var parts = [half]
    let pitch: CGFloat = 14, cell: CGFloat = 9.5 + w * 0.2
    // columns of tiles to the right of the solid half, breaking up as they go
    let cols: [(CGFloat, [Int])] = [(cx + 10, [-2, -1, 0, 1, 2]), (cx + 10 + pitch, [-1, 0, 2]), (cx + 10 + 2 * pitch, [-2, 0])]
    for (x, rows) in cols {
        for k in rows {
            let y = 50 + CGFloat(k) * pitch
            parts.append(rrect(CGRect(x: x - cell/2, y: y - cell/2, width: cell, height: cell), 1.5))
        }
    }
    return unite(parts)
}

let tone: Icon = { w in
    let c = P(58, 40), r: CGFloat = 29
    let ring = stroke(circle(c, r), w)
    // fill the half of the head above the handle's axis
    let axis = CGMutablePath()
    axis.move(to: P(c.x - 100, c.y + 100)); axis.addLine(to: P(c.x + 100, c.y - 100))
    axis.addLine(to: P(c.x - 100, c.y - 100)); axis.closeSubpath()
    let halfFill = circle(c, r).intersection(axis)
    let d: CGFloat = 0.7071
    let handle = stroke(line([P(c.x - r * d, c.y + r * d), P(12, 88)]), w * 1.25)
    return unite([ring, halfFill, handle])
}

func gridPath(_ map: (CGPoint) -> CGPoint, lines: [CGFloat], steps: Int = 48) -> [CGPath] {
    var out: [CGPath] = []
    for u in lines {
        out.append(line((0...steps).map { i in map(P(u, -1 + 2 * CGFloat(i) / CGFloat(steps))) }))
        out.append(line((0...steps).map { i in map(P(-1 + 2 * CGFloat(i) / CGFloat(steps), u)) }))
    }
    return out
}
let liquifyTwirl: Icon = { w in
    let map: (CGPoint) -> CGPoint = { p in
        let rr = sqrt(p.x * p.x + p.y * p.y)
        let t = max(0, 1 - rr / 1.0)
        let a = 1.6 * t * t
        let q = P(p.x * cos(a) - p.y * sin(a), p.x * sin(a) + p.y * cos(a))
        return P(50 + q.x * 41, 50 + q.y * 41)
    }
    let frame = stroke(rrect(CGRect(x: 9, y: 9, width: 82, height: 82), 14), w)
    let inner = gridPath(map, lines: [0]).map { stroke($0, w) }
    return unite([frame] + inner)
}
let cloneStamp: Icon = { w in
    let neck = CGMutablePath()
    neck.move(to: P(42, 30)); neck.addCurve(to: P(37, 54), control1: P(43, 40), control2: P(37, 46))
    neck.move(to: P(58, 30)); neck.addCurve(to: P(63, 54), control1: P(57, 40), control2: P(63, 46))
    return unite([
        stroke(circle(P(50, 19), 11.5), w),
        stroke(neck, w),
        stroke(rrect(CGRect(x: 12, y: 54, width: 76, height: 18), 6), w),
        stroke(line([P(20, 87), P(80, 87)]), w),
    ])
}

let icons: [(String, Icon)] = [
    ("tool.gradient", gradient), ("tool.censor", censor),
    ("tool.tone", tone), ("tool.liquify", liquifyTwirl), ("tool.clone", cloneStamp),
]

// MARK: weights
let weightNames = ["Ultralight", "Thin", "Light", "Regular", "Medium", "Semibold", "Bold", "Heavy", "Black"]
let weightStrokes: [CGFloat] = [2.5, 3.6, 5.2, 7.8, 8.8, 9.8, 11, 12.2, 13]
let weightCenters: [CGFloat] = [559.711, 856.422, 1153.13, 1449.84, 1746.56, 2043.27, 2339.98, 2636.69, 2933.4]
let scales: [(String, CGFloat, CGFloat)] = [("S", 1, 696), ("M", 1.25, 1126), ("L", 1.6, 1556)]
var scale: CGFloat = 0.95

func svgPath(_ p: CGPath, dx: CGFloat) -> String {
    var s = ""
    func f(_ v: CGFloat) -> String { String(format: "%.3f", Double(v)).replacingOccurrences(of: ".000", with: "") }
    func pt(_ q: CGPoint) -> String { "\(f(q.x * scale - dx)) \(f((q.y - 50) * scale - 35.23))" }
    var last = CGPoint.zero
    p.applyWithBlock { e in
        let el = e.pointee, a = el.points
        switch el.type {
        case .moveToPoint: s += "M\(pt(a[0]))"; last = a[0]
        case .addLineToPoint: s += "L\(pt(a[0]))"; last = a[0]
        case .addQuadCurveToPoint:
            let c1 = P(last.x + 2/3 * (a[0].x - last.x), last.y + 2/3 * (a[0].y - last.y))
            let c2 = P(a[1].x + 2/3 * (a[0].x - a[1].x), a[1].y + 2/3 * (a[0].y - a[1].y))
            s += "C\(pt(c1)) \(pt(c2)) \(pt(a[1]))"; last = a[1]
        case .addCurveToPoint: s += "C\(pt(a[0])) \(pt(a[1])) \(pt(a[2]))"; last = a[2]
        case .closeSubpath: s += "Z"
        @unknown default: break
        }
    }
    return s
}

func template(_ name: String, _ icon: Icon) -> String {
    var guides = "", symbols = ""
    for (sname, sfactor, baseline) in scales {
        for (i, wname) in weightNames.enumerated() {
            scale = 0.95 * sfactor
            let p = icon(weightStrokes[i])
            let b = p.boundingBoxOfPath
            let minX = b.minX * scale, width = b.width * scale
            let left = weightCenters[i] - width / 2
            let id = "\(wname)-\(sname)"
            guides += """
              <line id="left-margin-\(id)" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="\(left)" x2="\(left)" y1="\(baseline - 95.215)" y2="\(baseline + 24.121)"/>
              <line id="right-margin-\(id)" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="\(left + width)" x2="\(left + width)" y1="\(baseline - 95.215)" y2="\(baseline + 24.121)"/>

            """
            symbols += """
              <g id="\(id)" transform="matrix(1 0 0 1 \(left) \(baseline))">
               <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreview000000" d="\(svgPath(p, dx: minX))"/>
              </g>

            """
        }
    }
    return """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
    <svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
     <!--glyph: "", point size: 100.0, font version: "", template writer version: "101"-->
     <style>.monochrome-0 {fill:#000000}
    .multicolor-0:tintColor {fill:#007AFF}
    .hierarchical-0:primary {fill:#000000}
    .SFSymbolsPreview000000 {fill:#000000;opacity:1.0}
    </style>
     <g id="Notes">
      <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
      <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
      <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">\(name)</text>
     </g>
     <g id="Guides">
      <line id="Baseline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="696" y2="696"/>
      <line id="Capline-S" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="625.541" y2="625.541"/>
      <line id="Baseline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1126" y2="1126"/>
      <line id="Capline-M" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
      <line id="Baseline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1556" y2="1556"/>
      <line id="Capline-L" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
    \(guides) </g>
     <g id="Symbols">
    \(symbols) </g>
    </svg>

    """
}

// MARK: output
let catalog = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Shared/Support/Assets.xcassets")
for (name, icon) in icons {
    let set = catalog.appendingPathComponent("\(name).symbolset")
    try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    try! template(name, icon).write(to: set.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
    let contents = """
    {
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "symbols" : [
        {
          "filename" : "\(name).svg",
          "idiom" : "universal"
        }
      ]
    }

    """
    try! contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
