import PluginKitUI
import XCTest

final class FuzzyTests: XCTestCase {
    /// Queries that must match, or not (`nil`).
    func testMatching() {
        let cases: [(query: String, candidate: String, matches: Bool)] = [
            ("", "anything", true),
            ("dn", "Daily notes", true),
            ("DN", "daily notes", true),
            ("ete", "Été", true),
            ("ETE", "été à Paris", true),
            ("cafe", "Café crème", true),
            ("daily notes", "Daily-notes", true),
            ("xyz", "Daily notes", false),
            ("dn", "random", false),
            ("cab", "abc", false),
            ("abcd", "abc", false),
            ("notes", "", false),
        ]
        for (query, candidate, matches) in cases {
            XCTAssertEqual(Fuzzy.score(query, in: candidate) != nil, matches, "\(query) in \(candidate)")
        }
        XCTAssertEqual(Fuzzy.score("", in: "x"), 0)
    }

    /// Pairs where the first candidate must score higher than the second for the query.
    func testOrdering() {
        let cases: [(query: String, better: String, worse: String, why: String)] = [
            ("dn", "Daily notes", "Random addendum", "word starts"),
            ("da", "Daily", "Panda", "prefix"),
            ("n", "daily-notes", "dinner", "word start after -"),
            ("jd", "journal/daily", "jaded", "word start after /"),
            ("fb", "foo_bar", "fabric", "word start after _"),
            ("not", "notes", "nought", "consecutive"),
            ("note", "Note", "Notebook", "shorter"),
            ("rec", "Recipes", "Directory of records", "earlier"),
        ]
        for (query, better, worse, why) in cases {
            guard let high = Fuzzy.score(query, in: better), let low = Fuzzy.score(query, in: worse) else {
                XCTFail("\(query) should match \(better) and \(worse)")
                continue
            }
            XCTAssertGreaterThan(high, low, "\(query): \(better) before \(worse) (\(why))")
        }
    }

    func testRankDropsNonMatchesAndPutsTheBestFirst() {
        let ranked = Fuzzy.rank(["random", "Random addendum", "Daily notes"], query: "dn") { $0 }
        XCTAssertEqual(ranked, ["Daily notes", "Random addendum"])
    }

    func testRankKeepsTheOrderForAnEmptyQueryAndForTies() {
        let items = ["b", "a", "c"]
        XCTAssertEqual(Fuzzy.rank(items, query: "") { $0 }, items)
        XCTAssertEqual(Fuzzy.rank(items, query: "  ") { $0 }, items)

        let twins = [(id: 1, title: "Note"), (id: 2, title: "Note"), (id: 3, title: "note")]
        XCTAssertEqual(Fuzzy.rank(twins, query: "note") { $0.title }.map(\.id), [1, 2, 3])
    }
}
