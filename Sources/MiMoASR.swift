import Foundation

/// 小米 MiMo-ASR：OpenAI 兼容的 chat/completions 端点，
/// 音频以 WAV base64 放在 input_audio 里，鉴权走 `api-key` 头。
enum MiMoASR {
    private static func makeRequest(wav: Data, apiKey: String, endpoint: URL,
                                    model: String, language: String, stream: Bool,
                                    auth: MiMoAuth) throws -> URLRequest {
        let content: [[String: Any]] = [[
            "type": "input_audio",
            "input_audio": ["data": "data:audio/wav;base64," + wav.base64EncodedString()],
        ]]
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": content]],
        ]
        if !language.isEmpty { body["asr_options"] = ["language": language] }
        if stream { body["stream"] = true }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        switch auth {
        case .apiKey:
            request.setValue(apiKey, forHTTPHeaderField: "api-key")
        case .bearer:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if stream { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 整段识别（非流式）
    static func transcribe(wav: Data, apiKey: String, endpoint: URL,
                           model: String, language: String,
                           auth: MiMoAuth) async throws -> String {
        let request = try makeRequest(wav: wav, apiKey: apiKey, endpoint: endpoint,
                                      model: model, language: language, stream: false, auth: auth)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "MiMo", code: -1, userInfo: [NSLocalizedDescriptionKey: "无 HTTP 响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "MiMo", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: ASRUtil.httpError(http.statusCode, data)])
        }
        guard let obj = ASRUtil.jsonObject(from: data),
              let text = ASRUtil.firstString(forKeys: ["content"], in: obj) else {
            let preview = String(decoding: data.prefix(300), as: UTF8.self)
            throw NSError(domain: "MiMo", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "未解析出识别文本：\(preview)"])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 整段上传 + SSE 边返回边出字（MiMo 不支持边录边传，只能流式输出）
    static func transcribeStreaming(wav: Data, apiKey: String, endpoint: URL,
                                    model: String, language: String,
                                    auth: MiMoAuth,
                                    onPartial: @escaping (String) -> Void) async throws -> String {
        let request = try makeRequest(wav: wav, apiKey: apiKey, endpoint: endpoint,
                                      model: model, language: language, stream: true, auth: auth)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "MiMo", code: -1, userInfo: [NSLocalizedDescriptionKey: "无 HTTP 响应"])
        }
        guard (200..<300).contains(http.statusCode) else {
            var errBody = Data()
            for try await byte in bytes {
                errBody.append(byte)
                if errBody.count > 4096 { break }
            }
            throw NSError(domain: "MiMo", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: ASRUtil.httpError(http.statusCode, errBody)])
        }

        var accumulated = ""
        var sawSSE = false
        var rawBody = Data()
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else {
                // 兼容服务端忽略 stream 直接回整段 JSON 的情况
                if !sawSSE {
                    rawBody.append(Data((line + "\n").utf8))
                    if rawBody.count > 1_000_000 { break }
                }
                continue
            }
            sawSSE = true
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = ASRUtil.jsonObject(from: data) else { continue }
            if let delta = deltaText(obj), !delta.isEmpty {
                accumulated += delta
                onPartial(accumulated)
            }
        }
        if !sawSSE, let obj = ASRUtil.jsonObject(from: rawBody),
           let text = ASRUtil.firstString(forKeys: ["content"], in: obj) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deltaText(_ object: Any) -> String? {
        guard let dict = object as? [String: Any],
              let choices = dict["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any] else { return nil }
        return delta["content"] as? String
    }
}
