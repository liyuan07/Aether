import Foundation
import XCTest
@testable import PromptFeature

final class PromptClientTests: XCTestCase {
    private var stub: PromptNetworkStub!
    private var session: URLSession!
    private var client: PromptClient!
    private var configuration: PromptConfiguration!

    override func setUpWithError() throws {
        stub = PromptNetworkStub()
        let host = "\(UUID().uuidString.lowercased()).invalid"
        PromptMockURLProtocol.install(stub, host: host)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PromptMockURLProtocol.self]
        session = URLSession(configuration: sessionConfiguration)
        client = PromptClient(session: session)
        configuration = PromptConfiguration(baseURL: "https://\(host)/provider/v1", model: "test-model", systemPrompt: "合成测试规则")
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        if let host = URL(string: configuration.baseURL)?.host { PromptMockURLProtocol.remove(host: host) }
    }

    func testEndpointNormalizationPreservesCustomProviderPrefixes() throws {
        for (input, expected) in [
            ("https://provider.example", "https://provider.example/v1/chat/completions"),
            ("https://provider.example/", "https://provider.example/v1/chat/completions"),
            (" https://provider.example/v1/\n", "https://provider.example/v1/chat/completions"),
            ("https://provider.example/api/compatible/v1", "https://provider.example/api/compatible/v1/chat/completions"),
            ("https://provider.example/v1/chat/completions/", "https://provider.example/v1/chat/completions"),
            ("http://localhost:1234/v1", "http://localhost:1234/v1/chat/completions"),
            ("http://127.0.0.2:8080", "http://127.0.0.2:8080/v1/chat/completions"),
            ("http://[::1]:8080/v1", "http://[::1]:8080/v1/chat/completions")
        ] {
            XCTAssertEqual(try PromptClient.endpoint(for: input).absoluteString, expected)
        }
    }

    func testRejectsUnsafeOrMalformedEndpoints() {
        for value in ["", "provider.example", "file:///tmp/fake", "https://", "https://user:pass@provider.example/v1",
                      "https://provider.example/v1?key=synthetic", "https://provider.example/v1#fragment",
                      "http://provider.example/v1", "http://localhost.example/v1", "http://127.0.0.1.example/v1",
                      "http://192.168.1.1:8080/v1", "https://provider.example:70000", "https://pro vider.example/v1"] {
            XCTAssertThrowsError(try PromptClient.endpoint(for: value))
        }
    }

    func testRequestPreservesOriginalAndUsesOnlyRequiredCompatibleFields() async throws {
        let original = "  合成输入\n保留格式  "
        stub.data = response(content: "  合成输出  ")
        let result = try await client.optimize(input: original, configuration: configuration, apiKey: "synthetic-test-key")
        XCTAssertEqual(result, "合成输出")
        let request = try XCTUnwrap(stub.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/provider/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: stub.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["model", "messages", "stream"])
        XCTAssertEqual(body["model"] as? String, "test-model")
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": "合成测试规则"], ["role": "user", "content": original]])
    }

    func testEmptyKeyOmitsAuthorizationHeader() async throws {
        stub.data = response(content: "合成输出")
        _ = try await client.optimize(input: "合成输入", configuration: configuration, apiKey: "")
        XCTAssertNil(try XCTUnwrap(stub.request).value(forHTTPHeaderField: "Authorization"))
    }

    func testArrayContentExtractsTextPartsWithoutReasoning() async throws {
        stub.data = Data("""
        {"choices":[{"message":{"content":[{"type":"text","text":"合成第一段"},{"type":"reasoning","text":"不可当成结果"},{"type":"output_text","text":"合成第二段"}]},"finish_reason":"stop"}]}
        """.utf8)
        let result = try await client.optimize(input: "合成输入", configuration: configuration, apiKey: "")
        XCTAssertEqual(result, "合成第一段\n合成第二段")
    }

    func testCompatibleResponseMayOmitFinishReason() async throws {
        stub.data = Data("{\"choices\":[{\"message\":{\"content\":\"合成输出\"}}]}".utf8)
        let result = try await client.optimize(input: "合成输入", configuration: configuration, apiKey: "")
        XCTAssertEqual(result, "合成输出")
    }

    func testHTTPFailuresUseLocalErrorsWithoutEchoingServerBody() async {
        for (status, expected) in [(401, PromptClientError.authentication), (403, .authentication),
                                   (429, .rateLimited), (500, .serverUnavailable), (404, .endpointUnavailable),
                                   (302, .redirected), (408, .timedOut), (400, .httpStatus(400))] {
            stub.status = status
            stub.data = Data("synthetic-private-key-or-prompt".utf8)
            await assertFailure(expected)
        }
    }

    func testTruncationEmptyAndMalformedResponsesAreNotAccepted() async {
        for (data, expected) in [
            (response(content: "不完整输出", reason: "length"), PromptClientError.incompleteResponse),
            (response(content: "过滤结果", reason: "content_filter"), .refused),
            (response(content: "", reason: "stop"), .emptyResponse),
            (response(content: "   \n", reason: "stop"), .emptyResponse),
            (response(content: "工具内容", reason: "tool_calls"), .incompleteResponse),
            (Data("{\"choices\":[]}".utf8), .invalidResponse),
            (Data("not JSON synthetic".utf8), .invalidResponse),
            (Data("{\"choices\":[{\"message\":{\"content\":null,\"refusal\":\"合成拒绝\"},\"finish_reason\":\"stop\"}]}".utf8), .refused)
        ] {
            stub.data = data
            await assertFailure(expected)
        }
    }

    func testMissingConfigurationAndInvalidInputNeverMakeRequest() async {
        await assertFailure(.emptyInput, input: "  \n")
        configuration.model = ""
        await assertFailure(.missingModel)
        configuration.model = "test-model"
        configuration.systemPrompt = "  "
        await assertFailure(.missingRules)
        configuration.systemPrompt = "合成规则"
        await assertFailure(.invalidKey, key: "synthetic\r\nInjected: value")
        XCTAssertNil(stub.request)
    }

    func testTimeoutAndCancellationRemainDistinct() async {
        stub.error = URLError(.timedOut)
        await assertFailure(.timedOut)
        stub.error = URLError(.cancelled)
        do {
            _ = try await client.optimize(input: "合成输入", configuration: configuration, apiKey: "")
            XCTFail("Expected cancellation")
        } catch is CancellationError { } catch { XCTFail("Expected cancellation type") }
    }

    func testRedirectDelegateNeverForwardsAuthorization() throws {
        var redirect = URLRequest(url: URL(string: "https://other.example/chat/completions")!)
        redirect.setValue("Bearer synthetic-key", forHTTPHeaderField: "Authorization")
        let response = HTTPURLResponse(url: URL(string: configuration.baseURL)!, statusCode: 307,
                                       httpVersion: nil, headerFields: nil)!
        let task = session.dataTask(with: URL(string: configuration.baseURL)!)
        var called = false
        PromptRedirectBlocker().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                           newRequest: redirect) { request in
            called = true
            XCTAssertNil(request)
        }
        XCTAssertTrue(called)
        task.cancel()
    }

    private func response(content: String, reason: String = "stop") -> Data {
        try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": reason]]])
    }

    private func assertFailure(_ expected: PromptClientError, input: String = "合成输入", key: String = "", file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client.optimize(input: input, configuration: configuration, apiKey: key)
            XCTFail("Expected failure", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PromptClientError, expected, file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("synthetic-private"), file: file, line: line)
        }
    }
}

private final class PromptNetworkStub {
    var data = Data()
    var status = 200
    var error: Error?
    var request: URLRequest?
    var body = Data()
}

private final class PromptMockURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var stubs: [String: PromptNetworkStub] = [:]

    static func install(_ stub: PromptNetworkStub, host: String) {
        lock.lock(); defer { lock.unlock() }
        stubs[host] = stub
    }

    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }
        stubs.removeValue(forKey: host)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let stub = request.url?.host.flatMap { Self.stubs[$0] }
        Self.lock.unlock()
        guard let stub else { return client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) ?? () }
        stub.request = request
        if let body = request.httpBody {
            stub.body = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                stub.body.append(contentsOf: bytes.prefix(count))
            }
        }
        if let error = stub.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}
