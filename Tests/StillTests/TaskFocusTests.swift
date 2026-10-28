import XCTest
@testable import Still

final class TaskFocusTests: XCTestCase {
    func testFocusFiltersUseLocalCalendarDaysAndSeparateWaiting() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try date("2026-10-25T08:00:00Z")
        let yesterday = try date("2026-10-24T00:00:00Z")
        let todayAtMidnight = try date("2026-10-25T00:00:00Z")
        let tomorrow = try date("2026-10-26T23:45:00Z")

        let overdue = TaskItem(title: "overdue", dueDate: yesterday)
        let dueToday = TaskItem(title: "today", dueDate: todayAtMidnight)
        let upcoming = TaskItem(title: "upcoming", dueDate: tomorrow)
        let undated = TaskItem(title: "undated")
        let waiting = TaskItem(title: "waiting", dueDate: yesterday, status: .waiting)
        let done = TaskItem(title: "done", dueDate: todayAtMidnight, status: .done)
        let tasks = [overdue, dueToday, upcoming, undated, waiting, done]

        XCTAssertEqual(Set(TaskFocusPolicy.tasks(tasks, matching: .all, now: now, calendar: calendar).map(\.id)),
                       Set([overdue, dueToday, upcoming, undated, waiting].map(\.id)))
        XCTAssertEqual(Set(TaskFocusPolicy.tasks(tasks, matching: .today, now: now, calendar: calendar).map(\.id)),
                       Set([overdue, dueToday].map(\.id)))
        XCTAssertEqual(TaskFocusPolicy.tasks(tasks, matching: .upcoming, now: now, calendar: calendar).map(\.id), [upcoming.id])
        XCTAssertEqual(TaskFocusPolicy.tasks(tasks, matching: .waiting, now: now, calendar: calendar).map(\.id), [waiting.id])
        XCTAssertTrue(TaskFocusPolicy.isOverdue(overdue, now: now, calendar: calendar))
        XCTAssertFalse(TaskFocusPolicy.isOverdue(dueToday, now: now, calendar: calendar))
        XCTAssertFalse(TaskFocusPolicy.isOverdue(waiting, now: now, calendar: calendar))
        XCTAssertFalse(TaskFocusPolicy.isOverdue(done, now: now, calendar: calendar))
    }

    func testSelectionRevealsFilteredOrCompletedTaskWithoutChangingItsIdentity() throws {
        let now = try date("2026-10-25T08:00:00Z")
        let tomorrow = try date("2026-10-26T00:00:00Z")
        let future = TaskItem(title: "future", dueDate: tomorrow)
        let completed = TaskItem(title: "completed", status: .done)

        XCTAssertEqual(TaskFocusPolicy.filterRevealingSelection(future, currentFilter: .today, now: now), .all)
        XCTAssertEqual(TaskFocusPolicy.filterRevealingSelection(future, currentFilter: .upcoming, now: now), .upcoming)
        var presentation = TaskFocusPresentationState()
        XCTAssertFalse(presentation.showsDoneTasks, "Completed tasks are collapsed by default")
        presentation.filter = .today
        presentation.revealSelection(future, now: now)
        XCTAssertEqual(presentation.filter, .all)
        XCTAssertFalse(presentation.showsDoneTasks)
        presentation.revealSelection(completed, now: now)
        XCTAssertEqual(presentation.filter, .all)
        XCTAssertTrue(presentation.showsDoneTasks, "Selecting a completed task reveals the collapsed section")
        presentation.toggleDone()
        XCTAssertFalse(presentation.showsDoneTasks, "The section can still be collapsed without clearing selection")
    }

    func testBerlinDSTDayBoundaryUsesCalendarDateRatherThanElapsedHours() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        // The local day on 25 October 2026 is 25 hours long. The first task is only
        // one hour old, but its due date belongs to the previous local calendar day.
        let now = try date("2026-10-25T23:30:00Z") // 26 October, 00:30 CET
        let previousLocalDay = TaskItem(title: "one hour late", dueDate: try date("2026-10-25T22:30:00Z"))
        let dueToday = TaskItem(title: "today", dueDate: try date("2026-10-25T23:15:00Z"))
        let nextLocalDay = TaskItem(title: "tomorrow", dueDate: try date("2026-10-26T23:30:00Z"))

        XCTAssertTrue(TaskFocusPolicy.isOverdue(previousLocalDay, now: now, calendar: calendar))
        XCTAssertEqual(Set(TaskFocusPolicy.tasks([previousLocalDay, dueToday, nextLocalDay],
                                                 matching: .today, now: now, calendar: calendar).map(\.id)),
                       Set([previousLocalDay, dueToday].map(\.id)))
        XCTAssertEqual(TaskFocusPolicy.tasks([previousLocalDay, dueToday, nextLocalDay],
                                             matching: .upcoming, now: now, calendar: calendar).map(\.id),
                       [nextLocalDay.id])
    }

    private func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: value))
    }
}
