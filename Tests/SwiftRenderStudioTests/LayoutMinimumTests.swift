import AppKit
import SwiftUI
import XCTest
@testable import SwiftRenderStudio

/// Window layout: no column may demand more height than a laptop window has.
@MainActor
final class LayoutMinimumTests: XCTestCase {
    func testEmptyStateMessageDoesNotInflateTheColumnMinimum() {
        let view = StudioEmptyState(title: "No Comments Yet", symbol: "text.bubble",
                                    message: "Press C to comment at the playhead, or R to mark a region on the frame.")
        let host = NSHostingController(rootView: view)
        // Measured at a column's minimum width, as the split view does.
        let narrow = host.sizeThatFits(in: CGSize(width: 1, height: 0))
        XCTAssertLessThan(narrow.height, 300, "a char-per-line wrap made the window content ~1020 pt tall at minimum")
    }
}
