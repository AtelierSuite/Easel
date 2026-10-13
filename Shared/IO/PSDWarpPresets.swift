import CoreGraphics
import Foundation

/// Photoshop's preset warps — Arc, Flag, Fisheye and the rest — as the grid
/// of points Photoshop bends to for each. Photoshop keeps only the preset's
/// name and settings; these are the grids it makes from them, as fitted to
/// the ones it saves by Patchy (github.com/SethRobinson/Patchy, MIT), within
/// a millionth of a pixel.
enum PSDWarpPresets {
    /// A grid of Bézier control points, rows from the top, each from the left.
    private struct Grid {
        var columns: Int
        var rows: Int
        var points: [CGPoint]

        init(columns: Int, rows: Int, points: [CGPoint] = []) {
            self.columns = columns
            self.rows = rows
            self.points = points
        }

        /// Evenly over `width` by `height`.
        static func even(columns: Int, rows: Int, width: Double, height: Double) -> Grid {
            var grid = Grid(columns: columns, rows: rows)
            for row in 0..<rows {
                for column in 0..<columns {
                    grid.points.append(CGPoint(
                        x: width * Double(column) / Double(columns - 1), y: height * Double(row) / Double(rows - 1)
                    ))
                }
            }
            return grid
        }

        subscript(index: Int) -> CGPoint {
            get { points[index] }
            set { points[index] = newValue }
        }
    }

    static let styles: Set<String> = [
        "warpArc", "warpArcLower", "warpArcUpper", "warpArch", "warpBulge", "warpShellLower", "warpShellUpper",
        "warpFlag", "warpWave", "warpFish", "warpRise", "warpFisheye", "warpInflate", "warpSqueeze", "warpTwist",
    ]

    /// The sixteen points `style` bends contents in `bounds` to, four rows
    /// of four from the top left, or nil for a style Easel cannot draw.
    /// `bend` and the distortions are Photoshop's percentages.
    static func mesh(
        style: String, bend: Double, vertical: Bool, horizontalDistortion: Double, verticalDistortion: Double, bounds: CGRect
    ) -> [CGPoint]? {
        guard styles.contains(style), bounds.width > 0, bounds.height > 0 else { return nil }
        var grid: Grid
        // Twist comes out the same either way round.
        if vertical, style != "warpTwist" {
            grid = swapped(horizontal(style, bend: bend, width: bounds.height, height: bounds.width))
        } else {
            grid = horizontal(style, bend: bend, width: bounds.width, height: bounds.height)
        }
        distort(&grid, horizontal: horizontalDistortion, vertical: verticalDistortion)
        grid = cubic(grid)
        return grid.points.map { CGPoint(x: $0.x + bounds.minX, y: $0.y + bounds.minY) }
    }

    // MARK: - Styles

    /// A row along a circular arc on the chord from `ax` to `bx` at `y`,
    /// turning `theta` either side, bulging up or down.
    private static func arcRow(_ ax: Double, _ bx: Double, y: Double, theta: Double, up: Bool) -> [CGPoint] {
        let radius = (bx - ax) / (2 * sin(theta))
        let handle = 4.0 / 3.0 * tan(theta / 2) * radius
        let dy = up ? -handle * sin(theta) : handle * sin(theta)
        return [CGPoint(x: ax, y: y), CGPoint(x: ax + handle * cos(theta), y: y + dy),
                CGPoint(x: bx - handle * cos(theta), y: y + dy), CGPoint(x: bx, y: y)]
    }

    private static func straightRow(width: Double, y: Double) -> [CGPoint] {
        [0, 1, 2, 3].map { CGPoint(x: width * Double($0) / 3, y: y) }
    }

    /// Upside down: rows reversed, each flipped about the middle.
    private static func mirrored(_ grid: Grid, height: Double) -> Grid {
        var result = Grid(columns: grid.columns, rows: grid.rows)
        for row in (0..<grid.rows).reversed() {
            for column in 0..<grid.columns {
                let point = grid[row * grid.columns + column]
                result.points.append(CGPoint(x: point.x, y: height - point.y))
            }
        }
        return result
    }

    /// Across made down: x and y swapped and the grid turned on its side.
    private static func swapped(_ grid: Grid) -> Grid {
        var result = Grid(columns: grid.rows, rows: grid.columns)
        for column in 0..<grid.columns {
            for row in 0..<grid.rows {
                let point = grid[row * grid.columns + column]
                result.points.append(CGPoint(x: point.y, y: point.x))
            }
        }
        return result
    }

    private static func horizontal(_ style: String, bend raw: Double, width: Double, height: Double) -> Grid {
        let bend = min(max(raw, -100), 100)
        let theta = abs(bend) * .pi / 200
        // Flag, wave, fish and rise move by the height.
        let d = 2 * height * bend / 100
        let isStraight = abs(bend) < 1e-9
        switch style {
        case "warpArcLower", "warpArcUpper":
            guard !isStraight else { return .even(columns: 4, rows: 2, width: width, height: height) }
            // One edge stays; the other bows away for a positive bend.
            let grid = Grid(columns: 4, rows: 2, points: straightRow(width: width, y: 0)
                + arcRow(0, width, y: height, theta: theta, up: bend < 0))
            return style == "warpArcUpper" ? mirrored(grid, height: height) : grid
        case "warpFish":
            var grid = Grid(columns: 4, rows: 2, points: straightRow(width: width, y: 0) + straightRow(width: width, y: height))
            grid[1].y -= d
            grid[2].y += d
            grid[5].y += d
            grid[6].y -= d
            return grid
        case "warpFisheye":
            // Only the middle four move, each towards its nearest corner.
            var grid = Grid.even(columns: 4, rows: 4, width: width, height: height)
            let t = bend / 50
            for row in 1...2 {
                for column in 1...2 {
                    let index = row * 4 + column
                    let corner = CGPoint(x: column == 1 ? 0 : width, y: row == 1 ? 0 : height)
                    grid[index].x += t * (corner.x - grid[index].x)
                    grid[index].y += t * (corner.y - grid[index].y)
                }
            }
            return grid
        case "warpInflate", "warpSqueeze":
            // A quadratic patch whose edge middles slide out, or the sides in.
            var grid = Grid.even(columns: 3, rows: 3, width: width, height: height)
            let dx = width * bend / 200, dy = height * bend / 200
            grid[1].y -= dy
            grid[7].y += dy
            grid[3].x += style == "warpInflate" ? -dx : dx
            grid[5].x += style == "warpInflate" ? dx : -dx
            return grid
        case "warpTwist":
            // The middle four turn round one another.
            var grid = Grid.even(columns: 4, rows: 4, width: width, height: height)
            let mx = width * abs(bend) / 100, my = height * abs(bend) / 100
            if bend > 0 {
                grid[5].x += mx
                grid[6].y += my
                grid[10].x -= mx
                grid[9].y -= my
            } else if bend < 0 {
                grid[5].y += my
                grid[6].x -= mx
                grid[10].y -= my
                grid[9].x += mx
            }
            return grid
        case "warpShellLower", "warpShellUpper":
            guard !isStraight else { return .even(columns: 4, rows: 4, width: width, height: height) }
            var points = straightRow(width: width, y: 0) + straightRow(width: width, y: height / 3)
            if bend > 0 {
                let radius = 2 * height / 3
                points += [CGPoint(x: -radius * sin(theta), y: radius * cos(theta)), CGPoint(x: width / 3, y: radius),
                           CGPoint(x: 2 * width / 3, y: radius), CGPoint(x: width + radius * sin(theta), y: radius * cos(theta))]
                points += arcRow(-height * sin(theta), width + height * sin(theta), y: height * cos(theta), theta: theta, up: false)
            } else {
                let radius = height / 3
                points += [CGPoint(x: -radius * sin(theta), y: height - radius * cos(theta)), CGPoint(x: width / 3, y: 2 * height / 3),
                           CGPoint(x: 2 * width / 3, y: 2 * height / 3), CGPoint(x: width + radius * sin(theta), y: height - radius * cos(theta))]
                points += arcRow(0, width, y: height, theta: theta, up: true)
            }
            let grid = Grid(columns: 4, rows: 4, points: points)
            return style == "warpShellUpper" ? mirrored(grid, height: height) : grid
        case "warpArc":
            guard !isStraight else { return .even(columns: 4, rows: 2, width: width, height: height) }
            // The top corners swing about the bottom ones, so the band keeps
            // its thickness.
            let grid = Grid(columns: 4, rows: 2, points:
                arcRow(-height * sin(theta), width + height * sin(theta), y: height * (1 - cos(theta)), theta: theta, up: true)
                + arcRow(0, width, y: height, theta: theta, up: true))
            return bend < 0 ? mirrored(grid, height: height) : grid
        case "warpArch", "warpBulge":
            guard !isStraight else { return .even(columns: 4, rows: 2, width: width, height: height) }
            let up = bend > 0
            return Grid(columns: 4, rows: 2, points: arcRow(0, width, y: 0, theta: theta, up: up)
                + arcRow(0, width, y: height, theta: theta, up: style == "warpBulge" ? !up : up))
        case "warpFlag":
            var grid = Grid(columns: 4, rows: 2, points: straightRow(width: width, y: 0) + straightRow(width: width, y: height))
            grid[1].y -= d
            grid[2].y += d
            grid[5].y -= d
            grid[6].y += d
            return grid
        case "warpWave":
            // The edges stay straight; the middle waves.
            var grid = Grid(columns: 4, rows: 3, points: straightRow(width: width, y: 0)
                + straightRow(width: width, y: height / 2) + straightRow(width: width, y: height))
            grid[5].y += d
            grid[6].y -= d
            return grid
        default: // Rise.
            var grid = Grid(columns: 4, rows: 2, points: straightRow(width: width, y: 0) + straightRow(width: width, y: height))
            for index in [0, 1, 4, 5] { grid[index].y += d }
            return grid
        }
    }

    // MARK: - Distortion and degree

    /// Photoshop's horizontal and vertical distortion: rows scaled about the
    /// middle of their ends, more towards the bottom, then columns likewise
    /// towards the right.
    private static func distort(_ grid: inout Grid, horizontal: Double, vertical: Double) {
        let vertical = min(max(vertical, -100), 100), horizontal = min(max(horizontal, -100), 100)
        if vertical != 0 {
            for row in 0..<grid.rows {
                let first = row * grid.columns, last = first + grid.columns - 1
                let middle = CGPoint(x: (grid[first].x + grid[last].x) / 2, y: (grid[first].y + grid[last].y) / 2)
                let scale = 1 + (2 * Double(row) / Double(grid.rows - 1) - 1) * vertical / 100
                for index in first...last {
                    grid[index] = CGPoint(x: middle.x + (grid[index].x - middle.x) * scale, y: middle.y + (grid[index].y - middle.y) * scale)
                }
            }
        }
        if horizontal != 0 {
            for column in 0..<grid.columns {
                let first = column, last = (grid.rows - 1) * grid.columns + column
                let middle = CGPoint(x: (grid[first].x + grid[last].x) / 2, y: (grid[first].y + grid[last].y) / 2)
                let scale = 1 + (2 * Double(column) / Double(grid.columns - 1) - 1) * horizontal / 100
                for row in 0..<grid.rows {
                    let index = row * grid.columns + column
                    grid[index] = CGPoint(x: middle.x + (grid[index].x - middle.x) * scale, y: middle.y + (grid[index].y - middle.y) * scale)
                }
            }
        }
    }

    /// The same surface as a four by four grid, raising its degree each way.
    private static func cubic(_ grid: Grid) -> Grid {
        var grid = grid
        while grid.columns < 4 { grid = raisedAcross(grid) }
        while grid.rows < 4 { grid = transposed(raisedAcross(transposed(grid))) }
        return grid
    }

    /// Rows made columns, the points themselves unmoved.
    private static func transposed(_ grid: Grid) -> Grid {
        var result = Grid(columns: grid.rows, rows: grid.columns)
        for column in 0..<grid.columns {
            for row in 0..<grid.rows { result.points.append(grid[row * grid.columns + column]) }
        }
        return result
    }

    private static func raisedAcross(_ grid: Grid) -> Grid {
        let count = grid.columns
        var result = Grid(columns: count + 1, rows: grid.rows)
        for row in 0..<grid.rows {
            let points = Array(grid.points[(row * count)..<((row + 1) * count)])
            result.points.append(points[0])
            for index in 1..<count {
                let alpha = Double(index) / Double(count)
                result.points.append(CGPoint(
                    x: alpha * points[index - 1].x + (1 - alpha) * points[index].x,
                    y: alpha * points[index - 1].y + (1 - alpha) * points[index].y
                ))
            }
            result.points.append(points[count - 1])
        }
        return result
    }
}
