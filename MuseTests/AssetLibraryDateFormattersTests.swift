import XCTest
@testable import Muse

final class AssetLibraryDateFormattersTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.set(AppLanguage.zh.rawValue, forKey: DefaultsKeys.language)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.language)
        super.tearDown()
    }

    func testDisplayDateTimeUsesChineseMonthDayWithinSameYear() throws {
        let date = try makeDate(year: 2026, month: 6, day: 3, hour: 14, minute: 6)
        let referenceDate = try makeDate(year: 2026, month: 12, day: 1, hour: 0, minute: 0)

        XCTAssertEqual(
            AssetLibraryDateFormatters.displayDateTime(date, relativeTo: referenceDate),
            "6月3日 14:06"
        )
    }

    func testDisplayDateTimeIncludesYearAcrossYears() throws {
        let date = try makeDate(year: 2025, month: 12, day: 31, hour: 7, minute: 31)
        let referenceDate = try makeDate(year: 2026, month: 1, day: 1, hour: 0, minute: 0)

        XCTAssertEqual(
            AssetLibraryDateFormatters.displayDateTime(date, relativeTo: referenceDate),
            "2025年12月31日 07:31"
        )
    }

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = DateComponents(
            calendar: calendar,
            timeZone: .current,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        )
        return try XCTUnwrap(calendar.date(from: components))
    }
}
