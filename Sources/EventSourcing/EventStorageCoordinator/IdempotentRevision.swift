//
//  IdempotentRevision.swift
//  DDDKit
//

import Foundation

/// The contract's id de-duplication (KurrentDB's rule), shared by the stores in this
/// package: a batch whose ids equal the stored ids right after `expected` was already
/// written, so the append answers with that segment's last revision. `nil` when the
/// batch does not match, and for an empty batch, which has no segment and so no last
/// revision.
package func idempotentRevision(of batch: [UUID], in stored: [UUID], expected: UInt64?) -> UInt64? {
    guard !batch.isEmpty else { return nil }
    let start: Int
    if let expected {
        // Bail out in UInt64 before converting: `Int(expected) + 1` traps for
        // versions near UInt64.max, and such a version can never match anyway.
        guard expected < UInt64(stored.count) else { return nil }
        start = Int(expected) + 1
    } else {
        start = 0
    }
    let end = start + batch.count
    guard end <= stored.count else { return nil }
    guard Array(stored[start..<end]) == batch else { return nil }
    return UInt64(end - 1)
}
