//
//  ExampleAppUITests.swift
//  ExampleAppUITests
//
//  Created by Alex Chase on 8/24/26.
//

import XCTest

final class ExampleAppUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testSourcesExposeGRPCProbe() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Sources"].tap()
        XCTAssertTrue(app.navigationBars["Sources"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Run gRPC Probe"].exists)
        let endpoint = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "grpcb.in:9001")
        ).firstMatch
        XCTAssertTrue(endpoint.exists)

        // Set this in the scheme's Test action environment to exercise the public endpoint.
        guard ProcessInfo.processInfo.environment["RUN_LIVE_GRPC_PROBE"] == "1" else { return }
        app.buttons["Run gRPC Probe"].tap()
        let recorded = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "trace recorded")
        ).firstMatch
        XCTAssertTrue(recorded.waitForExistence(timeout: 15))

        app.navigationBars["Sources"].buttons.firstMatch.tap()
        let trace = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "grpcbin.GRPCBin/Empty")
        ).firstMatch
        XCTAssertTrue(trace.waitForExistence(timeout: 3))
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
