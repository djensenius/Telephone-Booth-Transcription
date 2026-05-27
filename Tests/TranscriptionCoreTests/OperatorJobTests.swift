import Foundation
import Testing
@testable import TranscriptionCore

@Suite("OperatorJob wire format")
struct OperatorJobTests {
    @Test func decodeTranscription() throws {
        let json = """
        {"id":"job-1","leaseToken":"L1","kind":"transcription",
         "transcription":{"audioUrl":"https://x/a.flac","sha256":"abc",
                          "durationMs":1500,"model":"whisper","language":"en"}}
        """.data(using: .utf8)!
        let job = try OperatorJob.decode(from: json)
        #expect(job.id == "job-1")
        #expect(job.leaseToken == "L1")
        #expect(job.kind == .transcription)
        if case .transcription(let p) = job.payload {
            #expect(p.audioURL == "https://x/a.flac")
            #expect(p.sha256 == "abc")
            #expect(p.durationMs == 1500)
        } else {
            Issue.record("expected transcription payload")
        }
    }

    @Test func decodeTranslation() throws {
        let json = """
        {"id":"j2","leaseToken":"L2","kind":"translation",
         "translation":{"input":"Hola mundo","sourceLanguage":"es"}}
        """.data(using: .utf8)!
        let job = try OperatorJob.decode(from: json)
        if case .translation(let p) = job.payload {
            #expect(p.input == "Hola mundo")
            #expect(p.sourceLanguage == "es")
        } else { Issue.record("expected translation payload") }
    }

    @Test func decodeModeration() throws {
        let json = """
        {"id":"j3","leaseToken":"L3","kind":"moderation",
         "moderation":{"input":"please be nice"}}
        """.data(using: .utf8)!
        let job = try OperatorJob.decode(from: json)
        if case .moderation(let p) = job.payload {
            #expect(p.input == "please be nice")
        } else { Issue.record("expected moderation payload") }
    }

    @Test func decodeRejectsMalformed() throws {
        let cases: [String] = [
            #"{"id":"x"}"#,
            #"{"id":"","leaseToken":"L","kind":"moderation","moderation":{"input":"x"}}"#,
            #"{"id":"j","leaseToken":"L","kind":"transcription","transcription":{}}"#,
            #"{"id":"j","leaseToken":"L","kind":"bogus"}"#
        ]
        for c in cases {
            #expect(throws: OperatorJob.DecodeError.self) {
                _ = try OperatorJob.decode(from: c.data(using: .utf8)!)
            }
        }
    }

    @Test func encodeTranscriptionResult() throws {
        let result = OperatorJobResult.transcription(text: "hello", language: "en", model: "whisper")
        let data = try result.encode(leaseToken: "T")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["leaseToken"] as? String == "T")
        #expect(obj?["text"] as? String == "hello")
        #expect(obj?["language"] as? String == "en")
        #expect(obj?["model"] as? String == "whisper")
    }

    @Test func encodeModerationResult() throws {
        let result = OperatorJobResult.moderation(flagged: true, recommendation: "block",
                                                  maxScore: 0.9, model: "mod-1")
        let data = try result.encode(leaseToken: "T")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["flagged"] as? Bool == true)
        #expect(obj?["recommendation"] as? String == "block")
        #expect(obj?["maxScore"] as? Double == 0.9)
    }

    @Test func encodeTranslationResult() throws {
        let result = OperatorJobResult.translation(translatedText: "hi", sourceLanguage: "es",
                                                   targetLanguage: "en", model: nil)
        let data = try result.encode(leaseToken: "T")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["translatedText"] as? String == "hi")
        #expect(obj?["targetLanguage"] as? String == "en")
        #expect(obj?["sourceLanguage"] as? String == "es")
        #expect(obj?["model"] == nil)
    }

    @Test func encodeError() throws {
        let err = OperatorJobError(code: "audio_too_large", message: "exceeded 100 MiB")
        let data = try err.encode(leaseToken: "T")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(obj?["errorCode"] as? String == "audio_too_large")
        #expect(obj?["errorMessage"] as? String == "exceeded 100 MiB")
        #expect(obj?["leaseToken"] as? String == "T")
    }
}
