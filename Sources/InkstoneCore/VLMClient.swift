import CoreGraphics
import Foundation

/// Minimal Anthropic Messages client for escalated pages.
///
/// Hand-rolled rather than pulled from a package: the pipeline makes exactly one
/// shape of request, and a dependency-free build means `swift build` works on a
/// machine with no network and no package cache.
public struct VLMClient: Sendable {

    public var model: String
    public var apiKey: String
    public var maxTokens: Int = 8_000
    public var endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public var apiVersion = "2023-06-01"
    /// Attempts per page, including the first. Retries cover 429 and 5xx only.
    public var maxAttempts = 4
    public var timeout: TimeInterval = 120

    public init(model: String, apiKey: String) {
        self.model = model
        self.apiKey = apiKey
    }

    /// Builds a client from config, or nil when escalation is off or the key is
    /// absent. A missing key is a configuration state, not an error: the
    /// pipeline falls back to flagging pages for review.
    public static func make(config: InkstoneConfig,
                            environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> VLMClient? {
        guard config.cloudEscalationEnabled else { return nil }
        guard let key = environment[config.apiKeyEnvVar], !key.isEmpty else {
            log.warn("cloud escalation enabled but \(config.apiKeyEnvVar) is unset")
            return nil
        }
        return VLMClient(model: config.vlmModel, apiKey: key)
    }

    /// Transcribes one page image, returning the model's markdown.
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

        let data = try await send(JSONSerialization.data(withJSONObject: body))
        return try Self.extractText(from: data)
    }

    // MARK: Transport

    private func send(_ body: Data) async throws -> Data {
        var lastError: InkstoneError = .vlm("no attempt was made")

        for attempt in 1...maxAttempts {
            var request = URLRequest(url: endpoint, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw InkstoneError.vlm("non-HTTP response")
                }
                switch http.statusCode {
                case 200:
                    return data
                case 429, 500...599:
                    let retryAfter = (http.value(forHTTPHeaderField: "retry-after")
                        .flatMap(Double.init)) ?? Self.backoff(attempt: attempt)
                    lastError = .vlm("HTTP \(http.statusCode): \(Self.errorMessage(data))")
                    if attempt < maxAttempts {
                        log.warn("VLM \(http.statusCode), retrying in \(Int(retryAfter))s "
                                 + "(attempt \(attempt)/\(maxAttempts))")
                        try await Task.sleep(nanoseconds: UInt64(retryAfter * 1_000_000_000))
                        continue
                    }
                default:
                    // 4xx other than rate limiting is our bug or a bad key;
                    // retrying only wastes time and money.
                    throw InkstoneError.vlm("HTTP \(http.statusCode): \(Self.errorMessage(data))")
                }
            } catch let error as InkstoneError {
                throw error
            } catch {
                lastError = .vlm(error.localizedDescription)
                if attempt < maxAttempts {
                    try await Task.sleep(
                        nanoseconds: UInt64(Self.backoff(attempt: attempt) * 1_000_000_000))
                    continue
                }
            }
        }
        throw lastError
    }

    /// Exponential backoff with a deterministic jitter ladder, capped at 30s.
    static func backoff(attempt: Int) -> Double {
        min(30, pow(2, Double(attempt))) + Double(attempt % 3) * 0.37
    }

    static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return String(data: data.prefix(400), encoding: .utf8) ?? "unreadable body" }
        return message
    }

    static func extractText(from data: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InkstoneError.vlm("response was not JSON")
        }
        guard let content = object["content"] as? [[String: Any]] else {
            throw InkstoneError.vlm("response had no content block")
        }
        let text = content
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        guard !text.isEmpty else { throw InkstoneError.vlm("model returned no text") }
        return Self.stripCodeFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Models sometimes wrap the whole transcription in a fence despite being
    /// told not to. Unwrap it rather than letting it corrupt the note.
    static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```") else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
