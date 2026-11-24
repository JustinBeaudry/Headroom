import Foundation

public struct HTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let body: Data?
    public let timeoutInterval: TimeInterval

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        timeoutInterval: TimeInterval = 15.0
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeoutInterval = timeoutInterval
    }
}

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public var isSuccess: Bool {
        (200...299).contains(statusCode)
    }

    public var isAuthFailure: Bool {
        statusCode == 401 || statusCode == 403
    }

    public func jsonObject() -> Any? {
        try? JSONSerialization.jsonObject(with: body)
    }
}

public enum HTTPClientError: Error, LocalizedError, Sendable {
    case invalidResponse
    case networkError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid HTTP response."
        case .networkError(let detail):
            return detail
        }
    }
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public final class URLSessionHTTPClient: HTTPClient, Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeoutInterval)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (k, v) in request.headers {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPClientError.invalidResponse
            }
            var normalizedHeaders: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let k = key as? String, let v = value as? String {
                    normalizedHeaders[k.lowercased()] = v
                }
            }
            return HTTPResponse(statusCode: http.statusCode, headers: normalizedHeaders, body: data)
        } catch let error as HTTPClientError {
            throw error
        } catch {
            throw HTTPClientError.networkError(error.localizedDescription)
        }
    }
}
