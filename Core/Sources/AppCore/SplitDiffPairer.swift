import Foundation
import DiffKit

public struct SplitDiffPair: Sendable, Equatable {
    public let left: DiffLine?
    public let right: DiffLine?

    public init(left: DiffLine?, right: DiffLine?) {
        self.left = left
        self.right = right
    }
}

public enum SplitDiffPairer {
    public static func pair(_ lines: [DiffLine]) -> [SplitDiffPair] {
        var pairs: [SplitDiffPair] = []
        var pending: [DiffLine] = []
        for line in lines {
            switch line.kind {
            case .context:
                pairs.append(contentsOf: pending.map { SplitDiffPair(left: $0, right: nil) })
                pending.removeAll()
                pairs.append(SplitDiffPair(left: line, right: line))
            case .removed:
                pending.append(line)
            case .added:
                if !pending.isEmpty {
                    let removed = pending.removeFirst()
                    pairs.append(SplitDiffPair(left: removed, right: line))
                } else {
                    pairs.append(SplitDiffPair(left: nil, right: line))
                }
            }
        }
        pairs.append(contentsOf: pending.map { SplitDiffPair(left: $0, right: nil) })
        return pairs
    }
}
