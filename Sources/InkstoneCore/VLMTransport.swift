import Foundation

/// Which vision model service escalated pages go to.
public enum VLMProviderKind: String, Codable, Sendable, CaseIterable {
    case openai
    case anthropic

    public var defaultModel: String {
        switch self {
        case .openai: return "gpt-4o"
        case .anthropic: return "claude-opus-5"
        }
    }

    public var defaultKeyEnvVar: String {
        switch self {
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        }
    }
}

/// Transcribes one page image into markdown.
public protocol VLMProvider: Sendable {
    var model: String { get }
    var kind: VLMProviderKind { get }

    func transcribe(
        image: CGImage, pageNumber: Int, notebook: String,
        diagramCount: Int, visionDraft: String?
    ) async throws -> String
}

import CoreGraphics

/// Retrying JSON-over-HTTPS, shared by every provider.
///
/// Split out so the two clients differ only in the shape of their request and
/// response, which is the only thing that actually differs between them.
struct VLMTransport: Sendable {

    var endpoint: URL
    var headers: [String: String]
    /// Attempts per page, including the first. Retries cover 429 and 5xx only —
    /// any other 4xx is a bad key or our own bug, and retrying it just wastes
    /// time and money.
    var maxAttempts = 4
    var timeout: TimeInterval = 120

    func send(_ body: Data) async throws -> Data {
        var lastError: InkstoneError = .vlm("no attempt was made")

        for attempt in 1...maxAttempts {
            var request = URLRequest(url: endpoint, timeoutInterval: timeout)
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }

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

    /// Pulls the human-readable message out of either provider's error body.
    /// Both nest it under `error.message`, so one reader covers both.
    static func errorMessage(_ data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String
        else { return String(data: data.prefix(400), encoding: .utf8) ?? "unreadable body" }
        return message
    }

    /// Models sometimes wrap a whole transcription in a fence despite being told
    /// not to. Unwrap it rather than letting it corrupt the note.
    static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```") else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 2 else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum VLM {

    /// Builds the configured provider, or nil when escalation is off or the key
    /// is absent. A missing key is a configuration state, not an error: the
    /// pipeline falls back to flagging pages for review.
    public static func make(
        config: InkstoneConfig,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (any VLMProvider)? {
        guard config.resolvedEscalationMode != .off else { return nil }

        let kind = config.resolvedProvider
        let variable = config.resolvedKeyEnvVar
        guard let key = environment[variable], !key.isEmpty else {
            log.warn("cloud escalation is on but \(variable) is unset")
            return nil
        }

        let model = config.resolvedModel
        switch kind {
        case .openai: return OpenAIVLM(model: model, apiKey: key)
        case .anthropic: return AnthropicVLM(model: model, apiKey: key)
        }
    }
}
