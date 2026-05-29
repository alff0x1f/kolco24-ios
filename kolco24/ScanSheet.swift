import SwiftUI

// MARK: - Model
struct ChipSlot: Identifiable {
    let id = UUID()
    let chipID: String?
    let memberName: String?
    var isFilled: Bool { chipID != nil }
}

// MARK: - Mock data
private let mockChips: [ChipSlot] = [
    .init(chipID: "597", memberName: "Маленков А."),
    .init(chipID: "601", memberName: "Иванов И."),
    .init(chipID: "604", memberName: "Сидоров П."),
    .init(chipID: nil,   memberName: nil),
    .init(chipID: nil,   memberName: nil),
    .init(chipID: nil,   memberName: nil),
]

// MARK: - ScanSheet
struct ScanSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let chips = mockChips
    private var scanned:   Int { chips.filter(\.isFilled).count }
    private var remaining: Int { chips.count - scanned }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Sheet handle
                Capsule()
                    .fill(Color.sub.opacity(0.35))
                    .frame(width: 36, height: 5)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                // Header
                HStack {
                    Color.clear.frame(width: 30)
                    Spacer()
                    VStack(spacing: 1) {
                        Text("Отметить КП")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color.ink)
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.sub)
                            .font(.system(size: 24))
                    }
                }
                .padding(.horizontal, DS.hPad)
                .padding(.bottom, 4)

                // Timer hero — stays at the top so the iOS NFC system sheet doesn't cover it
                TimerHeroView(seconds: 17, total: 20, remainingScans: remaining)
                    .padding(.horizontal, DS.hPad)
                    .padding(.top, 4)
                    .padding(.bottom, 10)

                // CP Waiting card
                CPWaitingCardView()
                    .padding(.horizontal, DS.hPad)
                    .padding(.bottom, 10)

                // Chips header
                HStack {
                    Text("Чипы команды")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.sub)
                        .textCase(.uppercase)
                    Spacer()
                    Text("\(scanned) / \(chips.count)")
                        .font(.mono(13, weight: .bold))
                        .foregroundStyle(scanned == chips.count ? Color.good : Color.ink)
                }
                .padding(.horizontal, DS.hPad + 2)
                .padding(.bottom, 6)

                // Chip grid
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 0), GridItem(.flexible(), spacing: 0)],
                    spacing: 0
                ) {
                    ForEach(Array(chips.enumerated()), id: \.element.id) { i, chip in
                        ChipSlotView(chip: chip)
                            .overlay(alignment: .trailing) {
                                if i % 2 == 0 {
                                    Rectangle()
                                        .fill(Color.hairline)
                                        .frame(width: 0.5)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if i < chips.count - 2 {
                                    Rectangle()
                                        .fill(Color.hairline)
                                        .frame(height: 0.5)
                                }
                            }
                    }
                }
                .background(Color.card)
                .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
                .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
                .padding(.horizontal, DS.hPad)

                Text("Сканировать чипы можно в любом порядке")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.hPad + 2)
                    .padding(.top, 6)
                    .padding(.bottom, 2)

                // Cancel
                Button("Отменить") { dismiss() }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.sub.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, DS.hPad)
                    .padding(.bottom, 22)
            }
        }
        .background(Color.paper)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - CP Waiting Card
private struct CPWaitingCardView: View {
    var body: some View {
        HStack(spacing: 14) {
            CPBadge(number: "?", size: 62)

            VStack(alignment: .leading, spacing: 3) {
                Text("Метка КП")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(Color.sub)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Text("КП не отсканирован")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.ink)
                Text("Поднесите телефон к чипу на КП")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sub)
            }
            Spacer()
        }
        .padding(16)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.cardShadow, radius: 1, y: 0.5)
    }
}

// MARK: - Chip Slot
private struct ChipSlotView: View {
    let chip: ChipSlot

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if chip.isFilled {
                    Circle()
                        .fill(Color.good)
                        .frame(width: 26, height: 26)
                        .shadow(color: Color.good.opacity(0.25), radius: 4)
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Circle()
                        .strokeBorder(
                            Color.sub.opacity(0.3),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                        )
                        .frame(width: 26, height: 26)
                }
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                if chip.isFilled, let name = chip.memberName, let cid = chip.chipID {
                    Text(name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.ink)
                        .lineLimit(1)
                    Text("Чип \(cid)")
                        .font(.mono(11, weight: .medium))
                        .foregroundStyle(Color.sub)
                } else {
                    Text("Ожидание")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.sub)
                    Text("NFC · SCAN")
                        .font(.mono(10, weight: .medium))
                        .foregroundStyle(Color.sub.opacity(0.5))
                        .textCase(.uppercase)
                        .tracking(0.4)
                }
            }
            Spacer()
        }
        .padding(11)
        .frame(minHeight: 56)
    }
}

// MARK: - Timer Hero
private struct TimerHeroView: View {
    let seconds: Int
    let total: Int
    let remainingScans: Int

    private var progress: Double { total > 0 ? Double(seconds) / Double(total) : 0 }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.amber, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Color.amber.opacity(0.5), radius: 6)
                VStack(spacing: 2) {
                    Text("\(seconds)")
                        .font(.mono(26, weight: .bold))
                        .foregroundStyle(.white)
                    Text("сек")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .textCase(.uppercase)
                        .tracking(1.1)
                }
            }
            .frame(width: 96, height: 96)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color.good)
                        .frame(width: 6, height: 6)
                        .shadow(color: Color.good.opacity(0.3), radius: 4)
                    Text("Сканируйте")
                        .font(.mono(10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .textCase(.uppercase)
                        .tracking(1.3)
                }
                Text("КП и ещё\u{00A0}\(remainingScans) чипа")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("Таймер сбрасывается на \(total)\u{00A0}с при каждом скане")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background { DarkHeroBackground() }
        .clipShape(RoundedRectangle(cornerRadius: DS.heroRadius))
        .shadow(color: Color.heroShadow, radius: 36, x: 0, y: 18)
    }
}

#Preview("Light") {
    ScanSheet()
}

#Preview("Dark") {
    ScanSheet()
        .preferredColorScheme(.dark)
}
