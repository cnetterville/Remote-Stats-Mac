//
//  TerminalEmulator.swift
//  Remote Stats Mac
//

import SwiftUI

// MARK: - Cell

struct TermCell: Equatable {
    var char: Character = " "
    var fg: TermColor = .default
    var bg: TermColor = .default
    var bold = false
}

// MARK: - Color

enum TermColor: Equatable {
    case `default`
    case index(Int)
    case rgb(UInt8, UInt8, UInt8)

    var swiftUIColor: Color {
        switch self {
        case .default:          return .primary
        case .index(let i):     return ansiColor(i)
        case .rgb(let r, let g, let b):
            return Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
        }
    }

    var bgSwiftUIColor: Color? {
        switch self {
        case .default:          return nil
        case .index(let i):     return ansiColor(i)
        case .rgb(let r, let g, let b):
            return Color(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255)
        }
    }
}

private func ansiColor(_ i: Int) -> Color {
    switch i {
    case 0:  return Color(red: 0.0, green: 0.0, blue: 0.0)
    case 1:  return Color(red: 0.8, green: 0.0, blue: 0.0)
    case 2:  return Color(red: 0.0, green: 0.8, blue: 0.0)
    case 3:  return Color(red: 0.8, green: 0.8, blue: 0.0)
    case 4:  return Color(red: 0.0, green: 0.0, blue: 0.8)
    case 5:  return Color(red: 0.8, green: 0.0, blue: 0.8)
    case 6:  return Color(red: 0.0, green: 0.8, blue: 0.8)
    case 7:  return Color(red: 0.75, green: 0.75, blue: 0.75)
    case 8:  return Color(red: 0.5,  green: 0.5,  blue: 0.5)
    case 9:  return Color(red: 1.0,  green: 0.0,  blue: 0.0)
    case 10: return Color(red: 0.0,  green: 1.0,  blue: 0.0)
    case 11: return Color(red: 1.0,  green: 1.0,  blue: 0.0)
    case 12: return Color(red: 0.0,  green: 0.0,  blue: 1.0)
    case 13: return Color(red: 1.0,  green: 0.0,  blue: 1.0)
    case 14: return Color(red: 0.0,  green: 1.0,  blue: 1.0)
    case 15: return .white
    default:
        if i >= 232 {
            let v = Double(i - 232) / 23.0
            return Color(white: v)
        } else if i >= 16 {
            let idx = i - 16
            let b = idx % 6; let g = (idx / 6) % 6; let r = idx / 36
            return Color(
                red:   r > 0 ? (Double(r) * 40 + 55) / 255 : 0,
                green: g > 0 ? (Double(g) * 40 + 55) / 255 : 0,
                blue:  b > 0 ? (Double(b) * 40 + 55) / 255 : 0
            )
        }
        return .primary
    }
}

// MARK: - Emulator

@Observable
final class TerminalEmulator {
    var cols: Int
    var rows: Int
    var grid: [[TermCell]]
    var cursorRow = 0
    var cursorCol = 0
    var generation = 0

    private enum ParseState {
        case normal
        case esc
        case csi(String)
        case osc(String)
        case charset
    }
    private var state: ParseState = .normal

    private var fg: TermColor = .default
    private var bg: TermColor = .default
    private var bold = false

    private var savedRow = 0
    private var savedCol = 0

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = cols
        self.rows = rows
        self.grid = TerminalEmulator.emptyGrid(cols: cols, rows: rows)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0, cols != self.cols || rows != self.rows else { return }
        var newGrid = TerminalEmulator.emptyGrid(cols: cols, rows: rows)
        for r in 0..<min(rows, self.rows) {
            for c in 0..<min(cols, self.cols) {
                newGrid[r][c] = grid[r][c]
            }
        }
        self.cols = cols; self.rows = rows; self.grid = newGrid
        cursorRow = min(cursorRow, rows - 1)
        cursorCol = min(cursorCol, cols - 1)
        generation += 1
    }

    func process(_ data: Data) {
        for byte in data { processByte(byte) }
        generation += 1
    }

    private func processByte(_ byte: UInt8) {
        switch state {
        case .normal:    processNormal(byte)
        case .esc:       processEsc(byte)
        case .csi(let a): processCSIByte(a, byte)
        case .osc(let a): processOSCByte(a, byte)
        case .charset:   state = .normal
        }
    }

    private func processNormal(_ b: UInt8) {
        switch b {
        case 0x1B: state = .esc
        case 0x07: break
        case 0x08: if cursorCol > 0 { cursorCol -= 1 }
        case 0x09: cursorCol = min(((cursorCol/8)+1)*8, cols-1)
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cursorCol = 0
        case 0x7F: break
        default:
            if b >= 0x20 { putChar(Character(UnicodeScalar(b))) }
        }
    }

    private func processEsc(_ b: UInt8) {
        switch b {
        case 0x5B: state = .csi("")
        case 0x5D: state = .osc("")
        case 0x28, 0x29: state = .charset
        case 0x37: saveCursor(); state = .normal
        case 0x38: restoreCursor(); state = .normal
        case 0x4D:
            if cursorRow == 0 { grid.insert(blankRow(), at: 0); if grid.count > rows { grid.removeLast() } }
            else { cursorRow -= 1 }
            state = .normal
        case 0x63: hardReset(); state = .normal
        default:   state = .normal
        }
    }

    private func processCSIByte(_ acc: String, _ b: UInt8) {
        if b >= 0x40 && b <= 0x7E {
            executeCSI(acc, Character(UnicodeScalar(b)))
            state = .normal
        } else if b < 0x20 {
            processNormal(b)
        } else {
            state = .csi(acc + String(UnicodeScalar(b)))
        }
    }

    private func processOSCByte(_ acc: String, _ b: UInt8) {
        if b == 0x07 || b == 0x1B { state = .normal }
        else { state = .osc(acc + String(UnicodeScalar(b))) }
    }

    private func executeCSI(_ params: String, _ cmd: Character) {
        let stripped = params.hasPrefix("?") || params.hasPrefix(">")
            ? String(params.dropFirst()) : params

        let parts = stripped.split(separator: ";", omittingEmptySubsequences: false)
        let nums  = parts.map { Int($0) }
        func p(_ i: Int, d: Int = 0) -> Int { i < nums.count ? (nums[i] ?? d) : d }
        func p1(_ i: Int) -> Int { let v = p(i, d: 1); return v == 0 ? 1 : v }

        switch cmd {
        case "A": cursorRow = max(0, cursorRow - p1(0))
        case "B": cursorRow = min(rows-1, cursorRow + p1(0))
        case "C": cursorCol = min(cols-1, cursorCol + p1(0))
        case "D": cursorCol = max(0, cursorCol - p1(0))
        case "E": cursorRow = min(rows-1, cursorRow + p1(0)); cursorCol = 0
        case "F": cursorRow = max(0, cursorRow - p1(0)); cursorCol = 0
        case "G": cursorCol = clampCol(p1(0) - 1)
        case "H", "f":
            cursorRow = clampRow(p1(0) - 1)
            cursorCol = clampCol(p1(1) - 1)
        case "J": eraseDisplay(p(0))
        case "K": eraseLine(p(0))
        case "L":
            for _ in 0..<max(1, p1(0)) {
                grid.insert(blankRow(), at: cursorRow)
                if grid.count > rows { grid.removeLast() }
            }
        case "M":
            for _ in 0..<max(1, p1(0)) {
                if cursorRow < grid.count { grid.remove(at: cursorRow) }
                grid.append(blankRow())
            }
        case "P":
            let n = max(1, p1(0))
            var row = grid[cursorRow]
            row.removeSubrange(cursorCol..<min(cursorCol + n, cols))
            while row.count < cols { row.append(TermCell()) }
            grid[cursorRow] = row
        case "S": for _ in 0..<max(1, p1(0)) { scrollUp() }
        case "T": for _ in 0..<max(1, p1(0)) { scrollDown() }
        case "X":
            let n = max(1, p1(0))
            for c in cursorCol..<min(cursorCol + n, cols) { grid[cursorRow][c] = blankCell() }
        case "d": cursorRow = clampRow(p1(0) - 1)
        case "m": processSGR(nums)
        case "r": break
        case "s": saveCursor()
        case "u": restoreCursor()
        case "h", "l": break
        default:  break
        }
    }

    private func processSGR(_ raw: [Int?]) {
        let p = raw.isEmpty ? [0] : raw.map { $0 ?? 0 }
        var i = 0
        while i < p.count {
            switch p[i] {
            case 0:  fg = .default; bg = .default; bold = false
            case 1:  bold = true
            case 2...9:  break
            case 21...29: break
            case 30...37: fg = .index(p[i] - 30)
            case 38:
                if i+2 < p.count, p[i+1] == 5 { fg = .index(p[i+2]); i += 2 }
                else if i+4 < p.count, p[i+1] == 2 {
                    fg = .rgb(UInt8(p[i+2]), UInt8(p[i+3]), UInt8(p[i+4])); i += 4
                }
            case 39: fg = .default
            case 40...47: bg = .index(p[i] - 40)
            case 48:
                if i+2 < p.count, p[i+1] == 5 { bg = .index(p[i+2]); i += 2 }
                else if i+4 < p.count, p[i+1] == 2 {
                    bg = .rgb(UInt8(p[i+2]), UInt8(p[i+3]), UInt8(p[i+4])); i += 4
                }
            case 49: bg = .default
            case 90...97:  fg = .index(p[i] - 90 + 8)
            case 100...107: bg = .index(p[i] - 100 + 8)
            default: break
            }
            i += 1
        }
    }

    private func putChar(_ c: Character) {
        guard cursorRow >= 0, cursorRow < rows, cursorCol >= 0, cursorCol < cols else { return }
        grid[cursorRow][cursorCol] = TermCell(char: c, fg: fg, bg: bg, bold: bold)
        cursorCol += 1
        if cursorCol >= cols { cursorCol = 0; lineFeed() }
    }

    private func lineFeed() {
        cursorRow += 1
        if cursorRow >= rows { scrollUp(); cursorRow = rows - 1 }
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseToEndOfLine()
            for r in (cursorRow+1)..<rows { grid[r] = blankRow() }
        case 1:
            eraseToStartOfLine()
            for r in 0..<cursorRow { grid[r] = blankRow() }
        case 2, 3:
            for r in 0..<rows { grid[r] = blankRow() }
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 0: eraseToEndOfLine()
        case 1: eraseToStartOfLine()
        case 2: grid[cursorRow] = blankRow()
        default: break
        }
    }

    private func eraseToEndOfLine() {
        guard cursorRow < rows else { return }
        for c in cursorCol..<cols { grid[cursorRow][c] = TermCell() }
    }

    private func eraseToStartOfLine() {
        guard cursorRow < rows else { return }
        for c in 0...min(cursorCol, cols-1) { grid[cursorRow][c] = TermCell() }
    }

    private func scrollUp()   { grid.removeFirst(); grid.append(blankRow()) }
    private func scrollDown() { grid.removeLast(); grid.insert(blankRow(), at: 0) }

    private func saveCursor()    { savedRow = cursorRow; savedCol = cursorCol }
    private func restoreCursor() { cursorRow = savedRow; cursorCol = savedCol }

    private func hardReset() {
        grid = TerminalEmulator.emptyGrid(cols: cols, rows: rows)
        cursorRow = 0; cursorCol = 0
        fg = .default; bg = .default; bold = false
    }

    private func blankRow() -> [TermCell]  { Array(repeating: TermCell(), count: cols) }
    private func blankCell() -> TermCell   { TermCell(fg: fg, bg: bg) }
    private func clampRow(_ r: Int) -> Int { max(0, min(rows-1, r)) }
    private func clampCol(_ c: Int) -> Int { max(0, min(cols-1, c)) }

    private static func emptyGrid(cols: Int, rows: Int) -> [[TermCell]] {
        Array(repeating: Array(repeating: TermCell(), count: cols), count: rows)
    }

    func attributedRow(_ r: Int, fontSize: CGFloat) -> AttributedString {
        guard r < rows else { return AttributedString() }
        var result = AttributedString()
        let monoFont = Font.system(size: fontSize, weight: .regular, design: .monospaced)
        let monoFontBold = Font.system(size: fontSize, weight: .bold, design: .monospaced)

        for cell in grid[r] {
            var a = AttributedString(String(cell.char))
            a.font = cell.bold ? monoFontBold : monoFont
            a.foregroundColor = cell.fg.swiftUIColor
            if let bgColor = cell.bg.bgSwiftUIColor { a.backgroundColor = bgColor }
            result += a
        }
        return result
    }
}
