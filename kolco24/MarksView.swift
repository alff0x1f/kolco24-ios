import SwiftUI

// MARK: - Model
struct CheckpointTile: Identifiable {
    let id = UUID()
    let kind: Kind
    let number: String
    let cost: Int
    let time: String
    var isRecent: Bool = false
    var thumb: Thumb?

    enum Kind { case nfc, photo }
    enum Thumb { case birch, triangle, rock }
}

// MARK: - Mock data
private let mockTiles: [CheckpointTile] = [
    .init(kind: .nfc,   number: "00", cost: 0, time: "10:16"),
    .init(kind: .photo, number: "02", cost: 2, time: "11:42", thumb: .birch),
    .init(kind: .nfc,   number: "04", cost: 3, time: "12:08"),
    .init(kind: .photo, number: "07", cost: 4, time: "13:22", isRecent: true, thumb: .triangle),
    .init(kind: .nfc,   number: "11", cost: 5, time: "13:34"),
    .init(kind: .nfc,   number: "13", cost: 5, time: "13:58"),
    .init(kind: .photo, number: "16", cost: 3, time: "14:21", thumb: .rock),
    .init(kind: .nfc,   number: "21", cost: 4, time: "14:47"),
]

// MARK: - MarksView
struct MarksView: View {
    @State private var showScan = false

    private let tiles = mockTiles
    private var totalCost: Int { tiles.reduce(0) { $0 + $1.cost } }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 4)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Metrics card
                HStack(spacing: 6) {
                    MetricView(label: "Взято", value: "\(tiles.count)", unit: "КП")
                    VDivider()
                    MetricView(label: "Сумма", value: "\(totalCost)", unit: "бал.")
                    VDivider()
                    MetricView(label: "До КВ", value: "10:19", isWarning: true)
                }
                .padding(.horizontal, 18)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.04), radius: 1, y: 0.5)
                .padding(.horizontal, DS.hPad)
                .padding(.bottom, 14)

                SectionHeader("Сегодня · 10 окт")

                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(tiles) { tile in
                        if tile.kind == .nfc {
                            NFCTileView(tile: tile)
                        } else {
                            PhotoTileView(tile: tile)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)

                NFCStripView()
                    .padding(.horizontal, DS.hPad)
                    .padding(.bottom, 14)
            }
            .padding(.top, 8)
        }
        .background(Color.paper)
        .navigationTitle("Отметки")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingCTAView(onNFC: { showScan = true }, onPhoto: {})
        }
        .sheet(isPresented: $showScan) {
            ScanSheet()
        }
    }
}

// MARK: - NFC Tile
private struct NFCTileView: View {
    let tile: CheckpointTile

    var body: some View {
        ZStack {
            Canvas { ctx, s in
                let stripeH = max(2.0, s.height * 0.1)
                ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .color(.white))
                let step: CGFloat = 5
                var x: CGFloat = -s.height
                while x < s.width + s.height {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + s.height, y: s.height))
                    ctx.stroke(p, with: .color(Color.black.opacity(0.018)), lineWidth: 1)
                    x += step
                }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: s.width, height: stripeH)),
                         with: .color(Color.brandRed.opacity(0.78)))
                ctx.fill(Path(CGRect(x: 0, y: s.height - stripeH, width: s.width, height: stripeH)),
                         with: .color(Color.brandRed.opacity(0.78)))
            }
            Text(tile.number)
                .font(.mono(28, weight: .bold))
                .foregroundStyle(Color.ink)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay {
            if tile.isRecent { Rectangle().strokeBorder(Color.good, lineWidth: 2) }
        }
        .overlay { Rectangle().stroke(Color.black.opacity(0.06), lineWidth: 0.5) }
    }
}

// MARK: - Photo Tile
private struct PhotoTileView: View {
    let tile: CheckpointTile

    private var gradient: LinearGradient {
        switch tile.thumb {
        case .birch:    return LinearGradient(colors: [Color(hex: "DCD3B0"), Color(hex: "8FA178"), Color(hex: "5B6A4A")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .triangle: return LinearGradient(colors: [Color(hex: "B7C4D3"), Color(hex: "6E7E94"), Color(hex: "2C3845")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .rock:     return LinearGradient(colors: [Color(hex: "C8BFA6"), Color(hex: "897E62"), Color(hex: "4A4233")], startPoint: .topLeading, endPoint: .bottomTrailing)
        default:        return LinearGradient(colors: [Color(hex: "C7C0A6"), Color(hex: "A8A085")], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    var body: some View {
        ZStack {
            gradient
            Canvas { ctx, s in
                let step: CGFloat = 8
                var x: CGFloat = -s.height
                while x < s.width + s.height {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + s.height, y: s.height))
                    ctx.stroke(p, with: .color(Color.white.opacity(0.06)), lineWidth: 2)
                    x += step
                }
            }
            LinearGradient(colors: [.white.opacity(0.06), .black.opacity(0.10)], startPoint: .top, endPoint: .bottom)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            CPBadge(number: tile.number, size: 28)
                .padding(4)
        }
        .overlay {
            if tile.isRecent { Rectangle().strokeBorder(Color.good, lineWidth: 2) }
        }
        .overlay { Rectangle().stroke(Color.black.opacity(0.06), lineWidth: 0.5) }
    }
}

// MARK: - NFC Strip
private struct NFCStripView: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.good.opacity(0.3))
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulse ? 2.6 : 0.8)
                    .opacity(pulse ? 0 : 0.5)
                Circle()
                    .fill(Color.good)
                    .frame(width: 6, height: 6)
            }
            .frame(width: 8, height: 8)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }
            (
                Text("NFC активен").fontWeight(.semibold).foregroundStyle(Color.ink) +
                Text(" · приложите телефон к КП или чипу команды").foregroundStyle(Color.sub)
            )
            .font(.system(size: 12))
            .lineLimit(2)
        }
    }
}

// MARK: - Floating CTA
private struct FloatingCTAView: View {
    let onNFC: () -> Void
    let onPhoto: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onNFC) {
                HStack(spacing: 8) {
                    Image(systemName: "wave.3.right")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Отметить КП")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color.kolcoOrange)
                .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
                .shadow(color: Color.kolcoOrange.opacity(0.55), radius: 20, x: 0, y: 8)
            }
            .buttonStyle(.plain)

            Button(action: onPhoto) {
                HStack(spacing: 6) {
                    Image(systemName: "camera")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.kolcoOrange)
                    Text("Фото")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.ink)
                }
                .frame(width: 96, height: 54)
                .background(Color.white.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.ctaRadius)
                        .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 8)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.hPad)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    NavigationStack { MarksView() }
}
