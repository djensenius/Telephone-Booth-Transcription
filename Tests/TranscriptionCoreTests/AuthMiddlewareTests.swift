import Foundation
import Hummingbird
import Testing
@testable import TranscriptionCore

@Suite("AuthMiddleware parseBearer")
struct AuthMiddlewareParseTests {
    typealias Mid = AuthMiddleware<BasicRequestContext>

    @Test func parsesBearerCaseInsensitive() {
        #expect(Mid.parseBearer("Bearer abc") == "abc")
        #expect(Mid.parseBearer("bearer abc") == "abc")
        #expect(Mid.parseBearer("BEARER abc") == "abc")
    }

    @Test func rejectsNonBearerScheme() {
        #expect(Mid.parseBearer("Basic abc") == nil)
        #expect(Mid.parseBearer("Token abc") == nil)
    }

    @Test func returnsNilForMissingSpace() {
        #expect(Mid.parseBearer("Bearer") == nil)
    }

    @Test func trimsSurroundingWhitespace() {
        #expect(Mid.parseBearer("  Bearer   abc  ") == "abc")
    }

    @Test func returnsEmptyStringForBearerWithEmptyToken() {
        #expect(Mid.parseBearer("Bearer ") == "")
    }
}

// Minimal stub for the generic context parameter so the parseBearer test
// doesn't need a real RequestContext.
struct EmptyContextStub {}
