//
//  MapFileStorageTests.swift
//  kolco24Tests
//
//  I/O-тесты дисковой части адаптера `Map/MapFileStorage.swift` во временном
//  каталоге: схема `fileURL`, `exists`/`fileSize`/`delete` и атомарная установка
//  файла на место (`moveIntoPlace`) — как первичное «скачивание» и как замена
//  существующего файла при докачке. Сам сетевой `download` unit-тестами не
//  покрыт (device/integration, прецедент платформенных адаптеров).
//

import Foundation
import Testing
@testable import kolco24

struct MapFileStorageTests {

    // MARK: - Инфраструктура

    /// Свежий временный каталог-корень на каждый тест; удаляется в конце.
    private func withTempStorage(_ body: (MapFileStorage, URL) throws -> Void) rethrows {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("kolco24-maptest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try body(MapFileStorage(rootURL: root), root)
    }

    /// Создать временный исходный файл (имитация скачанного во temp) с заданным содержимым.
    private func makeTempSource(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kolco24-mapsrc-\(UUID().uuidString).tmp")
        try contents.write(to: url)
        return url
    }

    // MARK: - fileURL / exists / size

    @Test func fileURLFollowsMapsRaceScheme() throws {
        try withTempStorage { storage, root in
            let url = storage.fileURL(raceId: 42)
            #expect(url == root.appendingPathComponent("maps/42.mbtiles"))
            #expect(url.lastPathComponent == "42.mbtiles")
        }
    }

    @Test func existsAndSizeReflectDisk() throws {
        try withTempStorage { storage, _ in
            #expect(storage.exists(raceId: 7) == false)
            #expect(storage.fileSize(raceId: 7) == nil)

            let payload = Data(repeating: 0xAB, count: 1234)
            try storage.moveIntoPlace(from: try makeTempSource(payload), raceId: 7)

            #expect(storage.exists(raceId: 7) == true)
            #expect(storage.fileSize(raceId: 7) == 1234)
        }
    }

    // MARK: - delete

    @Test func deleteRemovesFileAndIsIdempotent() throws {
        try withTempStorage { storage, _ in
            try storage.moveIntoPlace(from: try makeTempSource(Data([1, 2, 3])), raceId: 3)
            #expect(storage.exists(raceId: 3) == true)

            storage.delete(raceId: 3)
            #expect(storage.exists(raceId: 3) == false)
            // Повторное удаление отсутствующего файла — no-op (не бросает).
            storage.delete(raceId: 3)
            #expect(storage.exists(raceId: 3) == false)
        }
    }

    // MARK: - moveIntoPlace (атомарная установка/замена)

    @Test func moveIntoPlaceCreatesMapsDirAndInstallsFile() throws {
        try withTempStorage { storage, _ in
            // Каталог maps/ ещё не существует — moveIntoPlace должен его создать.
            #expect(FileManager.default.fileExists(atPath: storage.mapsRoot.path) == false)

            let src = try makeTempSource(Data([0x10, 0x20]))
            try storage.moveIntoPlace(from: src, raceId: 5)

            #expect(storage.exists(raceId: 5) == true)
            // Источник перемещён (не остался на месте).
            #expect(FileManager.default.fileExists(atPath: src.path) == false)
        }
    }

    @Test func moveIntoPlaceReplacesExistingFile() throws {
        try withTempStorage { storage, _ in
            try storage.moveIntoPlace(from: try makeTempSource(Data(repeating: 0x01, count: 10)), raceId: 9)
            #expect(storage.fileSize(raceId: 9) == 10)

            // Повторное «скачивание» — замена поверх существующего файла.
            let newPayload = Data(repeating: 0x02, count: 25)
            try storage.moveIntoPlace(from: try makeTempSource(newPayload), raceId: 9)

            #expect(storage.exists(raceId: 9) == true)
            #expect(storage.fileSize(raceId: 9) == 25)
            let onDisk = try Data(contentsOf: storage.fileURL(raceId: 9))
            #expect(onDisk == newPayload)
        }
    }
}
