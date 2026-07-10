//
//  UploadModelTests.swift
//  kolco24Tests
//
//  Тесты `App/UploadModel` (этап 6) — зеркала нет (в Android модели экрана нет, всё в composable),
//  пишутся с нуля поверх РЕАЛЬНОГО `MarkStore` над `AppDatabase.makeInMemory()` + `FakeTransport`.
//
//  Проверяем: счётчики из реальной БД (марки с разными флагами `uploadedLocal/Cloud`); эмиссия исходов
//  дренажа из актора доходит до модели через `outcomeUpdates`; `refresh()` флипает флаги через транспорт
//  и наполняет `outcomes`; градации `pendingLabel`; видимость «Финиш»-строки; rebind при смене команды
//  чистит состояние.
//
//  Ловушка `FakeTransport`: FIFO-очередь ответов по порядку ВЫЗОВОВ (не роутинг по URL), а `inMemory`
//  даёт cloud и local ОДИН транспорт — энкьюим в порядке `flushScope`: сначала Local-батч(и), потом Cloud.
//

import Foundation
import Testing
@testable import kolco24

@MainActor
struct UploadModelTests {

    // MARK: - Фикстуры

    private func mark(
        id: String, raceId: Int = 7, teamId: Int = 5,
        uploadedLocal: Bool = false, uploadedCloud: Bool = false
    ) -> Mark {
        Mark(
            id: id, raceId: raceId, teamId: teamId, checkpointId: 264, checkpointNumber: 12,
            cost: 5, method: "nfc", cpUid: "04A2B3C4D5E680", cpCode: "9f1a2b3c4d5e6f70",
            present: [1], presentDetails: nil, expectedCount: 1, complete: true,
            takenAt: 1000, updatedAt: 1000, uploadedLocal: uploadedLocal, uploadedCloud: uploadedCloud,
            trustedTakenAt: nil, elapsedRealtimeAt: nil, bootCount: nil, locLat: nil, locLon: nil
        )
    }

    /// Фото-марка: `method="photo"`, `photoPath` = закодированные валидные относительные пути кадров,
    /// раздельные флаги metadata (`uploadedX`) и кадров (`photosUploadedX`).
    private func photoMark(
        id: String, raceId: Int = 7, teamId: Int = 5,
        frames: Int,
        uploadedLocal: Bool = false, uploadedCloud: Bool = false,
        photosUploadedLocal: Bool = false, photosUploadedCloud: Bool = false
    ) -> Mark {
        let paths = (0..<frames).map { "marks/\(id)/frame\($0).jpg" }
        return Mark(
            id: id, raceId: raceId, teamId: teamId, checkpointId: 264, checkpointNumber: 12,
            cost: 5, method: "photo", cpUid: "", cpCode: "",
            present: [], presentDetails: nil, expectedCount: 0, complete: true,
            photoPath: PhotoPaths.encode(paths),
            takenAt: 1000, updatedAt: 1000,
            uploadedLocal: uploadedLocal, uploadedCloud: uploadedCloud,
            photosUploadedLocal: photosUploadedLocal, photosUploadedCloud: photosUploadedCloud,
            trustedTakenAt: nil, elapsedRealtimeAt: nil, bootCount: nil, locLat: nil, locLon: nil
        )
    }

    /// Точка GPS-трека с раздельными флагами доставки `uploadedLocal/Cloud`.
    private func trackPoint(
        id: String, raceId: Int = 7, teamId: Int = 5,
        segmentId: String = "seg-1",
        uploadedLocal: Bool = false, uploadedCloud: Bool = false
    ) -> TrackPoint {
        TrackPoint(
            id: id, raceId: raceId, teamId: teamId,
            lat: 55.75, lon: 37.62, accuracy: 5,
            gpsTimeMs: 1000, elapsedRealtimeAt: 1000, wallMs: 1000,
            segmentId: segmentId,
            uploadedLocal: uploadedLocal, uploadedCloud: uploadedCloud
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) {
            if clock.now > deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Тело `{"accepted":[<ids>]}` — эхо принятых id (эквивалент серверного ответа).
    private func acceptedBody(_ ids: [String]) -> String {
        "{\"accepted\":[\(ids.map { "\"\($0)\"" }.joined(separator: ","))]}"
    }

    // MARK: - Счётчики из реальной БД

    @Test func counts_reflectMarkFlags() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // 3 марки: одна доехала до cloud, одна до local, одна ни туда ни сюда.
        try await env.markStore.upsert(mark(id: "a", uploadedCloud: true))
        try await env.markStore.upsert(mark(id: "b", uploadedLocal: true))
        try await env.markStore.upsert(mark(id: "c"))

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.counts?.total == 3 }
        #expect(model.counts?.total == 3)
        #expect(model.counts?.cloud == 1)
        #expect(model.counts?.local == 1)
    }

    // MARK: - Градации pendingLabel

    @Test func pendingLabel_nothingToUpload() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.counts != nil }
        #expect(model.pendingLabel == "Пока нечего загружать")
    }

    @Test func pendingLabel_somePendingThenAllSent() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.markStore.upsert(mark(id: "a", uploadedCloud: true))
        try await env.markStore.upsert(mark(id: "b"))
        try await env.markStore.upsert(mark(id: "c"))

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        // total 3, cloud 1 → 2 не отправлено.
        await waitUntil { model.counts?.total == 3 }
        #expect(model.pendingLabel == "2 не отправлено")

        // Дотягиваем все до cloud → «Всё отправлено».
        try await env.markStore.upsert(mark(id: "b", uploadedCloud: true))
        try await env.markStore.upsert(mark(id: "c", uploadedCloud: true))
        await waitUntil { model.counts?.cloud == 3 }
        #expect(model.pendingLabel == "Всё отправлено")
    }

    // MARK: - refresh() флипает флаги + наполняет outcomes

    @Test func refresh_flipsFlagsAndPopulatesOkOutcomes() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.markStore.upsert(mark(id: "u1"))
        // Порядок flushScope: Local-батч, затем Cloud-батч (по одному POST на цель; второй fetch пустой).
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["u1"])) // local
        transport.enqueue(statusCode: 200, bodyString: acceptedBody(["u1"])) // cloud

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)
        await waitUntil { model.counts?.total == 1 }

        await model.refresh()

        // Флаги доехали до БД.
        let stored = try await env.markStore.getById("u1")
        #expect(stored?.uploadedLocal == true)
        #expect(stored?.uploadedCloud == true)

        // Исходы из актора дошли до модели через outcomeUpdates.
        await waitUntil { model.outcomes[.cloud]?.kind == .ok && model.outcomes[.local]?.kind == .ok }
        #expect(model.outcomes[.cloud]?.kind == .ok)
        #expect(model.outcomes[.local]?.kind == .ok)

        // Счётчики догнались → обе цели done, secondLine отсутствует.
        await waitUntil { model.counts?.cloud == 1 }
        #expect(model.cloudLine.done)
        #expect(model.cloudLine.secondLine == nil)
        #expect(model.finishLine?.done == true)
    }

    // MARK: - Офлайн-исход доходит до модели со второй строкой

    @Test func refresh_offlineOutcomeReachesModelWithSecondLine() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.markStore.upsert(mark(id: "u1"))
        transport.enqueueError(URLError(.notConnectedToInternet)) // local POST
        transport.enqueueError(URLError(.notConnectedToInternet)) // cloud POST

        // nowMs = 0 → относительное время «только что» (дельта зажимается в 0), детерминированно.
        let model = UploadModel(env: env, nowMs: { 0 })
        model.rebind(teamId: 5, raceId: 7)
        await waitUntil { model.counts?.total == 1 }

        await model.refresh()

        await waitUntil { model.outcomes[.cloud]?.kind == .offline }
        #expect(model.outcomes[.cloud]?.kind == .offline)
        // Флаги остались 0 (self-heal), строка не done → вторая строка с офлайн-лейблом.
        #expect(model.cloudLine.done == false)
        #expect(model.cloudLine.isError)
        #expect(model.cloudLine.secondLine == "только что · нет интернета")
        // «Финиш» стал видимым (есть исход) с собственным офлайн-лейблом.
        #expect(model.finishLine?.secondLine == "только что · сервер недоступен")
    }

    // MARK: - Видимость «Финиш»-строки

    @Test func finishLine_hiddenUntilOutcomeOrUpload() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.markStore.upsert(mark(id: "a")) // ничего не доехало

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)
        await waitUntil { model.counts?.total == 1 }

        // Ни исхода, ни доставленных local — «Финиш» скрыт; «Интернет» всегда виден.
        #expect(model.finishLine == nil)
        #expect(model.cloudLine.label == "Интернет")
    }

    // MARK: - Секции «Отметки» (metadata) и «Фото» (кадры)

    /// Фото-марка: секция «Отметки» считает метаданные строки, «Фото» — кадры; исходы общие per-target.
    @Test func photoMark_metadataAndPhotoSectionsSplit() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // metadata доехала до обеих целей; кадры приняты только LAN («Финиш»), cloud-кадры ещё pending.
        try await env.markStore.upsert(photoMark(
            id: "p1", frames: 2,
            uploadedLocal: true, uploadedCloud: true,
            photosUploadedLocal: true, photosUploadedCloud: false
        ))

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        // «Отметки» — по строке: 1/1 на обеих целях.
        await waitUntil { model.metadataCounts?.total == 1 }
        #expect(model.metadataCounts?.cloud == 1)
        #expect(model.metadataCounts?.local == 1)
        #expect(model.cloudLine.uploaded == 1)
        #expect(model.cloudLine.total == 1)
        #expect(model.cloudLine.done)

        // «Фото» — по кадрам: 2 всего, local 2 (флаг), cloud 0 (флаг не выставлен).
        await waitUntil { model.photoCounts?.total == 2 }
        #expect(model.hasPhotos)
        #expect(model.photoCounts?.total == 2)
        #expect(model.photoCounts?.local == 2)
        #expect(model.photoCounts?.cloud == 0)
        #expect(model.photoCloudLine.uploaded == 0)
        #expect(model.photoCloudLine.total == 2)
        #expect(model.photoCloudLine.done == false)
        // «Финиш» (LAN) секции «Фото» показан (uploaded > 0) и done.
        #expect(model.photoFinishLine?.uploaded == 2)
        #expect(model.photoFinishLine?.done == true)
    }

    /// Mid-drain марка (кадры приняты сервером, но флаг ещё не флипнут) — в `total`, но не в числителе.
    @Test func photoCounts_midDrainMarkInTotalNotNumerator() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // p1: 2 кадра приняты cloud (флаг). p2: 3 кадра — mid-drain (флаг cloud ещё 0).
        try await env.markStore.upsert(photoMark(id: "p1", frames: 2, photosUploadedCloud: true))
        try await env.markStore.upsert(photoMark(id: "p2", frames: 3, photosUploadedCloud: false))

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.photoCounts?.total == 5 }
        #expect(model.photoCounts?.total == 5)   // 2 + 3 всех кадров
        #expect(model.photoCounts?.cloud == 2)   // только флипнутые кадры p1
        #expect(model.photoCloudLine.uploaded == 2)
        #expect(model.photoCloudLine.total == 5)
        #expect(model.photoCloudLine.done == false)
    }

    /// `pendingLabel` (photo-aware) учитывает незалитые кадры: metadata доехала, кадры — нет → всё ещё pending.
    @Test func pendingLabel_countsUnsentFrames() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // Метаданные доехали до cloud, но кадры cloud ещё pending — строка не «отправлена» полностью.
        try await env.markStore.upsert(photoMark(
            id: "p1", frames: 2, uploadedCloud: true, photosUploadedCloud: false
        ))

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.counts?.total == 1 }
        // photo-aware cloud = 0 (кадры не приняты) → 1 не отправлено, хотя метаданные ушли.
        #expect(model.counts?.cloud == 0)
        #expect(model.pendingLabel == "1 не отправлено")
    }

    /// Секция «Фото» скрыта, когда кадров нет (только NFC-взятия).
    @Test func photoSection_hiddenWhenNoFrames() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.markStore.upsert(mark(id: "a"))
        try await env.markStore.upsert(mark(id: "b", uploadedCloud: true))

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.photoCounts != nil }
        #expect(model.photoCounts?.total == 0)
        #expect(model.hasPhotos == false)
        // «Отметки» при этом наполнены.
        await waitUntil { model.metadataCounts?.total == 2 }
        #expect(model.metadataCounts?.cloud == 1)
    }

    // MARK: - Секция «Трек» (точки GPS)

    /// Точки трека pending → секция «Трек» видна с корректными счётчиками per-target.
    @Test func trackSection_visibleWithCounts() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // 3 точки: одна доехала до cloud, одна до local, одна ни туда ни сюда.
        try await env.trackStore.insertAll([
            trackPoint(id: "t1", uploadedCloud: true),
            trackPoint(id: "t2", uploadedLocal: true),
            trackPoint(id: "t3")
        ])

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.trackCounts?.total == 3 }
        #expect(model.hasTrack)
        #expect(model.trackCounts?.total == 3)
        #expect(model.trackCounts?.local == 1)
        #expect(model.trackCounts?.cloud == 1)
        // «Интернет» секции «Трек» виден всегда (когда секция видима), не done (1/3).
        #expect(model.trackCloudLine.label == "Интернет")
        #expect(model.trackCloudLine.uploaded == 1)
        #expect(model.trackCloudLine.total == 3)
        #expect(model.trackCloudLine.done == false)
    }

    /// Ноль точек → секция «Трек» скрыта (правило секции «Фото»).
    @Test func trackSection_hiddenWhenNoPoints() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.markStore.upsert(mark(id: "a")) // только взятие, точек нет

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.trackCounts != nil }
        #expect(model.trackCounts?.total == 0)
        #expect(model.hasTrack == false)
        // «Финиш» трека скрыт до исхода/доставки; «Интернет» трека — калм-стейт 0/0.
        #expect(model.trackFinishLine == nil)
    }

    /// Только точки трека (взятий нет) → секция «Отметки» скрыта, секция «Трек» видна, экран не пуст.
    @Test func marksSection_hiddenWhenOnlyTrack() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.trackStore.insertAll([trackPoint(id: "t1"), trackPoint(id: "t2")])

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.trackCounts?.total == 2 }
        // Взятий нет → «Отметки» скрыта (иначе рисовался бы вводящий в заблуждение ряд «0/0»).
        #expect(model.metadataCounts?.total == 0)
        #expect(model.hasMarks == false)
        // …но трек виден и экран не пуст.
        #expect(model.hasTrack)
        #expect(model.hasContent)
    }

    /// Офлайн-исход дренажа трека доходит до модели со второй строкой; `refresh()` дренирует и трек.
    @Test func trackRefresh_offlineOutcomeReachesModel() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.trackStore.insertAll([trackPoint(id: "t1")])
        // Марок нет → markUploadAllPending без POST; трек: Local-POST, затем Cloud-POST.
        transport.enqueueError(URLError(.notConnectedToInternet)) // track local
        transport.enqueueError(URLError(.notConnectedToInternet)) // track cloud

        let model = UploadModel(env: env, nowMs: { 0 })
        model.rebind(teamId: 5, raceId: 7)
        await waitUntil { model.trackCounts?.total == 1 }

        await model.refresh()

        await waitUntil { model.trackOutcomes[.cloud]?.kind == .offline }
        #expect(model.trackOutcomes[.cloud]?.kind == .offline)
        // Флаги остались 0 (self-heal), строка не done → вторая строка с офлайн-лейблом.
        #expect(model.trackCloudLine.done == false)
        #expect(model.trackCloudLine.isError)
        #expect(model.trackCloudLine.secondLine == "только что · нет интернета")
        // «Финиш» трека стал видимым (есть исход) с собственным офлайн-лейблом.
        #expect(model.trackFinishLine?.secondLine == "только что · сервер недоступен")
    }

    /// `pendingLabel` суммирует незалитые отметки + кадры + точки трека.
    @Test func pendingLabel_sumsMarksFramesPoints() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        // 1 NFC-взятие pending + 1 фото-марка (2 кадра) pending → counts.total 2, cloud 0 (2 pending).
        try await env.markStore.upsert(mark(id: "a"))
        try await env.markStore.upsert(photoMark(id: "p1", frames: 2))
        // 2 точки трека pending → trackCounts 2 pending.
        try await env.trackStore.insertAll([trackPoint(id: "t1"), trackPoint(id: "t2")])

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)

        await waitUntil { model.counts?.total == 2 && model.trackCounts?.total == 2 }
        // 2 отметки (photo-aware) + 2 точки = 4 не отправлено.
        #expect(model.pendingLabel == "4 не отправлено")
    }

    // MARK: - rebind при смене команды чистит состояние

    @Test func rebind_clearsStateOnTeamChange() async throws {
        let transport = FakeTransport()
        let env = try AppEnvironment.inMemory(transport: transport.handle)
        try await env.markStore.upsert(mark(id: "a", raceId: 7, teamId: 5))

        let model = UploadModel(env: env)
        model.rebind(teamId: 5, raceId: 7)
        await waitUntil { model.counts?.total == 1 }
        #expect(model.counts?.total == 1)

        // Смена на пустую команду: состояние сбрасывается синхронно, затем счётчики нового скоупа (0).
        model.rebind(teamId: 9, raceId: 7)
        #expect(model.counts == nil) // синхронный сброс до первой эмиссии
        #expect(model.metadataCounts == nil)
        #expect(model.photoCounts == nil)
        #expect(model.trackCounts == nil)
        #expect(model.outcomes.isEmpty)
        #expect(model.trackOutcomes.isEmpty)

        await waitUntil { model.counts?.total == 0 }
        #expect(model.counts?.total == 0)
        #expect(model.pendingLabel == "Пока нечего загружать")
    }
}
