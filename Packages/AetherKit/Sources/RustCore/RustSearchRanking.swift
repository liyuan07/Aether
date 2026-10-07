// Copyright (C) 2026 Li Yuan. SPDX-License-Identifier: GPL-3.0-or-later
import CAetherCore

public typealias RustSearchRank = AetherSearchRankEntry

public enum RustSearchRanking {
    public static func order(_ entries: [RustSearchRank]) -> [Int] {
        var indices = Array(entries.indices)
        let valid = entries.withUnsafeBufferPointer { input in
            indices.withUnsafeMutableBufferPointer { output in
                aether_search_rank(input.baseAddress, input.count, output.baseAddress, output.count)
            }
        }
        if valid != 1 {
            // Preserve the existing native comparison for nonfinite transient
            // Foundation dates, which do not define a total Rust sort order.
            indices.sort { a, b in
                entries[a].score == entries[b].score
                    ? entries[a].timestamp > entries[b].timestamp
                    : entries[a].score > entries[b].score
            }
        }
        return indices
    }
}
