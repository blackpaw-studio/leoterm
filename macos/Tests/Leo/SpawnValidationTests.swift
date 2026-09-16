import Testing
@testable import Ghostty

struct SpawnValidationTests {
    @Test(arguments: [
        ("alpha", nil), ("-alpha", "Name cannot begin with -"),
        ("two words", "Name may only contain letters, numbers, ., _, and -"),
        ("alpha/one", "Name may only contain letters, numbers, ., _, and -")
    ]) func nameRules(value: String, expected: String?) {
        #expect(SpawnValidation.name(value) == expected)
    }

    @Test func templateAndRepositoryAreRequired() {
        #expect(SpawnValidation.spawn(template: "", repo: "/repo", name: nil, pathExists: { _ in true }) == "Template is required")
        #expect(SpawnValidation.spawn(template: "swift", repo: "/missing", name: nil, pathExists: { _ in false }) == "Choose an existing repository")
        #expect(SpawnValidation.spawn(template: "swift", repo: "/repo", name: "ok", pathExists: { _ in true }) == nil)
    }

    @Test(arguments: [
        ("", "Name is required"), ("same", "Name is unchanged"),
        ("two words", "Name cannot contain whitespace or /"), ("a/b", "Name cannot contain whitespace or /"),
        ("new-name", nil)
    ]) func renameRules(value: String, expected: String?) {
        #expect(SpawnValidation.rename(value, current: "same") == expected)
    }
}
