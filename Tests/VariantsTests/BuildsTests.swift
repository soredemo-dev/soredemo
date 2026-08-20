import Testing
@testable import Variants

/// **Replaced the module's placeholder test.** It asserted `VariantsModule.name == "Variants"`
/// — a tautology over a type that existed only to make the target compile, and green whether
/// or not the module did anything. `AspectVariantTests` is the module's real coverage; this
/// file keeps the target's presence check honest by pinning what the module actually vends.
@Test func variantsVendsTheThreeShapesTheRoadmapNames() {
    #expect(AspectVariant.all.map(\.name) == ["Landscape", "Portrait", "Square"])
}
