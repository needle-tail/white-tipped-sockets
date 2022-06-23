#if canImport(Network)
import XCTest
@testable import WhiteTipped
@testable import WTHelpers

final class WhiteTippedTests: XCTestCase {
    
    
    func testConnection() throws {
        Task {
        let socket = await WhiteTipped(headers: nil, urlRequest: nil, cookies: nil)
            await socket.connect(url: URL(string: "ws://192.168.1.177:8080")!, trustAll: true, certificates: nil)
        }
    }
}
#endif
