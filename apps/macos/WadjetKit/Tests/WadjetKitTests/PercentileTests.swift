import Testing
import WadjetKit

struct PercentileTests {
    @Test func twentyValues() {
        let a = Array(1...20).map(Double.init)
        #expect(a.percentile(50) == 10)
        #expect(a.percentile(95) == 19)
        #expect(a.percentile(100) == 20)
    }

    @Test func singleValue() {
        #expect([42.0].percentile(95) == 42)
    }

    @Test func unsorted() {
        #expect([300.0, 100].percentile(50) == 100)
        #expect([300.0, 100].percentile(95) == 300)
    }

    @Test func empty() {
        #expect([Double]().percentile(50) == nil)
    }
}
