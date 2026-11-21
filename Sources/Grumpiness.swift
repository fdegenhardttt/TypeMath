import Foundation

/// What the issue card shows after a finished line.
struct Reaction: Equatable {
    let face: String
    let title: String
    let remark: String?
    /// 0 calm … 4 furious; 3 shakes once, 4 shakes hard and turns red.
    let level: Int
}

/// The helper's mood: each new mistake makes it grumpier, clean lines and fixes calm it down.
/// Cheeky about the code, never about the person.
struct Grumpiness {
    static let faces = ["😊", "🙂", "😐", "😤", "🤬"]
    static let maxLevel = faces.count - 1
    static let cooldown: TimeInterval = 120

    private static let remarks: [[String]] = [
        ["Small thing.", "Easy fix.", "Happens to everyone."],
        ["Hmm.", "Let's keep an eye on that.", "Not ideal, but fine."],
        ["Again?", "We talked about this.", "I'm noticing a pattern."],
        ["I am being VERY patient.", "Deep breaths. For both of us.", "My circuits are heating up."],
        ["#$%&! Who taught you VBA?!", "THAT'S IT. I'M CALLING EXCEL SUPPORT.", "I need a minute. 🔥"],
    ]
    private static let repeats = ["Same thing again.", "Déjà vu.", "Again. The same one.", "THE SAME ONE. AGAIN.", "AGAIN?! #$%&!"]

    var enabled = true
    private(set) var level = 0
    private var cleanStreak = 0
    private var lastMistake: Date?
    private var lastKey: String?
    private var nextRemark = [Int](repeating: 0, count: faces.count)

    /// A finished line with this issue (or none). Returns what to show, if anything.
    /// `showLine` is false when line numbers aren't known (the editor didn't share its text).
    mutating func lineFinished(with issue: VBAIssue?, at now: Date, showLine: Bool = true) -> Reaction? {
        coolDown(at: now)
        guard let issue else {
            cleanStreak += 1
            if cleanStreak >= 3, level > 0 {
                level -= 1
                cleanStreak = 0
            }
            return nil
        }
        let title = "\(showLine ? "Line \(issue.line)" : "This line") · \(issue.message)"
        guard enabled else { return Reaction(face: "⚠️", title: title, remark: nil, level: 0) }

        if issue.kind == .style {  // tips only while calm, and they never count as mistakes
            return level == 0 ? Reaction(face: Self.faces[0], title: issue.message, remark: nil, level: 0) : nil
        }
        let isRepeat = issue.key == lastKey
        level = min(level + 1, Self.maxLevel)
        cleanStreak = 0
        lastMistake = now
        lastKey = issue.key
        return Reaction(face: Self.faces[level], title: title,
                        remark: isRepeat ? Self.repeats[level] : pickRemark(), level: level)
    }

    /// A previously flagged mistake is gone.
    mutating func mistakeFixed(at now: Date) -> Reaction? {
        coolDown(at: now)
        guard enabled, level > 0 else { return nil }
        level -= 1
        lastKey = nil
        return Reaction(face: Self.faces[level], title: "Fixed.", remark: "Finally. 😮‍💨", level: level)
    }

    private mutating func coolDown(at now: Date) {
        if let lastMistake, now.timeIntervalSince(lastMistake) > Self.cooldown {
            level = 0
            lastKey = nil
            self.lastMistake = nil
        }
    }

    /// The next remark for this level, rotating so the same one never shows twice in a row.
    private mutating func pickRemark() -> String {
        let pool = Self.remarks[level]
        let remark = pool[nextRemark[level] % pool.count]
        nextRemark[level] += 1
        return remark
    }
}
