import SwiftUI

/// Under the preview, in recording time:
///   Clip   – trim the start and end; drag the row to scrub
///   Zoom   – zooms (blue)
///   Edits  – cuts (red) and speed-ups (orange)
///   Camera – layout changes (purple), when there's a camera
///   Text   – titles and notes (teal)
///
/// Blocks: drag to move, drag an edge to resize, click to select, Delete to
/// remove. Double-click empty zoom space to add a zoom. Drag the playhead's
/// handle (or the strip above the rows) to scrub.
///
/// Keys (see EditorLayout): Space plays and pauses, I and O trim to the playhead.
struct EditorTimeline: View {
    @Bindable var model: ProjectEditorModel
    @State private var moveOrigin: (id: UUID, start: Double, end: Double)?

    private let rowHeight: CGFloat = 28
    private let rowSpacing: CGFloat = 6
    private let space = "timeline"
    /// Room above the rows for the playhead's handle.
    private let handleHeight: CGFloat = 16
    private var rowCount: CGFloat { model.hasCamera ? 5 : 4 }
    private var rowsHeight: CGFloat { rowHeight * rowCount + rowSpacing * (rowCount - 1) }
    private var totalHeight: CGFloat { handleHeight + rowsHeight }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            GeometryReader { geometry in
                let width = geometry.size.width
                VStack(spacing: 0) {
                    scrubStrip(width: width)
                    VStack(spacing: rowSpacing) {
                        clipRow(width: width)
                        zoomRow(width: width)
                        editsRow(width: width)
                        if model.hasCamera { layoutRow(width: width) }
                        textRow(width: width)
                    }
                }
                .overlay(alignment: .topLeading) { trimmedAreas(width: width) }
                .overlay(alignment: .topLeading) { playhead(width: width) }
                .coordinateSpace(name: space)
            }
            .frame(height: totalHeight)
            if let zoom = model.selectedZoom { zoomLevelBar(zoom) }
        }
        .focusable()
        .focusEffectDisabled()
        .onDeleteCommand { model.deleteSelected() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("\(Self.format(model.currentTime))  ·  video \(Self.format(model.outputLength))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
                .help("Undo (⌘Z)")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
                .help("Redo (⇧⌘Z)")
            if model.zoomsAreEdited { Button("Reset zooms") { model.resetZooms() }.buttonStyle(.link) }
            if model.editsAreCustom { Button("Reset edits") { model.resetEdits() }.buttonStyle(.link) }
            Button { model.addZoom(at: model.currentTime) } label: { Label("Zoom", systemImage: "plus.magnifyingglass") }
                .disabled(!model.style.autoZoom)
            Button { model.addEdit(.speed, at: model.currentTime) } label: { Label("Speed up", systemImage: "hare") }
            Button { model.addEdit(.cut, at: model.currentTime) } label: { Label("Cut", systemImage: "scissors") }
            Button { model.addText(at: model.currentTime) } label: { Label("Text", systemImage: "textformat") }
            if model.hasCamera {
                Button { model.addLayout(at: model.currentTime) } label: { Label("Layout", systemImage: "person.crop.rectangle") }
            }
        }
    }

    // MARK: Trimmed parts

    /// What the trim cuts away, as striped blocks across every row, labelled
    /// with how much is trimmed. Drag the yellow grips to change it.
    private func trimmedAreas(width: CGFloat) -> some View {
        let start = x(model.trimStart, width)
        let end = x(model.trimEnd, width)
        return ZStack(alignment: .topLeading) {
            if model.trimStart > 0.05 {
                trimmedBlock(seconds: model.trimStart, width: start).offset(x: 0, y: handleHeight)
            }
            if model.duration - model.trimEnd > 0.05 {
                trimmedBlock(seconds: model.duration - model.trimEnd, width: width - end).offset(x: end, y: handleHeight)
            }
        }
        .allowsHitTesting(false)
    }

    /// A trimmed part: the rows dimmed, plus a yellow block on the Edits row
    /// (next to the red cuts and orange speed-ups) saying how much is trimmed.
    private func trimmedBlock(seconds: Double, width: CGFloat) -> some View {
        let editsRowTop = rowHeight * 2 + rowSpacing * 2
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black.opacity(0.3))
                .frame(width: max(width, 0), height: rowsHeight)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.8))
                .overlay(alignment: .leading) {
                    if width > 60 {
                        Text("Trim \(seconds.formatted(.number.precision(.fractionLength(1)))) s")
                            .font(.caption2.bold())
                            .foregroundStyle(.black.opacity(0.75))
                            .padding(.leading, 10)
                    }
                }
                .frame(width: max(width, 0), height: rowHeight)
                .offset(y: editsRowTop)
        }
    }

    // MARK: Playhead

    /// The strip above the rows: click or drag anywhere on it to scrub.
    private func scrubStrip(width: CGFloat) -> some View {
        Color.clear
            .frame(height: handleHeight)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space)).onChanged {
                model.seek(to: time($0.location.x, width))
            })
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
    }

    /// The red line with a handle on top (an arrow pointing down) to grab.
    private func playhead(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            PlayheadHandle()
                .fill(.red)
                .frame(width: 14, height: handleHeight)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            Rectangle()
                .fill(.red)
                .frame(width: 2, height: rowsHeight)
                .allowsHitTesting(false)
        }
        .offset(x: x(model.currentTime, width) - 7)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space)).onChanged {
            model.seek(to: time($0.location.x, width))
        })
        .help("Drag to move through the video")
    }

    /// Under the rows while a zoom is selected: how close that zoom goes.
    private func zoomLevelBar(_ zoom: ZoomSegment) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Text("Zoom level").foregroundStyle(.secondary)
            Slider(value: Binding(
                get: { zoom.scale },
                set: { var changed = zoom; changed.scale = $0; model.updateZoom(changed) }
            ), in: 1.25...5)
            .frame(maxWidth: 260)
            Text(zoom.scale.formatted(.number.precision(.fractionLength(1))) + "×")
                .monospacedDigit()
                .frame(width: 36, alignment: .leading)
            Text("Drag the target in the panel on the right to choose where it zooms.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
    }

    // MARK: Rows

    private func clipRow(width: CGFloat) -> some View {
        let start = x(model.trimStart, width)
        let end = x(model.trimEnd, width)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.yellow.opacity(0.25))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.yellow, lineWidth: 2) }
                .overlay(alignment: .leading) { Text("Clip").font(.caption.bold()).padding(.leading, 12) }
                .frame(width: max(end - start, 12))
                .offset(x: start)
            trimHandle(at: start, width: width) { model.setTrimStart($0) }
            trimHandle(at: end - 12, width: width) { model.setTrimEnd($0) }
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space)).onChanged {
            model.seek(to: time($0.location.x, width))
        })
    }

    private func zoomRow(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            emptyRow(width: width) { if model.style.autoZoom { model.addZoom(at: $0) } }
            if model.style.autoZoom {
                ForEach(model.zoomSegments) { zoom in
                    block(
                        id: zoom.id, start: zoom.start, end: zoom.end,
                        label: zoom.scale.formatted(.number.precision(.fractionLength(1))) + "×",
                        color: .accentColor, width: width
                    ) { start, end in
                        var changed = zoom
                        changed.start = start
                        changed.end = end
                        model.updateZoom(changed)
                    }
                }
            } else {
                Text("Zoom is off").font(.caption).foregroundStyle(.secondary).padding(.leading, 8)
            }
        }
        .frame(height: rowHeight)
    }

    private func editsRow(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            emptyRow(width: width, onDoubleClick: nil)
            ForEach(model.timeEdits) { edit in
                block(
                    id: edit.id, start: edit.start, end: edit.end,
                    label: edit.kind == .cut ? "Cut" : edit.speed.formatted(.number.precision(.fractionLength(0))) + "×",
                    color: edit.kind == .cut ? .red : .orange, width: width
                ) { start, end in
                    var changed = edit
                    changed.start = start
                    changed.end = end
                    model.updateEdit(changed)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func layoutRow(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            emptyRow(width: width) { model.addLayout(at: $0) }
            ForEach(model.layoutSegments) { segment in
                block(
                    id: segment.id, start: segment.start, end: segment.end,
                    label: segment.layout.title, color: .purple, width: width
                ) { start, end in
                    var changed = segment
                    changed.start = start
                    changed.end = end
                    model.updateLayout(changed)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func textRow(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            emptyRow(width: width) { model.addText(at: $0) }
            ForEach(model.textOverlays) { overlay in
                block(
                    id: overlay.id, start: overlay.start, end: overlay.end,
                    label: overlay.text, color: .teal, width: width
                ) { start, end in
                    var changed = overlay
                    changed.start = start
                    changed.end = end
                    model.updateText(changed)
                }
            }
        }
        .frame(height: rowHeight)
    }

    private func emptyRow(width: CGFloat, onDoubleClick: ((Double) -> Void)?) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.quaternary.opacity(0.6))
            .contentShape(Rectangle())
            .onTapGesture(count: 2, coordinateSpace: .named(space)) { onDoubleClick?(time($0.x, width)) }
            // A click moves the playhead to exactly that spot.
            .onTapGesture(coordinateSpace: .named(space)) {
                model.selectedID = nil
                model.seek(to: time($0.x, width))
            }
    }

    // MARK: Blocks

    /// A movable, resizable block. `update` gets the new (start, end).
    private func block(
        id: UUID, start: Double, end: Double, label: String, color: Color, width: CGFloat,
        update: @escaping (Double, Double) -> Void
    ) -> some View {
        let left = x(start, width)
        let blockWidth = max(x(end, width) - left, 12)
        let isSelected = model.selectedID == id
        return RoundedRectangle(cornerRadius: 6)
            .fill(color.opacity(isSelected ? 1 : 0.65))
            .overlay { if isSelected { RoundedRectangle(cornerRadius: 6).strokeBorder(.white, lineWidth: 2) } }
            .overlay(alignment: .leading) {
                if blockWidth > 40 {
                    Text(label).font(.caption2.bold()).foregroundStyle(.white).padding(.leading, 10)
                }
            }
            .overlay(alignment: .leading) {
                resizeEdge(width: width) { update(min($0, end - 0.3), end) }
            }
            .overlay(alignment: .trailing) {
                resizeEdge(width: width) { update(start, max($0, start + 0.3)) }
            }
            .frame(width: blockWidth, height: rowHeight)
            .offset(x: left)
            .onTapGesture(coordinateSpace: .named(space)) {
                model.selectedID = id
                model.seek(to: time($0.x, width))
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
                .onChanged { value in
                    if moveOrigin?.id != id {
                        moveOrigin = (id, start, end)
                        model.selectedID = id
                    }
                    guard let origin = moveOrigin else { return }
                    let length = origin.end - origin.start
                    let newStart = min(max(0, origin.start + time(value.translation.width, width)), model.duration - length)
                    update(newStart, newStart + length)
                }
                .onEnded { _ in moveOrigin = nil })
    }

    private func resizeEdge(width: CGFloat, onDrag: @escaping (Double) -> Void) -> some View {
        Color.white.opacity(0.001)
            .frame(width: 8)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(space)).onChanged {
                onDrag(time($0.location.x, width))
            })
    }

    /// A thick yellow grip at each end of the clip. Drag to trim; I and O
    /// trim to the playhead.
    private func trimHandle(at position: CGFloat, width: CGFloat, onDrag: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.yellow)
            .overlay {
                HStack(spacing: 2) {
                    Capsule().fill(.black.opacity(0.45)).frame(width: 1.5, height: 12)
                    Capsule().fill(.black.opacity(0.45)).frame(width: 1.5, height: 12)
                }
            }
            .frame(width: 12, height: rowHeight)
            .offset(x: position)
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(space)).onChanged {
                onDrag(time($0.location.x, width))
            })
            .help("Drag to trim (or press I and O to trim to the playhead)")
    }

    // MARK: Helpers

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        width * seconds / max(model.duration, 0.01)
    }

    /// Timeline x (or a distance) → seconds.
    private func time(_ x: CGFloat, _ width: CGFloat) -> Double {
        min(max(0, Double(x / max(width, 1)) * model.duration), model.duration)
    }

    private static func format(_ seconds: Double) -> String {
        let total = max(0, seconds)
        return String(format: "%d:%04.1f", Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
    }
}

/// A rounded tab with a point at the bottom, like a map pin.
private struct PlayheadHandle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r: CGFloat = 3
        path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.height * 0.55))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
