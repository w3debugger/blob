import SwiftUI
import AppKit

struct MatrixRain: View {
    @State private var columns: [Column] = []
    @State private var size: CGSize = .zero
    @State private var isActive: Bool = NSApp?.isActive ?? true

    private let glyphs: [Character] = Array("01ｱｲｳｴｵｶｷｸｹｺ#@$%&*+=<>")
    private let columnWidth: CGFloat = 14
    private let rowHeight: CGFloat = 16

    struct Column: Identifiable {
        let id = UUID()
        var x: CGFloat
        var headY: CGFloat
        var speed: CGFloat
        var length: Int
        var chars: [Character]
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !isActive)) { timeline in
            Canvas { ctx, sz in
                if sz != size {
                    DispatchQueue.main.async { rebuild(for: sz) }
                }
                ctx.fill(Path(CGRect(origin: .zero, size: sz)), with: .color(.black))
                for col in columns {
                    for i in 0..<col.length {
                        let y = col.headY - CGFloat(i) * rowHeight
                        guard y > -rowHeight, y < sz.height else { continue }
                        let ch = col.chars[i % col.chars.count]
                        let alpha: Double = i == 0 ? 1.0 : max(0.05, 1.0 - Double(i) / Double(col.length))
                        let color = i == 0
                            ? Color.white.opacity(alpha)
                            : Color.green.opacity(alpha * 0.9)
                        let text = Text(String(ch))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(color)
                        ctx.draw(text, at: CGPoint(x: col.x, y: y))
                    }
                }
            }
            .onChange(of: timeline.date) { _, _ in
                tick()
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            isActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            isActive = false
        }
    }

    private func rebuild(for sz: CGSize) {
        size = sz
        let count = max(1, Int(sz.width / columnWidth))
        columns = (0..<count).map { i in
            Column(
                x: CGFloat(i) * columnWidth + 4,
                headY: CGFloat.random(in: -200...sz.height),
                speed: CGFloat.random(in: 1...3) * rowHeight,
                length: Int.random(in: 6...20),
                chars: (0..<24).map { _ in glyphs.randomElement()! }
            )
        }
    }

    private func tick() {
        guard size.height > 0 else { return }
        for i in columns.indices {
            columns[i].headY += columns[i].speed * 0.4
            if columns[i].headY - CGFloat(columns[i].length) * rowHeight > size.height {
                columns[i].headY = -CGFloat.random(in: 0...200)
                columns[i].speed = CGFloat.random(in: 1...3) * rowHeight
                columns[i].length = Int.random(in: 6...20)
                columns[i].chars = (0..<24).map { _ in glyphs.randomElement()! }
            }
            if Int.random(in: 0...10) == 0 {
                let idx = Int.random(in: 0..<columns[i].chars.count)
                columns[i].chars[idx] = glyphs.randomElement()!
            }
        }
    }
}
