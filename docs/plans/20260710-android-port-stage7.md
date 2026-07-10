# Этап 7 портирования: фото-отметка

Детализация этапа 7 из [android-port.md](android-port.md). Этапы 0–6 выполнены: чистая логика, GRDB-слой, сеть/sync, `@Observable`-модели, NFC-скан и выгрузка взятий готовы и покрыты тестами. Этап 7 добавляет фото-отметку — резервный способ взять КП, когда чип не читается (сорван, сломан): камера → кадры на диске → марка `method="photo"` → покадровая идемпотентная выгрузка.

## Overview

Кнопка «Фото» на вкладке «Отметки» (сейчас no-op) оживает: свежее NFC-взятие в 3-минутном окне → камера открывается сразу и кадры доклеиваются к нему (`attachPhotos`); иначе — пикер номера КП по легенде → новая марка `method="photo"` (`complete=true`, зачитывается локально, ждёт проверки судьёй). Кадры — даунскейленные JPEG на диске, в БД только относительные пути; выгрузка — по одному кадру на идемпотентный бинарный эндпоинт, после метаданных, на обе цели независимо. Тайлы фото-взятий показывают первый кадр, тап открывает лайтбокс с пейджером и шарингом.

**Ключевые решения брейншторма (адаптация под платформу, не 1в1 из Kotlin):**
- **Камера — полный кастомный экран на AVFoundation** (мультикадровая сессия, лента миниатюр с удалением, «Готово (N)», фронт/тыл, фонарик), но ориентация — через **`AVCaptureDevice.RotationCoordinator`** (таргет iOS 18): порт акселерометра (`RotationTracker`/`bucketOrientationDegrees`) и его тесты **не переносятся вовсе** — система решает ту же задачу (физический наклон при portrait-locked UI) нативно.
- **Даунскейл — ImageIO** (`CGImageSourceCreateThumbnailAtIndex` + `kCGImageSourceThumbnailMaxPixelSize` + `kCGImageSourceCreateThumbnailWithTransform = true`): ориентация запекается в пиксели системой — ручного поворота битмапы (как в Kotlin `prepareBitmap`) нет. Константы 1:1: `MAX_EDGE_PX = 1600`, `JPEG_QUALITY = 80`, `THUMB_MAX_EDGE = 512`, `THUMB_JPEG_QUALITY = 75`.
- **Хранилище — Application Support** (рядом с `kolco24.db`; аналог `filesDir`): каталог `marks/<markId>/<uuid>.jpg` + сосед `<uuid>.thumb.jpg`, в БД — относительный путь `marks/<markId>/<uuid>.jpg` (корень легко сменить).
- **Звук затвора — системный** от `AVCapturePhotoOutput` (порт `shutter.wav` не нужен); подтверждение записи кадра — хаптика (best-effort, конвенция этапа 5).
- **Скоуп — полный**: ядро (камера, пикер, тайлы, лайтбокс, покадровая выгрузка, orphan-sweep) + секция «Фото» в UploadView, нотис «N КП по фото · P баллов», `ShareLink` в лайтбоксе.

Вне скоупа: судейская проверка фото (сервер/этап 10), фоновая выгрузка (BGTaskScheduler — вне MVP).

**Известный факт, не баг:** бинарный эндпоинт кадров `/app/race/<id>/mark/<markId>/photo/<frameId>`, как и `/marks/`, ещё **не поднят** на сервере. Живая проверка покажет pending/«ошибка» — это спроектированный self-heal (транзиентные коды оставляют флаг `0`, тот же билд дошлёт). Hard gate этапа — зелёный локальный сьют + сборка.

## Context (from discovery)

**Уже готово и переиспользуется (не переписывать):**
- `Core/Marks/PhotoTarget.swift` (+ `PhotoTargetTests`/`ResolvePhotoCheckpointTests`/`FilterCheckpointsByQueryTests`) — `decidePhotoTarget` (окно `PHOTO_ATTACH_WINDOW_MS = 180_000`, включительная граница, новейшее **complete** не-photo взятие, `trustedTakenAt ?? takenAt`), `resolvePhotoCheckpoint`, `filterCheckpointsByQuery` — весь выбор цели уже портирован.
- `Data/Stores/MarkStore.swift` — фото-часть DB-слоя целиком: `attachPhotos(id:newPaths:now:)` (merge JSON-списка, bump `updatedAt`, сброс `photosUploaded* = 0`), `framePendingLocal/Cloud` (гейт `uploadedX=1 AND photosUploadedX=0 AND photoPath IS NOT NULL`, method-агностично — NFC-взятие с кадрами тоже дренируется), version-guarded `setPhotosUploaded{Local,Cloud}IfUnchanged`, `photoFrameRows` (observation), photo-aware `uploadCounts` + `uploadCountsMetadata`, расширенный `pendingUploadScopes`. Вложенный `enum MarkPhotoPaths` (encode/decode/isSafe) — **промоутится в Core** (Task 1).
- Схема `marks` (`Data/AppDatabase.swift`): `photoPath TEXT` (JSON-массив путей), `photosUploadedLocal/Cloud INTEGER NOT NULL` — отдельной таблицы кадров нет, связь кадр↔марка только через список путей.
- `Core/Upload/UploadModels.swift` — `combineOutcome(metadata, frame)` с приоритетом `error > offline > ok > nil` уже готов и оттестирован; в `MarkUploadRepository.flushScope` шов `combineOutcome(meta, nil)` (два вызова) ждёт кадровый исход.
- `Data/Repositories/MarkUploadRepository.swift` — generic `drainUploadLoop<Row>` и actor-скелет; `Net/ApiClient.swift` — generic `post` (подпись по байтам тела, без ретраев); `FakeTransport`-конвенция тестов.
- `Core/Marks/MarksDisplay.swift` — `MarkTile` с `enum MarkKind {nfc/photo}` и маппингом `method == "photo"`; фото-поля (`photoPaths`/`photoCount`), `lightboxPhotos`, `photoReviewSummary` помечены «этап 7».
- Паттерны: презентация шитов из `MarksView` (`.sheet(item:onDismiss:)` + фабрика `AppModel.makeScanModel()`), unstructured `Task` с захватом сторов (§6 этапа 5), one-shot GPS `attachLocation` (`ScanModel`), `fullScreenCover` + `NavigationStack` (team-picker flow), rebind-стейл-гард пер-таб моделей.

**Kotlin-источники** (в `/Users/alff0x1f/src/kolco24_app_v2`, пакет `app/src/main/java/ru/kolco24/kolco24/`; контракт — `docs/design/UPLOAD.md`):
- `ui/photo/PhotoCaptureScreen.kt` (541 строка) — камера CameraX: guard `isCapturing`, `firstSample` только на первом кадре (прокси присутствия, зеркало NFC-тапа), лента миниатюр с удалением, «Готово (N)», диалог «Удалить снимки?» при выходе с кадрами (удаляются **только кадры этой сессии** — у attach-цели могут быть старые), markId минтится **до** открытия камеры (кадры пишутся в `marks/<markId>/` до существования строки — фикс chicken-and-egg). `ImageCapture` не зеркалит сохранённый JPEG у фронталки (зеркалится только превью) — номера КП читаемы.
- `ui/photo/PhotoNumberPicker.kt` — цифровое поле, живой фильтр `filterCheckpointsByQuery`, строка `<cost>-<number>` + замок + описание, залоченные КП выбираемы (сценарий «метку сорвали»), номер вне легенды → инлайн-ошибка «КП с таким номером нет в легенде».
- `data/marks/PhotoStorage.kt` — константы 1600/80/512/75, `writeDownscaledJpeg` (null при любом сбое — битый кадр молча выбрасывается; тумба best-effort, её сбой не валит кадр), `deletePhoto` (кадр + тумба), `sweepOrphanDirs`/чистый `orphanPhotoDirs`, чистый `scaledDimensions`.
- `data/marks/PhotoPaths.kt` — `encodePhotoPaths`/`photoPaths` (никогда не бросает; null/мусор → `[]`), `isSafeRelativePhotoPath` (ровно 3 сегмента `marks/<id>/<file>.jpg`, без `..`/абсолютных — anti-traversal), **`frameIdOf`** (стем имени без `.jpg` — ключ идемпотентности кадра), **`thumbPathOf`** (конвенция имени, тумбы никогда не попадают в `photoPath`).
- `data/MarkRepository.kt` — `createPhotoMark` (L211–243): `method="photo"`, `complete=true`, `present=[]`, `presentDetails=null`, `cpUid=""`, `cpCode=""`, `cost = cp.cost ?? 0` (0 у залоченного; живой резолвер цены поправит после reveal), `expectedCount` только для серверного лога; `attachPhotos` (L250–252); **`frameDrainLoop` (L425–448) + `uploadOneMarksFrames` (L466–478)**: по каждой pending-марке кадры в порядке списка, все приняты → `Flipped` → version-guarded флип; `isHardFrameFailure` (**400/413 = ядовитый кадр** → `Pending`, марку пропустить, идти к следующей), прочие не-success → `Stop(kind)` — стоп всего таргета; нет прогресса за проход → `Error`; пустой первый fetch → `null`. Missing file (reader → null) = hard per-mark failure. `PhotoFrameUploader` по умолчанию `Offline` (незавайренный шов оставляет кадры pending), `PhotoFrameReader` — замыкание чтения байт.
- `data/api/ApiClient.kt` `uploadMarkPhoto` (L267–273): `POST /app/race/<raceId>/mark/<markId>/photo/<frameId>` — **сырые JPEG-байты** (не multipart, не base64), `Content-Type: image/jpeg`, та же 6-заголовочная подпись (хэш тела — от JPEG-байт), ответ `200/201` → success (тело не парсится). UPLOAD.md L229–243: идемпотентный upsert по `(race_id, mark_id, frame_id)`; `400`/`413` — hard, остальное — transient.
- `data/PhotoFrameCounts` / `foldPhotoFrameCounts` (MarkRepository.kt L522–533) — покадровая гранулярность: `total` = сумма кадров всех строк, числитель по таргету — кадры строки только при выставленном флаге (mid-drain марка даёт total, но 0 в числитель).
- `ui/marks/MarksScreen.kt` — фото-тайл (первый кадр, `thumb` с фолбэком, чип `<cost>-<number>`, глиф камеры только у `method="photo"`, бейдж «+N»), лайтбокс (`HorizontalPager` по `lightboxPhotos` — все кадры в порядке сетки, счётчик k/N, чип КП, шаринг, drag-to-dismiss), `photoReviewSummary` (L227–246): фото-only = complete `method=="photo"`, чей `checkpointId` не подтверждён чипом; `distinctBy { checkpointId }`.
- `MainActivity.kt` — `onPhotoClick` (L1050–1073): гейт на команду, `decidePhotoTarget`; пикер+коммит (L2062–2139): attach → `attachPhotos(markId, paths, firstSample.wallMs)`; новое → `createPhotoMark` + one-shot `attachLocation`; кадры без цели — осиротают, sweep подберёт.
- **Android-тесты для зеркалирования:** `PhotoPathsTest.kt`, `PhotoStorageTest.kt` (только чистые `scaledDimensions`/`orphanPhotoDirs`), `PhotoFrameCountsTest.kt`, фото-кейсы `MarkRepositoryUploadTest.kt` (~13), `IsHardFrameFailureTest`, photoReviewSummary-кейсы. **Не зеркалируются:** `PhotoCaptureScreenTest.kt` (`bucketOrientationDegrees` — заменён RotationCoordinator).

## Development Approach

- **testing approach**: порт-конвенция этапов 2–6 — Kotlin-тесты переносятся вместе с модулем в той же задаче (имена кейсов 1:1, header «Зеркало …»); для `PhotoModel`, `PhotoStorage`-I/O и UI зеркала нет — тесты свежие (regular: код → тесты в той же задаче) поверх реальных сторов на `AppDatabase.makeInMemory()` + `FakeTransport` + временных каталогов (`FileManager.temporaryDirectory`);
- complete each task fully before moving to the next;
- make small, focused changes (коммит на задачу);
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task;
- **CRITICAL: all tests must pass before starting next task**;
- **CRITICAL: update this plan file when scope changes during implementation**.

## Testing Strategy

- **unit tests**: Swift Testing. `kolco24Tests/Core/PhotoPathsTests`, `PhotoStorageLogicTests`, `PhotoMarkTests`, `PhotoFrameCountsTests`, `MarksDisplayPhotoTests` (photoReviewSummary/lightboxPhotos/тайл-поля); `kolco24Tests/Photo/PhotoStorageTests` (реальное I/O во временном каталоге — файлы и ImageIO работают в симуляторе); `kolco24Tests/Net/` — эндпоинт кадра через `FakeTransport`; `kolco24Tests/Data/Repositories/MarkUploadRepositoryTests` — кадровый дрейн; `kolco24Tests/App/PhotoModelTests` (`@MainActor`).
- **e2e**: автоматизированных нет; камера не работает в симуляторе — съёмка проверяется на устройстве (Post-Completion); серверные эндпоинты не подняты — сквозная проверка ограничена «кадры pending, исход на экране».
- Прогон: `xcodebuild test -project kolco24.xcodeproj -scheme kolco24 -destination 'platform=iOS Simulator,name=iPhone 16'` (нужен `Config/Secrets.xcconfig`; при флаки-имени — `id=<UDID>` из `xcrun simctl list devices available`).

## Progress Tracking

- mark completed items with `[x]` immediately when done
- add newly discovered tasks with ➕ prefix
- document issues/blockers with ⚠️ prefix

## Solution Overview

Поток данных: FAB «Фото» → `AppModel.makePhotoModel()` → `PhotoModel.start()` (fetch marks → `decidePhotoTarget`) → маршрут `.camera` (attach, markId переиспользуется) или `.picker` → камера (`PhotoCameraController` + `PhotoCaptureView`) → каждый кадр: JPEG-байты → `PhotoStorage.writeDownscaledJpeg` → относительный путь в буфер модели (`firstSample` от `TrustedClock` на первом кадре) → «Готово» → attach: `markStore.attachPhotos`; новое: `makePhotoMark` → `upsert` + one-shot GPS → закрытие кавера → `flushUploads` → `MarkUploadRepository.flushScope`: метаданные → **кадровый дрейн** → `combineOutcome(meta, frame)` → исход в стрим → `UploadModel`/`UploadView` (секция «Фото», покадровые счётчики).

Ключевые решения:
- **Новый платформенный слой `kolco24/Photo/`** (прецедент `Nfc/`/`Location/`/`Audio/`) — единственный дом камерно-графических импортов: `PhotoCameraController` (AVCaptureSession/AVCapturePhotoOutput/RotationCoordinator; **без protocol-шва** — камера не юнит-тестируема, тестируемое отделено в Core/модель) и `PhotoStorage` (диск + ImageIO). Grep-инвариант расширяется: `AVFoundation` разрешён в `Audio/` **и** `Photo/`; `import ImageIO` (новый для репозитория) — только в `Photo/`.
- **Чистая логика — в Core**: `PhotoPaths` (промоушен из `MarkStore` + `frameIdOf`/`thumbPathOf`), `makePhotoMark` (по образцу `makeKpTakeMark`: UUID и `TimeSample` параметрами), `scaledDimensions`/`orphanPhotoDirs`, фото-поля `MarkTile` + `lightboxPhotos` + `photoReviewSummary`, `foldPhotoFrameCounts` (в `Core/Upload/`).
- **`App/PhotoModel`** (`@Observable @MainActor`, только `Observation`/`Foundation`) — доменный редьюсер потока: решение цели, состояние пикера/камеры/буфера кадров, коммит. Дисковые операции — **инжектированные замыкания** (`writeFrame`/`deleteFrame`), так что модель тестируема без AVFoundation/ImageIO (идиома `TrustedClock`).
- **Кадровый дрейн — внутри `MarkUploadRepository`** (не новый актор): `frameDrainLoop` после метаданного цикла на каждом таргете, `combineOutcome(meta, frame)` вместо `(meta, nil)`; исходы остаются едиными по-таргетными (как Android — один `onUploadOutcome`).
- **Sweep осиротевших каталогов** — при старте (`AppModel.start()`, fire-and-forget): `markStore.allIds()` (добавить) + чистый `orphanPhotoDirs` + удаление каталогов через `PhotoStorage`.

## Technical Details

- **Пути**: корень `Application Support` (тот же каталог, где `kolco24.db`), в БД — только относительные `marks/<markId>/<uuid>.jpg`; абсолютный путь собирается в местах чтения/записи (`PhotoStorage.rootURL` инжектируется — в тестах временный каталог).
- **`PhotoStorage.writeDownscaledJpeg(markId:jpegData:) -> String?`**: ImageIO-даунскейл (max edge 1600, quality 80, `CreateThumbnailWithTransform` печёт EXIF-ориентацию) → `mkdir -p` → запись `<uuid>.jpg` → best-effort тумба 512/75 (`<uuid>.thumb.jpg`) → относительный путь; любой сбой → `nil` (кадр молча выброшен, конвенция Android). Блокирующее I/O — вызывать вне main (`Task.detached`/背景-очередь из модели).
- **`makePhotoMark`**: `method="photo"`, `complete=true`, `present=[]`, `presentDetails=nil`, `cpUid=""`, `cpCode=""`, `cost = cp.cost ?? 0`, `photoPath = encodePhotoPaths(paths)`, `takenAt/updatedAt = sample.wallMs`, `trustedTakenAt/elapsedRealtimeAt/bootCount` из того же `TimeSample`, `expectedCount` параметром (для серверного лога, на `complete` не влияет).
- **Эндпоинт кадра**: `ApiClient.uploadMarkPhoto(raceId:markId:frameId:bytes:) async -> PostResult<Void>` — generic `post`-пайплайн с `contentType: "image/jpeg"` и телом-байтами как есть (подпись по хэшу тех же байт, **без ретраев**, trailing-slash-**без** — путь Kotlin без слэша в конце: `/app/race/<id>/mark/<markId>/photo/<frameId>`; сверить с Kotlin-каноном буквально). Ответ 200/201 → `.success`, тело не парсится.
- **`frameDrainLoop`** (в файле репозитория): fetch `framePending*` (LIMIT 500) → по каждой марке кадры в порядке `photoPaths(mark.photoPath)`: `frameReader(rel)` → nil = hard → марку пропустить; `uploadMarkPhoto` → `.success` — следующий кадр; hard (`.badRequest`/`.error(413)`) → марку пропустить; иначе → стоп таргета с kind. Все кадры марки ок → version-guarded `setPhotosUploaded*IfUnchanged(id:updatedAt:)`. Нет прогресса за полный проход → `.error`; пустой первый fetch → `nil`.
- **`isHardFrameFailure(PostResult) -> Bool`**: `.badRequest` (400) и `.error(413)` — hard; всё остальное transient (зеркало Kotlin).
- **`PhotoFrameReader`** = `(String) -> Data?` в `AppEnvironment` (прод — чтение `rootURL + rel`; `inMemory` — `{ _ in nil }`, контрактно-безопасно: кадры остаются pending, как Android-default).
- **`foldPhotoFrameCounts`** — в `Core/Upload/` над лёгкой Core-структурой входа `PhotoFrameInput { photoPath: String?; local: Bool; cloud: Bool }` (решено: `PhotoFrameRow` — GRDB `FetchableRecord` в `Data/Stores/UploadTypes.swift`, в Core его тащить нельзя; `Data/`-адаптер маппит `PhotoFrameRow → PhotoFrameInput` при вызове — инвариант «Core без GRDB» важнее зеркальности файла).
- **Пикер**: `TextField` `.keyboardType(.numberPad)`, фильтр цифр, `filterCheckpointsByQuery` по легенде из `checkpointStore`, submit через `resolvePhotoCheckpoint`; залоченные КП выбираемы.
- **Камера**: `AVCaptureSession` на фоновой очереди, `AVCapturePhotoOutput`, `videoRotationAngle` кадра из `RotationCoordinator.videoRotationAngleForHorizonLevelCapture`; превью — `UIViewRepresentable` с `AVCaptureVideoPreviewLayer` (+ `videoRotationAngleForHorizonLevelPreview`); фронт/тыл пересборкой input, фонарик `torchMode` (только тыл). Разрешение: `AVCaptureDevice.requestAccess(for: .video)` на входе; отказ → заглушка со ссылкой в Настройки (`UIApplication.openSettingsURLString` — допустимый UIKit-импорт в `Photo/`? нет: линк из SwiftUI-вьюхи через `@Environment(\.openURL)`).
- **`INFOPLIST_KEY_NSCameraUsageDescription`** — в оба build config (конвенция location-ключа этапа 5).
- **Лайтбокс**: `fullScreenCover` + `TabView(.page)` по `lightboxPhotos(tiles)` (все кадры всех взятий в порядке сетки), счётчик `k/N`, чип КП, `ShareLink(item: URL)`, drag-to-dismiss (offset + threshold), фон чёрный.
- **Empty-state**: Kotlin-ветки лестницы про NFC-недоступность (роутинг «нет NFC → фото») на iOS **неприменимы** — все поддерживаемые iPhone имеют NFC; лестница `marksEmptyState` не меняется (фиксируем осознанно).

## What Goes Where

- **Implementation Steps**: код, тесты, документация — всё проверяемо сборкой/сьютом в симуляторе (файловое I/O и ImageIO работают в hosted-тестах).
- **Post-Completion**: съёмка/ориентация/фонарик — только на устройстве; живая выгрузка кадров — когда поднимут бэкенд.

## Implementation Steps

### Task 1: Core — PhotoPaths (промоушен + frameIdOf/thumbPathOf)

**Files:**
- Create: `kolco24/Core/Marks/PhotoPaths.swift`
- Modify: `kolco24/Data/Stores/MarkStore.swift` (убрать вложенный `MarkPhotoPaths`, перейти на Core)
- Create: `kolco24Tests/Core/PhotoPathsTests.swift`

- [x] перенести `encodePhotoPaths`/`decodePhotoPaths`/`isSafeRelativePhotoPath` из `MarkStore.MarkPhotoPaths` в `Core/Marks/PhotoPaths.swift` (чистый Foundation; decode никогда не бросает: null/blank/мусор → `[]`)
- [x] добавить `frameIdOf(_ relPath:) -> String` (стем без `.jpg` — ключ идемпотентности) и `thumbPathOf(_ framePath:) -> String` — зеркало `PhotoPaths.kt`
- [x] `MarkStore.attachPhotos` и все использования — на Core-функции; вложенный enum удалить
- [x] тесты (зеркало `PhotoPathsTest.kt`): round-trip + порядок, null/blank/malformed → `[]`, абсолютный/traversal/не-3-сегмента/не-`.jpg` отброшены, `frameIdOf` валидный + defensive, `thumbPathOf`
- [x] прогнать тесты — зелёные до Task 2

### Task 2: Core — makePhotoMark, scaledDimensions/orphanPhotoDirs, фото-поля MarksDisplay

**Files:**
- Create: `kolco24/Core/Marks/PhotoMark.swift`
- Create: `kolco24/Core/Marks/PhotoStorageLogic.swift`
- Modify: `kolco24/Core/Marks/MarksDisplay.swift`
- Create: `kolco24Tests/Core/PhotoMarkTests.swift`
- Create: `kolco24Tests/Core/PhotoStorageLogicTests.swift`
- Create: `kolco24Tests/Core/MarksDisplayPhotoTests.swift`

- [x] `makePhotoMark(markId:cp:raceId:teamId:paths:expectedCount:sample:) -> Mark` — зеркало `createPhotoMark` (L211–243): `method="photo"`, `complete=true`, `present=[]`, `presentDetails=nil`, `cpUid=""/cpCode=""`, `cost = cp.cost ?? 0`, `photoPath = encodePhotoPaths(paths)`, времена из `TimeSample`
- [x] `scaledDimensions(width:height:maxEdge:) -> (Int, Int)` (aspect, longest ≤ maxEdge, `max(1, …)`, не-положительные → как есть) и `orphanPhotoDirs(dirNames:liveMarkIds:) -> [String]` — зеркало чистой части `PhotoStorage.kt`
- [x] `MarkTile` + `photoPaths: [String]`/`photoCount: Int` (из `decodePhotoPaths`), `marksToTiles` наполняет; `lightboxPhotos(tiles) -> [LightboxPhoto]` (кадры в порядке сетки); `photoReviewSummary(marks:costOf:) -> PhotoReviewSummary?` (фото-only = complete photo, чей КП не подтверждён чипом; `distinctBy checkpointId`, счёт баллов через живой `costOf` — 1:1 с Kotlin) — снять пометки «этап 7, не портируется»
- [x] тесты: `PhotoMarkTests` (все поля, cost залоченного = 0, expectedCount не влияет на complete); `PhotoStorageLogicTests` (зеркало `PhotoStorageTest.kt`: unchanged-if-small, shrink L/P, never-zero, non-positive; orphanPhotoDirs 3 кейса); `MarksDisplayPhotoTests` (photoPaths/photoCount на тайле, lightboxPhotos порядок, photoReviewSummary — зеркало Kotlin-кейсов)
- [x] прогнать тесты — зелёные до Task 3

### Task 3: Photo/ — PhotoStorage (диск + ImageIO) и sweep

**Files:**
- Create: `kolco24/Photo/PhotoStorage.swift`
- Create: `kolco24Tests/Photo/PhotoStorageTests.swift`

- [ ] `struct PhotoStorage { let rootURL: URL }` — прод-фабрика от Application Support (каталог `kolco24.db`); константы `maxEdgePx = 1600`, `jpegQuality = 0.8`, `thumbMaxEdge = 512`, `thumbJpegQuality = 0.75`
- [ ] `writeDownscaledJpeg(markId:jpegData:) -> String?` — ImageIO (`CGImageSourceCreateThumbnailAtIndex`, `kCGImageSourceThumbnailMaxPixelSize`, `kCGImageSourceCreateThumbnailWithTransform=true`) → `<uuid>.jpg` → best-effort `<uuid>.thumb.jpg` → относительный путь; любой сбой → `nil`
- [ ] `deleteFrame(relPath:)` (кадр + тумба, только через `isSafeRelativePhotoPath`), `absoluteURL(relPath:)`, `sweepOrphanDirs(liveMarkIds:)` (список подкаталогов `marks/` + чистый `orphanPhotoDirs` + удаление)
- [ ] тесты (временный каталог + сгенерированный тестовый JPEG, в т.ч. с EXIF-ориентацией): запись → файл и тумба существуют, размеры ≤ 1600/512, ориентация запечена (пиксельные размеры повернуты); мусорные байты → `nil`, каталога/файлов нет; delete удаляет пару; sweep сносит только сирот
- [ ] прогнать тесты — зелёные до Task 4

### Task 4: Net — эндпоинт кадра uploadMarkPhoto

**Files:**
- Modify: `kolco24/Net/ApiClient.swift`
- Create: `kolco24Tests/Net/MarkPhotoUploadTests.swift`

- [ ] `uploadMarkPhoto(raceId:markId:frameId:bytes:) async -> PostResult<Void>` — POST сырых JPEG-байт на `/app/race/<raceId>/mark/<markId>/photo/<frameId>` (путь **без** trailing slash — 1:1 с Kotlin L267–273), `Content-Type: image/jpeg`, подпись по хэшу тех же байт, без ретраев; 200/201 → `.success`, тело не парсится
- [ ] тесты через `FakeTransport`: метод/путь/Content-Type/тело-байты как есть; 201 → success; 403 → ровно один запрос (нет ретрая); 413 → `.error(413)`; URLError → `.offline`
- [ ] прогнать тесты — зелёные до Task 5

### Task 5: Data/Repositories — кадровый дрейн в MarkUploadRepository

**Files:**
- Modify: `kolco24/Data/Repositories/MarkUploadRepository.swift`
- Modify: `kolco24/Data/Stores/MarkStore.swift` (добавить `allIds()`)
- Modify: `kolco24/App/AppEnvironment.swift` (прокинуть `frameReader`)
- Create/Modify: `kolco24/Core/Upload/…` (`foldPhotoFrameCounts` — см. Technical Details про вход без GRDB-типа)
- Modify: `kolco24Tests/Data/Repositories/MarkUploadRepositoryTests.swift`
- Create: `kolco24Tests/Core/PhotoFrameCountsTests.swift`

- [ ] `isHardFrameFailure` (400/413) + `frameDrainLoop` per target: fetch `framePending*(limit: 500)` → кадры марки по порядку → reader nil/hard → skip марки; transient → стоп таргета; все ок → `setPhotosUploaded*IfUnchanged`; нет прогресса → `.error`; пустой первый fetch → `nil`
- [ ] `flushScope`: после метаданного цикла каждого таргета — кадровый; `combineOutcome(meta, frame)` вместо `(meta, nil)` (оба вызова); deps актора: `frameReader: (String) -> Data?`
- [ ] `MarkStore.allIds() async throws -> [String]`; `AppEnvironment`: прод `frameReader` = чтение из `PhotoStorage`, `inMemory` → `{ _ in nil }`
- [ ] `foldPhotoFrameCounts(_ rows: [PhotoFrameInput]) -> UploadCounts` в `Core/Upload/` над Core-структурой `PhotoFrameInput { photoPath: String?; local: Bool; cloud: Bool }`; `Data/`-адаптер `PhotoFrameRow → PhotoFrameInput` — зеркало L522–533
- [ ] тесты дрейна (реальный `MarkStore` in-memory + `FakeTransport`, зеркала имён из `MarkRepositoryUploadTest.kt`): metadata-first (кадр не постится, пока метаданные pending); все кадры приняты → флип обоих таргетов независимо; transient стоп до следующих марок; hard (400) на одной марке — следующая всё равно флипается; 413 — то же; missing file → марка pending, следующие идут; LAN offline / cloud ok — независимость; `attachPhotos` реквьюит кадры (флаги сброшены); гонка `attachPhotos` с mid-drain флипом → version-guard не даёт застрять новому кадру; combined outcome: metadata error + frames ok ≠ ok; `IsHardFrameFailureTests` (400 hard, 413 hard, 500/429/offline transient)
- [ ] `PhotoFrameCountsTests`: пусто → нули; пустой список кадров; оба флага → все кадры в обоих числителях; mid-drain → в total, не в числитель; смешанные строки асимметрично по таргетам
- [ ] прогнать тесты — зелёные до Task 6

### Task 6: App — PhotoModel + фабрика + orphan sweep на старте

**Files:**
- Create: `kolco24/App/PhotoModel.swift`
- Modify: `kolco24/App/AppModel.swift` (фабрика `makePhotoModel()`, sweep в `start()`)
- Modify: `kolco24/App/AppEnvironment.swift` (замыкания `writeFrame`/`deleteFrame` поверх `PhotoStorage`; `inMemory` — фейки)
- Create: `kolco24Tests/App/PhotoModelTests.swift`

- [ ] `@Observable @MainActor PhotoModel` (только `Observation`/`Foundation`): `start()` — fetch марок команды → `decidePhotoTarget(marks, now)` → `route: .camera(attach: true)` (markId/cpNumber/checkpointId цели) или `.picker`; состояние пикера (query, отфильтрованная легенда из `checkpointStore`, инлайн-ошибка) → выбор КП → свежий UUID → `.camera(attach: false)`
- [ ] `changeCheckpoint()` — переход attach → пикер (зеркало `onChangeCheckpoint`, `MainActivity.kt` L2089–2094): сброс markId цели, `attach = false`, показ пикера — кнопка «изменить» в шапке камеры
- [ ] буфер кадров: `addFrame(jpegData:)` — `firstSample` от инжектированного `sampleNow` на первом кадре, запись через инжектированный `writeFrame` вне main, путь в `frames`; `removeFrame(at:)` → `deleteFrame`; `discard()` — удалить только кадры этой сессии
- [ ] `commit()`: attach → `markStore.attachPhotos(markId, frames, firstSample.wallMs)`; новое → `makePhotoMark` (`expectedCount` = размер ростера выбранной команды, зеркало `MainActivity.kt` L2101/2110) → `markStore.upsert` + one-shot GPS `attachLocation` (паттерн `ScanModel.attachLocationForNewTake`); всё в unstructured `Task` с захватом сторов (§6); `closeRequested` для кавера
- [ ] orphan-guard ветки коммита (зеркало L2105/2130): race/team nil или КП не разрезолвился после mid-flow рефреша легенды → лог, марки нет, кадры осиротают (sweep подберёт) — без краша
- [ ] `AppModel.makePhotoModel() -> PhotoModel?` (nil без команды — вью зовёт `onChooseTeam`), `flushUploads` при закрытии кавера (существующий шов); sweep в `AppModel.start()`: fire-and-forget `Task` — `markStore.allIds()` → `photoStorage.sweepOrphanDirs`
- [ ] тесты (`in-memory` БД, фейковые `writeFrame`/`deleteFrame`/`sampleNow`/локация): attach-ветка при свежем взятии (кадры доклеены, `photosUploaded*` сброшены); picker-ветка — новая марка со всеми полями (`expectedCount` = ростер) + GPS-фикс догнал; `changeCheckpoint` из attach → пикер → марка с новым UUID; невалидный номер → ошибка, марки нет; orphan-guard коммита (nil team) — марки нет, без краша; discard удаляет только свои кадры; firstSample только с первого кадра; sweep сносит сироту и щадит живой каталог
- [ ] прогнать тесты — зелёные до Task 7

### Task 7: UI — камера и пикер (Photo/ + вьюхи + вход с FAB)

**Files:**
- Create: `kolco24/Photo/PhotoCameraController.swift`
- Create: `kolco24/PhotoCaptureView.swift`
- Create: `kolco24/PhotoNumberPickerView.swift`
- Modify: `kolco24/MarksView.swift` (FAB `onPhoto` → fullScreenCover)
- Modify: `kolco24.xcodeproj/project.pbxproj` (`INFOPLIST_KEY_NSCameraUsageDescription` в оба config)

- [ ] `PhotoCameraController` (`import AVFoundation`, только в `Photo/`): сессия на фоновой очереди, `AVCapturePhotoOutput`, `RotationCoordinator` (capture + preview углы), фронт/тыл, torch (тыл), guard от повторного захвата; колбэк с JPEG `Data`
- [ ] `PhotoCaptureView`: превью (`UIViewRepresentable` + `AVCaptureVideoPreviewLayer`), затвор (хаптика после записи кадра), лента миниатюр с удалением, «Готово (N)» (активна при ≥1 кадре и не в захвате), фронт/тыл/фонарик, шапка «КП N» / «изменить КП N» (attach); назад с кадрами → `confirmationDialog` «Удалить снимки?»; отказ камеры → заглушка + `openURL` в Настройки
- [ ] `PhotoNumberPickerView`: цифровое поле (`.numberPad`), живой фильтр (`filterCheckpointsByQuery`), строка `<cost>-<number>` + замок + описание (дизайн-токены), submit → `resolvePhotoCheckpoint`, инлайн-ошибка «КП с таким номером нет в легенде»
- [ ] `MarksView`: `@State photoModel: PhotoModel?`, FAB `onPhoto` → `makePhotoModel()` (nil → `onChooseTeam`), `fullScreenCover(item:onDismiss: flush)` с `NavigationStack` (пикер → камера по route модели); `#Preview` с in-memory окружением и фейковым провайдером кадров
- [ ] прогнать полный сьют + сборку — зелёные до Task 8 (камерные вьюхи юнитами не кроются — компиляция + превью; поведенческая логика уже в `PhotoModelTests`)

### Task 8: UI — фото-тайл, лайтбокс, нотис «КП по фото»

**Files:**
- Modify: `kolco24/MarksView.swift` (реальный `PhotoTileView`, нотис)
- Create: `kolco24/PhotoLightboxView.swift`

- [ ] `PhotoTileView` реальный: первый кадр (`thumbPathOf` с фолбэком на полный, `UIImage(contentsOfFile:)`; кэп-заглушка при нечитаемом файле), чип `<cost>-<number>`, глиф камеры только у `kind == .photo`, бейдж «+N» при `photoCount > 1`; тап (только при наличии кадров) → лайтбокс
- [ ] `PhotoLightboxView`: `fullScreenCover`, `TabView(.page)` по `lightboxPhotos`, счётчик k/N, чип КП страницы, `ShareLink` (URL кадра), drag-to-dismiss, чёрный фон, статус-бар скрыт
- [ ] нотис `PhotoReviewNotice` на «Отметках» из `photoReviewSummary` («N КП по фото (tokens) · P баллов», токены через `tokensLabel`-конвенцию, warning-стилистика по токенам)
- [ ] `MarksModel`: derived-поля для нотиса/лайтбокса (чистые фны уже в Core, тесты — дополнить `MarksModelTests` кейсом фото-марки: тайл с photoCount, summary непустой)
- [ ] прогнать полный сьют + сборку — зелёные до Task 9

### Task 9: Upload UI — секция «Фото»

**Files:**
- Modify: `kolco24/App/UploadModel.swift`
- Modify: `kolco24/UploadView.swift`
- Modify: `kolco24Tests/App/UploadModelTests.swift`

- [ ] `UploadModel`: секция «Отметки» переводится на `uploadCountsMetadata` (метаданные отдельно); новая подписка `photoFrameRows` → `foldPhotoFrameCounts` → счётчики «Фото»; receipt-лайны «Фото» по тем же правилам («Интернет» всегда, «Финиш» по `outcome != nil || uploaded > 0`), исход — общий по-таргетный (combined); `pendingLabel` ряда TeamView — по photo-aware `uploadCounts` (кадры учитываются)
- [ ] `UploadView`: секция «Фото» (скрыта при нуле кадров — как Android), счётчики `uploaded/total` в `Font.mono`, глифы done/error по токенам
- [ ] тесты: photo-марка с кадрами — «Отметки» показывает метаданные, «Фото» — кадры; mid-drain марка в total, не в числителе; `pendingLabel` учитывает неотправленные кадры; секция скрыта без фото
- [ ] прогнать тесты — зелёные до Task 10

### Task 10: Верификация приёмки

- [ ] все требования Overview: attach-в-окне и пикер-ветка, кадры на диске относительными путями, покадровый идемпотентный дрейн после метаданных на обе цели, тайлы/лайтбокс/нотис/секция «Фото», sweep
- [ ] grep-инварианты: `import AVFoundation` только под `Audio/` и `Photo/`; `import ImageIO` только под `Photo/`; `import CoreNFC`/`CoreLocation` — на местах; `Core/`/`Model/`/`App/`-модели без `UIKit`/`SwiftUI`/`GRDB`/AVFoundation/ImageIO-типов; `import GRDB` только под `Data/`; `Photo/` без GRDB
- [ ] полный тест-сьют: `** TEST SUCCEEDED **`
- [ ] сборка: `** BUILD SUCCEEDED **`

### Task 11: [Final] Документация

- [ ] секция «Photo layer (этап 7)» в `CLAUDE.md` (что где живёт, ловушки: относительные пути, frameIdOf-идемпотентность, poison-frame 400/413, RotationCoordinator вместо акселерометра, ImageIO-ориентация)
- [ ] обновить `docs/plans/android-port.md` (этап 7 — done) при наличии такой конвенции у прошлых этапов
- [ ] move this plan to `docs/plans/completed/`

## Post-Completion

**Живая проверка на устройстве** (камера в симуляторе не работает; бэкенд-эндпоинты не подняты):
- свежее NFC-взятие → «Фото» открывает камеру сразу («изменить»), кадры доклеиваются к взятию; без свежего — пикер → новая фото-марка, тайл с кадром, «+N», лайтбокс листается, шаринг работает;
- ориентация: снимки в landscape/upside-down читаемы без поворота (RotationCoordinator + ImageIO transform);
- фронталка: сохранённый кадр НЕ зеркален (номера КП читаемы);
- экран «Загрузка данных»: секция «Фото» с pending-кадрами, исход «ошибка»/«сервер недоступен» — спроектированный self-heal; когда бэкенд поднимут — тот же билд дошлёт (метаданные, затем кадры, флип счётчиков);
- удаление приложения/сирот: прервать съёмку до коммита → после холодного старта каталог сироты выметен.

**Решения, отложенные на будущие этапы:**
- этап 8: GPS-трек (свой дрейн поверх `drainUploadLoop`);
- этап 10: судейская проверка фото на сервере — вне клиента;
- BGTaskScheduler для фоновой досылки кадров — вне MVP.
