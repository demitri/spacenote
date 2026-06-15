import XCTest
@testable import SpaceNote

/// Model-layer tests for the Phase 5 changes (PLAN.md §9): NoteFill Codable
/// round-trips, v1-manifest backward compatibility, effective-alpha semantics,
/// and the opacity-slider boundary rule.
final class NoteModelTests: XCTestCase {

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    // MARK: NoteFill Codable

    func testNoteFillPresetRoundTrip() throws {
        for color in NoteColor.allCases {
            let fill = NoteFill.preset(color)
            let data = try encode(fill)
            XCTAssertEqual(String(data: data, encoding: .utf8), "\"\(color.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(NoteFill.self, from: data), fill)
        }
    }

    func testNoteFillCustomRoundTrip() throws {
        let fill = NoteFill.custom(rgb: 0x1A2B3C)
        let data = try encode(fill)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"#1A2B3C\"")
        XCTAssertEqual(try JSONDecoder().decode(NoteFill.self, from: data), fill)
    }

    func testNoteFillDecodesV1PresetString() throws {
        // v1 manifests stored a bare NoteColor raw value.
        let data = "\"green\"".data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(NoteFill.self, from: data), .preset(.green))
    }

    func testNoteFillRejectsGarbage() {
        for bad in ["\"#GGGGGG\"", "\"#12345\"", "\"chartreuse\""] {
            XCTAssertThrowsError(try JSONDecoder().decode(NoteFill.self,
                                                          from: bad.data(using: .utf8)!),
                                 "should reject \(bad)")
        }
    }

    // MARK: Note v1 backward compatibility

    func testNoteDecodesV1WithoutNewFields() throws {
        // A v1 note JSON: no translucentOpacity, no showsToolbar; color is a bare
        // preset string; isTranslucent present.
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "rtfFilename": "n.rtf",
          "color": "yellow",
          "frame": [[10, 20], [280, 220]],
          "isCollapsed": false,
          "isTranslucent": true,
          "isFloating": false
        }
        """
        let note = try JSONDecoder().decode(Note.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(note.color, .preset(.yellow))
        XCTAssertEqual(note.translucentOpacity, 0.8, accuracy: 1e-9)   // decode default
        XCTAssertFalse(note.showsToolbar)                              // decode default
        XCTAssertFalse(note.isDesktopLabel)                           // v3 field, decode default
        XCTAssertTrue(note.isTranslucent)
    }

    func testNoteRoundTripPreservesNewFields() throws {
        var note = Note(color: .custom(rgb: 0xABCDEF),
                        frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        note.showsToolbar = true
        note.isTranslucent = true
        note.translucentOpacity = 0.55
        note.isDesktopLabel = true
        let decoded = try JSONDecoder().decode(Note.self, from: try encode(note))
        XCTAssertEqual(decoded.color, .custom(rgb: 0xABCDEF))
        XCTAssertTrue(decoded.showsToolbar)
        XCTAssertTrue(decoded.isTranslucent)
        XCTAssertEqual(decoded.translucentOpacity, 0.55, accuracy: 1e-9)
        XCTAssertTrue(decoded.isDesktopLabel)
    }

    // MARK: effectiveAlpha + slider boundary

    func testEffectiveAlpha() {
        var note = Note(color: .preset(.blue), frame: .zero)
        note.translucentOpacity = 0.6
        note.isTranslucent = false
        XCTAssertEqual(note.effectiveAlpha, 1.0, accuracy: 1e-9)
        note.isTranslucent = true
        XCTAssertEqual(note.effectiveAlpha, 0.6, accuracy: 1e-9)
    }

    func testSliderBelow100SetsTranslucent() {
        var note = Note(color: .preset(.blue), frame: .zero)
        note.applyOpacitySlider(0.5)
        XCTAssertTrue(note.isTranslucent)
        XCTAssertEqual(note.translucentOpacity, 0.5, accuracy: 1e-9)
        XCTAssertEqual(note.effectiveAlpha, 0.5, accuracy: 1e-9)
    }

    func testSliderAt100ClearsTranslucentButPreservesValue() {
        var note = Note(color: .preset(.blue), frame: .zero)
        note.applyOpacitySlider(0.4)   // remember 0.4
        note.applyOpacitySlider(1.0)   // drag to opaque
        XCTAssertFalse(note.isTranslucent)
        XCTAssertEqual(note.translucentOpacity, 0.4, accuracy: 1e-9,
                       "remembered opacity must survive a trip to 100%")
        XCTAssertEqual(note.effectiveAlpha, 1.0, accuracy: 1e-9)
        // Re-enabling translucency lands on a visible value, never 1.0.
        note.isTranslucent = true
        XCTAssertEqual(note.effectiveAlpha, 0.4, accuracy: 1e-9)
    }

    func testSliderClampsToFloor() {
        var note = Note(color: .preset(.blue), frame: .zero)
        note.applyOpacitySlider(0.05)
        XCTAssertEqual(note.translucentOpacity, 0.25, accuracy: 1e-9)
        XCTAssertTrue(note.isTranslucent)
    }

    // MARK: Manifest

    func testManifestRoundTripV3() throws {
        let note = Note(color: .custom(rgb: 0x102030),
                        frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let manifest = Manifest(version: Manifest.currentVersion, notes: [note])
        let decoded = try JSONDecoder().decode(Manifest.self, from: try encode(manifest))
        XCTAssertEqual(decoded.version, 3)
        XCTAssertEqual(decoded.notes.count, 1)
        XCTAssertEqual(decoded.notes[0].color, .custom(rgb: 0x102030))
    }
}
