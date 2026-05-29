import SwiftUI

// MARK: - CPBadge
// Checkpoint number badge: white card with red stripes top/bottom
struct CPBadge: View {
    let number: String
    var size: CGFloat = 62

    var body: some View {
        ZStack {
            Canvas { ctx, s in
                let stripeH = max(2.0, s.height * 0.12)
                ctx.fill(Path(CGRect(origin: .zero, size: s)), with: .color(.white))
                ctx.fill(Path(CGRect(x: 0, y: 0,               width: s.width, height: stripeH)), with: .color(Color.brandRed.opacity(0.78)))
                ctx.fill(Path(CGRect(x: 0, y: s.height - stripeH, width: s.width, height: stripeH)), with: .color(Color.brandRed.opacity(0.78)))
            }
            // CPBadge is a fixed-light card (white fill in both themes), so its
            // number/border use fixed colors — adaptive ink/hairline would turn
            // near-white in dark mode and vanish against the white badge.
            Text(number)
                .font(.mono(size * 0.38, weight: .bold))
                .foregroundStyle(number == "?" ? Color(hex: "56606A").opacity(0.4) : Color(hex: "161A1F"))
        }
        .frame(width: size, height: size * 0.84)
        .clipShape(RoundedRectangle(cornerRadius: max(3, size * 0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: max(3, size * 0.08))
                .stroke(Color.black.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - MetricView
struct MetricView: View {
    let label: String
    let value: String
    var unit: String? = nil
    var isWarning: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.sub)
                .textCase(.uppercase)
                .tracking(0.5)
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(value)
                    .font(isWarning ? .mono(22, weight: .bold) : .system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(isWarning ? Color.brandRed : Color.ink)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.sub)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
    }
}

// MARK: - VDivider
struct VDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(width: 0.5)
            .padding(.vertical, 10)
    }
}

// MARK: - SectionHeader
struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.sub)
            .textCase(.uppercase)
            .tracking(-0.08)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.hPad + 4)
            .padding(.bottom, 8)
    }
}

// MARK: - GreenCheckCircle
struct GreenCheckCircle: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle().fill(Color.good)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - DarkHeroBackground
// Shared between TeamHero and TimerHero
struct DarkHeroBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.charcoal, Color.charcoalHi],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.brandRed.opacity(0.5), .clear],
                center: .init(x: 1.15, y: -0.2),
                startRadius: 0, endRadius: 160
            )
            Canvas { ctx, s in
                let step: CGFloat = 9
                var x: CGFloat = -s.height
                while x < s.width + s.height {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + s.height, y: s.height))
                    ctx.stroke(p, with: .color(Color.white.opacity(0.025)), lineWidth: 1)
                    x += step
                }
            }
        }
    }
}
