import XCTest

/// Stages and captures the App Store screenshots.
///
/// Driven by `Assets/App Store/capture.sh`, which seeds the documents these
/// open and says where to write through `SCREENSHOT_DIR` and which language to
/// use through `SCREENSHOT_LANGUAGE`. Without them the tests skip, so they stay
/// out of the way of an ordinary test run.
final class AppStoreScreenshots: XCTestCase {
    /// What is set up over the picture before the capture.
    private enum Stage {
        /// Just the canvas, with the brush in hand.
        case canvas
        case layers
        /// The brush settings popover, with its list of tips open.
        case brushSettings
        /// The filters on the named layer, keyed by language.
        case filters(layer: [String: String])
        /// The top layer's points, handles and text, ready to edit.
        case points
        /// The mosaic brush in hand.
        case mosaic
    }

    private struct Shot {
        let name: String
        /// The file name without its extension, keyed by language.
        let document: [String: String]
        let stage: Stage
        /// Which of the picture's own swatches to paint with, if not black.
        var swatch: Int?
        /// Where to zoom in, as "zoom x y" with x and y fractions of the
        /// canvas, for the editor's debug-only screenshot hook.
        var focus: String?
    }

    private static let lakeside = ["en": "Lakeside Evening", "ja": "湖畔の夕暮れ"]
    private static let poppies = ["en": "Poppy Study", "ja": "ポピーの習作"]
    private static let poster = ["en": "Summer Festival", "ja": "夏まつり"]
    private static let passport = ["en": "Passport Scan", "ja": "パスポートのスキャン"]
    private static let plush = ["en": "Plush Portrait", "ja": "ぬいぐるみの肖像"]

    private static let shots = [
        Shot(name: "01-paint", document: lakeside, stage: .canvas, swatch: 0),
        // Close in on the plush's hand on the left, its cuff and pink tag.
        Shot(name: "02-layers", document: plush, stage: .layers, focus: "3.2 0.18 0.77"),
        Shot(name: "03-brushes", document: poppies, stage: .brushSettings, swatch: 0),
        Shot(name: "04-filters", document: lakeside, stage: .filters(layer: ["en": "Sky", "ja": "空"])),
        Shot(name: "05-design", document: poster, stage: .points),
        Shot(name: "06-mosaic", document: passport, stage: .mosaic),
    ]

    private var directory: URL!
    private var language = "en"
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("run through Assets/App Store/capture.sh")
        }
        directory = URL(fileURLWithPath: path)
        language = environment["SCREENSHOT_LANGUAGE"] ?? "en"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    @MainActor
    func testScreens() throws {
        // Every shot is in Dark Mode.
        defer { XCUIDevice.shared.appearance = .light }
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.appearance = .dark
        // The switch takes a moment to reach the system.
        Thread.sleep(forTimeInterval: 3)
        for shot in Self.shots {
            launch(focus: shot.focus)
            open(try XCTUnwrap(shot.document[language]))
            if let swatch = shot.swatch { pickSwatch(swatch) }
            try stage(shot.stage)
            // Let the panels finish animating in.
            Thread.sleep(forTimeInterval: 2)
            let file = directory.appendingPathComponent("\(shot.name).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
        }
    }

    // MARK: - Steps

    @MainActor
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    @MainActor
    private func launch(focus: String? = nil) {
        app = XCUIApplication()
        let locale = language == "ja" ? "ja_JP" : "en_US"
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        if let focus { app.launchArguments += ["-ScreenshotFocus", focus] }
        app.launch()
    }

    /// Opens a document from the app's folder in the document browser.
    @MainActor
    private func open(_ name: String) {
        let browse = app.buttons[language == "ja" ? "ブラウズ" : "Browse"].firstMatch
        if browse.waitForExistence(timeout: 15), !browse.isSelected {
            browse.tap()
        }

        // The cell, not its name: a tap on the name label does not open the file.
        let file = app.collectionViews.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "\(name) is not in the browser")
        // On iPhone the browser starts as a sheet that only shows its first row.
        if !file.isHittable {
            app.collectionViews.firstMatch.swipeUp()
        }
        file.tap()

        let canvas = app.descendants(matching: .any).matching(identifier: "canvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20), "\(name) never opened")
        Thread.sleep(forTimeInterval: 1)
    }

    @MainActor
    private func stage(_ stage: Stage) throws {
        switch stage {
        case .canvas:
            // The iPad opens with the layers in an inspector; put away, the
            // picture has the screen.
            if isPad { tap("toggleInspector") }
        case .layers:
            // The iPad already shows them in its inspector.
            if !isPad { tap("panel.layers") }
        case .brushSettings:
            let label = language == "ja" ? "ブラシ設定" : "Brush Settings"
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 5), "missing the brush settings button")
            button.tap()
            let tip = app.descendants(matching: .any).matching(identifier: "brushTip").firstMatch
            XCTAssertTrue(tip.waitForExistence(timeout: 5), "missing the tip picker")
            tip.tap()
            let marker = app.buttons[language == "ja" ? "マーカー" : "Marker"].firstMatch
            XCTAssertTrue(marker.waitForExistence(timeout: 5), "missing the list of tips")
        case .filters(let layer):
            if !isPad { tap("panel.layers") }
            tapInList("layer.\(try XCTUnwrap(layer[language]))")
            tapInList("layerFilters")
        case .points:
            tap("tool.nodes")
        case .mosaic:
            // The passport's details want the whole screen on an iPad too.
            if isPad { tap("toggleInspector") }
            tap("tool.censor")
            tap("censor.type")
            tap("censor.type.mosaic")
        }
    }

    /// Picks one of the picture's own swatches from the colour well, then
    /// puts the swatches away with a tap outside them, which only closes the
    /// popover: nothing is painted where it lands.
    @MainActor
    private func pickSwatch(_ index: Int) {
        tap("colorWell")
        let swatches = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '#'"))
        XCTAssertTrue(swatches.firstMatch.waitForExistence(timeout: 5), "missing the swatches")
        swatches.element(boundBy: index).tap()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        Thread.sleep(forTimeInterval: 1)
    }

    /// Taps a row of a panel's list, scrolling the list up to it first: the
    /// rows below the fold are not made until they are scrolled to.
    @MainActor
    private func tapInList(_ identifier: String) {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let list = app.collectionViews.firstMatch
        for _ in 0..<6 where list.exists && !(element.exists && element.isHittable) {
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.waitForExistence(timeout: 5), "missing \(identifier)")
        element.tap()
    }

    /// Taps the element with `identifier`, scrolling the tool carousel along
    /// first if the element is off the end of it.
    @MainActor
    private func tap(_ identifier: String) {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5), "missing \(identifier)")
        // Off the end of the carousel, a button has no point to tap, so
        // where it sits is checked rather than whether it can be hit, and
        // the carousel is turned towards it a little at a time.
        let carousel = app.scrollViews.containing(.button, identifier: "tool.brush").firstMatch
        for _ in 0..<6 {
            let middle = element.frame.midX
            if middle < 0 {
                carousel.swipeRight(velocity: .slow)
            } else if middle > app.frame.maxX {
                carousel.swipeLeft(velocity: .slow)
            } else {
                break
            }
        }
        element.tap()
    }
}
