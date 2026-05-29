import SwiftUI

// MARK: - Model
struct TeamMember: Identifiable {
    let id = UUID()
    let name: String
    let chipID: String?
    var isBound: Bool { chipID != nil }

    var initials: String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
    }
}

// MARK: - Mock data
private let mockMembers: [TeamMember] = [
    .init(name: "Маленков А.", chipID: "597"),
    .init(name: "Иванов И.",   chipID: "601"),
    .init(name: "Сидоров П.",  chipID: "604"),
    .init(name: "Петрова О.",  chipID: "611"),
    .init(name: "Кузьмин Д.",  chipID: nil),
    .init(name: "Смирнов Я.",  chipID: nil),
]

// MARK: - TeamView
struct TeamView: View {
    private let members = mockMembers
    private var boundCount: Int { members.filter(\.isBound).count }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                TeamHeroView(bound: boundCount, total: members.count)
                    .padding(.top, 8)

                SectionHeader("Состав · \(members.count)")
                    .padding(.top, 20)

                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.id) { idx, m in
                        MemberRowView(member: m)
                            .padding(.horizontal, DS.hPad)
                            .padding(.vertical, 8)
                        if idx < members.count - 1 {
                            Rectangle()
                                .fill(Color.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, DS.hPad + 38 + 12)
                        }
                    }
                }
                .background(Color.card)
                .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
                .padding(.horizontal, DS.hPad)

                Text("Привяжите NFC-чип каждому участнику до старта — без него отметки не засчитаются.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DS.hPad + 4)
                    .padding(.top, 8)

                SectionHeader("Прочее")
                    .padding(.top, 20)

                VStack(spacing: 0) {
                    MiscRowView(systemImage: "gearshape.fill", iconBg: Color.charcoal, label: "Настройки", sub: "Соревнование, сервер, NFC")
                        .padding(.horizontal, DS.hPad)
                        .padding(.vertical, 8)
                    Rectangle()
                        .fill(Color.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, DS.hPad + 30 + 12)
                    MiscRowView(systemImage: "questionmark.circle.fill", iconBg: Color.kolcoOrange, label: "Справка и правила", sub: "Регламент, FAQ, контакты оргкомитета")
                        .padding(.horizontal, DS.hPad)
                        .padding(.vertical, 8)
                }
                .background(Color.card)
                .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
                .padding(.horizontal, DS.hPad)
                .padding(.bottom, 32)
            }
        }
        .background(Color.paper)
        .navigationTitle("Команда")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Team Hero
private struct TeamHeroView: View {
    let bound: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color.brandRed)
                    .frame(width: 6, height: 6)
                    .shadow(color: Color.brandRed.opacity(0.3), radius: 4)
                Text("Команда")
                    .font(.mono(10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .textCase(.uppercase)
                    .tracking(1.3)
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("342")
                    .font(.mono(38, weight: .bold))
                    .foregroundStyle(.white)
                Text("Бронь")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.top, 6)

            Text("Категория 12 ч · \(total) человек")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(bound == total ? Color.good : Color.amber)
                        .frame(width: 6, height: 6)
                        .shadow(color: (bound == total ? Color.good : Color.amber).opacity(0.3), radius: 4)
                    Text("\(bound) / \(total) с чипом")
                        .font(.mono(11, weight: .bold))
                        .foregroundStyle(.white)
                        .tracking(0.3)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.1))
                .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
                .clipShape(Capsule())

                if bound < total {
                    Text("\(total - bound) чипа не привязаны")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { DarkHeroBackground() }
        .clipShape(RoundedRectangle(cornerRadius: DS.heroRadius))
        .shadow(color: Color.charcoal.opacity(0.45), radius: 36, x: 0, y: 18)
        .padding(.horizontal, DS.hPad)
        .padding(.bottom, 14)
    }
}

// MARK: - Member Row
private struct MemberRowView: View {
    let member: TeamMember

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                if member.isBound {
                    LinearGradient(
                        colors: [Color(light: "E2E6EB", dark: "2A3240"),
                                 Color(light: "C5CCD5", dark: "374352")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .clipShape(Circle())
                    Text(member.initials)
                        .font(.mono(13, weight: .bold))
                        .foregroundStyle(Color.ink)
                } else {
                    Circle()
                        .strokeBorder(
                            Color.kolcoOrange.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                        )
                    Image(systemName: "person")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.kolcoOrange.opacity(0.7))
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(member.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.ink)

                if member.isBound, let cid = member.chipID {
                    HStack(spacing: 5) {
                        Circle().fill(Color.good)
                            .frame(width: 5, height: 5)
                            .shadow(color: Color.good.opacity(0.3), radius: 3)
                        Text("Чип \(cid)")
                            .font(.mono(12, weight: .semibold))
                            .foregroundStyle(Color.sub)
                    }
                } else {
                    HStack(spacing: 5) {
                        Circle().fill(Color.kolcoOrange)
                            .frame(width: 5, height: 5)
                        Text("Чип не привязан")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.kolcoOrange)
                    }
                }
            }

            Spacer()

            if member.isBound {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sub.opacity(0.45))
            } else {
                Button {} label: {
                    HStack(spacing: 6) {
                        Image(systemName: "wave.3.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.kolcoOrange)
                        Text("Привязать")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.ink)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.hairline, lineWidth: 0.5)
                    )
                    .shadow(color: Color.cardShadow, radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Misc Row
private struct MiscRowView: View {
    let systemImage: String
    let iconBg: Color
    let label: String
    let sub: String

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7)
                    .fill(iconBg)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.ink)
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.sub)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.sub.opacity(0.45))
        }
        .padding(.vertical, 3)
    }
}

#Preview("Light") {
    NavigationStack { TeamView() }
}

#Preview("Dark") {
    NavigationStack { TeamView() }
        .preferredColorScheme(.dark)
}
