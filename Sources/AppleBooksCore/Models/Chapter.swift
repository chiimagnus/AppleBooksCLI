public struct Chapter: Equatable, Sendable {
    public let id: String
    public let title: String
    public let href: String
    public let fragment: String
    public let order: Int
    public let depth: Int

    public init(id: String, title: String, href: String, fragment: String, order: Int, depth: Int) {
        self.id = id
        self.title = title
        self.href = href
        self.fragment = fragment
        self.order = order
        self.depth = depth
    }
}
