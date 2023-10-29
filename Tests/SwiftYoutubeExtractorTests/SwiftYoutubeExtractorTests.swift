import XCTest
@testable import SwiftYoutubeExtractor

final class SwiftYoutubeExtractorTests: XCTestCase {
    func test() async throws {
        let formats = try await YoutubeExtractor().formats(for: "dQw4w9WgXcQ")
        
        print(formats)
        
        XCTAssertGreaterThan(formats.count, 0)
    }
}
