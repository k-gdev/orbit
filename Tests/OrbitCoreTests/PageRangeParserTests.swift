import Testing
@testable import OrbitCore

@Suite struct PageRangeParserTests {
    @Test func ranges() {
        #expect(PageRangeParser.parse("1-3, 5", pageCount: 10) == [1...3, 5...5])
        #expect(PageRangeParser.parse("4", pageCount: 10) == [4...4])
        #expect(PageRangeParser.parse("0-2", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("3-1", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("11", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("1-x", pageCount: 10) == nil)
    }

    @Test func spacesAndBounds() {
        #expect(PageRangeParser.parse(" 1 - 2 ,4 ", pageCount: 4) == [1...2, 4...4])
        #expect(PageRangeParser.parse("1-10", pageCount: 10) == [1...10])
        #expect(PageRangeParser.parse("1-11", pageCount: 10) == nil)
    }

    @Test func malformedItems() {
        #expect(PageRangeParser.parse("1,,3", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("1,", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("-3", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("1-2-3", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("   ", pageCount: 10) == nil)
        #expect(PageRangeParser.parse("2", pageCount: 0) == nil)
    }
}
