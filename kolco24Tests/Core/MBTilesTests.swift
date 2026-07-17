//
//  MBTilesTests.swift
//  kolco24Tests
//
//  Свежие тесты чистой математики MBTiles (зеркала нет — новый код). TMS y-flip
//  на границах (z=0, максимальный y) и парсинг `metadata` never-throw (полный/
//  частичный набор, мусор в bounds, пустой словарь).
//

import Testing
@testable import kolco24

struct MBTilesTests {

    // MARK: - TMS y-flip

    @Test func tmsRow_zeroZoom_zeroY() {
        // z=0: единственный валидный y == 0 → 0.
        #expect(tmsRow(z: 0, y: 0) == 0)
    }

    @Test func tmsRow_typicalZoom() {
        // z=15, y=10: 2^15 − 1 − 10 == 32767 − 10 == 32757.
        #expect(tmsRow(z: 15, y: 10) == 32757)
    }

    @Test func tmsRow_maxY_flipsToZero() {
        // Максимальный y на z=15 == 2^15 − 1 == 32767 → 0.
        #expect(tmsRow(z: 15, y: 32767) == 0)
    }

    @Test func tmsRow_isInvolution() {
        // Флип — инволюция: дважды применённый возвращает исходный y.
        let z = 12
        let y = 1234
        #expect(tmsRow(z: z, y: tmsRow(z: z, y: y)) == y)
    }

    // MARK: - metadata

    @Test func metadata_fullValidSet() {
        let raw = [
            "bounds": "37.1,55.2,37.9,55.9",
            "center": "37.5,55.55,12",
            "minzoom": "8",
            "maxzoom": "15",
            "format": "png",
        ]
        let meta = parseMBTilesMetadata(raw)
        #expect(meta.bounds?.w == 37.1)
        #expect(meta.bounds?.s == 55.2)
        #expect(meta.bounds?.e == 37.9)
        #expect(meta.bounds?.n == 55.9)
        #expect(meta.center?.lon == 37.5)
        #expect(meta.center?.lat == 55.55)
        #expect(meta.minZoom == 8)
        #expect(meta.maxZoom == 15)
    }

    @Test func metadata_partialZoomsOnly() {
        let meta = parseMBTilesMetadata(["minzoom": "10", "maxzoom": "16"])
        #expect(meta.bounds == nil)
        #expect(meta.center == nil)
        #expect(meta.minZoom == 10)
        #expect(meta.maxZoom == 16)
    }

    @Test func metadata_boundsWrongComponentCount_nil() {
        // Не 4 компонента → bounds nil.
        let meta = parseMBTilesMetadata(["bounds": "37.1,55.2,37.9"])
        #expect(meta.bounds == nil)
    }

    @Test func metadata_boundsNotNumbers_nil() {
        let meta = parseMBTilesMetadata(["bounds": "a,b,c,d"])
        #expect(meta.bounds == nil)
    }

    @Test func metadata_emptyDict_allNil() {
        let meta = parseMBTilesMetadata([:])
        #expect(meta == MBTilesMetadata())
        #expect(meta.bounds == nil)
        #expect(meta.center == nil)
        #expect(meta.minZoom == nil)
        #expect(meta.maxZoom == nil)
    }

    @Test func metadata_garbageZoom_nil() {
        let meta = parseMBTilesMetadata(["minzoom": "abc", "maxzoom": "15.5"])
        #expect(meta.minZoom == nil)
        #expect(meta.maxZoom == nil)  // "15.5" не целое → nil
    }
}
