import SwiftUI
import AppKit
import AgentLoadCore

// SwiftUI views for the dropdown and the hover side panel. Sizes, weights and colours are
// taken 1:1 from docs/mockup.html (v4, approved). Do not restyle without asking the owner.

// MARK: - Palette

/// Flat colours. Light values are the mockup's hex codes; dark values follow Apple's dark
/// system colours. Flat (not materials) on purpose: ImageRenderer cannot draw materials, and
/// the PNG renders must match the live window.
struct Palette {
    let scheme: ColorScheme
    /// Text on the accent-coloured hover highlight: white, like a selected native menu item.
    var onAccent = false
    /// Same palette for content drawn on the hover highlight.
    func accented() -> Palette { var c = self; c.onAccent = true; return c }
    private func pick(_ light: UInt32, _ dark: UInt32) -> Color { Color(hex: scheme == .dark ? dark : light) }
    var background: Color { pick(0xF5F5F7, 0x2C2C2E) }   // .menu / .side
    var text: Color { onAccent ? .white : pick(0x1D1D1F, 0xF5F5F7) }         // body text
    // Dark mode greys and the row highlight are translucent white (like the system's secondary
    // label colour), so they stay readable on the dark menu material over a bright desktop, where
    // the flat #8E8E93 got lost (2026-11-14). Over the flat render colour they look as before.
    var grey1: Color { onAccent ? Color.white.opacity(0.85) : scheme == .dark ? Color.white.opacity(0.60) : Color(hex: 0x6E6E73) }   // .verdict, .k
    var grey2: Color { onAccent ? Color.white.opacity(0.80) : scheme == .dark ? Color.white.opacity(0.50) : Color(hex: 0x86868B) }   // .sec, .pj, .sub, .ft
    /// Gauge bar track ("B · No cards", owner 2026-11-14): black 8% / white 12%, on the glass.
    var track: Color { scheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }
    /// Hairline under the gauges: black 10% / white 15%.
    var separator: Color { scheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.10) }
    var rowHover: Color { scheme == .dark ? Color.white.opacity(0.10) : Color(hex: 0xE8E8ED) }   // "…" button hover
    /// Session / folded row hover: the system accent colour, like a highlighted native menu item
    /// (owner, 2026-11-14). Follows System Settings → Appearance → Accent colour (blue by default).
    var rowAccent: Color { Color(nsColor: .controlAccentColor) }
    var divider: Color { pick(0xD2D2D7, 0x48484A) }      // footer border
    /// Hairline ring around the dropdown and the hover panel, as native menus have on macOS 26
    /// (measured from a native NSMenu: slightly darker than the menu in light mode, lighter in dark).
    var menuBorder: Color { scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08) }
    static func status(_ l: StatusLevel) -> Color {
        switch l {
        case .green: return Color(hex: 0x34C759)
        case .amber: return Color(hex: 0xFF9F0A)
        case .red: return Color(hex: 0xFF453A)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// System font at a CSS-style numeric weight (the mockup uses 550 and 650, between the
/// named SwiftUI weights). SF is a variable font, so in-between weights render correctly.
func sf(_ size: CGFloat, _ cssWeight: Int = 400) -> Font {
    // CSS 400 → 0 (regular), 500 → 0.23 (medium), 600 → 0.3 (semibold), 700 → 0.4 (bold).
    let w: CGFloat
    switch cssWeight {
    case ..<450: w = 0
    case ..<500: w = 0.115
    case ..<600: w = 0.23 + CGFloat(cssWeight - 500) / 100 * 0.07
    case ..<700: w = 0.3 + CGFloat(cssWeight - 600) / 100 * 0.1
    default: w = 0.4
    }
    return Font(NSFont.systemFont(ofSize: size, weight: NSFont.Weight(w)))
}

// MARK: - Line height

/// CSS `line-height` used by the reference mockup (v6): every text line is a box of
/// 1.5 × font size, which gives the airy look the owner approved.
let cssLineHeight: CGFloat = 1.5

/// SwiftUI's own height for one line of the system font at `size`, measured once per size.
@MainActor private var naturalLineHeights: [CGFloat: CGFloat] = [:]
@MainActor func naturalLineHeight(_ size: CGFloat) -> CGFloat {
    if let h = naturalLineHeights[size] { return h }
    let h = NSHostingView(rootView: Text("Ag").font(sf(size))).fittingSize.height
    naturalLineHeights[size] = h
    return h
}

extension View {
    /// Pads a single text line (or a row of same-size text) to a CSS line box of
    /// 1.5 × `size`: the extra space splits evenly above and below, as in a browser.
    @MainActor func lineBox(_ size: CGFloat, lineHeight: CGFloat = cssLineHeight) -> some View {
        padding(.vertical, max(0, (size * lineHeight - naturalLineHeight(size)) / 2))
    }
}

// MARK: - Model shared by the app and the views

final class AppModel: ObservableObject {
    @Published var snapshot: Snapshot?
    /// Row under the mouse: a session id, or "folded:tools" / "folded:other" (drives the row
    /// highlight and the side panel).
    @Published var hoveredRowID: String?
    /// Row frames in the dropdown's coordinate space, to place the side panel next to a row.
    var rowFrames: [String: CGRect] = [:]
    var onHoverChange: ((String?) -> Void)?
    var onOpenFolder: ((SessionRow) -> Void)?
    var onQuit: (() -> Void)?
    /// "…" button in the header: shows the small menu (Open at Login, Quit).
    var onMore: (() -> Void)?
}

struct RowFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Dropdown

struct DropdownView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme
    /// Fixed "now" for PNG renders; nil = live clock.
    var renderNow: Date? = nil
    /// Paint the flat #f5f5f7 menu colour behind everything. Only for PNG renders: the live
    /// window shows the translucent system menu material instead (ImageRenderer cannot draw it).
    var flatBackground = true

    var body: some View {
        let p = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            if let s = model.snapshot {
                content(s, p)
            } else {
                Text("Measuring…").font(sf(13)).foregroundStyle(p.grey2).lineBox(13).padding(.vertical, 20)
            }
        }
        // CSS `width: 376px` excludes padding (content-box), so the card is 376 + 2×12 = 400 pt wide
        // (widened from 340 by the owner, 2026-11-14; the extra room goes to the name column).
        .frame(width: 376, alignment: .leading)
        .padding(.top, 12).padding(.horizontal, 12).padding(.bottom, 10)
        .menuSurface(flat: flatBackground, p: p)
        .coordinateSpace(name: "dropdown")
        .onPreferenceChange(RowFrameKey.self) { model.rowFrames = $0 }
    }

    @ViewBuilder private func content(_ s: Snapshot, _ p: Palette) -> some View {
        // 1. Headline + verdict
        // The "…" button top-right replaces the old footer (owner chose option C, 2026-11-14).
        HStack(spacing: 7) {
            Circle().fill(Palette.status(s.level)).frame(width: 8, height: 8)
            Text(s.headline).font(sf(15, 600)).foregroundStyle(p.text).lineLimit(1)
            Spacer(minLength: 6)
            MoreButton(p: p) { model.onMore?() }
        }
        .lineBox(15)
        Text(s.verdict).font(sf(12)).foregroundStyle(p.grey1).lineBox(12)
            .padding(.top, 2).padding(.bottom, 10)

        // 2. Gauges ("B · No cards, bigger numbers", owner 2026-11-14): no card background, a big
        //    number with a small grey "of 8 cores", a 6 pt bar, a hairline underneath.
        //    Mockup: .gs{gap:16px;padding:0 2px 6px;border-bottom:.5px} .gg{padding:2px 4px 4px}
        HStack(alignment: .top, spacing: 16) {
            // Cores actually in use (not the load average), so it never exceeds the core count.
            Gauge(title: "CPU", value: String(format: "%.1f", s.cpuAveragePercent / 100), unit: "of \(s.cores) cores",
                  fraction: s.cpuAveragePercent / Double(max(s.cores, 1) * 100), color: Palette.status(s.cpuLevel), p: p)
            // Grey "Swapping N MB/s" line only while memory is actively moving to/from disk.
            Gauge(title: "Memory", value: String(format: "%.1f", Double(s.memUsedBytes) / Format.gib),
                  unit: "of \(Int((Double(s.memTotalBytes) / Format.gib).rounded())) GB",
                  fraction: Double(s.memUsedBytes) / Double(max(s.memTotalBytes, 1)), color: Palette.status(s.memLevel), p: p,
                  note: Format.swapping(s.swapBytesPerSec))
        }
        .padding(.horizontal, 2).padding(.bottom, 6)
        .overlay(alignment: .bottom) { Rectangle().fill(p.separator).frame(height: 0.5) }

        // 3. Sessions
        // The gauges' 4 px bottom margin and this header's 12 px top margin collapse (CSS) to 12.
        SectionHeader(title: "Sessions", p: p)
        if s.sessions.isEmpty {
            // Not in the mockup (it always shows sessions); a quiet line instead of an empty section.
            Text("No sessions running").font(sf(11)).foregroundStyle(p.grey2).lineBox(11)
                .padding(.vertical, 5).padding(.horizontal, 4)
        }
        ForEach(s.sessions) { r in
            SessionRowView(row: r, hovered: model.hoveredRowID == r.id, p: p)
                .hoverable(id: r.id, model: model)
                .onTapGesture { model.onOpenFolder?(r) }
        }

        // 4. Apps & tools (renamed from "Everything that is not a session", owner 2026-11-14): two folded rows (layout "A · Folded groups").
        //    Hover shows their items in the side panel; clicking does nothing.
        SectionHeader(title: "Apps & tools", p: p)
        ForEach([s.agentToolsGroup, s.otherAppsGroup]) { g in
            FoldedRowView(group: g, hovered: model.hoveredRowID == g.id, p: p)
                .hoverable(id: g.id, model: model)
        }

        // No footer: Quit lives in the "…" menu in the header.
    }

}

struct SectionHeader: View {
    let title: String
    let p: Palette
    var topMargin: CGFloat = 12
    /// Kept whole after the title (" · CLAUDE CODE"); only the title truncates.
    var suffix: String? = nil
    var body: some View {
        HStack(spacing: 0) {
            Text(title.uppercased()).lineLimit(1).truncationMode(.tail)
            if let suffix { Text(" · " + suffix.uppercased()).lineLimit(1).fixedSize().layoutPriority(1) }
        }
        .font(sf(11, 500)).tracking(0.44).foregroundStyle(p.grey2)
        .lineBox(11)
        .padding(.top, topMargin).padding(.horizontal, 2).padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Gauge: View {
    let title: String
    /// Big number, e.g. "8.6".
    let value: String
    /// Small grey text after it, e.g. "of 8 cores".
    let unit: String
    let fraction: Double
    let color: Color
    let p: Palette
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(sf(11)).foregroundStyle(p.grey1).lineBox(11)
            // .v{font-size:20px;font-weight:600;letter-spacing:-.01em;line-height:1.25}
            // .v small{font-size:12px;font-weight:400;color:#6e6e73;margin-left:3px}
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(sf(20, 600)).tracking(-0.2).foregroundStyle(p.text)
                Text(unit).font(sf(12)).foregroundStyle(p.grey1)
            }
            .lineLimit(1)
            .lineBox(20, lineHeight: 1.25)
            // .track{height:6px;margin-top:6px;border-radius:3px}
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(p.track)
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: g.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 6).padding(.top, 6)
            if let note {
                Text(note).font(sf(11)).foregroundStyle(p.grey2).lineLimit(1).lineBox(11).padding(.top, 3)
            }
        }
        .padding(.top, 2).padding(.horizontal, 4).padding(.bottom, 4)   // .gg{padding:2px 4px 4px}
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// The right-hand columns of every dropdown row, per the v5 grid
/// `minmax(0,1fr) 42px 52px 8px` (6 pt gaps): CPU, memory, and the grey "›" hinting at the
/// hover panel.
struct Numbers: View {
    let cpu: Double
    let mem: UInt64
    let p: Palette
    var body: some View {
        Text(Format.cpu(cpu)).frame(width: 42, alignment: .trailing)
            .font(sf(13).monospacedDigit()).foregroundStyle(p.text).lineBox(13)
        Text(Format.gb(mem)).frame(width: 52, alignment: .trailing)
            .font(sf(13).monospacedDigit()).foregroundStyle(p.text).lineBox(13)
        Text("›").font(sf(13)).foregroundStyle(p.grey2).frame(width: 8, alignment: .trailing).lineBox(13)
    }
}

extension View {
    /// Reports the row's frame (to place the side panel) and tracks the mouse over it.
    func hoverable(id: String, model: AppModel) -> some View {
        self.background(GeometryReader { g in
                Color.clear.preference(key: RowFrameKey.self, value: [id: g.frame(in: .named("dropdown"))])
            })
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { model.hoveredRowID = id }
                else if model.hoveredRowID == id { model.hoveredRowID = nil }
                model.onHoverChange?(model.hoveredRowID)
            }
    }
}

struct SessionRowView: View {
    let row: SessionRow
    let hovered: Bool
    let base: Palette
    init(row: SessionRow, hovered: Bool, p: Palette) { self.row = row; self.hovered = hovered; self.base = p }
    private var p: Palette { hovered ? base.accented() : base }
    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                // Line 1: harness icon (16 × 16, centred on the line), 6 pt gap, title, project.
                HStack(alignment: .center, spacing: 6) {
                    HarnessIcon(harness: row.harness, p: p)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.title).font(sf(13, 500)).foregroundStyle(p.text)
                            .lineLimit(1).truncationMode(.tail).lineBox(13)
                        if let project = row.project {
                            Text(project).font(sf(11)).foregroundStyle(p.grey2)
                                .lineLimit(1).fixedSize().lineBox(11)          // project always stays visible
                                .layoutPriority(1)
                        }
                    }
                }
                // Line 2 aligned with the title text: icon 16 + gap 6 = 22 pt.
                Text(row.subtitle).font(sf(11)).foregroundStyle(p.grey2)
                    .lineLimit(1).truncationMode(.tail).lineBox(11)
                    .padding(.leading, 22)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Numbers(cpu: row.cpuPercent, mem: row.memBytes, p: p)
        }
        .padding(.vertical, 5).padding(.horizontal, 4)   // mockup: padding 5px 4px
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? p.rowAccent : Color.clear))
    }
}

/// "Agent tools" / "Other apps": styled like a session row (medium title, one grey line).
struct FoldedRowView: View {
    let group: FoldedGroup
    let hovered: Bool
    let base: Palette
    init(group: FoldedGroup, hovered: Bool, p: Palette) { self.group = group; self.hovered = hovered; self.base = p }
    private var p: Palette { hovered ? base.accented() : base }
    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                Text(group.title).font(sf(13, 500)).foregroundStyle(p.text).lineLimit(1).truncationMode(.tail).lineBox(13)
                Text(group.members).font(sf(11)).foregroundStyle(p.grey2).lineLimit(1).truncationMode(.tail).lineBox(11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Numbers(cpu: group.cpuPercent, mem: group.memBytes, p: p)
        }
        .padding(.vertical, 5).padding(.horizontal, 4)   // same as session rows
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovered ? p.rowAccent : Color.clear))
    }
}

// MARK: - Hover side panel

/// One line in the side panel.
struct PanelItem: Identifiable {
    var id: String { label }
    let label: String
    /// nil = a line without numbers (e.g. the titles a waiting session waits on).
    let cpu: Double?
    let mem: UInt64?
}

struct SidePanelView: View {
    /// Flat menu colour behind the panel (PNG renders only; live it sits on the menu material).
    var flatBackground = true
    let heading: String
    /// Harness name after the session title in the heading (session panels only).
    var headingSuffix: String? = nil
    let items: [PanelItem]
    /// A single grey line instead of items (thinking sessions).
    var note: String? = nil
    @Environment(\.colorScheme) private var scheme

    /// Session panel: heading = session title (the mockup's "On hover ·" prefix is a mockup
    /// annotation); trivial process kinds hidden.
    init(row: SessionRow) {
        heading = row.title                     // shown in caps: "FIX LOGIN REDIRECT · CLAUDE CODE"
        headingSuffix = row.harness.displayName
        switch row.state {
        case .thinking where row.kinds.isEmpty:
            items = []
            note = "Thinking. No programs running on this Mac"
        case .thinking:
            // Thinking with its Claude Code brain running here: list it.
            items = row.kinds.map { PanelItem(label: $0.label, cpu: $0.cpuPercent, mem: $0.memBytes) }
        case .waiting:
            items = row.waitingFor.map { PanelItem(label: $0, cpu: nil, mem: nil) }
                + row.kinds.map { PanelItem(label: $0.label, cpu: $0.cpuPercent, mem: $0.memBytes) }
        case .processes:
            items = SidePanelView.shownKinds(row.kinds).map { PanelItem(label: $0.label, cpu: $0.cpuPercent, mem: $0.memBytes) }
        }
    }

    /// Folded-row panel ("AGENT TOOLS" / "OTHER APPS"): every item, nothing hidden.
    init(group: FoldedGroup) {
        heading = group.panelTitle
        items = group.items.map { PanelItem(label: $0.name, cpu: $0.cpuPercent, mem: $0.memBytes) }
    }

    var body: some View {
        let p = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: heading, p: p, topMargin: 0, suffix: headingSuffix)
            if let note {
                Text(note).font(sf(11)).foregroundStyle(p.grey2).lineLimit(1).truncationMode(.tail)
                    .lineBox(11)   // grey line in the style of the rows' grey lines
                    .padding(.vertical, 3).padding(.horizontal, 2)
            }
            ForEach(items) { k in
                HStack(spacing: 6) {
                    Text(k.label).font(sf(13, 500)).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    if let cpu = k.cpu, let mem = k.mem {
                        Text(Format.cpu(cpu)).frame(width: 40, alignment: .trailing)
                        Text(Format.gb(mem)).frame(width: 48, alignment: .trailing)
                    }
                }
                .font(sf(13).monospacedDigit()).foregroundStyle(p.text)
                .lineBox(13)
                .padding(.vertical, 3).padding(.horizontal, 2)   // mockup: padding 3px 2px
            }
        }
        // Content-box like the mockup: 240 + 2×10 = 260 pt wide.
        .frame(width: 240, alignment: .leading)
        .padding(.top, 10).padding(.horizontal, 10).padding(.bottom, 8)
        .menuSurface(flat: flatBackground, p: p)
    }

    /// Hides trivial helpers (a `grep` or `tail` at 0% and a few MB) so the panel shows the
    /// programs that matter. Everything is still counted in the session's totals.
    static func isWorthShowing(_ k: KindGroup) -> Bool {
        k.cpuPercent >= 1 || k.memBytes >= 50 * 1_048_576
    }

    /// The kinds listed: the significant ones, or (for an idle-looking session where nothing
    /// is significant) its three heaviest, so the panel is never empty.
    static func shownKinds(_ kinds: [KindGroup]) -> [KindGroup] {
        // A terminal harness's own processes ("Claude Code itself") are always listed.
        let significant = kinds.filter { isWorthShowing($0) || $0.kind.hasSuffix(" itself") || $0.kind == "Claude Code (agent)" }
        return significant.isEmpty ? Array(kinds.prefix(3)) : significant
    }
}

/// Small grey "…" button (22 × 22) in the header; highlighted on hover like a toolbar button.
struct MoreButton: View {
    let p: Palette
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(hover ? p.text : p.grey2)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? p.rowHover : Color.clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture(perform: action)
            .help("More")
    }
}

// MARK: - Menu surface

/// Native menu corner: circular 12 pt, measured from a native NSMenu on macOS 26.
let menuCornerRadius: CGFloat = 12

/// macOS 26+: the live windows sit on Liquid Glass (NSGlassEffectView), which brings its own rim,
/// so the hairline ring is drawn only on the older material and in flat PNG renders.
var usesLiquidGlass: Bool {
    if #available(macOS 26, *) { return !CommandLine.arguments.contains("--debug-old-material") }
    return false
}

extension View {
    /// The dropdown / hover panel surface: the flat menu colour for PNG renders (live, the window's
    /// window shows Liquid Glass or the menu material instead), plus the hairline ring where the
    /// surface has no rim of its own.
    func menuSurface(flat: Bool, p: Palette) -> some View {
        background(RoundedRectangle(cornerRadius: menuCornerRadius).fill(flat ? p.background : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: menuCornerRadius)
                .strokeBorder(flat || !usesLiquidGlass ? p.menuBorder : Color.clear, lineWidth: 0.5))
    }
}

// MARK: - Harness icons

/// The official icon of the agent tool running a session, 16 × 16 pt, left of the title.
/// App icons are loaded at runtime from the installed apps (nothing of other companies is
/// shipped in this repo); Pi has no app, so its mark is drawn from its MIT-licensed logo.
/// Fallback when the app is not installed: a grey SF Symbol "terminal".
struct HarnessIcon: View {
    let harness: Harness
    let p: Palette
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Group {
            if harness == .pi {
                PiMark()
            } else if let img = HarnessIcons.image(harness, dark: scheme == .dark) {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "terminal").font(.system(size: 11)).foregroundStyle(p.grey2)
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Loads each icon once and keeps it (per harness and light/dark).
enum HarnessIcons {
    @MainActor private static var cache: [String: NSImage?] = [:]

    @MainActor static func image(_ h: Harness, dark: Bool) -> NSImage? {
        let key = "\(h.rawValue)-\(dark)"
        if let c = cache[key] { return c }
        let img = load(h, dark: dark)
        cache[key] = img
        return img
    }

    /// Candidate files per harness, first existing one wins. `icon(forFile:)` returns a generic
    /// icon for a missing path rather than nil, so existence is checked first.
    static func load(_ h: Harness, dark: Bool) -> NSImage? {
        let fm = FileManager.default
        func appIcon(_ path: String) -> NSImage? {
            guard fm.fileExists(atPath: path) else { return nil }
            let i = NSWorkspace.shared.icon(forFile: path)
            i.size = NSSize(width: 32, height: 32)
            return i
        }
        switch h {
        case .openChamber: return appIcon("/Applications/OpenChamber.app")
        case .openCode: return appIcon("/Applications/OpenCode.app")
        case .claudeCode: return appIcon("/Applications/Claude.app")   // Claude's mark; Claude Code has no app
        case .codex:
            if let i = appIcon("/Applications/Codex.app") { return i }
            // The official Codex icon shipped inside the ChatGPT app.
            let res = "/Applications/ChatGPT.app/Contents/Resources/"
            let file = res + (dark ? "icon-codex-dark-color.png" : "icon-codex-light.png")
            return fm.fileExists(atPath: file) ? NSImage(contentsOfFile: file) : nil
        case .pi: return nil
        }
    }
}

/// Pi's logo (https://pi.dev/logo.svg, MIT-licensed project), drawn from its three paths.
/// The SVG's 800-unit box has wide margins around the mark; the crop 100…700 gives it about
/// the visual size of the app icons next to it.
struct PiMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 600, o: CGFloat = 100
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: (x - o) * s, y: (y - o) * s) }
            func poly(_ pts: [(CGFloat, CGFloat)], _ hex: UInt32) {
                var path = Path()
                path.move(to: pt(pts[0].0, pts[0].1))
                for q in pts.dropFirst() { path.addLine(to: pt(q.0, q.1)) }
                path.closeSubpath()
                ctx.fill(path, with: .color(Color(hex: hex)))
            }
            poly([(165.29, 165.29), (517.36, 165.29), (517.36, 400), (400, 400), (400, 282.65), (165.29, 282.65)], 0xF09082)
            poly([(165.29, 282.65), (282.65, 282.65), (282.65, 400), (400, 400), (400, 517.36), (282.65, 517.36),
                  (282.65, 634.72), (165.29, 634.72)], 0x4D9ABF)
            poly([(517.36, 400), (634.72, 400), (634.72, 634.72), (517.36, 634.72)], 0xF1BE58)
        }
    }
}
