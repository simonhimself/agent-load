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
    private func pick(_ light: UInt32, _ dark: UInt32) -> Color { Color(hex: scheme == .dark ? dark : light) }
    var background: Color { pick(0xF5F5F7, 0x2C2C2E) }   // .menu / .side
    var card: Color { pick(0xFFFFFF, 0x3A3A3C) }         // .gg gauge cards
    var text: Color { pick(0x1D1D1F, 0xF5F5F7) }         // body text
    var grey1: Color { pick(0x6E6E73, 0x98989D) }        // .verdict, .k
    var grey2: Color { pick(0x86868B, 0x8E8E93) }        // .sec, .pj, .sub, .ft
    var track: Color { pick(0xE5E5EA, 0x48484A) }        // gauge track
    var rowHover: Color { pick(0xE8E8ED, 0x3A3A3C) }     // .row.on
    var divider: Color { pick(0xD2D2D7, 0x48484A) }      // footer border
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
    @MainActor func lineBox(_ size: CGFloat) -> some View {
        padding(.vertical, max(0, (size * cssLineHeight - naturalLineHeight(size)) / 2))
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

    var body: some View {
        let p = Palette(scheme: scheme)
        VStack(alignment: .leading, spacing: 0) {
            if let s = model.snapshot {
                content(s, p)
            } else {
                Text("Measuring…").font(sf(13)).foregroundStyle(p.grey2).lineBox(13).padding(.vertical, 20)
            }
        }
        // CSS `width: 340px` excludes padding (content-box), so the card is 340 + 2×12 = 364 pt wide.
        .frame(width: 340, alignment: .leading)
        .padding(.top, 12).padding(.horizontal, 12).padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.background))
        .coordinateSpace(name: "dropdown")
        .onPreferenceChange(RowFrameKey.self) { model.rowFrames = $0 }
    }

    @ViewBuilder private func content(_ s: Snapshot, _ p: Palette) -> some View {
        // 1. Headline + verdict
        HStack(spacing: 7) {
            Circle().fill(Palette.status(s.level)).frame(width: 8, height: 8)
            Text(s.headline).font(sf(15, 600)).foregroundStyle(p.text).lineLimit(1)
        }
        .lineBox(15)
        Text(s.verdict).font(sf(12)).foregroundStyle(p.grey1).lineBox(12)
            .padding(.top, 2).padding(.bottom, 10)

        // 2. Gauges
        HStack(spacing: 8) {
            Gauge(title: "CPU", value: Format.cores(load: s.load1, cores: s.cores),
                  fraction: s.load1 / Double(max(s.cores, 1)), color: Palette.status(s.cpuLevel), p: p)
            // Grey "Swapping N MB/s" line only while memory is actively moving to/from disk.
            Gauge(title: "Memory", value: Format.memory(used: s.memUsedBytes, total: s.memTotalBytes),
                  fraction: Double(s.memUsedBytes) / Double(max(s.memTotalBytes, 1)), color: Palette.status(s.memLevel), p: p,
                  note: Format.swapping(s.swapBytesPerSec))
        }
        .fixedSize(horizontal: false, vertical: true)   // both cards as tall as the taller one
        .padding(.bottom, 10)

        // 3. Sessions
        // In the mockup the gauges' 10 px bottom margin and this header's 12 px top margin
        // collapse (CSS margin collapsing) to 12, so 2 pt more here.
        SectionHeader(title: "Sessions", p: p, topMargin: 2)
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

        // 6. Footer
        VStack(spacing: 0) {
            p.divider.frame(height: 1)
            // "Updated N s ago" removed (owner, 2026-11-14): only Quit, on the right.
            HStack {
                Spacer()
                Text("Quit").contentShape(Rectangle()).onTapGesture { model.onQuit?() }
            }
            .font(sf(11)).foregroundStyle(p.grey2)
            .lineBox(11)
            .padding(.top, 6)
        }
        .padding(.top, 6)
    }

}

struct SectionHeader: View {
    let title: String
    let p: Palette
    var topMargin: CGFloat = 12
    var body: some View {
        Text(title.uppercased()).font(sf(11, 500)).tracking(0.44).foregroundStyle(p.grey2)
            .lineLimit(1).truncationMode(.tail).lineBox(11)
            .padding(.top, topMargin).padding(.horizontal, 2).padding(.bottom, 3)
    }
}

struct Gauge: View {
    let title: String
    let value: String
    let fraction: Double
    let color: Color
    let p: Palette
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(sf(11)).foregroundStyle(p.grey1).lineBox(11)
            Text(value).font(sf(13, 500)).foregroundStyle(p.text).lineLimit(1).lineBox(13)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(p.track)
                    RoundedRectangle(cornerRadius: 2).fill(color)
                        .frame(width: g.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 4).padding(.top, 4)
            if let note {
                Text(note).font(sf(11)).foregroundStyle(p.grey2).lineLimit(1).lineBox(11).padding(.top, 3)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 9)   // mockup: padding 7px 9px
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(p.card))
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
    let p: Palette
    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.title).font(sf(13, 500)).foregroundStyle(p.text)
                        .lineLimit(1).truncationMode(.tail).lineBox(13)
                    if let project = row.project {
                        Text(project).font(sf(11)).foregroundStyle(p.grey2)
                            .lineLimit(1).fixedSize().lineBox(11)          // project always stays visible
                            .layoutPriority(1)
                    }
                }
                Text(row.subtitle).font(sf(11)).foregroundStyle(p.grey2)
                    .lineLimit(1).truncationMode(.tail).lineBox(11)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Numbers(cpu: row.cpuPercent, mem: row.memBytes, p: p)
        }
        .padding(.vertical, 5).padding(.horizontal, 4)   // mockup: padding 5px 4px
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered ? p.rowHover : Color.clear))
    }
}

/// "Agent tools" / "Other apps": styled like a session row (medium title, one grey line).
struct FoldedRowView: View {
    let group: FoldedGroup
    let hovered: Bool
    let p: Palette
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
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered ? p.rowHover : Color.clear))
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
    let heading: String
    let items: [PanelItem]
    /// A single grey line instead of items (thinking sessions).
    var note: String? = nil
    @Environment(\.colorScheme) private var scheme

    /// Session panel: heading = session title (the mockup's "On hover ·" prefix is a mockup
    /// annotation); trivial process kinds hidden.
    init(row: SessionRow) {
        heading = row.title
        switch row.state {
        case .thinking:
            items = []
            note = "Thinking. No programs running on this Mac"
        case .waiting:
            items = row.waitingFor.map { PanelItem(label: $0, cpu: nil, mem: nil) }
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
            SectionHeader(title: heading, p: p, topMargin: 0)
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
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(p.background))
    }

    /// Hides trivial helpers (a `grep` or `tail` at 0% and a few MB) so the panel shows the
    /// programs that matter. Everything is still counted in the session's totals.
    static func isWorthShowing(_ k: KindGroup) -> Bool {
        k.cpuPercent >= 1 || k.memBytes >= 50 * 1_048_576
    }

    /// The kinds listed: the significant ones, or (for an idle-looking session where nothing
    /// is significant) its three heaviest, so the panel is never empty.
    static func shownKinds(_ kinds: [KindGroup]) -> [KindGroup] {
        let significant = kinds.filter(isWorthShowing)
        return significant.isEmpty ? Array(kinds.prefix(3)) : significant
    }
}
