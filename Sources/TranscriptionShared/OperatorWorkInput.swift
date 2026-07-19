import Foundation

/// Envelope delivered by the Operator status WebSocket when local work is ready.
public struct OperatorWorkEnvelope: Sendable, Equatable, Decodable {
    public var kind: String
    public var messageId: String
    public var needs: [OperatorJob.Kind]

    public init(kind: String = "work", messageId: String, needs: [OperatorJob.Kind]) {
        self.kind = kind
        self.messageId = messageId
        self.needs = needs
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case messageId
        case needs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? container.decode(String.self, forKey: .kind)) ?? ""
        messageId = (try? container.decode(String.self, forKey: .messageId)) ?? ""
        let rawNeeds = (try? container.decode([String].self, forKey: .needs)) ?? []
        needs = rawNeeds.compactMap(OperatorJob.Kind.init(rawValue:))
    }

    public static func decodeWork(from data: Data) throws -> OperatorWorkEnvelope? {
        let envelope = try JSONDecoder().decode(OperatorWorkEnvelope.self, from: data)
        guard envelope.kind == "work", !envelope.messageId.isEmpty, !envelope.needs.isEmpty else {
            return nil
        }
        return envelope
    }
}

/// Inputs fetched from `GET /v1/worker/messages/{id}/work`.
public struct OperatorWorkInput: Sendable, Equatable, Decodable {
    public struct Audio: Sendable, Equatable, Decodable {
        public var url: String
        public var sha256: String
        public var durationMs: Int?
        public var contentType: String?
        public var filename: String?

        public init(url: String, sha256: String, durationMs: Int? = nil,
                    contentType: String? = nil, filename: String? = nil) {
            self.url = url
            self.sha256 = sha256
            self.durationMs = durationMs
            self.contentType = contentType
            self.filename = filename
        }
    }

    public struct Transcription: Sendable, Equatable, Decodable {
        public var id: String
        public var text: String
        public var language: String?
        public var model: String?
        public var translationStatus: String?
        public var translatedText: String?
        public var moderationText: String?

        public init(id: String, text: String, language: String? = nil, model: String? = nil,
                    translationStatus: String? = nil, translatedText: String? = nil,
                    moderationText: String? = nil) {
            self.id = id
            self.text = text
            self.language = language
            self.model = model
            self.translationStatus = translationStatus
            self.translatedText = translatedText
            self.moderationText = moderationText
        }
    }

    public var id: String
    public var status: String
    public var audio: Audio?
    public var transcription: Transcription?

    public init(id: String, status: String, audio: Audio? = nil, transcription: Transcription? = nil) {
        self.id = id
        self.status = status
        self.audio = audio
        self.transcription = transcription
    }

    public func makeJob(for need: OperatorJob.Kind) -> OperatorJob? {
        switch need {
        case .transcription:
            guard let audio, !audio.url.isEmpty, !audio.sha256.isEmpty else { return nil }
            return OperatorJob(
                id: id,
                leaseToken: "",
                kind: .transcription,
                payload: .transcription(.init(
                    audioURL: audio.url,
                    sha256: audio.sha256,
                    durationMs: audio.durationMs,
                    model: nil,
                    language: transcription?.language,
                    contentType: audio.contentType,
                    filename: audio.filename
                ))
            )
        case .translation:
            guard let transcription, !transcription.text.isEmpty else { return nil }
            return OperatorJob(
                id: id,
                leaseToken: "",
                kind: .translation,
                payload: .translation(.init(input: transcription.text, sourceLanguage: transcription.language))
            )
        case .moderation:
            guard let transcription,
                  let input = transcription.moderationText?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !input.isEmpty else { return nil }
            return OperatorJob(id: id, leaseToken: "", kind: .moderation,
                               payload: .moderation(.init(input: input)))
        }
    }
}
