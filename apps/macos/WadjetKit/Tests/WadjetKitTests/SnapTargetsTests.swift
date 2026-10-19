import Foundation
import Testing
import WadjetKit

struct SnapTargetsTests {
    @Test func windowsFiltersAndFlips() {
        let infos: [[String: Any]] = [
            ["kCGWindowLayer": 0, "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": 42,
             "kCGWindowBounds": CGRect(x: 100, y: 50, width: 400, height: 300).dictionaryRepresentation],
            ["kCGWindowLayer": 0, "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": 7,
             "kCGWindowBounds": CGRect(x: 0, y: 0, width: 400, height: 300).dictionaryRepresentation],
            ["kCGWindowLayer": 25, "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": 42,
             "kCGWindowBounds": CGRect(x: 0, y: 0, width: 400, height: 300).dictionaryRepresentation],
            ["kCGWindowLayer": 0, "kCGWindowAlpha": 0.0, "kCGWindowOwnerPID": 42,
             "kCGWindowBounds": CGRect(x: 0, y: 0, width: 400, height: 300).dictionaryRepresentation],
            ["kCGWindowLayer": 0, "kCGWindowAlpha": 1.0, "kCGWindowOwnerPID": 42,
             "kCGWindowBounds": CGRect(x: 0, y: 0, width: 30, height: 30).dictionaryRepresentation],
        ]
        #expect(SnapTarget.windows(infos, excludingOwner: 7, primaryHeight: 1000)
            == [.rect(CGRect(x: 100, y: 650, width: 400, height: 300))])
    }
}
