import Testing
@testable import UsageNotch

@Suite("Developer context parser")
struct DeveloperContextProviderTests {
    @Test func cleanTrackingBranch() {
        let state = DeveloperContextProvider.parseStatus("## main...origin/main\n")
        #expect(state.branch == "main")
        #expect(state.changedFiles == 0)
        #expect(state.ahead == 0)
        #expect(state.behind == 0)
    }

    @Test func changesAndDivergence() {
        let state = DeveloperContextProvider.parseStatus("""
        ## feature/cockpit...origin/feature/cockpit [ahead 2, behind 1]
         M Sources/App.swift
        ?? Sources/New.swift

        """)
        #expect(state.branch == "feature/cockpit")
        #expect(state.changedFiles == 2)
        #expect(state.ahead == 2)
        #expect(state.behind == 1)
    }

    @Test func unbornAndDetachedBranches() {
        #expect(DeveloperContextProvider.parseStatus("## No commits yet on main\n").branch == "main")
        #expect(DeveloperContextProvider.parseStatus(
            "## HEAD (no branch)\n", fallbackBranch: "release"
        ).branch == "release")
    }
}
