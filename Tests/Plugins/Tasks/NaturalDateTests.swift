import XCTest
@testable import TasksPlugin

final class NaturalDateTests: XCTestCase {
    /// A Monday.
    private let today = "2026-10-19"

    private func first(_ query: String, _ language: String = "en") -> String? {
        NaturalDate.suggestions(for: query, today: today, language: language).first
    }

    func testEmptyQueryOffersTodayTomorrowAndNextWeek() {
        XCTAssertEqual(NaturalDate.suggestions(for: "", today: today), ["2026-10-19", "2026-10-20", "2026-10-26"])
    }

    func testWordsAndTheirStarts() {
        XCTAssertEqual(first("today"), "2026-10-19")
        XCTAssertEqual(first("tod"), "2026-10-19")
        XCTAssertEqual(first("tom"), "2026-10-20")
        XCTAssertEqual(first("Tomorrow"), "2026-10-20")
        XCTAssertEqual(first("yesterday"), "2026-10-18")
        XCTAssertEqual(first("next week"), "2026-10-26")
        XCTAssertEqual(first("next month"), "2026-11-01")
        XCTAssertEqual(first("end of month"), "2026-10-31")
        XCTAssertEqual(first("this weekend"), "2026-10-24")
        XCTAssertEqual(first("demain", "fr"), "2026-10-20")
        XCTAssertEqual(first("aujourd'hui", "fr"), "2026-10-19")
        XCTAssertEqual(first("après-demain", "fr"), "2026-10-21")
        XCTAssertEqual(first("tomorrow", "fr"), "2026-10-20", "English is understood in every language")
        XCTAssertNil(first("demain"), "French only for a French user")
    }

    func testWeekdaysAreTheNextOne() {
        XCTAssertEqual(first("fri"), "2026-10-23")
        XCTAssertEqual(first("wednesday"), "2026-10-21")
        // Today is a Monday: "monday" is next week's.
        XCTAssertEqual(first("monday"), "2026-10-26")
        XCTAssertEqual(first("vendredi", "fr"), "2026-10-23")
        XCTAssertEqual(first("lun", "fr"), "2026-10-26")
    }

    func testDayAndMonth() {
        XCTAssertEqual(first("21oct"), "2026-10-21")
        XCTAssertEqual(first("21 oct"), "2026-10-21")
        XCTAssertEqual(first("oct 21"), "2026-10-21")
        XCTAssertEqual(first("october 21st"), "2026-10-21")
        XCTAssertEqual(first("21 octobre", "fr"), "2026-10-21")
        XCTAssertEqual(first("1er mai", "fr"), "2027-05-01")
        XCTAssertEqual(first("3 février", "fr"), "2027-02-03")
        XCTAssertEqual(first("21 oct 2028"), "2028-10-21")
        // Passed this year: next year's.
        XCTAssertEqual(first("1 jan"), "2027-01-01")
        XCTAssertEqual(first("19 oct"), "2026-10-19")
        // A month written in part offers each month it can be.
        XCTAssertEqual(NaturalDate.suggestions(for: "4 ju", today: today), ["2027-06-04", "2027-07-04"])
        XCTAssertEqual(NaturalDate.suggestions(for: "30 feb", today: today), [])
    }

    func testNumbers() {
        XCTAssertEqual(first("21"), "2026-10-21")
        XCTAssertEqual(first("5"), "2026-11-05")
        XCTAssertEqual(first("21/10"), "2026-10-21")
        XCTAssertEqual(first("10/21"), "2026-10-21")
        XCTAssertEqual(first("3/11"), "2026-11-03")
        XCTAssertEqual(first("21.10.2027"), "2027-10-21")
        XCTAssertEqual(first("2026-12-25"), "2026-12-25")
        XCTAssertEqual(first("2026-02-30"), nil)
    }

    func testCountedDays() {
        XCTAssertEqual(first("in 3 days"), "2026-10-22")
        XCTAssertEqual(first("3d"), "2026-10-22")
        XCTAssertEqual(first("2 weeks"), "2026-11-02")
        XCTAssertEqual(first("in 1 month"), "2026-11-19")
        XCTAssertEqual(first("+3"), "2026-10-22")
        XCTAssertEqual(first("dans 2 jours", "fr"), "2026-10-21")
        XCTAssertEqual(first("1 semaine", "fr"), "2026-10-26")
    }

    func testTheUsersLanguage() {
        // German, Spanish, Italian, Dutch.
        XCTAssertEqual(first("morgen", "de"), "2026-10-20")
        XCTAssertEqual(first("übermorgen", "de"), "2026-10-21")
        XCTAssertEqual(first("freitag", "de"), "2026-10-23")
        XCTAssertEqual(first("21. Oktober", "de"), "2026-10-21")
        XCTAssertEqual(first("in 2 Wochen", "de"), "2026-11-02")
        XCTAssertEqual(first("mañana", "es"), "2026-10-20")
        XCTAssertEqual(first("manana", "es"), "2026-10-20")
        XCTAssertEqual(first("viernes", "es"), "2026-10-23")
        XCTAssertEqual(first("21 de octubre", "es"), "2026-10-21")
        XCTAssertEqual(first("en 3 días", "es"), "2026-10-22")
        XCTAssertEqual(first("domani", "it"), "2026-10-20")
        XCTAssertEqual(first("venerdì", "it"), "2026-10-23")
        XCTAssertEqual(first("tra 3 giorni", "it"), "2026-10-22")
        XCTAssertEqual(first("overmorgen", "nl"), "2026-10-21")
        XCTAssertEqual(first("vrijdag", "nl"), "2026-10-23")
        XCTAssertEqual(first("21 oktober", "nl"), "2026-10-21")
        // Arabic, Hindi.
        XCTAssertEqual(first("غدا", "ar"), "2026-10-20")
        XCTAssertEqual(first("الجمعة", "ar"), "2026-10-23")
        XCTAssertEqual(first("कल", "hi"), "2026-10-20")
        XCTAssertEqual(first("शुक्रवार", "hi"), "2026-10-23")
        XCTAssertEqual(first("3 दिन बाद", "hi"), "2026-10-22")
        // Japanese, Korean, Chinese (`zh-Hans`, as the app names it).
        XCTAssertEqual(first("明日", "ja"), "2026-10-20")
        XCTAssertEqual(first("金曜日", "ja"), "2026-10-23")
        XCTAssertEqual(first("3日後", "ja"), "2026-10-22")
        XCTAssertEqual(first("10月21日", "ja"), "2026-10-21")
        XCTAssertEqual(first("내일", "ko"), "2026-10-20")
        XCTAssertEqual(first("금요일", "ko"), "2026-10-23")
        XCTAssertEqual(first("3일 후", "ko"), "2026-10-22")
        XCTAssertEqual(first("10월 21일", "ko"), "2026-10-21")
        XCTAssertEqual(first("明天", "zh-Hans"), "2026-10-20")
        XCTAssertEqual(first("周五", "zh-Hans"), "2026-10-23")
        XCTAssertEqual(first("3天后", "zh-Hans"), "2026-10-22")
        XCTAssertEqual(first("2027年1月2日", "zh-Hans"), "2027-01-02")
        // A language Loam does not know: English.
        XCTAssertEqual(first("tomorrow", "sv"), "2026-10-20")
    }

    func testTitlesInTheUsersLanguage() {
        XCTAssertTrue(NaturalDate.title(of: "2026-10-20", today: today, language: "fr").hasPrefix("Demain, "))
        XCTAssertTrue(NaturalDate.title(of: "2026-10-20", today: today, language: "de").hasPrefix("Morgen, "))
        XCTAssertTrue(NaturalDate.title(of: "2026-10-20", today: today, language: "ja").hasPrefix("明日, "))
        XCTAssertFalse(NaturalDate.title(of: "2026-10-21", today: today, language: "fr").contains("Wed"))
    }

    func testNothingForText() {
        XCTAssertEqual(NaturalDate.suggestions(for: "bob", today: today), [])
        XCTAssertEqual(NaturalDate.suggestions(for: "tomorrow please", today: today), [])
    }

    func testTitles() {
        XCTAssertEqual(NaturalDate.title(of: "2026-10-19", today: today), "Today, Mon, Oct 19")
        XCTAssertEqual(NaturalDate.title(of: "2026-10-20", today: today), "Tomorrow, Tue, Oct 20")
        XCTAssertEqual(NaturalDate.title(of: "2026-10-21", today: today), "Wed, Oct 21")
        XCTAssertEqual(NaturalDate.title(of: "2027-01-01", today: today), "Fri, Jan 1, 2027")
    }
}
