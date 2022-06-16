import XCTest
@testable import WhiteTipped

final class WhiteTippedTests: XCTestCase {
    
    
    func testConnection() throws {
        Task {
        let socket = await WhiteTipped(headers: nil, urlRequest: nil, cookies: nil)
            await socket.connect(url: URL(string: "ws://192.168.1.177:8080")!)
            //Never Called
            await socket.fireAfterConnection()
        }
    }
}