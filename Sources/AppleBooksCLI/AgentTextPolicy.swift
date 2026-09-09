import AppleBooksCore
import Foundation

struct BoundedTextProfile: Sendable {
    let maximumGraphemes: Int
    let maximumUTF8Bytes: Int

    static let preview = BoundedTextProfile(maximumGraphemes: 240, maximumUTF8Bytes: 4 * 1_024)
    static let metadata = BoundedTextProfile(maximumGraphemes: 512, maximumUTF8Bytes: 8 * 1_024)
    static let shortMetadata = BoundedTextProfile(maximumGraphemes: 128, maximumUTF8Bytes: 2 * 1_024)
    static let detail = BoundedTextProfile(maximumGraphemes: 4_000, maximumUTF8Bytes: 32 * 1_024)
}

enum BoundedTextPolicy {
    static func truncate(_ value: String?, profile: BoundedTextProfile) -> (value: String?, truncated: Bool) {
        guard let value else { return (nil, false) }
        guard value.count > profile.maximumGraphemes || value.utf8.count > profile.maximumUTF8Bytes else {
            return (value, false)
        }

        var result = ""
        var graphemes = 0
        var bytes = 0
        for character in value {
            let characterBytes = character.utf8.count
            guard graphemes < profile.maximumGraphemes,
                  bytes <= profile.maximumUTF8Bytes - characterBytes else {
                break
            }
            result.append(character)
            graphemes += 1
            bytes += characterBytes
        }
        return (result, true)
    }

    static func accepts(_ value: String, profile: BoundedTextProfile) -> Bool {
        value.count <= profile.maximumGraphemes && value.utf8.count <= profile.maximumUTF8Bytes
    }
}

enum PublicStableTokenPolicy {
    static let maximumUTF8Bytes = PublicStableIdentityPolicy.maximumUTF8Bytes

    static func isEligible(_ value: String?) -> Bool {
        PublicStableIdentityPolicy.isEligible(value)
    }

    static func validateInput(_ value: String) throws {
        guard isEligible(value) else {
            throw CLIError.usageInvalid("Stable identity is invalid.")
        }
    }
}

func boundedField(
    _ value: String?,
    field: String,
    profile: BoundedTextProfile,
    truncatedFields: inout [String]
) -> String? {
    let result = BoundedTextPolicy.truncate(value, profile: profile)
    if result.truncated { truncatedFields.append(field) }
    return result.value
}
