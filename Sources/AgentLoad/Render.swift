import AppKit
import SwiftUI
import AgentLoadCore

/// `--render-png <path> [--hover | --hover-tools | --hover-other] [--dark] [--mockup-data]`: renders the dropdown from live data with
/// ImageRenderer, composed like docs/mockup.html (grey backdrop, card shadows, side panel to
/// the right) so the two can be compared side by side.
enum Render {
    @MainActor
    /// `hover`: id of the row to hover: "session" (first session), "folded:tools", "folded:other", or nil.
    static func renderPNG(to path: String, hover: String?, dark: Bool, mockupData: Bool = false) -> Bool {
        let snap: Snapshot
        if mockupData {
            snap = MockupData.snapshot()
        } else {
            let sampler = Sampler()
            _ = sampler.sample(includeOtherUsers: true)
            Thread.sleep(forTimeInterval: 3)
            snap = sampler.sample(includeOtherUsers: true)
        }

        let model = AppModel()
        model.snapshot = snap
        let hoveredID: String?
        switch hover {
        case "session": hoveredID = snap.sessions.first?.id
        case "thinking": hoveredID = snap.sessions.first { $0.state == .thinking }?.id
        case "waiting": hoveredID = snap.sessions.first { $0.state == .waiting }?.id
        default: hoveredID = hover
        }
        model.hoveredRowID = hoveredID
        let panel = hoveredID.flatMap { AppDelegate.sidePanel(for: $0, in: snap) }

        // Where the hovered row sits, for placing the side panel level with it.
        var rowTop: CGFloat = 0
        if let hoveredID {
            let measure = ImageRenderer(content: DropdownView(model: model, renderNow: snap.date.addingTimeInterval(2)))
            _ = measure.nsImage   // forces layout; fills model.rowFrames via the preference
            rowTop = model.rowFrames[hoveredID]?.minY ?? 0
        }

        let shadow = Color.black.opacity(0.25)
        let content = HStack(alignment: .top, spacing: 6) {
            DropdownView(model: model, renderNow: snap.date.addingTimeInterval(2))
                .compositingGroup().shadow(color: shadow, radius: 15, x: 0, y: 10)
            if let panel {
                panel
                    .compositingGroup().shadow(color: shadow, radius: 15, x: 0, y: 10)
                    .padding(.top, rowTop)
            }
        }
        .padding(30)
        .background(Color(hex: 0xC9CCD3))
        .environment(\.colorScheme, dark ? .dark : .light)

        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let cg = r.cgImage else { return false }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        do { try data.write(to: URL(fileURLWithPath: path)) } catch { return false }
        print("wrote \(path) (\(cg.width)x\(cg.height) px)")
        return true
    }
}
