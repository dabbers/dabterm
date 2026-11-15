//
//  iOSTerminalView+Dabterm.swift
//  dabterm addition (not upstream): exposes selection plumbing so the app can offer a
//  touch "select mode" (drag anywhere to select) without long-press menus.
//
#if os(iOS) || os(visionOS)
import UIKit

extension TerminalView {
    /// Grid position (col/row in the display buffer) for a point in view coordinates.
    public func dabGridPosition(at point: CGPoint) -> Position {
        calculateTapHit(point: point).grid
    }
    /// Starts a character selection at a view point.
    public func dabSelectionBegin(at point: CGPoint) {
        let pos = dabGridPosition(at: point)
        withTerminal { _ in
            selection.selectNone()
            selection.selectionMode = .character
            selection.startSelection(row: pos.row, col: pos.col)
            selection.pivot = pos
        }
        enableSelectionPanGesture()
        requestDisplay()
    }
    /// Extends the current selection to a view point (while dragging).
    public func dabSelectionExtend(to point: CGPoint) {
        let pos = dabGridPosition(at: point)
        withTerminal { _ in selection.pivotExtend(bufferPosition: pos) }
        requestDisplay()
    }
    /// Selects whole rows between two view points.
    public func dabSelectRows(from a: CGPoint, to b: CGPoint) {
        let p1 = dabGridPosition(at: a), p2 = dabGridPosition(at: b)
        withTerminal { terminal in
            selection.selectNone()
            let r1 = min(p1.row, p2.row), r2 = max(p1.row, p2.row)
            selection.setSelection(start: Position(col: 0, row: r1), end: Position(col: terminal.cols - 1, row: r2))
        }
        enableSelectionPanGesture()
        requestDisplay()
    }
    public func dabSelectNone() {
        withTerminal { _ in selection.selectNone() }
        disableSelectionPanGesture()
        requestDisplay()
    }
    /// The selected text, if any, without clearing the selection.
    public var dabSelectedText: String? {
        withTerminal { _ in selection.active ? selection.getSelectedText() : nil }
    }
    /// Text of the whole scrollback + screen (for "copy all").
    public var dabAllText: String {
        withTerminal { terminal in
            var lines: [String] = []
            let buffer = terminal.buffer
            for i in 0..<buffer.lines.count { lines.append(buffer.lines[i].translateToString(trimRight: true)) }
            return lines.joined(separator: "\n")
        }
    }
}
#endif
