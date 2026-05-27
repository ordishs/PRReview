import Testing
import CommandSupport

@Test func toolResolverReturnsFirstExistingCandidate() {
    let resolved = ToolResolver.resolve("x", candidates: ["/nonexistent/x", "/bin/echo"])
    #expect(resolved == "/bin/echo")
}

@Test func toolResolverReturnsNilWhenNoneExist() {
    #expect(ToolResolver.resolve("x", candidates: ["/nope/a", "/nope/b"]) == nil)
}
