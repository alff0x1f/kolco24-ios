//
//  MapUrlTests.swift
//  kolco24Tests
//
//  Зеркало `data/map/MapUrlTest.kt` + iOS-only https-гейт абсолютного URL.
//

import Testing
@testable import kolco24

struct MapUrlTests {

    private let base = "https://kolco24.ru"

    @Test func nullAndBlankAreNoMap() {
        #expect(resolveMapUrl(nil, baseURL: base) == nil)
        #expect(resolveMapUrl("", baseURL: base) == nil)
        #expect(resolveMapUrl("  ", baseURL: base) == nil)
    }

    @Test func absoluteHttpsUrlIsKeptAsIs() {
        #expect(resolveMapUrl("https://cdn.example.com/r8", baseURL: base) == "https://cdn.example.com/r8")
    }

    @Test func absoluteNonHttpsUrlIsNoMap() {
        #expect(resolveMapUrl("http://cdn.example.com/r8.mbtiles", baseURL: base) == nil)
        #expect(resolveMapUrl("ftp://cdn.example.com/r8", baseURL: base) == nil)
        #expect(resolveMapUrl("not-a-url", baseURL: base) == nil)
    }

    @Test func rootRelativePathResolvesAgainstBaseHost() {
        #expect(resolveMapUrl("/media/maps/8.mbtiles", baseURL: base) == "https://kolco24.ru/media/maps/8.mbtiles")
        #expect(resolveMapUrl("/media/maps/8.mbtiles", baseURL: base + "/") == "https://kolco24.ru/media/maps/8.mbtiles")
    }

    @Test func rootRelativePathDropsBasePath() {
        #expect(resolveMapUrl("/media/maps/8.mbtiles", baseURL: "https://kolco24.ru/api/")
                == "https://kolco24.ru/media/maps/8.mbtiles")
    }

    @Test func lanBaseKeepsSchemeAndPort() {
        #expect(resolveMapUrl("/media/maps/8.mbtiles", baseURL: "http://192.168.1.10:8000")
                == "http://192.168.1.10:8000/media/maps/8.mbtiles")
    }

    @Test func pathsThatCouldEscapeTheHostAreRejected() {
        #expect(resolveMapUrl("//evil.com/8.mbtiles", baseURL: base) == nil)
        #expect(resolveMapUrl("/\\evil.com/8.mbtiles", baseURL: base) == nil)
        #expect(resolveMapUrl("/\t/evil.com/8.mbtiles", baseURL: base) == nil)
        #expect(resolveMapUrl("/\n/evil.com/8.mbtiles", baseURL: base) == nil)
        #expect(resolveMapUrl("/media/maps/a b.mbtiles", baseURL: base) == nil)
        #expect(resolveMapUrl("/media/\u{0000}8.mbtiles", baseURL: base) == nil)
    }

    @Test func encodedSlashesStayOnBaseHost() {
        #expect(resolveMapUrl("/%2F%2Fevil.com/8.mbtiles", baseURL: base)
                == "https://kolco24.ru/%2F%2Fevil.com/8.mbtiles")
        #expect(resolveMapUrl("/%5Cevil.com/8.mbtiles", baseURL: base)
                == "https://kolco24.ru/%5Cevil.com/8.mbtiles")
    }

    @Test func invalidBaseIsNoMap() {
        #expect(resolveMapUrl("/media/maps/8.mbtiles", baseURL: "not a url") == nil)
    }
}
