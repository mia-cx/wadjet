import Foundation

/// Completed irreversible degradation steps. A younger host never restores lost content.
public struct CanvasRetentionState: OptionSet, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let sdr = Self(rawValue: 1 << 0)
    public static let lossyHEIC = Self(rawValue: 1 << 1)
    public static let unusedDisplaysDropped = Self(rawValue: 1 << 2)
}

/// Retention metadata supplied by the Canvas store. IDs must be unique within one evaluation.
public struct CanvasRetentionRecord: Equatable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var keptBySaveFile: Bool
    public var state: CanvasRetentionState
    public var linkedCanvasIDs: Set<UUID>

    public init(
        id: UUID, createdAt: Date, keptBySaveFile: Bool = false,
        state: CanvasRetentionState = [], linkedCanvasIDs: Set<UUID> = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.keptBySaveFile = keptBySaveFile
        self.state = state
        self.linkedCanvasIDs = linkedCanvasIDs
    }
}

/// Elapsed 24-hour days per stage. Zero disables deletion; zero for other stages means immediately.
public struct CanvasRetentionSettings: Equatable, Sendable {
    public let daysUntilSDRAndLossyHEIC: Int
    public let daysUntilDroppingUnusedDisplays: Int
    public let daysUntilDeletion: Int

    public init(
        daysUntilSDRAndLossyHEIC: Int = 7,
        daysUntilDroppingUnusedDisplays: Int = 30,
        daysUntilDeletion: Int = 90
    ) {
        precondition(daysUntilSDRAndLossyHEIC >= 0 && daysUntilDroppingUnusedDisplays >= 0 && daysUntilDeletion >= 0)
        self.daysUntilSDRAndLossyHEIC = daysUntilSDRAndLossyHEIC
        self.daysUntilDroppingUnusedDisplays = daysUntilDroppingUnusedDisplays
        self.daysUntilDeletion = daysUntilDeletion
    }
}

/// Work for the store to apply and persist. Deletion replaces all other work for that Canvas.
public enum CanvasRetentionAction: String, Codable, Sendable {
    case convertToSDR, reencodeLossyHEIC, dropUnusedDisplays, delete
}

/// One Canvas's due work, ordered so SDR conversion precedes lossy encoding.
public struct CanvasRetentionDecision: Equatable, Sendable {
    public let canvasID: UUID
    public let actions: [CanvasRetentionAction]
}

/// Pure retention planning. The caller owns file IO and records completed actions before the next sweep.
public struct CanvasRetentionPolicy: Sendable {
    private let now: @Sendable () -> Date
    private static let secondsPerDay: TimeInterval = 86_400

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// Returns only Canvases with due work, in input order. References to missing IDs and self-links
    /// have no effect. Every other existing link prevents deletion, including cycles and hosts due
    /// for deletion in this sweep; a later sweep can delete an orphan once its hosts are gone.
    /// Effective creation dates propagate from newer hosts through every link, without reversing
    /// completed degradation. Save file records themselves never receive actions.
    public func actionsDue(
        for records: [CanvasRetentionRecord], settings: CanvasRetentionSettings = .init()
    ) -> [CanvasRetentionDecision] {
        let currentDate = now()
        var effectiveDates = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.createdAt) })
        let links = Dictionary(uniqueKeysWithValues: records.map { record in
            (record.id, record.linkedCanvasIDs.filter { $0 != record.id && effectiveDates[$0] != nil })
        })
        let referenced = Set(links.values.flatMap { $0 })

        // Propagate only increases. This reaches a fixed point even for cycles, and keeps
        // the newest transitive host independent of the input records' order.
        var queue = records.map(\.id)
        var index = 0
        while index < queue.count {
            let host = queue[index]
            index += 1
            guard let hostDate = effectiveDates[host] else { continue }
            for target in links[host] ?? [] {
                guard let targetDate = effectiveDates[target], hostDate > targetDate else { continue }
                effectiveDates[target] = hostDate
                queue.append(target)
            }
        }

        return records.compactMap { record in
            guard !record.keptBySaveFile, let effectiveDate = effectiveDates[record.id] else { return nil }
            let age = currentDate.timeIntervalSince(effectiveDate)
            if settings.daysUntilDeletion > 0,
               age >= Double(settings.daysUntilDeletion) * Self.secondsPerDay,
               !referenced.contains(record.id) {
                return CanvasRetentionDecision(canvasID: record.id, actions: [.delete])
            }

            var actions: [CanvasRetentionAction] = []
            if age >= Double(settings.daysUntilSDRAndLossyHEIC) * Self.secondsPerDay {
                if !record.state.contains(.sdr) { actions.append(.convertToSDR) }
                if !record.state.contains(.lossyHEIC) { actions.append(.reencodeLossyHEIC) }
            }
            if age >= Double(settings.daysUntilDroppingUnusedDisplays) * Self.secondsPerDay,
               !record.state.contains(.unusedDisplaysDropped) {
                actions.append(.dropUnusedDisplays)
            }
            return actions.isEmpty ? nil : CanvasRetentionDecision(canvasID: record.id, actions: actions)
        }
    }
}
