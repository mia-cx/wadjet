import Testing
import WadjetKit

struct IslandRuleTests {
    // Proves the live toolbar ends once its Tool is disarmed with no Annotations
    // left, and stays while either remains.
    @Test(arguments: [
        (true, false, true), // a Tool armed on an empty screen
        (false, true, true), // disarmed, Annotations left: the collapsed island with its count
        (false, false, false), // disarmed and empty, or the last Annotation went unarmed: dismissed
    ])
    func liveToolbar(toolArmed: Bool, hasAnnotations: Bool, keeps: Bool) {
        #expect(IslandRule.keepsLiveToolbar(toolArmed: toolArmed, hasAnnotations: hasAnnotations) == keeps)
    }

    // Proves the island shows for exactly one of its reasons, and not for none.
    @Test(arguments: [
        (true, false, false, true), // toolbar open
        (false, true, false, true), // Annotations on screen
        (false, false, true, true), // a Recording with its island option on
        (false, false, false, false), // nothing needs it
    ])
    func island(toolbarOpen: Bool, hasAnnotations: Bool, recordingIsland: Bool, shows: Bool) {
        #expect(IslandRule.showsIsland(toolbarOpen: toolbarOpen, hasAnnotations: hasAnnotations,
                                       recordingIsland: recordingIsland) == shows)
    }
}
