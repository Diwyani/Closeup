import AppKit
import SwiftUI

/// A colour swatch with its hex value. Click it for a picker in a popover:
/// saturation/brightness square, hue slider, hex field, eyedropper and
/// recent colours (like Figma's).
struct ColorField: View {
    @Binding var color: RGBAColor
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: 6) {
                Swatch(color: color, size: CGSize(width: 22, height: 16))
                Text(color.hex)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .leading) {
            ColorPickerPanel(color: $color)
        }
    }
}

/// Two colour stops on a bar, for the background gradient.
struct GradientField: View {
    @Binding var start: RGBAColor
    @Binding var end: RGBAColor
    /// All the colours, when a preset has more than two (shown on the bar).
    var stops: [RGBAColor]?
    @State private var editing: Stop?

    enum Stop: Identifiable { case start, end; var id: Self { self } }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: (stops ?? [start, end]).map(\.color), startPoint: .leading, endPoint: .trailing))
                    .frame(height: 22)
                HStack {
                    stopButton(start, .start)
                    Spacer()
                    stopButton(end, .end)
                }
                .padding(.horizontal, 3)
            }
            Button {
                swap(&start, &end)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
            }
            .buttonStyle(.borderless)
            .help("Swap colours")
        }
        .popover(item: $editing, arrowEdge: .leading) { stop in
            ColorPickerPanel(color: stop == .start ? $start : $end)
        }
    }

    private func stopButton(_ color: RGBAColor, _ stop: Stop) -> some View {
        Circle()
            .fill(color.color)
            .frame(width: 16, height: 16)
            .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
            .shadow(color: .black.opacity(0.3), radius: 1.5)
            .contentShape(Circle())
            .onTapGesture { editing = stop }
            .help(stop == .start ? "First colour" : "Second colour")
    }
}

private struct Swatch: View {
    let color: RGBAColor
    let size: CGSize

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.color)
            .frame(width: size.width, height: size.height)
            .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.15)) }
    }
}

/// The picker itself. Edits happen in hue/saturation/brightness, so the hue
/// doesn't jump when you drag through white or black.
private struct ColorPickerPanel: View {
    @Binding var color: RGBAColor
    @State private var hsb: HSB
    @State private var hexText: String
    @State private var recent = RecentColors.load()

    private let width: CGFloat = 220

    init(color: Binding<RGBAColor>) {
        _color = color
        _hsb = State(initialValue: HSB(color.wrappedValue))
        _hexText = State(initialValue: color.wrappedValue.hex)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            saturationBrightness
            hueSlider
            HStack(spacing: 8) {
                Button {
                    NSColorSampler().show { picked in
                        guard let picked, let srgb = picked.usingColorSpace(.sRGB) else { return }
                        set(RGBAColor(r: srgb.redComponent, g: srgb.greenComponent, b: srgb.blueComponent))
                    }
                } label: {
                    Image(systemName: "eyedropper")
                }
                .help("Pick a colour from anywhere on screen")

                Text("#").foregroundStyle(.secondary)
                TextField("Hex", text: $hexText)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if let parsed = RGBAColor(hexString: hexText) { set(parsed) } else { hexText = color.hex }
                    }
            }
            if !recent.isEmpty {
                HStack(spacing: 6) {
                    ForEach(recent, id: \.self) { hex in
                        if let swatch = RGBAColor(hexString: hex) {
                            Swatch(color: swatch, size: CGSize(width: 20, height: 20))
                                .onTapGesture { set(swatch) }
                                .help("#\(hex)")
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: width + 24)
        .onDisappear { recent = RecentColors.add(color.hex) }
    }

    private var saturationBrightness: some View {
        let height: CGFloat = 150
        return ZStack {
            Color(hue: hsb.h, saturation: 1, brightness: 1)
            LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
            Circle()
                .strokeBorder(.white, lineWidth: 2)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .frame(width: 14, height: 14)
                .position(x: hsb.s * width, y: (1 - hsb.b) * height)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            var changed = hsb
            changed.s = min(max(value.location.x / width, 0), 1)
            changed.b = 1 - min(max(value.location.y / height, 0), 1)
            update(changed)
        })
    }

    private var hueSlider: some View {
        let hues = stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) }
        return ZStack(alignment: .leading) {
            Capsule().fill(LinearGradient(colors: hues, startPoint: .leading, endPoint: .trailing))
            Circle()
                .fill(Color(hue: hsb.h, saturation: 1, brightness: 1))
                .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                .shadow(color: .black.opacity(0.4), radius: 1)
                .frame(width: 16, height: 16)
                .offset(x: hsb.h * (width - 16))
        }
        .frame(width: width, height: 16)
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            var changed = hsb
            changed.h = min(max(value.location.x / width, 0), 0.999)
            update(changed)
        })
    }

    private func update(_ changed: HSB) {
        hsb = changed
        color = changed.rgb
        hexText = color.hex
    }

    private func set(_ new: RGBAColor) {
        color = new
        hsb = HSB(new)
        hexText = new.hex
    }
}

/// Hue, saturation, brightness, each 0…1.
private struct HSB: Equatable {
    var h: Double, s: Double, b: Double

    init(_ color: RGBAColor) {
        let maxValue = max(color.r, color.g, color.b), minValue = min(color.r, color.g, color.b)
        let delta = maxValue - minValue
        b = maxValue
        s = maxValue == 0 ? 0 : delta / maxValue
        var hue = 0.0
        if delta > 0 {
            if maxValue == color.r { hue = (color.g - color.b) / delta }
            else if maxValue == color.g { hue = 2 + (color.b - color.r) / delta }
            else { hue = 4 + (color.r - color.g) / delta }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        h = hue
    }

    var rgb: RGBAColor {
        let ns = NSColor(hue: h, saturation: s, brightness: b, alpha: 1).usingColorSpace(.sRGB) ?? .black
        return RGBAColor(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent)
    }
}

/// The last eight colours you picked, shared by every picker.
private enum RecentColors {
    static let key = "recentColors"

    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    static func add(_ hex: String) -> [String] {
        let list = Array(([hex] + load().filter { $0 != hex }).prefix(8))
        UserDefaults.standard.set(list, forKey: key)
        return list
    }
}

extension RGBAColor {
    /// "6E8BFF"
    var hex: String {
        String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }

    /// Accepts "6E8BFF", "#6E8BFF" or "6EF".
    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespaces).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
