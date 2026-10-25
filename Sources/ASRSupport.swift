import Foundation

// MARK: - 供应商与模式

enum ASRProvider: String, CaseIterable, Identifiable {
    case volcengine
    case qwen
    case mimo

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .volcengine: return "火山引擎 SeedASR"
        case .qwen: return "阿里 Qwen-ASR"
        case .mimo: return "小米 MiMo-ASR"
        }
    }

    /// 是否支持边录边发（真流式传输）
    var supportsRealtimeAudio: Bool {
        switch self {
        case .volcengine, .qwen: return true
        case .mimo: return false   // MiMo 需要整段音频，只支持边返回边出字
        }
    }
}

enum ASRMode: String, CaseIterable, Identifiable {
    case streaming   // 流式：边说边出字（MiMo 为整段上传后边返回边出字）
    case file        // 非流式：录完整段，松手后一次性出字

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .streaming: return "流式（边说边出字）"
        case .file: return "非流式（松手后一次性出字）"
        }
    }
}

// MARK: - 接口预设

/// Qwen 区域预设：国内站 / 国际站（新加坡）/ 自定义
enum QwenPreset: String, CaseIterable, Identifiable {
    case cn
    case intl
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cn: return "国内站（北京）"
        case .intl: return "国际站（新加坡）"
        case .custom: return "自定义"
        }
    }

    var realtimeURL: String {
        switch self {
        case .cn:
            return "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        case .intl:
            return "wss://ap-southeast-1.maas.qwencloudapi.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime"
        case .custom:
            return ""
        }
    }

    var httpURL: String {
        switch self {
        case .cn:
            return "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        case .intl:
            return "https://ap-southeast-1.maas.qwencloudapi.com/api/v1/services/aigc/multimodal-generation/generation"
        case .custom:
            return ""
        }
    }
}

/// MiMo 预设：按量付费 / Token Plan 三个区域 / 自定义
enum MiMoPreset: String, CaseIterable, Identifiable {
    case payAsYouGo
    case tokenPlanCN
    case tokenPlanSGP
    case tokenPlanAMS
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .payAsYouGo: return "按量付费（api.xiaomimimo.com）"
        case .tokenPlanCN: return "Token Plan 中国"
        case .tokenPlanSGP: return "Token Plan 新加坡"
        case .tokenPlanAMS: return "Token Plan 欧洲"
        case .custom: return "自定义"
        }
    }

    var url: String {
        switch self {
        case .payAsYouGo: return "https://api.xiaomimimo.com/v1/chat/completions"
        case .tokenPlanCN: return "https://token-plan-cn.xiaomimimo.com/v1/chat/completions"
        case .tokenPlanSGP: return "https://token-plan-sgp.xiaomimimo.com/v1/chat/completions"
        case .tokenPlanAMS: return "https://token-plan-ams.xiaomimimo.com/v1/chat/completions"
        case .custom: return ""
        }
    }
}

/// MiMo 鉴权头：官方文档用 api-key，部分 Token Plan 工具链要求 Bearer
enum MiMoAuth: String, CaseIterable, Identifiable {
    case apiKey
    case bearer

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .apiKey: return "api-key 头"
        case .bearer: return "Authorization: Bearer"
        }
    }
}

// MARK: - 通用工具

enum ASRUtil {
    /// 16-bit 单声道 PCM 包成标准 WAV
    static func wav(fromPCM16 pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        let byteRate = sampleRate * 2
        d.append(contentsOf: Array("RIFF".utf8))
        var riffSize = UInt32(36 + pcm.count).littleEndian
        d.append(Data(bytes: &riffSize, count: 4))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        var fmtSize = UInt32(16).littleEndian
        d.append(Data(bytes: &fmtSize, count: 4))
        var audioFormat = UInt16(1).littleEndian
        d.append(Data(bytes: &audioFormat, count: 2))
        var channels = UInt16(1).littleEndian
        d.append(Data(bytes: &channels, count: 2))
        var rate = UInt32(sampleRate).littleEndian
        d.append(Data(bytes: &rate, count: 4))
        var br = UInt32(byteRate).littleEndian
        d.append(Data(bytes: &br, count: 4))
        var blockAlign = UInt16(2).littleEndian
        d.append(Data(bytes: &blockAlign, count: 2))
        var bits = UInt16(16).littleEndian
        d.append(Data(bytes: &bits, count: 2))
        d.append(contentsOf: Array("data".utf8))
        var dataSize = UInt32(pcm.count).littleEndian
        d.append(Data(bytes: &dataSize, count: 4))
        d.append(pcm)
        return d
    }

    /// 线性插值重采样（Int16 单声道）
    static func resample(_ data: Data, from sr: Double, to target: Double) -> Data {
        guard abs(sr - target) > 1, data.count >= 4 else { return data }
        let inCount = data.count / 2
        let outCount = max(1, Int(Double(inCount) * target / sr))
        var out = Data(count: outCount * 2)
        let ratio = sr / target
        data.withUnsafeBytes { r in
            let src = r.bindMemory(to: Int16.self)
            out.withUnsafeMutableBytes { r in
                let dst = r.bindMemory(to: Int16.self)
                for i in 0..<outCount {
                    dst[i] = src[min(Int(Double(i) * ratio), inCount - 1)]
                }
            }
        }
        return out
    }

    /// 在任意嵌套 JSON 里按字段名找第一个非空字符串（兼容各家不同响应结构）
    static func firstString(forKeys keys: Set<String>, in object: Any) -> String? {
        if let dict = object as? [String: Any] {
            for key in keys {
                if let s = dict[key] as? String,
                   !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return s
                }
            }
            for value in dict.values {
                if let found = firstString(forKeys: keys, in: value) { return found }
            }
        } else if let arr = object as? [Any] {
            for value in arr {
                if let found = firstString(forKeys: keys, in: value) { return found }
            }
        }
        return nil
    }

    static func jsonObject(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    /// 把 HTTP 错误整理成一行可读文本
    static func httpError(_ status: Int, _ body: Data) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        return "HTTP \(status): \(text.prefix(300))"
    }
}

// MARK: - 设置读写

struct ASRSettings {
    private static let d = UserDefaults.standard

    static var provider: ASRProvider {
        get { ASRProvider(rawValue: d.string(forKey: "ASRProvider") ?? "") ?? .volcengine }
        set { d.set(newValue.rawValue, forKey: "ASRProvider") }
    }

    static var mode: ASRMode {
        get { ASRMode(rawValue: d.string(forKey: "ASRMode") ?? "") ?? .streaming }
        set { d.set(newValue.rawValue, forKey: "ASRMode") }
    }

    static var language: String {
        get { d.string(forKey: "ASRLanguage") ?? "" }
        set { d.set(newValue, forKey: "ASRLanguage") }
    }

    static var qwenAPIKey: String {
        get { d.string(forKey: "QwenAPIKey") ?? "" }
        set { d.set(newValue, forKey: "QwenAPIKey") }
    }

    static var qwenPreset: QwenPreset {
        get { QwenPreset(rawValue: d.string(forKey: "QwenPreset") ?? "") ?? .cn }
        set { d.set(newValue.rawValue, forKey: "QwenPreset") }
    }

    static var qwenRealtimeURL: String {
        get { d.string(forKey: "QwenRealtimeURL") ?? "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime" }
        set { d.set(newValue, forKey: "QwenRealtimeURL") }
    }

    static var qwenHTTPURL: String {
        get { d.string(forKey: "QwenHTTPURL") ?? "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation" }
        set { d.set(newValue, forKey: "QwenHTTPURL") }
    }

    static var qwenModel: String {
        get { d.string(forKey: "QwenModel") ?? "qwen3-asr-flash" }
        set { d.set(newValue, forKey: "QwenModel") }
    }

    static var mimoAPIKey: String {
        get { d.string(forKey: "MiMoAPIKey") ?? "" }
        set { d.set(newValue, forKey: "MiMoAPIKey") }
    }

    static var mimoPreset: MiMoPreset {
        get { MiMoPreset(rawValue: d.string(forKey: "MiMoPreset") ?? "") ?? .payAsYouGo }
        set { d.set(newValue.rawValue, forKey: "MiMoPreset") }
    }

    static var mimoAuth: MiMoAuth {
        get { MiMoAuth(rawValue: d.string(forKey: "MiMoAuth") ?? "") ?? .apiKey }
        set { d.set(newValue.rawValue, forKey: "MiMoAuth") }
    }

    static var mimoURL: String {
        get { d.string(forKey: "MiMoURL") ?? "https://api.xiaomimimo.com/v1/chat/completions" }
        set { d.set(newValue, forKey: "MiMoURL") }
    }

    static var mimoModel: String {
        get { d.string(forKey: "MiMoModel") ?? "mimo-v2.5-asr" }
        set { d.set(newValue, forKey: "MiMoModel") }
    }

    static func apiKey(for provider: ASRProvider) -> String {
        switch provider {
        case .volcengine: return UserDefaults.standard.string(forKey: "VolcengineAPIKey") ?? ""
        case .qwen: return qwenAPIKey
        case .mimo: return mimoAPIKey
        }
    }
}
