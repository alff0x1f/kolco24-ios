//
//  PhotoPathsTests.swift
//  kolco24Tests
//
//  Зеркало `data/marks/PhotoPathsTest.kt` (12 кейсов) 1:1: round-trip с сохранением
//  порядка, nil/blank/битый JSON → `[]`, отбрасывание абсолютных/traversal/
//  неправильной формы путей, `frameIdOf` (валидный + defensive), `thumbPathOf`
//  (относительный / голое имя / остаётся под каталогом кадра).
//

import Testing
@testable import kolco24

struct PhotoPathsTests {

    @Test func roundTripPreservesValuesAndOrder() {
        let paths = [
            "marks/m1/a.jpg",
            "marks/m1/b.jpg",
            "marks/m1/c.jpg",
        ]

        let restored = PhotoPaths.decode(PhotoPaths.encode(paths))

        #expect(restored == paths)
    }

    @Test func roundTripEmptyList() {
        let restored = PhotoPaths.decode(PhotoPaths.encode([]))

        #expect(restored.isEmpty)
    }

    @Test func nullAndBlankDecodeToEmpty() {
        #expect(PhotoPaths.decode(nil).isEmpty)
        #expect(PhotoPaths.decode("").isEmpty)
        #expect(PhotoPaths.decode("   ").isEmpty)
    }

    @Test func malformedJsonDecodesToEmpty() {
        #expect(PhotoPaths.decode("not-json").isEmpty)
        #expect(PhotoPaths.decode("{\"key\":\"value\"}").isEmpty)
        #expect(PhotoPaths.decode("[1,2,3]").isEmpty)
    }

    @Test func absolutePathsAreDropped() {
        let restored = PhotoPaths.decode(
            PhotoPaths.encode(["/data/data/app/marks/m1/a.jpg", "marks/m1/b.jpg"])
        )

        #expect(restored == ["marks/m1/b.jpg"])
    }

    @Test func traversalPathsAreDropped() {
        let restored = PhotoPaths.decode(
            PhotoPaths.encode([
                "marks/../../etc/passwd",
                "marks/m1/../secret.jpg",
                "marks/m1/ok.jpg",
            ])
        )

        #expect(restored == ["marks/m1/ok.jpg"])
    }

    @Test func wrongShapeEntriesAreDropped() {
        let restored = PhotoPaths.decode(
            PhotoPaths.encode([
                "other/m1/a.jpg",   // неправильный корень
                "marks/m1/a.png",   // неправильное расширение
                "marks/m1",         // слишком мало сегментов
                "marks/m1/sub/a.jpg", // слишком много сегментов
                "marks//a.jpg",     // пустой сегмент
                "marks/m1/a.jpg",   // единственный валидный
            ])
        )

        #expect(restored == ["marks/m1/a.jpg"])
    }

    @Test func frameIdOfValidPathReturnsUuidStem() {
        #expect(
            PhotoPaths.frameIdOf("marks/m1/550e8400-e29b-41d4-a716-446655440000.jpg")
                == "550e8400-e29b-41d4-a716-446655440000"
        )
    }

    @Test func thumbPathOfRelativeFramePath() {
        #expect(
            PhotoPaths.thumbPathOf("marks/m1/550e8400-e29b-41d4-a716-446655440000.jpg")
                == "marks/m1/550e8400-e29b-41d4-a716-446655440000.thumb.jpg"
        )
    }

    @Test func thumbPathOfBareFileName() {
        // Место записи передаёт голое имя файла кадра (каталог уже разрезолвлен).
        #expect(PhotoPaths.thumbPathOf("a.jpg") == "a.thumb.jpg")
    }

    @Test func thumbPathOfStaysUnderTheFrameDirectory() {
        // Производный путь лишь переписывает расширение — валидированный безопасный путь кадра
        // никогда не даст thumb-путь, выходящий за marks/<markId>/ (на это опирается deletePhoto).
        #expect(PhotoPaths.isSafeRelativePhotoPath(PhotoPaths.thumbPathOf("marks/m1/a.jpg")))
    }

    @Test func frameIdOfDefensiveCases() {
        // Без расширения: срезается только хвостовой суффикс ".jpg" — имя без расширения
        // возвращается как есть, без падения.
        #expect(PhotoPaths.frameIdOf("marks/m1/noext") == "noext")
        // Вложенный путь: важен только последний сегмент.
        #expect(PhotoPaths.frameIdOf("marks/m1/sub/a.jpg") == "a")
        // Голое имя файла, без каталога вовсе.
        #expect(PhotoPaths.frameIdOf("a.jpg") == "a")
    }
}
