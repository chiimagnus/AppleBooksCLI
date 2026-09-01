import CoreGraphics
import Foundation
import Testing
@testable import AppleBooksCore

@Suite("ObsidianMarkdownProfileTests")
struct ObsidianMarkdownProfileTests {
    @Test
    func defaultsArePresentationOnlyAndKeepEveryExtraSwitchOff() throws {
        #expect(MarkdownProfile.plain.syntax == .plain)
        #expect(MarkdownProfile.obsidian.syntax == .obsidian)
        #expect(MarkdownProfile.plain.options == ObsidianMarkdownOptions())
        #expect(MarkdownProfile.obsidian.options == ObsidianMarkdownOptions())

        let fixture = Fixture()
        let markdown = MarkdownAnnotationExporter.render(fixture.currentGroup, profile: .obsidian)
        #expect(markdown.hasPrefix("# "))
        #expect(markdown.contains("\n---\n") == false)
        #expect(markdown.contains("Reading progress") == false)
        #expect(markdown.contains("Citation") == false)
        #expect(markdown.contains("Style") == false)
        #expect(markdown.contains("[[Authors/") == false)
        #expect(markdown.contains("\n## Chapter ") == false)
    }

    @Test
    func richProfileQuotesYAMLAndEscapesObsidianTargetsWithoutMutatingRawValues() throws {
        let fixture = Fixture()
        let options = ObsidianMarkdownOptions(
            extendedFrontmatter: true,
            bodyMetadata: true,
            includeTags: true,
            customTags: ["custom\n---\n#tag", "safe"],
            chapterHeadings: true,
            annotationDates: true,
            annotationStyle: true,
            readingProgress: true,
            citation: true,
            authorLinks: true,
            authorPages: true,
            groupConsecutiveNullLocationFragments: true
        )
        let profile = MarkdownProfile(syntax: .obsidian, options: options)
        let markdown = MarkdownAnnotationExporter.render(fixture.currentGroup, profile: profile)
        let lines = markdown.components(separatedBy: "\n")

        #expect(lines.first == "---")
        #expect(lines.filter { $0 == "---" }.count == 2)
        #expect(markdown.contains("title: \"Title\\n---\\n# injected ](\"") == true)
        #expect(markdown.contains("publisher: \"Publisher: #\\n---\"") == true)
        #expect(markdown.contains("  - \"subject\\n---\"") == true)
        #expect(markdown.contains("  - \"custom\\n---\\n#tag\"") == true)
        #expect(markdown.contains("[[Authors/A%5D%5D%7C%23%5E%2F%2E%2E|A%5D%5D%7C%23%5E%2F%2E%2E]]"))
        #expect(markdown.contains("**Reading progress:** 42.5%"))
        #expect(markdown.contains("**Publisher:** Publisher: \\# ---"))
        #expect(markdown.contains("**Year:** 2024"))
        #expect(markdown.contains("**Language:** zh-Hans"))
        #expect(markdown.contains("**ISBN:** 978-0-00-000000-0"))
        #expect(markdown.contains("## Chapter \\#1"))
        #expect(markdown.contains("**Date:** 2020-09-13T12:26:40.500Z"))
        #expect(markdown.contains("**Style:** raw-9"))
        #expect(markdown.contains("**Underline:** true"))
        #expect(markdown.contains("**Citation:**"))
        #expect(markdown.contains("p. 42"))
        #expect(markdown.contains("Location: epubcfi"))

        #expect(profile.options.authorPages)
        #expect(fixture.book.title == Fixture.hostileTitle)
        #expect(fixture.book.author == Fixture.hostileAuthor)
        #expect(fixture.records[2].payload == .epub(EnrichedAnnotation(annotation: fixture.annotations[2], source: .currentLibrary(fixture.book))))
    }

    @Test
    func nullLocationGroupingPreservesEveryMemberAndUsesNextLocatedRecordOnlyForPresentation() {
        let fixture = Fixture()
        let groups = AnnotationPresentationGroup.make(
            records: fixture.records,
            groupConsecutiveNullLocationFragments: true
        )

        #expect(groups.count == 3)
        #expect(groups.map(memberPKs) == [[1, 2, 3], [4], [5]])
        #expect(groups[0].members[0] == fixture.records[0])
        #expect(groups[0].members[1] == fixture.records[1])
        #expect(groups[0].members[2] == fixture.records[2])
        #expect(groups[2].locatedMember == nil)

        let ungrouped = AnnotationPresentationGroup.make(
            records: fixture.records,
            groupConsecutiveNullLocationFragments: false
        )
        #expect(ungrouped.map(memberPKs) == [[1], [2], [3], [4], [5]])
        #expect(fixture.currentGroup.records == fixture.records)
    }

    @Test
    func groupedFragmentsInheritChapterPresentationWithoutLosingTheirOwnTextAndNote() {
        let fixture = Fixture()
        let profile = MarkdownProfile(
            syntax: .obsidian,
            options: ObsidianMarkdownOptions(
                chapterHeadings: true,
                groupConsecutiveNullLocationFragments: true
            )
        )
        let markdown = MarkdownAnnotationExporter.render(fixture.currentGroup, profile: profile)

        let chapter = try! #require(markdown.firstRange(of: "## Chapter \\#1"))
        let first = try! #require(markdown.firstRange(of: "> fragment-one"))
        let second = try! #require(markdown.firstRange(of: "> fragment-two"))
        let located = try! #require(markdown.firstRange(of: "> located-three"))
        #expect(chapter.lowerBound < first.lowerBound)
        #expect(first.lowerBound < second.lowerBound)
        #expect(second.lowerBound < located.lowerBound)
        #expect(markdown.contains("> note-one"))
        #expect(markdown.contains("> trailing-five"))
    }

    @Test
    func pdfCitationUsesPhysicalPageAndNeverInventsEPUBLocation() throws {
        let fixture = Fixture()
        let source = PDFSource(fileURL: URL(fileURLWithPath: "/tmp/citation.pdf"), book: fixture.book)
        let record = ExportRecord(payload: .pdf(
            source: source,
            highlight: PDFHighlight(
                page: 7,
                traversalIndex: 0,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                quadrilateralPoints: [],
                note: nil,
                pdfKitRGBA: nil,
                presentationColor: nil,
                modifiedAt: fixture.date,
                text: "pdf quote",
                textSource: .boundsFallback,
                textIsApproximate: true,
                textUnavailableReason: nil
            )
        ))
        let group = ExportGroup(source: .pdf(source), records: [record])
        let profile = MarkdownProfile(syntax: .obsidian, options: ObsidianMarkdownOptions(citation: true))

        let markdown = MarkdownAnnotationExporter.render(group, profile: profile)
        #expect(markdown.contains("**Citation:**"))
        #expect(markdown.contains("p. 7"))
        #expect(markdown.contains("epubcfi") == false)
    }

    private func memberPKs(_ group: AnnotationPresentationGroup) -> [Int64] {
        group.members.compactMap { record in
            guard case let .epub(enriched) = record.payload else { return nil }
            return enriched.annotation.localPK
        }
    }

    private struct Fixture {
        static let hostileTitle = "Title\n---\n# injected ]("
        static let hostileAuthor = "A]]|#^/.."

        let date = Date(timeIntervalSince1970: 1_600_000_000.5)
        let book: Book
        let annotations: [Annotation]
        let records: [ExportRecord]
        let currentGroup: ExportGroup

        init() {
            let currentBook = Book(
                localPK: 10,
                assetID: "asset:#](\n---",
                title: Self.hostileTitle,
                author: Self.hostileAuthor,
                description: nil,
                epubID: nil,
                genre: "genre:#",
                genresRaw: nil,
                comments: nil,
                language: "zh-Hans",
                year: 2024,
                contentType: 1,
                pageCount: nil,
                path: "/definitely/missing/book.epub",
                fileSize: nil,
                coverURL: nil,
                isFinished: false,
                readingProgressRaw: 0.425,
                durationRawMilliseconds: nil,
                creationDate: nil,
                modificationDate: nil,
                finishedDate: nil,
                lastOpenDate: nil,
                purchaseDate: nil,
                releaseDate: nil,
                isExplicit: nil,
                isLocked: nil,
                isEphemeral: nil,
                isHidden: nil,
                isSample: nil,
                isStoreAudiobook: nil,
                rating: nil
            )

            let currentAnnotations = [
                Self.annotation(pk: 1, text: "fragment-one", note: "note-one", location: nil),
                Self.annotation(pk: 2, text: "fragment-two", note: nil, location: nil),
                Self.annotation(
                    pk: 3,
                    text: "located-three",
                    note: "```\n---\n]( <script>",
                    location: "epubcfi(/6/2[Chapter #1]!/4/2:3)",
                    style: 9,
                    underline: true,
                    physicalLocation: 42,
                    date: date
                ),
                Self.annotation(
                    pk: 4,
                    text: "located-four",
                    note: nil,
                    location: "epubcfi(/6/4[Chapter 2]!/4/2:3)"
                ),
                Self.annotation(pk: 5, text: "trailing-five", note: nil, location: nil),
            ]
            let currentRecords = currentAnnotations.map {
                ExportRecord(payload: .epub(EnrichedAnnotation(annotation: $0, source: .currentLibrary(currentBook))))
            }
            let metadata = EPUBMetadata(
                title: "metadata title",
                creator: "metadata creator",
                identifiers: ["id"],
                isbn: "978-0-00-000000-0",
                language: "en",
                publisher: "Publisher: #\n---",
                publicationDate: "2024-01-01",
                rights: nil,
                subjects: ["subject\n---", "safe"],
                coverItemID: nil
            )
            book = currentBook
            annotations = currentAnnotations
            records = currentRecords
            currentGroup = ExportGroup(source: .epubCurrent(currentBook), records: currentRecords, epubMetadata: metadata)
        }

        private static func annotation(
            pk: Int64,
            text: String,
            note: String?,
            location: String?,
            style: Int64? = nil,
            underline: Bool? = false,
            physicalLocation: Int64? = nil,
            date: Date? = nil
        ) -> Annotation {
            Annotation(
                localPK: pk,
                uuid: "uuid-\(pk)",
                rawAssetID: "asset:#](\n---",
                isDeleted: false,
                isUnderline: underline,
                style: style,
                type: 1,
                createdAt: date,
                modifiedAt: nil,
                representativeText: nil,
                selectedText: text,
                note: note,
                location: location.map(Location.init(rawCFI:)),
                chapterHint: "fallback-\(pk)",
                physicalLocation: physicalLocation,
                rangeStart: nil,
                rangeEnd: nil
            )
        }
    }
}
