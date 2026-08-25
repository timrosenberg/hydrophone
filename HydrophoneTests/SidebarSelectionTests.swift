import Testing
@testable import Hydrophone

struct SidebarSelectionTests {
    @Test func simpleCasesRoundTripThroughRawValues() {
        let selections: [SidebarSelection] = [
            .home,
            .albums,
            .artists,
            .songs,
            .favorites,
            .composers
        ]

        for selection in selections {
            #expect(SidebarSelection(rawValue: selection.rawValue) == selection)
        }
    }
}
