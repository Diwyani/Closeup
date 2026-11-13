import XCTest

/// Export sizes, presets, saved style settings and small layout maths.
final class ExportSettingsTests: XCTestCase {
    func testExportSizesForEveryShape() {
        XCTAssertEqual(ExportResolution.hd1080.size(for: .wide), CGSize(width: 1920, height: 1080))
        XCTAssertEqual(ExportResolution.hd1080.size(for: .vertical), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(ExportResolution.hd1080.size(for: .square), CGSize(width: 1080, height: 1080))
        XCTAssertEqual(ExportResolution.hd1080.size(for: .classic), CGSize(width: 1440, height: 1080))
        XCTAssertEqual(ExportResolution.hd720.size(for: .wide), CGSize(width: 1280, height: 720))
        XCTAssertEqual(ExportResolution.uhd4K.size(for: .wide), CGSize(width: 3840, height: 2160))
    }

    func testEveryExportSizeIsEven() {
        // Video encoders refuse odd widths and heights.
        for resolution in ExportResolution.allCases {
            for aspect in ExportStyle.Aspect.allCases {
                let size = resolution.size(for: aspect)
                XCTAssertEqual(Int(size.width) % 2, 0, "\(resolution.rawValue) \(aspect.rawValue)")
                XCTAssertEqual(Int(size.height) % 2, 0, "\(resolution.rawValue) \(aspect.rawValue)")
            }
        }
    }

    func testBitrateGrowsWithResolution() {
        XCTAssertLessThan(ExportResolution.hd720.bitrate, ExportResolution.hd1080.bitrate)
        XCTAssertLessThan(ExportResolution.hd1080.bitrate, ExportResolution.uhd4K.bitrate)
    }

    func testPresets() {
        XCTAssertEqual(ExportPreset.youtube.aspect, .wide)
        XCTAssertEqual(ExportPreset.youtube.resolution, .uhd4K)
        XCTAssertEqual(ExportPreset.x.resolution, .hd1080)
        XCTAssertEqual(ExportPreset.linkedIn.aspect, .square)
        XCTAssertEqual(ExportPreset.vertical.aspect, .vertical)
    }

    // MARK: style.json

    func testStyleSurvivesSavingAndLoading() throws {
        var style = ExportStyle()
        style.aspect = .vertical
        style.padding = 12
        style.zoomSegments = [ZoomSegment(start: 1, end: 2, scale: 2.5, focus: CGPoint(x: 0.25, y: 0.75), followsCursor: false)]
        style.timeEdits = [TimeEdit(kind: .speed, start: 3, end: 6, speed: 8)]
        style.dismissedEdits = [TimeEdit(kind: .cut, start: 7, end: 8)]
        style.trimStart = 1.5
        style.trimEnd = 9
        style.cameraLayouts = [LayoutSegment(start: 0, end: 3, layout: .sideBySide)]
        style.textOverlays = [TextOverlay(start: 0, end: 2)]
        style.captions = [Caption(start: 0, end: 1, text: "Hi", words: [CaptionWord(text: "Hi", start: 0, end: 1)])]
        style.microphoneVolume = 0.5
        style.gradientStops = GradientPreset.all[6].stops

        let url = FileManager.default.temporaryDirectory.appending(path: "closeup-style-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try style.save(to: url)
        XCTAssertEqual(try ExportStyle.load(from: url), style)
    }

    func testAnEmptyStyleFileGivesTheDefaults() throws {
        let style = try JSONDecoder().decode(ExportStyle.self, from: Data("{}".utf8))
        XCTAssertEqual(style, ExportStyle())
    }

    func testAnOlderStyleFileKeepsItsValuesAndFillsInTheRest() throws {
        let json = #"{"padding": 40, "aspect": "1:1", "autoZoom": false}"#
        let style = try JSONDecoder().decode(ExportStyle.self, from: Data(json.utf8))
        XCTAssertEqual(style.padding, 40)
        XCTAssertEqual(style.aspect, .square)
        XCTAssertFalse(style.autoZoom)
        XCTAssertEqual(style.cursorSize, ExportStyle().cursorSize)
        XCTAssertEqual(style.captionLook, ExportStyle().captionLook)
    }

    func testTitlesFromBeforeTextLooksKeepTheirBox() throws {
        let json = #"{"start": 1, "end": 3, "text": "Old", "hasBackground": true}"#
        let overlay = try JSONDecoder().decode(TextOverlay.self, from: Data(json.utf8))
        XCTAssertEqual(overlay.look.box, .dark)
        XCTAssertEqual(overlay.look.weight, .bold)
        let plain = try JSONDecoder().decode(TextOverlay.self, from: Data(#"{"start": 1, "end": 3}"#.utf8))
        XCTAssertEqual(plain.look.box, TextLook.Box.none)
        XCTAssertEqual(plain.text, "Your text")
    }

    func testDefaultsThatDefineTheLook() {
        // Changing any of these changes how every new export looks.
        let style = ExportStyle()
        XCTAssertEqual(style.padding, 80)
        XCTAssertEqual(style.cornerRadius, 14)
        XCTAssertEqual(style.zoomLevel, 2)
        XCTAssertEqual(style.typingZoomLevel, 3)
        XCTAssertEqual(style.cursorSize, 1.5)
        XCTAssertEqual(style.aspect, .wide)
        XCTAssertEqual(style.backgroundKind, .gradient)
    }

    // MARK: Small maths

    func testTitleFadesInAndOut() {
        let overlay = TextOverlay(start: 2, end: 5)
        XCTAssertEqual(overlay.opacity(at: 1.9), 0)
        XCTAssertEqual(overlay.opacity(at: 2.125), 0.5, accuracy: 1e-9)
        XCTAssertEqual(overlay.opacity(at: 3), 1)
        XCTAssertEqual(overlay.opacity(at: 4.875), 0.5, accuracy: 1e-9)
        XCTAssertEqual(overlay.opacity(at: 5), 0)
    }

    func testLayoutChangeEasesInAndOut() {
        let segments = [LayoutSegment(start: 10, end: 20, layout: .camera)]
        XCTAssertNil(LayoutGeometry.active(in: segments, at: 5))
        XCTAssertEqual(LayoutGeometry.active(in: segments, at: 15)?.1, 1)
        let halfway = LayoutGeometry.active(in: segments, at: 10 - LayoutGeometry.transition / 2)
        XCTAssertEqual(halfway?.0, .camera)
        XCTAssertEqual(Double(halfway!.1), 0.5, accuracy: 1e-6)  // smoothstep is 0.5 at the midpoint
        XCTAssertEqual(Double(LayoutGeometry.active(in: segments, at: 10 - LayoutGeometry.transition)!.1), 0, accuracy: 1e-6)
    }

    func testLayoutBlendIsAStraightMix() {
        let a = LayoutGeometry(screenArea: CGRect(x: 0, y: 0, width: 100, height: 100), cameraRect: .zero, cameraRadius: 0, cameraOpacity: 0)
        let b = LayoutGeometry(screenArea: CGRect(x: 100, y: 0, width: 300, height: 100), cameraRect: .zero, cameraRadius: 10, cameraOpacity: 1)
        let mixed = a.blended(to: b, 0.5)
        XCTAssertEqual(mixed.screenArea, CGRect(x: 50, y: 0, width: 200, height: 100))
        XCTAssertEqual(mixed.cameraRadius, 5)
        XCTAssertEqual(mixed.cameraOpacity, 0.5)
    }

    func testSideBySideSplitsTheFrameWithoutOverlap() {
        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let padded = bounds.insetBy(dx: 80, dy: 80)
        let layout = LayoutGeometry.make(.sideBySide, bounds: bounds, padded: padded, style: ExportStyle(), unit: 1)
        XCTAssertFalse(layout.screenArea.intersects(layout.cameraRect))
        XCTAssertTrue(padded.contains(layout.screenArea))
        XCTAssertTrue(padded.contains(layout.cameraRect))
        XCTAssertEqual(layout.cameraRect.width / (padded.width - 24), 0.4, accuracy: 1e-6)
    }

    func testHexColours() {
        let color = RGBAColor(hex: 0xFF8000)
        XCTAssertEqual(color.r, 1)
        XCTAssertEqual(color.g, 128.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(color.b, 0)
        XCTAssertEqual(color.a, 1)
        XCTAssertEqual(color.hex, "FF8000")
        XCTAssertEqual(RGBAColor(hexString: "#6ef")?.hex, "66EEFF")
        XCTAssertNil(RGBAColor(hexString: "nope"))
    }
}
