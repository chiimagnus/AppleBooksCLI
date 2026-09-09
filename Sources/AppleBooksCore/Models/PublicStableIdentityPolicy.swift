import Foundation

package enum PublicStableIdentityPolicy {
    package static let maximumUTF8Bytes = 2_048

    package static func isEligible(_ value: String?) -> Bool {
        guard let value,
              value.isEmpty == false,
              value.utf8.count <= maximumUTF8Bytes,
              value.utf8.contains(0) == false,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value else {
            return false
        }
        return true
    }
}
