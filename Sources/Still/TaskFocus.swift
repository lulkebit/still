import Foundation

enum TaskFocusFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case today
    case upcoming
    case waiting

    var id: String { rawValue }
    var localizationKey: String { "task.focus.\(rawValue)" }
}

enum TaskFocusPolicy {
    static func tasks(
        _ tasks: [TaskItem],
        matching filter: TaskFocusFilter,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [TaskItem] {
        tasks.filter { includes($0, in: filter, now: now, calendar: calendar) }
    }

    static func includes(
        _ task: TaskItem,
        in filter: TaskFocusFilter,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        switch filter {
        case .all:
            return task.status != .done
        case .waiting:
            return task.status == .waiting
        case .today:
            guard task.status == .open, let dueDate = task.dueDate else { return false }
            return calendar.startOfDay(for: dueDate) <= calendar.startOfDay(for: now)
        case .upcoming:
            guard task.status == .open, let dueDate = task.dueDate else { return false }
            return calendar.startOfDay(for: dueDate) > calendar.startOfDay(for: now)
        }
    }

    static func isOverdue(
        _ task: TaskItem,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> Bool {
        guard task.status == .open, let dueDate = task.dueDate else { return false }
        return calendar.startOfDay(for: dueDate) < calendar.startOfDay(for: now)
    }

    static func filterRevealingSelection(
        _ task: TaskItem,
        currentFilter: TaskFocusFilter,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> TaskFocusFilter {
        includes(task, in: currentFilter, now: now, calendar: calendar) ? currentFilter : .all
    }

}

struct TaskFocusPresentationState: Equatable {
    var filter: TaskFocusFilter = .all
    var showsDoneTasks = false

    mutating func toggleDone() {
        showsDoneTasks.toggle()
    }

    mutating func revealSelection(_ task: TaskItem, now: Date = .now, calendar: Calendar = .current) {
        if task.status == .done {
            showsDoneTasks = true
        } else {
            filter = TaskFocusPolicy.filterRevealingSelection(task, currentFilter: filter,
                                                              now: now, calendar: calendar)
        }
    }
}
