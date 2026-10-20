import Testing
import WadjetKit

struct DragModifiersTests {
    // Proves what each key combination does to a drag: ⌘ alone stops
    // snapping, Control stops attaching, ⇧ alone constrains, and ⇧⌘ is a
    // chord that attaches a whole Annotation with snapping on and no
    // constraint. Only the chord attaches a whole Annotation; points attach
    // by default.
    @Test func eachCombination() {
        // keys, snaps, constrains, attaches points, attaches whole
        let rows: [(String, DragModifiers, Bool, Bool, Bool, Bool)] = [
            ("none", DragModifiers(), true, false, true, false),
            ("⌘", DragModifiers(command: true), false, false, true, false),
            ("⌃", DragModifiers(control: true), true, false, false, false),
            ("⇧", DragModifiers(shift: true), true, true, true, false),
            ("⇧⌘", DragModifiers(shift: true, command: true), true, false, true, true),
            ("⌃⇧⌘", DragModifiers(shift: true, command: true, control: true), true, false, false, false),
            ("⌃⌘", DragModifiers(command: true, control: true), false, false, false, false),
        ]
        for (keys, m, snaps, constrains, points, whole) in rows {
            #expect(m.snaps == snaps, "\(keys) snaps")
            #expect(m.constrains == constrains, "\(keys) constrains")
            #expect(m.attachesPoints == points, "\(keys) attaches points")
            #expect(m.attachesWhole == whole, "\(keys) attaches whole")
        }
    }
}
