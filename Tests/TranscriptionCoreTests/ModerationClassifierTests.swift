import Foundation
import Hummingbird
import Testing
@testable import TranscriptionCore

@Suite("ModerationClassifier JSON parsing")
struct ModerationClassifierParseTests {
    @Test func parsesPlainJSON() throws {
        let raw = """
        {
          "categories": {"hate": true, "harassment": false, "violence": false},
          "category_scores": {"hate": 0.92, "harassment": 0.04, "violence": 0.01}
        }
        """
        let r = try ModerationClassifier.parseClassifierJSON(raw)
        #expect(r.flagged == true)
        #expect(r.categories.hate == true)
        #expect(r.categories.harassment == false)
        #expect(abs(r.categoryScores.hate - 0.92) < 1e-9)
    }

    @Test func stripsMarkdownFences() throws {
        let raw = """
        ```json
        {"categories": {"hate": false}, "category_scores": {"hate": 0.01}}
        ```
        """
        let r = try ModerationClassifier.parseClassifierJSON(raw)
        #expect(r.flagged == false)
    }

    @Test func rejectsMalformedJSON() {
        let raw = "not json at all"
        #expect(throws: ModerationClassifier.ClassifierError.self) {
            try ModerationClassifier.parseClassifierJSON(raw)
        }
    }

    @Test func unknownCategoriesAreIgnoredSafely() throws {
        // Local LLMs occasionally hallucinate categories outside the schema.
        // We must ignore them rather than crash.
        let raw = """
        {"categories": {"made-up": true, "hate": true},
         "category_scores": {"made-up": 0.5, "hate": 0.9}}
        """
        let r = try ModerationClassifier.parseClassifierJSON(raw)
        #expect(r.categories.hate == true)
        #expect(r.flagged == true)
    }

    @Test func flaggedTrueIfAnyCategoryTrue() throws {
        let raw = """
        {"categories": {"hate": false, "harassment": false, "violence": true},
         "category_scores": {"hate": 0, "harassment": 0, "violence": 0.7}}
        """
        let r = try ModerationClassifier.parseClassifierJSON(raw)
        #expect(r.flagged == true)
    }

    @Test func flaggedFalseIfNoCategoryTrue() throws {
        let raw = """
        {"categories": {"hate": false, "harassment": false, "violence": false},
         "category_scores": {"hate": 0, "harassment": 0, "violence": 0}}
        """
        let r = try ModerationClassifier.parseClassifierJSON(raw)
        #expect(r.flagged == false)
    }

    @Test func parsesIllicitCategories() throws {
        let raw = """
        {"categories": {"illicit": true, "illicit/violent": true},
         "category_scores": {"illicit": 0.8, "illicit/violent": 0.6}}
        """
        let r = try ModerationClassifier.parseClassifierJSON(raw)
        #expect(r.categories.illicit == true)
        #expect(r.categories.illicitViolent == true)
        #expect(r.flagged == true)
    }
}

@Suite("ModerationRoute input parsing")
struct ModerationRouteInputTests {
    typealias Route = ModerationRoute<BasicRequestContext>

    @Test func parsesStringInput() {
        let body = ByteBufferAdapter.make(#"{"input":"hello world"}"#)
        let inputs = Route.parseInputs(body: body)
        #expect(inputs == ["hello world"])
    }

    @Test func parsesArrayInput() {
        let body = ByteBufferAdapter.make(#"{"input":["a","b","c"]}"#)
        let inputs = Route.parseInputs(body: body)
        #expect(inputs == ["a", "b", "c"])
    }

    @Test func emptyForMissingInput() {
        let body = ByteBufferAdapter.make(#"{"model":"x"}"#)
        #expect(Route.parseInputs(body: body).isEmpty)
    }

    @Test func emptyForMalformed() {
        let body = ByteBufferAdapter.make("not-json")
        #expect(Route.parseInputs(body: body).isEmpty)
    }
}

@Suite("ModelExtractor")
struct ModelExtractorTests {
    @Test func extractsModelFromMultipart() {
        let boundary = "----TestBoundary"
        let contentType = "multipart/form-data; boundary=\(boundary)"
        let body = "--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large\r\n--\(boundary)--\r\n"
        let buf = ByteBufferAdapter.make(body)
        #expect(ModelExtractor.extractModelFromMultipart(buf, contentType: contentType) == "whisper-large")
    }

    @Test func extractsModelFromJSON() {
        let buf = ByteBufferAdapter.make(#"{"model":"omni-moderation-latest","input":"x"}"#)
        #expect(ModelExtractor.extractModelFromJSON(buf) == "omni-moderation-latest")
    }

    @Test func returnsNilForMissingModel() {
        let buf = ByteBufferAdapter.make(#"{"input":"x"}"#)
        #expect(ModelExtractor.extractModelFromJSON(buf) == nil)
    }
}

import NIOCore
enum ByteBufferAdapter {
    static func make(_ string: String) -> ByteBuffer {
        ByteBuffer(bytes: Array(string.utf8))
    }
}
