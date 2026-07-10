//
//  TeamView.swift
//  kolco24
//
//  Вкладка «Команда» на реальных данных. Порт ПОВЕДЕНИЯ `ui/team/TeamScreen.kt`: без выбранной
//  команды — `TeamEmptyState` (онбординг или «команда исчезла» при `missing`), иначе герой-карточка
//  и ростер выбранной команды. Сама команда приходит из `AppModel.selectedTeamState`; привязки
//  чипов — из `TeamModel` (наблюдение `member_chip_bindings` по `numberInTeam`).
//
//  «Привязать» открывает `BindChipSheet` (одноразовая NFC-сессия через `TeamModel.beginBind`).
//  Отвязка: long-press на привязанном участнике → confirm-диалог → `TeamModel.unbind` (`deleteSlot`).
//  «Сменить команду» открывает флоу выбора (`onChooseTeam`).
//

import SwiftUI

struct TeamView: View {
    @Environment(AppModel.self) private var appModel
    /// Модель привязок создаётся один раз в `.task` (env инкапсулирован в `AppModel`).
    @State private var model: TeamModel?
    /// Модель экрана «Загрузка данных» — живёт вместе с вкладкой, чтобы подзаголовок ряда (`pendingLabel`)
    /// был реактивным; переиспользуется при открытии шита.
    @State private var uploadModel: UploadModel?
    /// Точка входа во флоу выбора (пробрасывается хостом; в превью — no-op).
    var onChooseTeam: () -> Void = {}

    /// Слот, для которого открыт confirm-диалог отвязки.
    @State private var unbindTarget: TeamMemberItem?
    /// Открыт ли шит «Загрузка данных».
    @State private var showUpload = false

    var body: some View {
        content
            .background(Color.paper)
            .navigationTitle("Команда")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: [appModel.selectedRaceId, appModel.selectedTeamId]) {
                if model == nil { model = appModel.makeTeamModel() }
                model?.rebind(teamId: appModel.selectedTeamId, raceId: appModel.selectedRaceId)
                if uploadModel == nil { uploadModel = appModel.makeUploadModel() }
                uploadModel?.rebind(teamId: appModel.selectedTeamId, raceId: appModel.selectedRaceId)
            }
            .sheet(isPresented: $showUpload) {
                if let uploadModel {
                    UploadView(model: uploadModel)
                }
            }
            .sheet(isPresented: Binding(
                get: { model?.bindMember != nil },
                set: { if !$0 { model?.cancelBind() } }
            )) {
                if let model, let member = model.bindMember {
                    BindChipSheet(model: model, member: member)
                }
            }
            .confirmationDialog(
                "Отвязать чип?",
                isPresented: Binding(
                    get: { unbindTarget != nil },
                    set: { if !$0 { unbindTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: unbindTarget
            ) { member in
                Button("Отвязать", role: .destructive) {
                    if let teamId = appModel.selectedTeamId {
                        Task { await model?.unbind(teamId: teamId, numberInTeam: member.numberInTeam) }
                    }
                    unbindTarget = nil
                }
                Button("Отмена", role: .cancel) { unbindTarget = nil }
            } message: { member in
                Text("Чип участника «\(member.name)» станет непривязанным.")
            }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.selectedTeamState {
        case .loading:
            // Подавляем мигание empty-состояния до первой эмиссии observation.
            Color.paper
        case .none:
            TeamEmptyState(onChooseTeam: onChooseTeam)
        case .missing:
            TeamEmptyState(missing: true, onChooseTeam: onChooseTeam)
        case .present(let team):
            teamContent(team)
        }
    }

    private func teamContent(_ team: Team) -> some View {
        let members = team.members.sorted { $0.numberInTeam < $1.numberInTeam }
        let bound = model?.boundCount(members: members) ?? 0
        let category = model?.category(for: team)

        return ScrollView {
            VStack(spacing: 0) {
                TeamHeroView(
                    team: team,
                    category: category,
                    bound: bound,
                    total: team.ucount
                )
                .padding(.top, 8)

                SectionHeader("Состав · \(members.count)")
                    .padding(.top, 20)

                VStack(spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.element.numberInTeam) { idx, m in
                        MemberRowView(
                            member: m,
                            binding: model?.binding(for: m.numberInTeam),
                            onBind: { model?.beginBind(member: m) },
                            onUnbind: { unbindTarget = m }
                        )
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

                if let model {
                    TrackCardView(
                        recorder: appModel.trackRecorder,
                        model: model,
                        team: team,
                        raceId: appModel.selectedRaceId,
                        teamId: appModel.selectedTeamId
                    )
                    .padding(.top, 20)
                }

                SectionHeader("Прочее")
                    .padding(.top, 20)

                VStack(spacing: 0) {
                    Button { onChooseTeam() } label: {
                        MiscRowView(systemImage: "arrow.left.arrow.right", iconBg: Color.charcoal, label: "Сменить команду", sub: "Выбрать другое соревнование или команду")
                            .padding(.horizontal, DS.hPad)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    Rectangle()
                        .fill(Color.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, DS.hPad + 30 + 12)
                    Button { showUpload = true } label: {
                        MiscRowView(systemImage: "arrow.up.circle.fill", iconBg: Color.good, label: "Загрузка данных", sub: uploadModel?.pendingLabel ?? "Пока нечего загружать")
                            .padding(.horizontal, DS.hPad)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
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
        .refreshable { await appModel.refreshAll() }
    }
}

// MARK: - Team Hero

private struct TeamHeroView: View {
    let team: Team
    let category: Category?
    let bound: Int
    let total: Int

    private var allBound: Bool { total > 0 && bound >= total }

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
                if let number = team.startNumber, !number.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(number)
                        .font(.mono(38, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text(displayTeamName(team))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }
            .padding(.top, 6)

            Text(peopleLine(category: category, ucount: total))
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)

            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(allBound ? Color.good : Color.amber)
                        .frame(width: 6, height: 6)
                        .shadow(color: (allBound ? Color.good : Color.amber).opacity(0.3), radius: 4)
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

                if !allBound && total > 0 {
                    Text(chipNotBoundText(total - bound))
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
        .shadow(color: Color.heroShadow, radius: 36, x: 0, y: 18)
        .padding(.horizontal, DS.hPad)
        .padding(.bottom, 14)
    }
}

// MARK: - Member Row

private struct MemberRowView: View {
    let member: TeamMemberItem
    let binding: MemberChipBinding?
    let onBind: () -> Void
    let onUnbind: () -> Void

    private var isBound: Bool { binding != nil }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar
            ZStack {
                if isBound {
                    LinearGradient(
                        colors: [Color(light: "E2E6EB", dark: "2A3240"),
                                 Color(light: "C5CCD5", dark: "374352")],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    .clipShape(Circle())
                    Text(initials(member.name))
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

                if let binding {
                    HStack(spacing: 5) {
                        Circle().fill(Color.good)
                            .frame(width: 5, height: 5)
                            .shadow(color: Color.good.opacity(0.3), radius: 3)
                        Text("№\(binding.participantNumber)")
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

            if isBound {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sub.opacity(0.45))
            } else {
                Button(action: onBind) {
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
                    .background(Color.cardElevated)
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
        .contentShape(Rectangle())
        // Long-press на привязанном участнике → запрос отвязки (тап ничего не делает — защита от
        // случайного удаления, порт `combinedClickable` из `TeamScreen.kt`).
        .onLongPressGesture {
            if isBound { onUnbind() }
        }
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
        .contentShape(Rectangle())
    }
}

// MARK: - Track Card (этап 8)

/// Карточка «GPS-трек» на вкладке «Команда». Порт строк/состояний `ui/track/TrackCard.kt` 1:1:
/// - `recording` → пульсирующая точка + «Идёт запись» + `pointsLabel` (сырой live-счётчик рекордера) +
///   «Остановить» (brandRed);
/// - idle + 0 точек → онбординг-текст + CTA «Начать запись»;
/// - idle + >0 → метрики Точки/Сегменты/Время + «Начать запись» + вторичная «Поделиться GPX».
///
/// Держит и `recorder`, и `model` (оба `@Observable`) — SwiftUI трекает `recorder.state`/`recorder.pointCount`
/// напрямую, поэтому карточка перерисовывается на старт/стоп без ручного моста. GPX-файл пере-генерится
/// офф-мейн при смене `trackUsable` в temp-каталог и раздаётся системным `ShareLink`.
private struct TrackCardView: View {
    let recorder: TrackRecorder
    let model: TeamModel
    let team: Team
    let raceId: Int?
    let teamId: Int?

    /// Готовый временный GPX-файл для `ShareLink` (пере-генерится офф-мейн при смене трека).
    @State private var gpxURL: URL?

    private var recording: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    /// Метка для имени файла: стартовый номер команды, иначе id (порт `label`).
    private var teamLabel: String {
        if let number = team.startNumber?.trimmingCharacters(in: .whitespaces), !number.isEmpty {
            return number
        }
        return teamId.map(String.init) ?? "track"
    }

    /// Имя трека в GPX `<name>` (порт `teamForTab?.teamname ?: "Команда $label"`).
    private var trackName: String {
        let name = team.teamname.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Команда \(teamLabel)" : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("GPS-трек")

            VStack(alignment: .leading, spacing: 0) {
                if recording {
                    recordingContent
                } else {
                    idleContent
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card)
            .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
            .padding(.horizontal, DS.hPad)
        }
        // Пере-генерация GPX-файла офф-мейн при смене набора точек (recording не показывает шаринг,
        // но пустой набор гасит `gpxURL`, а финальные точки после стопа перегенерят файл).
        .task(id: model.trackUsable) { await regenerateGpx() }
    }

    // MARK: Recording

    @ViewBuilder
    private var recordingContent: some View {
        HStack(spacing: 10) {
            PulsingDot()
            VStack(alignment: .leading, spacing: 2) {
                Text("Идёт запись")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.ink)
                Text(pointsLabel(recorder.pointCount))
                    .font(.mono(11))
                    .foregroundStyle(Color.sub)
            }
            Spacer()
        }
        .padding(.bottom, 14)

        Button { recorder.stop() } label: {
            HStack(spacing: 8) {
                Image(systemName: "stop.fill").font(.system(size: 15))
                Text("Остановить").font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.brandRed.opacity(0.14))
            .foregroundStyle(Color.brandRed)
            .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
        }
        .buttonStyle(.plain)
    }

    // MARK: Idle

    @ViewBuilder
    private var idleContent: some View {
        if model.trackPointCount > 0 {
            TrackMetricsRow(
                pointCount: model.trackPointCount,
                segmentCount: model.trackSegmentCount,
                timeRange: model.trackTimeRange
            )
            .padding(.bottom, 14)
        } else {
            Text("Запишите GPS-трек команды во время гонки.")
                .font(.system(size: 13))
                .foregroundStyle(Color.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 14)
        }

        Button {
            if let raceId, let teamId { recorder.start(raceId: raceId, teamId: teamId) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "play.fill").font(.system(size: 15))
                Text("Начать запись").font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.kolcoOrange)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
            .opacity(teamId == nil ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(teamId == nil)

        if model.trackPointCount > 0, let gpxURL {
            ShareLink(item: gpxURL) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 15))
                    Text("Поделиться GPX").font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .foregroundStyle(Color.ink)
                .clipShape(RoundedRectangle(cornerRadius: DS.ctaRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.ctaRadius)
                        .stroke(Color.hairline, lineWidth: 0.75)
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }

        if model.degradedAccuracy {
            Text("Только примерная геолокация (нет GPS).")
                .font(.system(size: 11))
                .foregroundStyle(Color.sub)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
        }
    }

    // MARK: GPX

    private func regenerateGpx() async {
        let points = model.trackUsable
        guard !points.isEmpty else { gpxURL = nil; return }
        let name = trackName
        let fileName = gpxFileName(teamLabel: teamLabel, dateIso: todayIso())
        // Сериализацию GPX (CPU) гоним офф-мейн, а ЗАПИСЬ на детерминированный путь — только после проверки
        // отмены. `.task(id:)` отменяет старое поколение при смене `trackUsable`, и отменённое поколение
        // выходит ДО записи: без этого отставшая старая генерация перезаписала бы файл устаревшим треком,
        // и `ShareLink` отдавал бы неактуальное содержимое. Запись сериализована на MainActor (структурный
        // контекст `.task`) — два поколения не перекрывают запись.
        let gpx = await Task.detached(priority: .utility) { buildGpx(points: points, trackName: name) }.value
        if Task.isCancelled { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tracks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent(fileName)
        do {
            try Data(gpx.utf8).write(to: fileURL)
            gpxURL = fileURL
        } catch {
            gpxURL = nil
        }
    }
}

/// Пульсирующая точка «идёт запись» (порт `PulsingDot`): infinite fade 1 → 0.25.
private struct PulsingDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color.kolcoOrange)
            .frame(width: 12, height: 12)
            .opacity(on ? 0.25 : 1)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Ряд метрик idle-трека: Точки / Сегменты / Время (порт `TrackMetrics`). Слова склоняются по счётчику
/// (`pointsWord`/`segmentsWord`) и капитализируются, значения — `Font.mono`.
private struct TrackMetricsRow: View {
    let pointCount: Int
    let segmentCount: Int
    let timeRange: String?

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            metric(value: "\(pointCount)", label: pointsWord(pointCount).capitalizedFirst)
            metric(value: "\(segmentCount)", label: segmentsWord(segmentCount).capitalizedFirst)
            metric(value: timeRange ?? "—", label: "Время")
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.mono(16, weight: .bold))
                .foregroundStyle(Color.ink)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.sub)
                .textCase(.uppercase)
                .tracking(0.4)
        }
    }
}

private extension String {
    /// Капитализирует только первый символ (порт `replaceFirstChar { it.uppercase() }`).
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}

/// Русское склонение «N чип(а/ов) не привязан(ы)» (порт `chipNotBoundText` из `TeamScreen.kt`).
private func chipNotBoundText(_ n: Int) -> String {
    "\(n) \(pluralRu(count: n, one: "чип не привязан", few: "чипа не привязаны", many: "чипов не привязаны"))"
}
