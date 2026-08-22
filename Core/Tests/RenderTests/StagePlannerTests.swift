import Testing
import Foundation
import Geometry
import Timeline
import Project
@testable import Render

@Test func theCardIsInsetAndCentredInsideTheOutput() {
    let plan = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1600, sourceHeight: 1000,
                                 style: .default)
    // The card keeps the SOURCE aspect ratio, is centred, and never touches the edge.
    #expect(plan.card.width / plan.card.height == 1.6)
    #expect(plan.card.x > 0 && plan.card.y > 0)
    #expect(plan.card.x + plan.card.width < 1920)
    #expect(plan.card.y + plan.card.height < 1080)
    #expect(abs((plan.card.x + plan.card.width / 2) - 960) < 0.5)
    #expect(abs((plan.card.y + plan.card.height / 2) - 540) < 0.5)
}

@Test func aTallerSourceIsFittedByHeightNotStretched() {
    let wide = StagePlanner.plan(outputWidth: 1920, outputHeight: 1080,
                                 sourceWidth: 1000, sourceHeight: 1600, style: .default)
    #expect(abs(wide.card.width / wide.card.height - 0.625) < 0.001)
    #expect(wide.card.height <= 1080)
}

@Test func theCornerRadiusIsClampedToHalfTheShorterSide() {
    let style = StageStyle(insetFraction: 0.04, cornerRadius: 10_000,
                           shadowRadius: 24, shadowOpacity: 0.35,
                           background: .solid(red: 0.1, green: 0.1, blue: 0.12))
    let plan = StagePlanner.plan(outputWidth: 400, outputHeight: 400,
                                 sourceWidth: 400, sourceHeight: 400, style: style)
    #expect(plan.cornerRadius == min(plan.card.width, plan.card.height) / 2)
}

// MARK: - decode validation
//
// Synthesised `Decodable` bypasses the validating memberwise `init`, so the JSON is
// hand-built — `init` traps before such a value could be encoded. `.dataCorrupted`
// specifically: a bare `precondition` would trap and synthesised `Codable` would not
// throw at all.

/// A `StageRect` with `width` hand-edited negative.
@Test func decodingAStageRectWithNegativeExtentThrows() throws {
    let json = Data("""
    {"x":0,"y":0,"width":-1,"height":10}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(StageRect.self, from: json)
        Issue.record("expected decoding a negative-width StageRect to throw")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted (StageRect's own validation), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
    }
}

/// `insetFraction` is hand-edited to `0.5`, the exact boundary `init` rejects
/// since the precondition requires strictly less than `0.5`.
@Test func decodingAStageStyleWithOutOfRangeInsetFractionThrows() throws {
    let json = Data("""
    {"background":{"solid":{"blue":0.11,"green":0.09,"red":0.09}},
     "cornerRadius":18,"insetFraction":0.5,"shadowOpacity":0.35,"shadowRadius":32}
    """.utf8)
    do {
        _ = try JSONDecoder().decode(StageStyle.self, from: json)
        Issue.record("expected decoding an out-of-range insetFraction StageStyle to throw")
    } catch let error as DecodingError {
        guard case .dataCorrupted = error else {
            Issue.record("expected .dataCorrupted (StageStyle's own validation), got \(error)")
            return
        }
    } catch {
        Issue.record("expected DecodingError, got \(error)")
    }
}

/// Codable round trip for `StageRect`.
@Test func stageRectRoundTrips() throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let rect = StageRect(x: 12.5, y: -3, width: 200, height: 150)
    let back = try JSONDecoder().decode(StageRect.self, from: try enc.encode(rect))
    #expect(back == rect)
    #expect(back.x == rect.x)
    #expect(back.y == rect.y)
    #expect(back.width == rect.width)
    #expect(back.height == rect.height)
}

/// Codable round trip for `StageStyle`, including the nested `StageBackground`.
@Test func stageStyleRoundTrips() throws {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    let style = StageStyle(insetFraction: 0.08, cornerRadius: 22, shadowRadius: 40,
                           shadowOpacity: 0.5, background: .solid(red: 0.2, green: 0.3, blue: 0.4))
    let back = try JSONDecoder().decode(StageStyle.self, from: try enc.encode(style))
    #expect(back == style)
    #expect(back.insetFraction == style.insetFraction)
    #expect(back.cornerRadius == style.cornerRadius)
    #expect(back.shadowRadius == style.shadowRadius)
    #expect(back.shadowOpacity == style.shadowOpacity)
    #expect(back.background == style.background)
}
