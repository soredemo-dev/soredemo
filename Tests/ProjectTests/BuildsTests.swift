import Testing
@testable import Project

@Test func projectModuleBuilds() {
    #expect(ProjectModule.name == "Project")
}
