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
    /// Активный оффлайн-дескриптор (`nil` → Apple-подложка). Пересобирается при смене `readyPath`.
    @State private var overlay: MapOverlayDescriptor?
    /// Точка входа во флоу выбора команды (пробрасывается хостом).
    var onChooseTeam: () -> Void = {}

    /// Путь готовой подложки (`ready(path)`) — ключ пересборки дескриптора и пересоздания `MKMapView`.
    private var readyPath: String? {
        if case let .ready(path) = model?.availability { return path }
        return nil
    }

    var body: some View {
        content
            .background(Color.paper)
            .navigationTitle("Карта")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: [appModel.selectedRaceId, appModel.selectedTeamId]) {
                if model == nil { model = appModel.makeMapModel() }
                model?.rebind(teamId: appModel.selectedTeamId, raceId: appModel.selectedRaceId)
            }
            .onAppear { model?.refreshAvailability() }
            .onChange(of: readyPath, initial: true) { _, path in
                rebuildOverlay(path)
            }
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
            trackPath: model.trackPath,
            pins: model.pins,
            overlay: overlay
        )
        // Смена пути подложки пересоздаёт `MKMapView` — иначе оффлайн-оверлей, добавляемый в `makeUIView`
        // однократно, не подхватился бы при докачивании карты во время открытой вкладки.
        .id(readyPath ?? "")
        .ignoresSafeArea(edges: .bottom)
        .overlay { availabilityOverlay(model.availability, model: model) }
    }

    @ViewBuilder
    private func availabilityOverlay(_ availability: MapAvailability, model: MapModel) -> some View {
        switch availability {
        case .noMapForRace:
            VStack(spacing: 0) {
                unavailableLine
                Spacer(minLength: 0)
            }
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
        case .ready:
            EmptyView()
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
        .padding(.top, 8)
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Скачивание карты…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.ink)
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(Color.kolcoOrange)
                Text("\(Int((min(max(progress, 0), 1)) * 100))%")
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

    // MARK: - Оффлайн-дескриптор

    /// Пересобирает оффлайн-дескриптор при смене готового пути. `MBTilesReader(path:)` — тип того же
    /// модуля (GRDB не импортируется в корневую вьюху); замыкание `tileData` держит reader живым, пока
    /// оверлей используется. Ошибка открытия файла → `nil` (карта деградирует в Apple-подложку).
    private func rebuildOverlay(_ path: String?) {
        guard let path else {
            overlay = nil
            return
        }
        guard let reader = try? MBTilesReader(path: path) else {
            overlay = nil
            return
        }
        overlay = MapOverlayDescriptor(
            metadata: reader.metadata(),
            tileData: { z, x, y in reader.tileData(z: z, x: x, y: y) }
        )
    }
}
