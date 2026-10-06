import Foundation
import CAetherCore

public protocol PromptOptimizing {
    func optimize(input: String, configuration: PromptConfiguration, apiKey: String) async throws -> String
}

public enum PromptClientError: LocalizedError, Equatable {
    case invalidURL, insecureURL, missingModel, missingRules, emptyInput, invalidKey
    case authentication, rateLimited, endpointUnavailable, serverUnavailable, httpStatus(Int)
    case redirected, invalidResponse, emptyResponse, incompleteResponse, refused, timedOut, network

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "请填写有效的 Base URL，不含用户名、密码、查询参数或片段。"
        case .insecureURL:
            return "远程 API 必须使用 HTTPS；只有本机回环地址允许 HTTP。"
        case .missingModel:
            return "请先在设置中填写服务商提供的模型名称。"
        case .missingRules:
            return "请先填写优化规则，或恢复内置规则。"
        case .emptyInput:
            return "请先输入要优化的提示词。"
        case .invalidKey:
            return "API Key 中包含空白或控制字符，请检查后重试。"
        case .authentication:
            return "API 认证失败，请检查 API Key 和模型访问权限。"
        case .rateLimited:
            return "服务商限制了请求，请检查 API 额度或稍后重试。"
        case .endpointUnavailable:
            return "未找到接口或模型，请检查 Base URL 和模型名称。"
        case .serverUnavailable:
            return "API 服务暂时不可用，请稍后重试。"
        case .httpStatus(let status):
            return "API 请求失败（HTTP \(status)），请检查接口设置。"
        case .redirected:
            return "API 地址发生跳转，已停止请求。请将 Base URL 更新为最终接口地址。"
        case .invalidResponse:
            return "服务商返回了无法识别的结果，请确认接口兼容 Chat Completions。"
        case .emptyResponse:
            return "模型未返回提示词，请检查模型设置后重试。"
        case .incompleteResponse:
            return "模型输出未完成，未保存为历史。请缩短输入或调整服务商的输出限制后重试。"
        case .refused:
            return "模型未提供优化结果，请调整输入或检查服务商限制后重试。"
        case .timedOut:
            return "请求超时，请检查网络或稍后重试。"
        case .network:
            return "无法连接 API，请检查网络和 Base URL。"
        }
    }
}

public final class PromptClient: PromptOptimizing {
    private let session: URLSession
    private let redirectDelegate = PromptRedirectBlocker()

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil
            configuration.timeoutIntervalForRequest = 90
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: configuration)
        }
    }

    public static func endpoint(for baseURL: String) throws -> URL {
        let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw PromptClientError.invalidURL
        }
        let path = try withPromptUTF8(host.lowercased()) { host in
            try withPromptUTF8(components.percentEncodedPath) { path in
                try promptCoreText(aether_prompt_endpoint(scheme == "http" ? 1 : scheme == "https" ? 2 : 0, host, path))
            }
        }
        components.scheme = scheme
        components.percentEncodedPath = path
        guard let url = components.url else { throw PromptClientError.invalidURL }
        return url
    }

    public func optimize(input: String, configuration: PromptConfiguration, apiKey: String) async throws -> String {
        try Task.checkCancellation()
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PromptClientError.emptyInput
        }
        let endpoint = try Self.endpoint(for: configuration.baseURL)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = configuration.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw PromptClientError.missingModel }
        guard !rules.isEmpty else { throw PromptClientError.missingRules }
        guard key.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
            throw PromptClientError.invalidKey
        }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try withPromptUTF8(model) { model in
            try withPromptUTF8(rules) { rules in
                try withPromptUTF8(input) { input in try promptCoreData(aether_prompt_request(model, rules, input)) }
            }
        }

        do {
            // Per-task delegate also blocks redirects when tests inject a custom URLSession.
            let (data, response) = try await session.data(for: request, delegate: redirectDelegate)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw PromptClientError.invalidResponse }
            let decoded = try data.withUnsafeBytes {
                try promptCoreData(aether_prompt_response(Int32(clamping: response.statusCode), AetherBytes(data: $0.bindMemory(to: UInt8.self).baseAddress, length: $0.count)), httpStatus: response.statusCode)
            }
            guard let raw = String(data: decoded, encoding: .utf8) else { throw PromptClientError.invalidResponse }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw PromptClientError.emptyResponse }
            return text
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PromptClientError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw PromptClientError.timedOut
        } catch {
            // Never surface a raw server response, request, key, or URLSession diagnostic.
            throw PromptClientError.network
        }
    }
}

final class PromptRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
