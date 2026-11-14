import XCTest
@testable import ymd_menubar

final class StandaloneTests: XCTestCase {
    func testMissingKeyDoesNotAskForTerminal() {
        XCTAssertFalse(APIError.noKey.localizedDescription.contains("ymd serve"))
    }
}
