import Combine
import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let question: String
    let answer: String
    var date = Date()
}

/// Questions and their answers, newest first, saved on this Mac only.
final class History: ObservableObject {
    static let shared = History()
    static let limit = 100

    @Published private(set) var entries: [HistoryEntry]
    private let defaults: UserDefaults
    private let key = "history"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) }
        entries = saved ?? []
    }

    /// Adds an answer, moving a repeated question to the top instead of listing it twice.
    func add(question: String, answer: String) {
        let question = question.trimmingCharacters(in: CharacterSet(charactersIn: " =?\n\t"))
        guard !question.isEmpty else { return }
        if let first = entries.first, first.question == question, first.answer == answer { return }
        entries.removeAll { $0.question == question }
        entries.insert(HistoryEntry(question: question, answer: answer), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        defaults.set(try? JSONEncoder().encode(entries), forKey: key)
    }
}
