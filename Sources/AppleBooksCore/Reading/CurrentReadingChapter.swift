enum CurrentReadingChapter {
    static func resolve(chapterID: String, in content: BookContent) throws -> Chapter? {
        try content.listChapters().first { $0.id == chapterID }
    }
}
