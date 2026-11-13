import SwiftUI
import UniformTypeIdentifiers

/// The right-hand panel: background, frame, cursor and export settings.
/// Every control writes straight into `model.style`, which updates the preview.
struct StyleInspector: View {
    @Bindable var model: ProjectEditorModel

    /// "1.2 s"
    static func seconds(_ value: Double) -> String {
        max(0, value).formatted(.number.precision(.fractionLength(1))) + " s"
    }

    var body: some View {
        Form {
            Section("Shape") {
                Picker("Shape", selection: $model.style.aspect) {
                    ForEach(ExportStyle.Aspect.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Section("Background") {
                Picker("Type", selection: $model.style.backgroundKind) {
                    Text("Gradient").tag(ExportStyle.BackgroundKind.gradient)
                    Text("Solid").tag(ExportStyle.BackgroundKind.solid)
                    Text("Picture").tag(ExportStyle.BackgroundKind.image)
                }
                .pickerStyle(.segmented)

                switch model.style.backgroundKind {
                case .gradient:
                    GradientSwatches(style: $model.style)
                    LabeledContent("Colours") {
                        // Editing either end turns a many-colour preset back into two colours.
                        GradientField(
                            start: Binding(get: { model.style.gradientStart },
                                           set: { model.style.gradientStart = $0; model.style.gradientStops = nil }),
                            end: Binding(get: { model.style.gradientEnd },
                                         set: { model.style.gradientEnd = $0; model.style.gradientStops = nil }),
                            stops: model.style.gradientStops)
                            .frame(width: 150)
                    }
                    ValueSlider("Angle", value: $model.style.gradientAngle, in: 0...360) { "\(Int($0))°" }
                case .solid:
                    LabeledContent("Colour") { ColorField(color: $model.style.solidColor) }
                case .image:
                    PictureControls(model: model)
                }
            }

            if model.hasCamera {
                Section("Camera") {
                    Picker("Layout", selection: $model.style.baseLayout) {
                        ForEach(CameraLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .help("For the whole video. Layout blocks on the timeline change it for parts.")

                    // Only the settings for the layouts in use.
                    if model.usesLayout(.sideBySide) {
                        Picker("Camera side", selection: $model.style.cameraSide) {
                            Text("Left").tag(ExportStyle.Side.left)
                            Text("Right").tag(ExportStyle.Side.right)
                        }
                        .pickerStyle(.segmented)
                        .help("In tall videos, left puts the camera on top")
                        ValueSlider("Camera width", value: $model.style.cameraPanelShare, in: 0.2...0.7) { "\(Int($0 * 100))%" }
                    }
                    if model.usesLayout(.sideBySide) || model.usesLayout(.camera) {
                        ValueSlider("Panel corners", value: $model.style.cameraPanelRadius, in: 0...80) { "\(Int($0))" }
                    }
                    if model.usesLayout(.bubble) {
                        Toggle("Show bubble", isOn: $model.style.showsCamera)
                        Group {
                            Picker("Corner", selection: $model.style.cameraCorner) {
                                Image(systemName: "arrow.up.left").tag(ExportStyle.Corner.topLeft)
                                Image(systemName: "arrow.up.right").tag(ExportStyle.Corner.topRight)
                                Image(systemName: "arrow.down.left").tag(ExportStyle.Corner.bottomLeft)
                                Image(systemName: "arrow.down.right").tag(ExportStyle.Corner.bottomRight)
                            }
                            .pickerStyle(.segmented)
                            Picker("Shape", selection: $model.style.cameraShape) {
                                Text("Circle").tag(ExportStyle.CameraShape.circle)
                                Text("Square").tag(ExportStyle.CameraShape.square)
                                Text("Tall").tag(ExportStyle.CameraShape.tall)
                                Text("Wide").tag(ExportStyle.CameraShape.wide)
                            }
                            .pickerStyle(.segmented)
                            ValueSlider("Size", value: $model.style.cameraSize, in: 0.12...0.65) { "\(Int($0 * 100))%" }
                            if model.style.cameraShape != .circle {
                                ValueSlider("Corners", value: $model.style.cameraRoundness, in: 0...0.5) { "\(Int($0 * 200))%" }
                            }
                        }
                        .disabled(!model.style.showsCamera)
                    }

                    Toggle("Mirror", isOn: $model.style.cameraMirrored)
                }
            }

            Section("Frame") {
                ValueSlider("Padding", value: $model.style.padding, in: 0...240) { "\(Int($0))" }
                ValueSlider("Corners", value: $model.style.cornerRadius, in: 0...60) { "\(Int($0))" }
                ValueSlider("Shadow", value: $model.style.shadow, in: 0...1) { "\(Int($0 * 100))%" }
            }

            if let selected = model.selectedZoom {
                Section("Selected zoom") {
                    ValueSlider("Level", value: Binding(
                        get: { selected.scale },
                        set: { var zoom = selected; zoom.scale = $0; model.updateZoom(zoom) }
                    ), in: 1.25...5) {
                        $0.formatted(.number.precision(.fractionLength(1))) + "×"
                    }
                    ZoomTargetMap(model: model, zoom: selected)
                    Toggle("Follow cursor", isOn: Binding(
                        get: { selected.followsCursor == true },
                        set: { var zoom = selected; zoom.followsCursor = $0; model.updateZoom(zoom) }
                    ))
                    .help("Off: the zoom holds still on its target. On: it follows your cursor around.")
                    if selected.focus != nil {
                        Button("Automatic target") {
                            var zoom = selected
                            zoom.focus = nil
                            model.updateZoom(zoom)
                        }
                    }
                    Button("Delete zoom", role: .destructive) { model.deleteSelected() }
                }
            }

            if let selected = model.selectedEdit {
                Section(selected.kind == .cut ? "Selected cut" : "Selected speed-up") {
                    if selected.kind == .speed {
                        ValueSlider("Speed", value: Binding(
                            get: { selected.speed },
                            set: { var edit = selected; edit.speed = $0; model.updateEdit(edit) }
                        ), in: 1.5...10) { $0.formatted(.number.precision(.fractionLength(1))) + "×" }
                    }
                    Button(selected.kind == .cut ? "Remove cut" : "Remove speed-up", role: .destructive) {
                        model.deleteSelected()
                    }
                }
            }

            if let selected = model.selectedText {
                Section("Selected text") {
                    TextField("Text", text: Binding(
                        get: { selected.text },
                        set: { var overlay = selected; overlay.text = $0; model.updateText(overlay) }
                    ), axis: .vertical)
                    Picker("Position", selection: Binding(
                        get: { selected.position },
                        set: { var overlay = selected; overlay.position = $0; model.updateText(overlay) }
                    )) {
                        Text("Top").tag(TextOverlay.Position.top)
                        Text("Middle").tag(TextOverlay.Position.center)
                        Text("Bottom").tag(TextOverlay.Position.bottom)
                    }
                    .pickerStyle(.segmented)
                    ValueSlider("Size", value: Binding(
                        get: { selected.size },
                        set: { var overlay = selected; overlay.size = $0; model.updateText(overlay) }
                    ), in: 0.5...2.5) { $0.formatted(.number.precision(.fractionLength(1))) + "×" }
                    TextLookControls(look: Binding(
                        get: { selected.look },
                        set: { var overlay = selected; overlay.look = $0; model.updateText(overlay) }
                    ))
                    Toggle("Dim behind", isOn: Binding(
                        get: { selected.dimsBehind },
                        set: { var overlay = selected; overlay.dimsBehind = $0; model.updateText(overlay) }
                    ))
                    .help("Darkens the screen while this title shows, like a spotlight")
                    Toggle("Avoid the action", isOn: Binding(
                        get: { selected.avoidsAction },
                        set: { var overlay = selected; overlay.avoidsAction = $0; model.updateText(overlay) }
                    ))
                    .disabled(selected.position == .center)
                    .help("Moves to the other edge if the cursor is working near this one")
                    Button("Delete text", role: .destructive) { model.deleteSelected() }
                }
            }

            if let selected = model.selectedLayout {
                Section("Selected layout") {
                    Picker("Layout", selection: Binding(
                        get: { selected.layout },
                        set: { var segment = selected; segment.layout = $0; model.updateLayout(segment) }
                    )) {
                        ForEach(CameraLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Button("Remove layout", role: .destructive) { model.deleteSelected() }
                }
            }

            Section {
                Toggle("Auto-trim start & end", isOn: Binding(
                    get: { model.style.autoTrim }, set: { model.setAutoTrim($0) }))
                    .help("Keeps from just before your first click, keystroke or word to just after your last. Turn off for the whole recording.")
                if model.style.autoTrim {
                    let cut = model.trimStart + (model.duration - model.trimEnd)
                    TimingNote(cut < 0.05
                        ? "Nothing to trim: there's no click, keystroke or word near the start or end."
                        : "Trimmed \(Self.seconds(model.trimStart)) from the start and \(Self.seconds(model.duration - model.trimEnd)) from the end (yellow Clip bar).")
                }
                Group {
                    Toggle("Speed up long waits", isOn: $model.style.speedUpIdle)
                    ValueSlider("Speed", value: $model.style.idleSpeed, in: 2...10) {
                        $0.formatted(.number.precision(.fractionLength(0))) + "×"
                    }
                    .disabled(!model.style.speedUpIdle)
                    if model.style.speedUpIdle {
                        let count = model.automaticEditCount(.speed)
                        TimingNote(count > 0
                            ? "\(count) speed-up\(count == 1 ? "" : "s") on the timeline (orange)."
                            : "No quiet waits of 3 s or longer in this recording.")
                    }
                    Toggle("Cut pauses", isOn: $model.style.cutsSilence)
                    ValueSlider("Pause length", value: $model.style.silenceLength, in: 0.8...3) {
                        $0.formatted(.number.precision(.fractionLength(1))) + " s"
                    }
                    .disabled(!model.style.cutsSilence)
                    if model.style.cutsSilence || model.style.removesFillers {
                        let count = model.automaticEditCount(.cut)
                        TimingNote(count > 0
                            ? "\(count) cut\(count == 1 ? "" : "s") on the timeline (red)."
                            : "No pauses of \(model.style.silenceLength.formatted(.number.precision(.fractionLength(1)))) s or longer without moving, clicking or talking.")
                    }
                    if model.hasMicrophone {
                        Toggle("Remove filler sounds (um, uh)", isOn: $model.style.removesFillers)
                            .disabled(!model.canRemoveFillers)
                            .help(model.canRemoveFillers
                                  ? "Cuts short sounds with no recognised word, like um, uh, coughs and loud breaths"
                                  : "Generate captions first (Captions section). It uses their word timings.")
                    }
                }
            } header: {
                Text("Timing")
            } footer: {
                Text(model.editsAreCustom
                     ? "Your own cuts and speed-ups are kept; automatic ones fill in around them. Reset edits on the timeline to start over."
                     : "Waits of 3 s or more are sped up; shorter pauses are cut. Your voice is never sped up or cut.")
                    .foregroundStyle(.secondary)
            }

            Section("Zoom") {
                Toggle("Zoom", isOn: $model.style.autoZoom)
                Group {
                    Toggle("Zoom while typing", isOn: $model.style.zoomOnTyping)
                    ValueSlider("Typing zoom", value: $model.style.typingZoomLevel, in: 1.25...5) {
                        $0.formatted(.number.precision(.fractionLength(1))) + "×"
                    }
                    .disabled(!model.style.zoomOnTyping)
                    .help("How close it zooms while you type. Higher for small text: about 3× for 12 px.")
                    ValueSlider("Zoom level", value: $model.style.zoomLevel, in: 1.25...3.5) {
                        $0.formatted(.number.precision(.fractionLength(1))) + "×"
                    }
                    ValueSlider("Speed", value: $model.style.zoomSpeed, in: 0.5...2) {
                        $0.formatted(.number.precision(.fractionLength(1))) + "×"
                    }
                }
                .disabled(!model.style.autoZoom)
            }

            Section("Cursor") {
                Toggle("Show cursor", isOn: $model.style.showsCursor)
                ValueSlider("Size", value: $model.style.cursorSize, in: 0.5...3) {
                    $0.formatted(.number.precision(.fractionLength(1))) + "×"
                }
                .disabled(!model.style.showsCursor)
                ValueSlider("Smoothing", value: $model.style.cursorSmoothing, in: 0...1) { "\(Int($0 * 100))%" }
                    .disabled(!model.style.showsCursor)
                Group {
                    Toggle("Hide when idle", isOn: $model.style.hidesIdleCursor)
                    Toggle("Click glow", isOn: $model.style.clickEffect)
                    Toggle("Motion blur", isOn: $model.style.motionBlur)
                }
                .disabled(!model.style.showsCursor)
            }


            if model.hasMicrophone {
                CaptionsSection(model: model)
            }

            if model.hasMicrophone || model.hasSystemAudio {
                Section("Audio") {
                    if model.hasMicrophone {
                        ValueSlider("Microphone", value: $model.style.microphoneVolume, in: 0...2) { "\(Int($0 * 100))%" }
                        HStack {
                            Toggle("Clean up voice", isOn: $model.style.cleansAudio)
                                .disabled(model.isCleaningAudio)
                            if model.isCleaningAudio { ProgressView().controlSize(.small) }
                        }
                        .help("Removes background noise and evens out loudness")
                        if let error = model.audioError { Text(error).foregroundStyle(.red) }
                    }
                    if model.hasSystemAudio {
                        ValueSlider("System audio", value: $model.style.systemVolume, in: 0...2) { "\(Int($0 * 100))%" }
                    }
                }
            }

        }
        .formStyle(.grouped)
    }
}

/// The whole screen, small, with the zoom's view drawn on it. Drag the box
/// to choose exactly where the zoom goes.
private struct ZoomTargetMap: View {
    @Bindable var model: ProjectEditorModel
    let zoom: ZoomSegment

    var body: some View {
        if let map = model.screenMap {
            let aspect = CGFloat(map.width) / CGFloat(map.height)
            GeometryReader { geometry in
                let size = geometry.size
                let box = CGSize(width: size.width / zoom.scale, height: size.height / zoom.scale)
                let target = model.zoomTarget(zoom)
                ZStack(alignment: .topLeading) {
                    Image(decorative: map, scale: 1)
                        .resizable()
                        .frame(width: size.width, height: size.height)
                        .opacity(0.55)
                    if let target {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .background(Color.accentColor.opacity(0.15))
                            .frame(width: box.width, height: box.height)
                            .position(
                                x: min(max(target.x * size.width, box.width / 2), size.width - box.width / 2),
                                y: min(max(target.y * size.height, box.height / 2), size.height - box.height / 2))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    var changed = zoom
                    changed.focus = CGPoint(
                        x: min(max(value.location.x / size.width, 0), 1),
                        y: min(max(value.location.y / size.height, 0), 1))
                    changed.followsCursor = false
                    model.updateZoom(changed)
                })
            }
            .aspectRatio(aspect, contentMode: .fit)
            .help("Drag to choose where this zoom looks")
            Text(zoom.followsCursor == true ? "Following the cursor. Drag the map to hold still on a spot."
                 : zoom.focus == nil ? "Automatic: the middle of what you did. Drag to choose your own."
                 : "Your target. Drag to move it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// A short line under a Timing switch saying what it found.
private struct TimingNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

/// Box, text colour and weight, for a title or the captions.
private struct TextLookControls: View {
    @Binding var look: TextLook

    var body: some View {
        Picker("Box", selection: $look.box) {
            ForEach(TextLook.Box.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if look.box == .custom || look.box == .glass {
            LabeledContent(look.box == .glass ? "Tint" : "Box colour") { ColorField(color: $look.boxColor) }
        }
        if look.box != .none {
            ValueSlider(look.box == .glass ? "Tint amount" : "Box opacity", value: $look.boxOpacity, in: 0...1) {
                "\(Int($0 * 100))%"
            }
        }
        Toggle("Auto text colour", isOn: $look.autoColor)
            .help("White or black, whichever reads better on what's behind the text")
        if !look.autoColor {
            LabeledContent("Text colour") { ColorField(color: $look.textColor) }
        }
        Picker("Weight", selection: $look.weight) {
            Text("Regular").tag(TextLook.Weight.regular)
            Text("Semibold").tag(TextLook.Weight.semibold)
            Text("Bold").tag(TextLook.Weight.bold)
        }
        .pickerStyle(.segmented)
    }
}

/// Choose a background picture (or your wallpaper), then blur and dim it.
private struct PictureControls: View {
    @Bindable var model: ProjectEditorModel

    var body: some View {
        if let thumbnail = model.backgroundThumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 90)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        HStack {
            Button(model.style.backgroundImage == nil ? "Choose picture" : "Change picture") { choosePicture() }
            Button("Use my wallpaper") { model.useDesktopWallpaper() }
        }
        if let error = model.backgroundError { Text(error).foregroundStyle(.red) }
        if model.style.backgroundImage != nil {
            ValueSlider("Blur", value: $model.style.backgroundBlur, in: 0...1) { "\(Int($0 * 100))%" }
            ValueSlider("Dim", value: $model.style.backgroundDim, in: 0...1) { "\(Int($0 * 100))%" }
        }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for the background"
        if panel.runModal() == .OK, let url = panel.url { model.useBackgroundImage(url) }
    }
}

/// Generate, show and fix captions.
private struct CaptionsSection: View {
    @Bindable var model: ProjectEditorModel

    var body: some View {
        Section("Captions") {
            HStack {
                Button(model.captions.isEmpty ? "Generate captions" : "Regenerate") { model.generateCaptions() }
                    .disabled(model.isGeneratingCaptions)
                if model.isGeneratingCaptions {
                    ProgressView().controlSize(.small)
                    Text("Listening").foregroundStyle(.secondary)
                }
            }
            if let error = model.captionError { Text(error).foregroundStyle(.red) }
            if !model.captions.isEmpty {
                Toggle("Show captions", isOn: $model.style.showsCaptions)
                ValueSlider("Size", value: $model.style.captionSize, in: 0.6...1.8) {
                    $0.formatted(.number.precision(.fractionLength(1))) + "×"
                }
                .disabled(!model.style.showsCaptions)
                Group {
                    TextLookControls(look: $model.style.captionLook)
                    Toggle("Avoid the action", isOn: $model.style.captionsAvoidAction)
                        .help("Moves captions to the top while the cursor works near the bottom")
                }
                .disabled(!model.style.showsCaptions)
                DisclosureGroup("Edit text") {
                    ForEach(model.captions) { caption in
                        HStack(alignment: .firstTextBaseline) {
                            // Click the time to jump there.
                            Button(Self.format(caption.start)) { model.seek(to: caption.start) }
                                .buttonStyle(.link)
                                .monospacedDigit()
                            TextField("", text: Binding(
                                get: { caption.text },
                                set: { var changed = caption; changed.text = $0; model.updateCaption(changed) }
                            ), axis: .vertical)
                            .labelsHidden()
                        }
                    }
                }
            }
        }
    }

    private static func format(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

/// Shape preset, resolution, export and sharing. Lives in the Export
/// popover at the top right of the editor.
struct ExportControls: View {
    @Bindable var model: ProjectEditorModel

    var body: some View {
        Menu("Preset") {
            ForEach(ExportPreset.allCases) { preset in
                Button(preset.title) {
                    model.style.aspect = preset.aspect
                    model.resolution = preset.resolution
                }
            }
        }
        .disabled(model.exportProgress != nil)
        .help("Sets the shape and size for where you'll post it")

        Picker("Resolution", selection: $model.resolution) {
            ForEach(ExportResolution.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .disabled(model.exportProgress != nil)

        if let progress = model.exportProgress {
            HStack {
                ProgressView(value: progress)
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
                Button("Cancel") { model.cancelExport() }
            }
        } else {
            Button {
                model.export()
            } label: {
                Label("Export MP4", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }

        if model.outputLength > 140, model.exportProgress == nil {
            Text("Longer than 2:20, the limit for videos on X with a free account.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let url = model.exportedURL, model.exportProgress == nil {
            // Drag this chip into a browser tab, Slack, Finder or any app.
            HStack(spacing: 8) {
                Image(systemName: "film")
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text("Drag anywhere to share").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }

            HStack {
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([url as NSURL])
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the video, then paste it into X, Slack, a browser or any app")
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        if let error = model.exportError {
            Text(error).foregroundStyle(.red)
        }
        if let error = model.saveError {
            Text(error).foregroundStyle(.red)
        }
    }
}

/// One-click gradient presets.
private struct GradientSwatches: View {
    @Binding var style: ExportStyle

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 10), count: 7), spacing: 10) {
            ForEach(GradientPreset.all) { preset in
                let current = style.gradientStops ?? [style.gradientStart, style.gradientEnd]
                let isSelected = current == preset.stops
                Circle()
                    .fill(LinearGradient(
                        colors: preset.stops.map(\.color),
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                    .overlay {
                        Circle().strokeBorder(.primary.opacity(isSelected ? 0.9 : 0.1), lineWidth: isSelected ? 2 : 1)
                    }
                    .help(preset.name)
                    .onTapGesture {
                        var changed = style
                        changed.gradientStart = preset.start
                        changed.gradientEnd = preset.end
                        changed.gradientStops = preset.stops.count > 2 ? preset.stops : nil
                        changed.gradientAngle = preset.angle
                        style = changed
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// A labelled slider with its value shown on the right.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: @escaping (Double) -> String) {
        self.title = title
        _value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                    .labelsHidden()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }
        }
    }
}

extension RGBAColor {
    /// Bridges to SwiftUI's Color so ColorPicker can edit it.
    var color: Color {
        get { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
        set {
            let ns = NSColor(newValue).usingColorSpace(.sRGB) ?? .black
            r = Double(ns.redComponent)
            g = Double(ns.greenComponent)
            b = Double(ns.blueComponent)
            a = Double(ns.alphaComponent)
        }
    }
}
