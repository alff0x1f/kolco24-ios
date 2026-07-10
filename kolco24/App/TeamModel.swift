//
//  TeamModel.swift
//  kolco24
//
//  `@Observable @MainActor`-модель вкладки «Команда». Порт ПОВЕДЕНИЯ (не структуры) роли
//  `Kolco24AppRoot` для экрана `ui/team/TeamScreen.kt`: сама выбранная команда приходит из
//  `AppModel.selectedTeamState`, а здесь живёт лишь локальный слой привязок чипов —
//  наблюдение `member_chip_bindings` для текущей команды (ключ — `numberInTeam`) и derived
//  `boundCount`/`allBound`, плюс отвязка (`deleteSlot`).
//
//  `bindings.count { … }` в Android — `members.count { bindings.containsKey(it.numberInTeam) }`:
//  считаются только слоты актуального ростера, поэтому derived-хелперы принимают `[TeamMemberItem]`
//  извне (ростер владеет `AppModel`, не эта модель).
//
//  Этап 5 (задача 9): сюда же переехал bind-флоу привязки браслета к участнику — порт хост-вайринга
//  из `MainActivity.kt` (~1792–1922). NFC-сессия (`any ChipScanning`) живёт весь открытый лист (как
//  Android-`DisposableEffect`-хук до `onDispose`) и поднимает `TagReading` на каждый тап; редьюсер
//  `processBind` различает «пул ещё не синхронизирован» (инлайн-`refreshMemberTags`) от «uid реально не
//  в пуле», зовёт готовый `decideBind` и на исход пишет слот через атомарный `reassign`. Повторный тап
//  после офлайна/`notInPool` работает именно потому, что сессия не одноразовая. Отдельной bind-модели нет
//  (Solution Overview). Прод-сканер `NfcChipScanner` инстанцируется здесь (App-слой, один модуль —
//  CoreNFC не импортируется); тесты подают `FakeChipScanner` в `beginBind(member:scanner:)`.
//
//  `import SwiftUI`/`GRDB`/`CoreNFC` запрещены (grep-инвариант) — хватает `Observation`. Данные — из
//  GRDB-observation стора привязок и `MemberTagsRepository`; фидбек — через шов `ScanFeedbackPlaying`.
//

import Foundation
import Observation

@MainActor
@Observable
final class TeamModel {

    /// Привязки чипов текущей команды, ключ — `numberInTeam` слота участника.
    /// Пусто между `rebind` на новую команду и первой эмиссией её observation (stale-guard).
    private(set) var bindings: [Int: MemberChipBinding] = [:]
    /// Категории гонки выбранной команды — для строки «Категория X · N человек» на герой-карточке.
    private(set) var categories: [Category] = []

    // MARK: - Bind-флоу (этап 5, задача 9)

    /// Состояние листа привязки — порт `BindSheetState` из `BindChipSheet.kt`. `nil` в `bindMember`
    /// (лист закрыт) сбрасывает флоу.
    enum BindSheetState: Equatable {
        /// Сессия открыта, ждём чип.
        case waiting
        /// Пул ещё не синхронизирован — запущен фоновый refresh, участнику предлагается поднести чип снова.
        case poolNotReady
        /// Прочитанный [uid] не из пула гонки.
        case notInPool(uid: String)
        /// [uid] (участник [participantNumber]) уже привязан к другому слоту — предложить перепривязку.
        case alreadyBound(uid: String, participantNumber: Int)
        /// Привязали [participantNumber] к этому слоту — лист автозакрывается.
        case success(participantNumber: Int)
    }

    /// Участник, для которого открыт bind-лист (драйвит presentation в `TeamView`); `nil` — лист закрыт.
    private(set) var bindMember: TeamMemberItem?
    /// Текущее состояние bind-листа.
    private(set) var bindState: BindSheetState = .waiting

    @ObservationIgnored private let env: AppEnvironment
    @ObservationIgnored private var bindingsTask: Task<Void, Never>?
    @ObservationIgnored private var categoriesTask: Task<Void, Never>?
    @ObservationIgnored private var bindStreamTask: Task<Void, Never>?
    @ObservationIgnored private var bindScanner: (any ChipScanning)?
    /// Потокобезопасное зеркало «bind-лист жив и ждёт чип» для `NfcChipScanner.shouldRestart` (читается
    /// на делегатной NFC-очереди, пишется здесь на MainActor). `true` на открытии листа, `false` на
    /// `cancelBind` и на входе в `.success` (не пересоздаём NFC-шторку поверх success-холда, Finding-4).
    /// Заменяет прямое чтение @MainActor `bindMember` с чужой очереди (гонка данных, Finding-3).
    @ObservationIgnored private let bindLiveness = ScanLiveness()
    /// Кэш «пул этой гонки уже подтверждён синхронизированным» в пределах открытого листа — повторные
    /// сканы над пустым пулом не дёргают refresh заново (порт `hasSyncedPool` из `MainActivity.kt`).
    @ObservationIgnored private var hasSyncedPool = false
    /// Токен текущей bind-сессии: инкрементируется на каждый `beginBind`. Стрим-Task и его завершающая
    /// очистка захватывают своё значение и сравнивают его с текущим — так стрим ПРЕДЫДУЩЕЙ сессии не
    /// закроет лист, переоткрытый на ТОГО ЖЕ участника (быстрый повторный тап; `bindMember == member`
    /// не различает такие сессии — Finding-2).
    @ObservationIgnored private var bindGeneration = 0
    /// Команда/гонка активного наблюдения — для идемпотентности `rebind` на той же команде.
    @ObservationIgnored private var boundTeamId: Int?
    @ObservationIgnored private var boundRaceId: Int?

    init(env: AppEnvironment) {
        self.env = env
    }

    deinit {
        bindingsTask?.cancel()
        categoriesTask?.cancel()
        bindStreamTask?.cancel()
    }

    // MARK: - Жизненный цикл

    /// Перепривязывает наблюдение привязок команды [teamId] и категорий её гонки [raceId] (или
    /// снимает оба при `nil`). Идемпотентно для той же пары. Stale-guard: до первой эмиссии новой
    /// команды в `bindings`/`categories` лежат данные прежней — очищаем синхронно (порт chips-guard
    /// из `MainActivity.kt`, где `collectAsState` не сбрасывается при смене ключа).
    func rebind(teamId: Int?, raceId: Int? = nil) {
        if teamId == boundTeamId, raceId == boundRaceId, bindingsTask != nil { return }
        cancelBind()
        bindingsTask?.cancel()
        categoriesTask?.cancel()
        bindings = [:]
        categories = []
        boundTeamId = teamId
        boundRaceId = raceId

        if let teamId {
            let observation = env.memberChipBindingStore.observeForTeam(teamId)
            bindingsTask = Task { [weak self] in
                do {
                    for try await rows in observation {
                        guard let self, !Task.isCancelled else { return }
                        self.bindings = Dictionary(uniqueKeysWithValues: rows.map { ($0.numberInTeam, $0) })
                    }
                } catch {}
            }
        }

        if let raceId {
            let observation = env.teamStore.observeCategoriesForRace(raceId)
            categoriesTask = Task { [weak self] in
                do {
                    for try await cats in observation {
                        guard let self, !Task.isCancelled else { return }
                        self.categories = cats
                    }
                } catch {}
            }
        }
    }

    /// Категория команды (для герой-строки), или `nil`, если не найдена/не задана.
    func category(for team: Team) -> Category? {
        guard let cid = team.categoryId else { return nil }
        return categories.first { $0.id == cid }
    }

    // MARK: - Derived (над актуальным ростером)

    /// Число участников ростера с привязанным чипом (только текущие слоты — устаревшие записи
    /// удалённых участников игнорируются). Делегирует общий Core-хелпер `boundCount(members:bindings:)`.
    func boundCount(members: [TeamMemberItem]) -> Int {
        kolco24.boundCount(members: members, bindings: bindings)
    }

    /// Все ли участники команды привязаны (герой-счётчик «N / total с чипом»). `total` — `team.ucount`.
    func allBound(members: [TeamMemberItem], total: Int) -> Bool {
        total > 0 && boundCount(members: members) >= total
    }

    /// Привязка слота [numberInTeam] или `nil`, если не привязан.
    func binding(for numberInTeam: Int) -> MemberChipBinding? {
        bindings[numberInTeam]
    }

    // MARK: - Действия

    /// Отвязка чипа от слота участника (порт `onUnbindMember` → `deleteSlot`). Ошибка молчалива —
    /// observation сам обновит `bindings` при успехе.
    func unbind(teamId: Int, numberInTeam: Int) async {
        try? await env.memberChipBindingStore.deleteSlot(teamId: teamId, numberInTeam: numberInTeam)
    }

    // MARK: - Bind-флоу (порт хост-вайринга MainActivity.kt ~1792–1922)

    /// Открывает bind-лист для [member] и стартует длинную прод-сессию `NfcChipScanner`. App-слой в
    /// одном модуле, поэтому тип из `Nfc/` инстанцируется без импорта CoreNFC (grep-инвариант). Bind не
    /// использует время скана — семпл нужен лишь для `TagReading`, берётся синхронным мостом к часам.
    ///
    /// Сессия ЖИВЁТ весь открытый лист (порт Android-`DisposableEffect`: reader-хук армирован до `onDispose`),
    /// а не гаснет после первого чтения: после `poolNotReady`-офлайна и `notInPool` UI зовёт «поднесите чип
    /// снова» — с одноразовой сессией повторный тап был бы мёртв. `shouldRestart` держит сессию сквозь 60-с
    /// системный лимит, пока лист открыт; `cancelBind`/success-автозакрытие её инвалидируют.
    func beginBind(member: TeamMemberItem) {
        let clock = env.trustedClock
        let liveness = bindLiveness
        let scanner = NfcChipScanner(
            sampleNow: { AppModel.syncSample(clock) },
            shouldRestart: { liveness.isAlive }
        )
        beginBind(member: member, scanner: scanner)
    }

    /// Шов сканера: открывает bind-лист и подписывается на один `TagReading` инжектированного [scanner]
    /// (тесты — `FakeChipScanner`). Сбрасывает состояние листа и кэш синхронизации на каждый новый слот.
    func beginBind(member: TeamMemberItem, scanner: any ChipScanning) {
        guard boundTeamId != nil, boundRaceId != nil else { return }
        bindStreamTask?.cancel()
        bindScanner?.stop()
        bindGeneration += 1
        let generation = bindGeneration
        bindMember = member
        bindState = .waiting
        hasSyncedPool = false
        bindLiveness.set(true)
        bindScanner = scanner
        // `readings()` ДО `start()`: прод-сканер синхронно завершает поток внутри `start()`, когда NFC
        // недоступен — установи мы континуейшн после, он бы висел на уже завершённом потоке.
        let stream = scanner.readings()
        scanner.start()
        bindStreamTask = Task { [weak self] in
            for await reading in stream {
                guard let self else { return }
                await self.processBind(reading, member: member, generation: generation)
            }
            // Поток завершился (пользователь отменил системную NFC-шторку / NFC недоступен): если ЭТА
            // сессия всё ещё текущая и не в success (у success своё ~900мс автозакрытие в `BindChipSheet`),
            // закрываем — иначе лист завис бы в `.waiting` без активного сканера (bind-аналог
            // `ScanModel.closeRequested`). Гвард по `generation` (а не по `bindMember == member`) не даёт
            // стриму ПРОШЛОЙ сессии закрыть лист, переоткрытый на того же участника быстрым повторным тапом
            // (Finding-2); `rebind`/повторный `beginBind` бампят generation и отменяют этот Task.
            guard let self, self.bindGeneration == generation else { return }
            if case .success = self.bindState { return }
            self.cancelBind()
        }
    }

    /// Порт `onReassign`: подтверждение перепривязки из состояния `alreadyBound` — переносит чип на
    /// текущий слот через атомарный `reassign`. Отличие от `writeBind`: при ошибке записи возвращаемся
    /// в `.alreadyBound` (порт Android-`onReassign`-catch), чтобы кнопка «Перепривязать» осталась для
    /// повторной попытки — а не в `.waiting`, где кнопки уже нет.
    func confirmReassign() async {
        guard case let .alreadyBound(uid, participantNumber) = bindState,
              let member = bindMember, let teamId = boundTeamId else { return }
        let generation = bindGeneration
        do {
            try await env.memberChipBindingStore.reassign(
                MemberChipBinding(
                    teamId: teamId, numberInTeam: member.numberInTeam,
                    nfcUid: uid, participantNumber: participantNumber
                )
            )
            // Лист мог закрыться/переоткрыться (в т.ч. на того же участника), пока шла запись — не
            // клобберим чужое состояние (сравнение по `generation`, Finding-2).
            if isBindStale(member, generation: generation) { return }
            // Гасим liveness ДО показа success: во время ~900мс success-холда 60-с таймаут/ошибка чтения
            // не должны заново открыть системную NFC-шторку поверх success-UI (Finding-4).
            bindLiveness.set(false)
            bindState = .success(participantNumber: participantNumber)
            env.feedback.play(.success)
        } catch {
            if isBindStale(member, generation: generation) { return }
            bindState = .alreadyBound(uid: uid, participantNumber: participantNumber)
            env.feedback.play(.failure)
        }
    }

    /// Закрывает bind-лист: инвалидирует сессию, снимает подписку и сбрасывает состояние. Идемпотентно.
    func cancelBind() {
        bindLiveness.set(false)
        bindStreamTask?.cancel()
        bindStreamTask = nil
        bindScanner?.stop()
        bindScanner = nil
        bindMember = nil
        bindState = .waiting
        hasSyncedPool = false
    }

    /// Порт тела `onTagScanned` (~1802–1887): один прочитанный чип → пул/`hasBeenSynced`/инлайн-refresh →
    /// `findByUid` → `decideBind` → состояние листа + запись слота. Сериализовано единым `for await`
    /// (замена Android-`scanMutex`).
    /// Скан устарел, если лист закрылся (`cancelBind` → `bindMember == nil` / отмена стрим-Task) или
    /// переоткрылся (`rebind`/повторный `beginBind` бампят `bindGeneration` — ловит даже переоткрытие на
    /// ТОГО ЖЕ участника, которое `bindMember == member` не различает, Finding-2).
    /// Резюмируясь после `await`, старый `processBind`/`confirmReassign` не должен мутировать состояние
    /// нового листа или писать привязку прежнего слота (Android сериализует это `scanMutex`; на iOS —
    /// единый for-await + эти проверки после каждого `await`).
    private func isBindStale(_ member: TeamMemberItem, generation: Int) -> Bool {
        bindMember != member || bindGeneration != generation || Task.isCancelled
    }

    private func processBind(_ reading: TagReading, member: TeamMemberItem, generation: Int) async {
        // Игнорируем шальные сканы во время success-автозакрытия (порт гварда `sheetState is Success`).
        if case .success = bindState { return }
        guard let teamId = boundTeamId, let raceId = boundRaceId else { return }
        if isBindStale(member, generation: generation) { return }
        let uid = reading.uid  // нормализован сканером (`normalizeNfcUid`)
        let currentSlot = SlotKey(teamId: teamId, numberInTeam: member.numberInTeam)

        // Полный пул тянем целиком, чтобы отличить «пул ещё не синхронизирован» (пустая таблица) от
        // «uid реально отсутствует в пуле» (таблица непуста, uid нет) — одного `findByUid` не хватает.
        var pool = await currentPool(raceId: raceId)
        if isBindStale(member, generation: generation) { return }
        if pool.isEmpty && !hasSyncedPool {
            // Пустой пул и в этом листе ещё не подтверждён: сначала долговечная запись `sync_meta`
            // (переживает пересоздание экрана и стартовый прогрев, синхронизировавший пустой пул).
            if (try? await env.memberTagsRepository.hasBeenSynced(raceId: raceId)) == true {
                if isBindStale(member, generation: generation) { return }
                hasSyncedPool = true
            } else {
                if isBindStale(member, generation: generation) { return }
                // Синка ещё не было — инлайн-refresh. Сервер недоступен → остаёмся ждать (neutral);
                // на успехе помечаем синхронизированным и перечитываем пул.
                bindState = .poolNotReady
                let result = try? await env.memberTagsRepository.refreshMemberTags(raceId)
                if isBindStale(member, generation: generation) { return }
                switch result {
                case .offline, .forbidden, .httpError, .none:
                    bindState = .waiting
                    env.feedback.play(.neutral)
                    return
                case .updated, .notModified, .skipped:
                    hasSyncedPool = true
                    pool = await currentPool(raceId: raceId)
                    if isBindStale(member, generation: generation) { return }
                }
            }
        }

        let poolNumber = pool.first { $0.nfcUid == uid }?.number
        let existing = (try? await env.memberChipBindingStore.findByUid(uid)) ?? nil
        if isBindStale(member, generation: generation) { return }
        switch decideBind(uid: uid, poolNumber: poolNumber, existing: existing, currentSlot: currentSlot) {
        case .notInPool:
            bindState = .notInPool(uid: uid)
            env.feedback.play(.failure)
        case let .alreadyOnThisSlot(participantNumber):
            // Перезаписываем `participantNumber` из авторитетного пула на случай, если он сменился
            // с момента исходной привязки (порт ветки AlreadyOnThisSlot).
            await writeBind(teamId: teamId, member: member, uid: uid, participantNumber: participantNumber, generation: generation)
        case let .alreadyBound(_, participantNumber):
            // Предупреждение, не ошибка: чип привязан в другом месте, но кнопка «Перепривязать» ещё
            // может завершить флоу — нейтральный «прочитан»-сигнал.
            bindState = .alreadyBound(uid: uid, participantNumber: participantNumber)
            env.feedback.play(.neutral)
        case let .readyToBind(participantNumber):
            await writeBind(teamId: teamId, member: member, uid: uid, participantNumber: participantNumber, generation: generation)
        }
    }

    /// Атомарная запись привязки чипа [uid] на слот [member] (`reassign` — сброс любого слота с этим
    /// uid + upsert, чтобы чип не оказался на двух слотах). Успех → `success` + фидбек; ошибка → назад в
    /// ожидание + failure.
    ///
    /// Пред-записи стейл-гвард НЕ нужен: `processBind` проверяет `isBindStale` сразу перед этим вызовом
    /// (после последнего await `findByUid`), а между той проверкой и первым await `reassign` нет ни одной
    /// точки приостановки на MainActor — вклиниться `cancelBind`/`rebind` не могут. Отмена, пришедшая ВО
    /// ВРЕМЯ самого `reassign`-await, запись уже не отменяет (GRDB не бросает CancellationError) — это
    /// непредотвратимо в любом языке и совпадает с Android (bind идёт через корневой composition-`scope`
    /// (MainActivity.kt:510), а не per-sheet, так что запись переживает закрытие листа); мутация состояния
    /// при этом гейтится пост-await `isBindStale`, а observation привязок сам сводит UI.
    private func writeBind(teamId: Int, member: TeamMemberItem, uid: String, participantNumber: Int, generation: Int) async {
        do {
            try await env.memberChipBindingStore.reassign(
                MemberChipBinding(
                    teamId: teamId, numberInTeam: member.numberInTeam,
                    nfcUid: uid, participantNumber: participantNumber
                )
            )
            // Строка привязки для этого слота записана (переживает закрытие), но состояние листа трогаем
            // только если он всё ещё про эту сессию — иначе не клобберим переоткрытый лист.
            if isBindStale(member, generation: generation) { return }
            // Гасим liveness ДО success-холда (Finding-4, см. confirmReassign).
            bindLiveness.set(false)
            bindState = .success(participantNumber: participantNumber)
            env.feedback.play(.success)
        } catch {
            if isBindStale(member, generation: generation) { return }
            bindState = .waiting
            env.feedback.play(.failure)
        }
    }

    /// Первое значение пула member-тегов гонки (аналог Kotlin `.first()`).
    private func currentPool(raceId: Int) async -> [MemberTag] {
        do {
            for try await tags in env.memberTagsRepository.observeForRace(raceId) {
                return tags
            }
        } catch {}
        return []
    }
}
