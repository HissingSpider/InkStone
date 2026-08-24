import CoreGraphics
import Foundation

/// OpenAI Chat Completions with an image part.
///
/// Chat Completions rather than the newer Responses API: it is the most widely
/// supported shape across models and proxies, and Inkstone makes exactly one
/// kind of request, so there is nothing to gain from the richer surface.
public struct OpenAIVLM: VLMProvider {

    public var model: String
    public var apiKey: String
    public var maxTokens: Int = 8_000
    public var endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!
    /// Set for Azure or a gateway that speaks the same protocol.
    public var organization: String?

    public var kind: VLMProviderKind { .openai }

    public init(model: String, apiKey: String) {
        self.model = model
        self.apiKey = apiKey
        // Escape hatch for Azure, a self-hosted gateway, or a test double.
        if let override = ProcessInfo.processInfo.environment["INKSTONE_OPENAI_ENDPOINT"],
           let url = URL(string: override) {
            self.endpoint = url
        }
    }

    public func transcribe(
        image: CGImage, pageNumber: Int, notebook: String,
        diagramCount: Int, visionDraft: String?
    ) async throws -> String {
        let payload = try ImageEncoding.vlmPayload(image)
        let instruction = VLMPrompt.user(
            pageNumber: pageNumber, notebook: notebook,
            hasDiagrams: diagramCount, visionDraft: visionDraft)

        var headers = ["authorization": "Bearer \(apiKey)"]
        if let organization { headers["openai-organization"] = organization }
        let transport = VLMTransport(endpoint: endpoint, headers: headers)

        // `detail: high` matters here. On the low-detail path the image is
        // downsampled hard before the model sees it, which is fine for "what is
        // in this picture" and useless for reading handwriting.
        let content: [[String: Any]] = [
            ["type": "text", "text": instruction],
            ["type": "image_url",
             "image_url": ["url": "data:image/jpeg;base64,\(payload)", "detail": "high"]],
        ]
        let messages: [[String: Any]] = [
            ["role": "system", "content": VLMPrompt.system],
            ["role": "user", "content": content],
        ]

        var body: [String: Any] = ["model": model, "messages": messages]
        body[Self.tokenLimitKey(for: model)] = maxTokens

        do {
            let data = try await transport.send(try JSONSerialization.data(withJSONObject: body))
            return try Self.extractText(from: data)
        } catch let error as InkstoneError {
            // Newer model families rejected `max_tokens` in favour of
            // `max_completion_tokens`, and which family a name belongs to is not
            // reliably knowable ahead of time. Rather than hard-code a list that
            // rots, let the API tell us and retry once.
            guard Self.mentionsTokenParameterSwap("\(error)") else { throw error }
            log.info("\(model) wants max_completion_tokens; retrying")

            var retry = body
            retry.removeValue(forKey: "max_tokens")
            retry.removeValue(forKey: "max_completion_tokens")
            retry["max_completion_tokens"] = maxTokens
            let data = try await transport.send(try JSONSerialization.data(withJSONObject: retry))
            return try Self.extractText(from: data)
        }
    }

    /// Best guess at the token-limit parameter this model wants. A wrong guess
    /// is recovered from by the adaptive retry above, so this only saves a round
    /// trip — it does not need to be exhaustive.
    static func tokenLimitKey(for model: String) -> String {
        let name = model.lowercased()
        let newerFamilies = ["o1", "o3", "o4", "gpt-5", "gpt-6"]
        let usesCompletionTokens = newerFamilies.contains { name.hasPrefix($0) }
        return usesCompletionTokens ? "max_completion_tokens" : "max_tokens"
    }

    static func mentionsTokenParameterSwap(_ message: String) -> Bool {
        message.contains("max_completion_tokens")
    }

    static func extractText(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InkstoneError.vlm("response was not JSON")
        }
        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            throw InkstoneError.vlm("response had no choices")
        }

        // A truncated answer is a silently half-transcribed page, which is worse
        // than a failure because it looks like a complete note.
        if let reason = first["finish_reason"] as? String, reason == "length" {
            throw InkstoneError.vlm(
                "model hit the token limit mid-page; raise maxTokens or lower renderDPI")
        }

        guard let message = first["message"] as? [String: Any] else {
            throw InkstoneError.vlm("choice had no message")
        }

        // `content` is a plain string on Chat Completions, but gateways and
        // newer shapes sometimes hand back the parts array instead.
        let text: String
        if let plain = message["content"] as? String {
            text = plain
        } else if let parts = message["content"] as? [[String: Any]] {
            text = parts.compactMap { $0["text"] as? String }.joined()
        } else {
            throw InkstoneError.vlm("model returned no text")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw InkstoneError.vlm("model returned no text") }
        return VLMTransport.stripCodeFence(trimmed)
    }
}

extension OpenAIVLM: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never render the key.
    ///
    /// Swift will happily print a struct's stored properties into a log line, a
    /// crash report or a test-failure message, and a secret that can describe
    /// itself will eventually describe itself somewhere it should not. This
    /// closes that off at the type.
    public var description: String { "OpenAIVLM(model: \(model), key: <redacted>)" }
    public var debugDescription: String { description }
}
