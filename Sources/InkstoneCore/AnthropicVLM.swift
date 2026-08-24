import CoreGraphics
import Foundation

/// Anthropic Messages with an image block.
public struct AnthropicVLM: VLMProvider {

    public var model: String
    public var apiKey: String
    public var maxTokens: Int = 8_000
    public var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public var apiVersion = "2023-06-01"

    public var kind: VLMProviderKind { .anthropic }

    public init(model: String, apiKey: String) {
        self.model = model
        self.apiKey = apiKey
    }

    public func transcribe(
        image: CGImage, pageNumber: Int, notebook: String,
        diagramCount: Int, visionDraft: String?
    ) async throws -> String {
        let payload = try ImageEncoding.vlmPayload(image)
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": VLMPrompt.system,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": payload]],
                    ["type": "text",
                     "text": VLMPrompt.user(pageNumber: pageNumber, notebook: notebook,
                                            hasDiagrams: diagramCount, visionDraft: visionDraft)],
                ],
            ]],
        ]

        let transport = VLMTransport(
            endpoint: endpoint,
            headers: ["x-api-key": apiKey, "anthropic-version": apiVersion])
        return try Self.extractText(from: try await transport.send(
            try JSONSerialization.data(withJSONObject: body)))
    }

    static func extractText(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InkstoneError.vlm("response was not JSON")
        }
        if let reason = object["stop_reason"] as? String, reason == "max_tokens" {
            throw InkstoneError.vlm(
                "model hit the token limit mid-page; raise maxTokens or lower renderDPI")
        }
        guard let content = object["content"] as? [[String: Any]] else {
            throw InkstoneError.vlm("response had no content block")
        }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw InkstoneError.vlm("model returned no text") }
        return VLMTransport.stripCodeFence(text)
    }
}

extension AnthropicVLM: CustomStringConvertible, CustomDebugStringConvertible {
    /// Never render the key.
    ///
    /// Swift will happily print a struct's stored properties into a log line, a
    /// crash report or a test-failure message, and a secret that can describe
    /// itself will eventually describe itself somewhere it should not. This
    /// closes that off at the type.
    public var description: String { "AnthropicVLM(model: \(model), key: <redacted>)" }
    public var debugDescription: String { description }
}
