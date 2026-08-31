public struct Page<Element> {
    public let items: [Element]
    public let total: Int
    public let limit: Int
    public let offset: Int

    public init(items: [Element], total: Int, limit: Int, offset: Int) {
        self.items = items
        self.total = total
        self.limit = limit
        self.offset = offset
    }
}

public enum PageInputError: Error, Equatable, Sendable {
    case limitOutOfRange
    case negativeOffset
}

func resolvedPageLimit(_ limit: Int?, default defaultLimit: Int, offset: Int) throws -> Int {
    guard offset >= 0 else { throw PageInputError.negativeOffset }
    let effective = limit ?? defaultLimit
    guard (1...100).contains(effective) else { throw PageInputError.limitOutOfRange }
    return effective
}
