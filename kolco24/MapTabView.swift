//
//  MapTabView.swift
//  kolco24
//
//  Вкладка «Карта» (корень `kolco24/`, дизайн-токены). Без выбранной команды — `TeamEmptyState`
//  (онбординг «выбери команду», как на «Легенде»/«Отметках»); с командой — `TrackMapView` во весь экран
//  (живой трек + взятые КП) поверх оффлайн-подложки MBTiles, а поверх карты — оверлеи по машине
//  состояний `MapModel.MapAvailability`:
//   - `noMapForRace`   — ненавязчивая строка «Оффлайн-карта для этой гонки недоступна» (карта работает
//                        онлайн на Apple-подложке, трек/КП рендерятся);
//   - `notDownloaded`/`failed` — нижняя CTA-карточка «Скачать карту гонки» (стиль CTA `MarksView`);
//   - `downloading(p)` — карточка с прогрессом, процентом и крестиком-отменой;
//   - `ready`          — чистая карта (оверлеев нет).
//  Сверху слева — чип «Все точки» (фильтр выбросов трека, общая настройка с «Настройками»): виден, когда
//  фильтр что-то скрыл («Все точки · +N») или режим уже включён (чтобы его можно было выключить).
//  Ошибка скачивания уходит тостом (`MapModel.onToast` → `AppModel.toastMessage`), CTA возвращается в
//  `notDownloaded` при следующем `refreshAvailability`.
//
//  Оффлайн-дескриптор (`MapOverlayDescriptor`) строится ЗДЕСЬ из `ready(path)`: `MBTilesReader(path:)`
//  того же модуля (GRDB — транзитивная зависимость, `import GRDB` в корневую вьюху не тянется —
//  grep-инвариант) даёт `tileData`/`metadata` для `TrackMapView`. Пересобирается только при смене
//  пути (`.id(readyPath)` заодно пересоздаёт `MKMapView`, чтобы оффлайн-оверлей подхватился при
//  докачивании во время открытой вкладки).
//
//  `refreshAvailability()` дёргается в `.task`/`.onAppear`: вкладки `TabView` живут постоянно, а
//  удаление карты в настройках (файл-как-флаг) иначе не долетело бы до уже созданной модели.
//

import SwiftUI

struct MapTabView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: MapModel?
    /// Мемо-кэш оффлайн-дескриптора (держит `MBTilesReader` живым, не переоткрывая `DatabaseQueue` на
    /// каждый прогон `body`). Дескриптор выводится СИНХРОННО в `body` из `readyPath` — не через
    /// `@State`+`onChange`, иначе `makeUIView` при смене `.id` видел бы устаревший `nil` (Finding H1).
    @State private var overlayCache = OverlayCache()
    /// Точка входа во флоу выбора команды (пробрасывается хостом).
    var onChooseTeam: () -> Void = {}

    /// Путь готовой подложки (`ready(path)`) — ключ пересборки дескриптора и пересоздания `MKMapView`.
    private var readyPath: String? {
        if case let .ready(path) = model?.availability { return path }
        return nil
    }

    /// Активный оффлайн-дескриптор (`nil` → Apple-подложка). Выводится синхронно в `body`, поэтому
    /// `makeUIView`/`updateUIView` всегда видят текущее значение — дескриптор для нового `readyPath`
    /// готов ДО пересоздания `MKMapView` по `.id`.
    private var overlay: MapOverlayDescriptor? {
        overlayCache.descriptor(for: readyPath)
    }

    var body: some View {
        content
            .background(Color.paper)
            .navigationTitle("Карта")
            .navigationBarTitleDisplayMode(.inline)
            // Keep tab icons legible over both Apple maps and arbitrary offline tiles.
            .toolbarBackground(Color.card, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .task(id: [appModel.selectedRaceId, appModel.selectedTeamId]) {
                if model == nil { model = appModel.makeMapModel() }
                model?.rebind(teamId: appModel.selectedTeamId, raceId: appModel.selectedRaceId)
            }
            .onAppear { model?.refreshAvailability() }
    }

    @ViewBuilder
    private var content: some View {
        switch appModel.selectedTeamState {
        case .loading:
            // Подавляем мигание empty-состояния до первой эмиссии observation.
            Color.paper
        case .present:
            if let model {
                mapContent(model: model)
            } else {
                Color.paper
            }
        case .missing:
            TeamEmptyState(missing: true, onChooseTeam: onChooseTeam)
        case .none:
            TeamEmptyState(onChooseTeam: onChooseTeam)
        }
    }

    // MARK: - Карта + оверлеи состояний

    private func mapContent(model: MapModel) -> some View {
        TrackMapView(
            trackLines: model.trackLines,
            speedRuns: model.speedRuns,
            stopPins: model.stopPins,
            pins: model.pins,
            overlay: overlay
        )
        // Смена пути подложки пересоздаёт `MKMapView` — иначе оффлайн-оверлей, добавляемый в `makeUIView`
        // однократно, не подхватился бы при докачивании карты во время открытой вкладки.
        .id(readyPath ?? "")
        .overlay { availabilityOverlay(model.availability, model: model) }
        .overlay(alignment: .top) { topOverlay(model: model) }
    }

    private func topOverlay(model: MapModel) -> some View {
        VStack(spacing: 6) {
            if case .noMapForRace = model.availability {
                unavailableLine
            }
            if model.showAllPoints || model.hiddenPointCount > 0 {
                showAllPointsChip(
                    selected: model.showAllPoints,
                    hiddenCount: model.hiddenPointCount,
                    onTap: model.toggleShowAllPoints
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let runs = model.speedRuns, !runs.isEmpty {
                speedLegend
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, DS.hPad)
        .padding(.top, 8)
    }

    /// Легенда раскраски по скорости: образец цвета + диапазон, км/ч.
    private var speedLegend: some View {
        HStack(spacing: 8) {
            ForEach(SpeedBand.allCases, id: \.self) { band in
                HStack(spacing: 3) {
                    Capsule()
                        .fill(SpeedStroke.band(band).color)
                        .frame(width: 12, height: 4)
                    Text(speedBandLegendLabel(band))
                        .font(.mono(11, weight: .semibold))
                }
            }
            Text("км/ч")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.sub)
        }
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Цвет трека по скорости")
    }

    /// Чип «Все точки»: выключен — полупрозрачный материал + число скрытых точек; включён — оранжевый
    /// с галочкой. Камера при переключении не двигается.
    private func showAllPointsChip(selected: Bool, hiddenCount: Int, onTap: @escaping () -> Void) -> some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                }
                Text("Все точки")
                    .font(.system(size: 13, weight: .semibold))
                if hiddenCount > 0 {
                    Text("· +\(hiddenCount)")
                        .font(.mono(12, weight: .semibold))
                }
            }
            .foregroundStyle(selected ? Color.white : Color.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                if selected {
                    Capsule().fill(Color.kolcoOrange)
                } else {
                    Capsule().fill(.ultraThinMaterial)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func availabilityOverlay(_ availability: MapAvailability, model: MapModel) -> some View {
        switch availability {
        case .noMapForRace, .ready:
            EmptyView()
        case .notDownloaded, .failed:
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                downloadCTA { model.downloadMap() }
            }
        case .downloading(let progress):
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                downloadingCard(progress: progress) { model.cancelDownload() }
            }
        }
    }

    /// Ненавязчивая плашка «карты нет» (гонка без `map_url`). Карта при этом работает онлайн.
    private var unavailableLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11))
            Text("Оффлайн-карта для этой гонки недоступна")
                .font(.system(size: 12))
        }
        .foregroundStyle(Color.sub)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// CTA скачивания подложки (стиль CTA `MarksView`): оранжевая кнопка + пояснение, нижняя карточка.
    private func downloadCTA(onDownload: @escaping () -> Void) -> some View {
        VStack(spacing: 8) {
            Button(action: onDownload) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Скачать карту гонки")
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

            Text("Скачается один раз по Wi-Fi — дальше карта работает офлайн.")
                .font(.system(size: 12))
                .foregroundStyle(Color.sub)
                .multilineTextAlignment(.center)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .padding(.horizontal, DS.hPad)
        .padding(.bottom, DS.hPad)
    }

    /// Карточка активного скачивания: прогресс-бар, процент и крестик-отмена.
    private func downloadingCard(progress: Double, onCancel: @escaping () -> Void) -> some View {
        let clamped = min(max(progress, 0), 1)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Скачивание карты…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                ProgressView(value: clamped)
                    .tint(Color.kolcoOrange)
                Text("\(Int(clamped * 100))%")
                    .font(.mono(12, weight: .semibold))
                    .foregroundStyle(Color.sub)
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.sub)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: DS.cardRadius))
        .shadow(color: Color.cardShadow, radius: 12, y: 4)
        .padding(.horizontal, DS.hPad)
        .padding(.bottom, DS.hPad)
    }

}

// MARK: - Оффлайн-дескриптор

/// Мемо-кэш оффлайн-дескриптора: строит его лениво при смене готового пути и держит `MBTilesReader`
/// живым, пока путь не изменился (иначе `DatabaseQueue` переоткрывался бы на каждый прогон `body`).
/// `MBTilesReader(path:)` — тип того же модуля (GRDB не импортируется в корневую вьюху); замыкание
/// `tileData` захватывает reader. Ошибка открытия файла → `nil` (карта деградирует в Apple-подложку).
@MainActor
private final class OverlayCache {
    private var path: String?
    private var reader: MBTilesReader?
    private var cached: MapOverlayDescriptor?

    /// Дескриптор для [path] (`nil` → нет подложки). Для того же пути возвращает мемоизированное
    /// значение без переоткрытия файла.
    func descriptor(for path: String?) -> MapOverlayDescriptor? {
        if path == self.path { return cached }
        self.path = path
        // Читаемый sqlite без таблицы `tiles`/без тайлов — НЕ подложка: иначе
        // `canReplaceMapContent` дал бы пустую подавленную карту без ретрая. При невалидности
        // возвращаем `nil` → карта деградирует в онлайн Apple-подложку (Finding C2).
        guard let path,
              let reader = try? MBTilesReader(path: path),
              reader.looksLikeValidMBTiles() else {
            self.reader = nil
            self.cached = nil
            return nil
        }
        self.reader = reader
        let descriptor = MapOverlayDescriptor(
            metadata: reader.metadata(),
            tileData: { z, x, y in reader.tileData(z: z, x: x, y: y) }
        )
        self.cached = descriptor
        return descriptor
    }
}
