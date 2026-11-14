import Foundation
import SQLite3
import Testing
import ZIPFoundation
@testable import AppleBooksCore

@Suite("EPUBAnnotationLocatorTests")
struct EPUBAnnotationLocatorTests {
    @Test
    func matchesAppleBooksNativeCFIForFirstChapter() throws {
        let fixture = try Fixture(chapters: ["""
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Test</title></head><body>
        <h1>Test chapter</h1><p id="line1">The copper lantern stayed beside the window.</p>
        <p id="line2">A patient robot counted seven blue stones.</p>
        <p id="line3">The quiet telescope watched a silver valley.</p>
        <p id="line4">This sentence is reserved for the code-created highlight.</p>
        </body></html>
        """], includeMetadata: true)
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        for (word, expected) in [
            ("lantern", "epubcfi(/6/2[chapter]!/4/4[line1]/1,:11,:18)"),
            ("robot", "epubcfi(/6/2[chapter]!/4/6[line2]/1,:10,:15)"),
            ("reserved", "epubcfi(/6/2[chapter]!/4/10[line4]/1,:17,:25)"),
        ] {
            let match = try locator.locate(word)
            #expect(match.cfi == expected)
            #expect(match.selectedText == word)
            #expect(match.chapterOrder == 1)
        }
    }

    @Test
    func nestedTextNodesUseXMLPathsAndCorrectUTF16Offsets() throws {
        let fixture = try Fixture(chapters: ["""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <h1>Title</h1>
        <p id="p">Alpha <em>bravo</em> &amp; <strong>delta</strong> end.</p>
        <p id="unicode">中文 👩🏽‍💻 é e\u{301} 终点。</p>
        </body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        let bravo = try locator.locate("bravo")
        let combined = try locator.locate("pha bravo")
        let across = try locator.locate("bravo & delta")
        #expect(bravo.cfi == "epubcfi(/4/2[chapter]!/2/4[p]/2/1,:0,:5)")
        #expect(combined.cfi == "epubcfi(/4/2[chapter]!/2/4[p],/1:2,/2/1:5)")
        #expect(across.cfi == "epubcfi(/4/2[chapter]!/2/4[p],/2/1:0,/4/1:5)")
        #expect(try locator.locate("👩🏽‍💻").selectedText == "👩🏽‍💻")
        #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate("🏽") }
        #expect(try locator.locate("e\u{301}").selectedText == "e\u{301}")
        #expect(try locator.locate("&").selectedText == "&")
    }

    @Test
    func multipleMatchesRequireContextOrExplicitOccurrence() throws {
        let fixture = try Fixture(chapters: ["""
        <html><body><p>red violet red blue red green</p></body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(throws: EPUBAnnotationLocatorError.ambiguous(3)) { _ = try locator.locate("red", chapterOrder: 1) }
        let second = try locator.locate("red", chapterOrder: 1, occurrence: 2)
        #expect(second.cfi.contains(":11,:14"))
        #expect(try locator.locate("red", prefix: " violet ").cfi == second.cfi)
        #expect(throws: EPUBAnnotationLocatorError.invalidOccurrence) { _ = try locator.locate("red", occurrence: 0) }
        #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate("greenish") }
        #expect(throws: EPUBAnnotationLocatorError.invalidText) { _ = try locator.locate(" \t ") }
    }

    @Test
    func sharedChapterResourceHonorsFragmentBoundaries() throws {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body><h2 id="one">One</h2>
        <p>unique first</p><h2 id="two">Two</h2><p>unique second</p>
        </body></html>
        """
        let fixture = try Fixture(chapters: [xhtml], ncx: ["chapter.xhtml#one", "chapter.xhtml#two"])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(try locator.locate("unique first", chapterOrder: 1).chapterOrder == 1)
        #expect(try locator.locate("unique second", chapterOrder: 2).chapterOrder == 2)
        #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate("unique second", chapterOrder: 1) }
        #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate("unique first", chapterOrder: 2) }
        #expect(throws: EPUBAnnotationLocatorError.chapterNotFound) { _ = try locator.locate("One", chapterOrder: 3) }
    }

    @Test
    func blockBoundariesAndInvisibleContentCannotCreatePhantomRanges() throws {
        let fixture = try Fixture(chapters: ["""
        <html><head><title>hidden word</title><style>.x { display:none; }</style></head><body>
        <p>first</p><p>second</p>
        <p hidden="hidden">hidden word</p><p style="display:none">hidden word</p>
        <p><span>hello</span><br/><span>world</span></p>
        <p>before<img src="picture.png"/>after</p>
        </body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        for text in ["firstsecond", "first second", "hidden word", "helloworld", "hello world", "beforeafter"] {
            #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate(text) }
        }
    }

    @Test
    func packedAndDirectoryFormsProduceSameCFI() throws {
        let fixture = try Fixture(chapters: ["""
        <html><body><p id="x">Repeated &amp; exact text.</p></body></html>
        """])
        defer { fixture.remove() }
        let zip = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
        defer { try? FileManager.default.removeItem(at: zip) }
        let archive = try Archive(url: zip, accessMode: .create)
        for path in ["META-INF/container.xml", "OPS/content.opf", "OPS/chapter.xhtml"] {
            let data = try Data(contentsOf: fixture.root.appendingPathComponent(path))
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, size in
                let start = Int(position)
                let end = min(start + size, data.count)
                return start < end ? data.subdata(in: start..<end) : Data()
            }
        }
        let directory = try EPUBAnnotationLocator(content: BookContent(root: fixture.root)).locate("exact")
        let archived = try EPUBAnnotationLocator(content: BookContent(reader: ZIPEPUBResourceReader(fileURL: zip))).locate("exact")
        #expect(directory.cfi == archived.cfi)
    }

    @Test
    func malformedXMLAndMissingFragmentsFailClosed() throws {
        let invalid = try Fixture(chapters: ["<html><body><p>broken</body></html>"])
        defer { invalid.remove() }
        #expect(throws: EPUBAnnotationLocatorError.invalidXHTML) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: invalid.root)).locate("broken")
        }
        let missing = try Fixture(chapters: ["<html><body><p>words</p></body></html>"], ncx: ["chapter.xhtml#missing"])
        defer { missing.remove() }
        #expect(throws: EPUBAnnotationLocatorError.fragmentNotFound) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: missing.root)).locate("words", chapterOrder: 1)
        }
    }

    @Test
    func independentXMLDOMRoundTripsSingleAndCrossNodeRanges() throws {
        let xhtml = """
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>A</title></head><body>
        <h1>Heading</h1><p id="test">First <em>mixed</em> and <strong>nested</strong> ending.</p>
        <p id="unicode">Before 👩🏽‍💻 and e\u{301} after.</p>
        </body></html>
        """
        let fixture = try Fixture(chapters: [xhtml])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        for phrase in ["First", "mixed", "rst mixed", "mixed and nested", "👩🏽‍💻", "e\u{301}"] {
            let result = try locator.locate(phrase)
            #expect(try independentCFISelection(xhtml: xhtml, cfi: result.cfi) == phrase)
        }
    }

    @Test
    func whitespaceFallbackPreservesSourceTextAndStrictPunctuation() throws {
        let fixture = try Fixture(chapters: ["""
        <html><body><p id="p">Hello\u{00A0}  \n  world. Two　three.</p></body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(try locator.locate("Hello world").selectedText == "Hello\u{00A0}  \n  world")
        #expect(try locator.locate("Two three").selectedText == "Two　three")
        #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate("Hello world!") }
        #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate("hello") }
    }

    @Test
    func entitiesCDATAAndUnicodeUseSourceUTF16NotDisplayOffset() throws {
        let fixture = try Fixture(chapters: ["""
        <html><body><p id="e">One &amp; two &#x3000; <![CDATA[café]]> 😀 end</p></body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(try locator.locate("&").selectedText == "&")
        #expect(try locator.locate("café").selectedText == "café")
        #expect(try locator.locate("😀").selectedText == "😀")
        #expect(try locator.locate("two café").selectedText == "two \u{3000} café")
    }

    @Test
    func CFITracksRealOPFSpineAndEscapesAssertions() throws {
        let fixture = try Fixture(chapters: ["<html><body><p id=\"part]one\">Unique words here</p></body></html>"])
        defer { fixture.remove() }
        let opf = fixture.root.appendingPathComponent("OPS/content.opf")
        var source = try String(contentsOf: opf, encoding: .utf8)
        source = source.replacingOccurrences(of: "<itemref idref=\"chapter\"/>", with: "<itemref id=\"item^ref\" idref=\"chapter\"/>")
        source = source.replacingOccurrences(of: "<manifest>", with: "<metadata/><guide/><manifest>")
        try source.write(to: opf, atomically: true, encoding: .utf8)
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(try locator.locate("Unique").cfi == "epubcfi(/8/2[item^^ref]!/2/2[part^]one]/1,:0,:6)")
    }

    @Test
    func changesToSourceInvalidateReturnedGeneration() throws {
        let fixture = try Fixture(chapters: ["<html><body><p>Original evidence.</p></body></html>"])
        defer { fixture.remove() }
        let content = try BookContent(root: fixture.root)
        let located = try EPUBAnnotationLocator(content: content).locate("Original")
        let chapter = try content.resolveChapter(order: 1)
        #expect(located.sourceGeneration == (try content.chapterCursorGenerationComponent(for: chapter)))
        let chapterURL = fixture.root.appendingPathComponent("OPS/chapter.xhtml")
        try Data("<html><body><p>Different source evidence, longer than before.</p></body></html>".utf8).write(to: chapterURL)
        #expect(located.sourceGeneration != (try content.chapterCursorGenerationComponent(for: chapter)))
    }

    @Test
    func exactBookIdentityRejectsWrongMediaAndSupplementalFallback() throws {
        let fixture = try Fixture(chapters: ["<html><body><p>Own source only.</p></body></html>"])
        defer { fixture.remove() }
        let db = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: db) }
        var handle: OpaquePointer?
        guard sqlite3_open(db.path, &handle) == SQLITE_OK, let handle else {
            throw EPUBAnnotationLocatorError.bookNotFound
        }
        defer { sqlite3_close_v2(handle) }
        guard sqlite3_exec(handle, "CREATE TABLE ZBKLIBRARYASSET(Z_PK INTEGER PRIMARY KEY,ZASSETID TEXT,ZPATH TEXT,ZCONTENTTYPE INTEGER);", nil, nil, nil) == SQLITE_OK else {
            throw EPUBAnnotationLocatorError.bookNotFound
        }
        let rows = [
            ("correct", fixture.root.path, 1),
            ("wrong-type", fixture.root.path, 3),
            ("missing", fixture.root.appendingPathComponent("gone.epub").path, 1),
        ]
        for (identity, path, kind) in rows {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO ZBKLIBRARYASSET(ZASSETID,ZPATH,ZCONTENTTYPE) VALUES(?,?,?)", -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw EPUBAnnotationLocatorError.bookNotFound
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, identity, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 2, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 3, Int32(kind))
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw EPUBAnnotationLocatorError.bookNotFound }
        }
        let connection = try SQLiteConnection.readOnly(path: db.path)
        defer { try? connection.close() }
        let query = BookQueries(connection: connection)
        let current = try EPUBAnnotationLocator(assetID: "correct", bookQueries: query, configuration: .empty)
            .locate("Own")
        #expect(current.selectedText == "Own")
        #expect(current.bookIdentity?.assetID == "correct")
        #expect(current.bookIdentity?.path == fixture.root.path)
        #expect(current.bookIdentity?.contentType == 1)
        #expect(throws: EPUBAnnotationLocatorError.bookNotFound) {
            _ = try EPUBAnnotationLocator(assetID: "unknown", bookQueries: query, configuration: .empty)
        }
        #expect(throws: EPUBAnnotationLocatorError.unsupportedSource) {
            _ = try EPUBAnnotationLocator(assetID: "wrong-type", bookQueries: query, configuration: .empty)
        }
        #expect(throws: EPUBAnnotationLocatorError.unsupportedSource) {
            _ = try EPUBAnnotationLocator(assetID: "missing", bookQueries: query, configuration: .empty)
        }

        let fallbackRoot = fixture.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fallbackRoot) }
        try FileManager.default.createDirectory(at: fallbackRoot, withIntermediateDirectories: true)
        let fallback = fallbackRoot.appendingPathComponent("gone.epub")
        let archive = try Archive(url: fallback, accessMode: .create)
        for path in ["META-INF/container.xml", "OPS/content.opf", "OPS/chapter.xhtml"] {
            let data = try Data(contentsOf: fixture.root.appendingPathComponent(path))
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(data.count, start + size))
            }
        }
        let configFile = fallbackRoot.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: ["epub_root": fallbackRoot.path]).write(to: configFile)
        let config = try AppleBooksConfiguration(fileURL: configFile)
        #expect(throws: EPUBAnnotationLocatorError.unsupportedSource) {
            _ = try EPUBAnnotationLocator(assetID: "missing", bookQueries: query, configuration: config)
        }
    }

    @Test
    func epubThreeNavAndDifferentSpineEntriesResolveCorrectly() throws {
        let fixture = try Fixture(chapters: [
            "<html><body><p id=\"a\">First chapter text.</p></body></html>",
            "<html><body><p id=\"b\">Second chapter text.</p></body></html>",
        ], nav: ["chapter.xhtml#a", "ch1.xhtml#b"])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(try locator.locate("First", chapterOrder: 1).cfi == "epubcfi(/4/2[chapter]!/2/2[a]/1,:0,:5)")
        #expect(try locator.locate("Second", chapterOrder: 2).cfi == "epubcfi(/4/4[ch1]!/2/2[b]/1,:0,:6)")
    }

    @Test
    func textAndCDATAAroundCommentsShareOneCFINonElementSlot() throws {
        let fixture = try Fixture(chapters: ["""
        <html><body><p id="p">abc<!-- ignored -->def<![CDATA[ghi]]>jkl</p></body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(try locator.locate("def").cfi == "epubcfi(/4/2[chapter]!/2/2[p]/1,:3,:6)")
        #expect(try locator.locate("bcdefghij").cfi == "epubcfi(/4/2[chapter]!/2/2[p]/1,:1,:10)")
    }

    @Test
    func manyNavigationFragmentsOnOneXHTMLDoNotLoseLastSelection() throws {
        let chapters = (1...240).map { index in
            "<h2 id=\"part\(index)\">Section \(index)</h2><p>Content for section \(index).</p>"
        }.joined()
        let fixture = try Fixture(
            chapters: ["<html><body>\(chapters)</body></html>"],
            ncx: (1...240).map { "chapter.xhtml#part\($0)" }
        )
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        let found = try locator.locate("Content for section 240.", chapterOrder: 240)
        #expect(found.chapterOrder == 240)
        #expect(found.selectedText == "Content for section 240.")
        #expect(found.cfi.contains("[part240]") == false)
        #expect(throws: EPUBAnnotationLocatorError.noMatch) {
            _ = try locator.locate("Content for section 240.", chapterOrder: 239)
        }
    }

    @Test
    func carriageReturnLineEndingsAndNumericEntitiesUseDecodedUTF16Positions() throws {
        let fixture = try Fixture(chapters: ["<html><body><p id=\"crlf\">A\r\nB&#x1F600;C</p></body></html>"])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(try locator.locate("B").cfi == "epubcfi(/4/2[chapter]!/2/2[crlf]/1,:2,:3)")
        #expect(try locator.locate("C").cfi == "epubcfi(/4/2[chapter]!/2/2[crlf]/1,:5,:6)")
    }

    @Test
    func styleRulesWithHiddenDeclarationsCannotProduceFalseHighlights() throws {
        let fixture = try Fixture(chapters: ["""
        <html><head><style type="text/css">.concealed { display: none; }</style></head>
        <body><p class="concealed">This text is invisible.</p><p>Visible text.</p></body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(throws: EPUBAnnotationLocatorError.noMatch) {
            _ = try locator.locate("invisible")
        }
        #expect(try locator.locate("Visible").selectedText == "Visible")
    }

    @Test
    func externalAndImportedStylesheetsWithHiddenRulesFailClosed() throws {
        let fixture = try Fixture(chapters: ["""
        <html><head><link rel="stylesheet" href="hidden.css"/></head>
        <body><p class="concealed">Difficult text.</p></body></html>
        """])
        defer { fixture.remove() }
        try Data(".concealed { display: /* comment */ none !important; }".utf8)
            .write(to: fixture.root.appendingPathComponent("OPS/hidden.css"))
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        #expect(throws: EPUBAnnotationLocatorError.noMatch) {
            _ = try locator.locate("Difficult")
        }
        try Data("@import \"nested.css\";".utf8)
            .write(to: fixture.root.appendingPathComponent("OPS/hidden.css"))
        #expect(throws: EPUBAnnotationLocatorError.ambiguousVisibility) {
            _ = try locator.locate("Difficult")
        }
    }

    @Test
    func cssSelectorsExcludeOnlyTheirTargetsAndPreserveAdjacentTextBounds() throws {
        let fixture = try Fixture(chapters: ["""
        <html><head><style>
          .hide, p#special.hidden { display: none !important; }
          p.safe { display: block; }
        </style></head><body>
        <p>left<span class="hide">invisible</span>right</p>
        <p class="safe">Visible sibling.</p>
        <p id="special" class="hidden">Secret section.</p>
        </body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        for phrase in ["invisible", "leftright", "Secret"] {
            #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate(phrase) }
        }
        #expect(try locator.locate("Visible sibling.").selectedText == "Visible sibling.")
    }

    @Test
    func complexCSSVisibilitySelectorsFailClosedRatherThanGuessing() throws {
        let fixture = try Fixture(chapters: ["""
        <html><head><style>main p.hidden { display:none; }</style></head>
        <body><main><p class="hidden">Complex hidden.</p><p>Visible.</p></main></body></html>
        """])
        defer { fixture.remove() }
        #expect(throws: EPUBAnnotationLocatorError.ambiguousVisibility) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: fixture.root)).locate("Visible")
        }
    }

    @Test
    func ordinaryStylesWithoutHiddenDeclarationsRemainReadable() throws {
        let fixture = try Fixture(chapters: ["""
        <html><head><style>p { color: blue; display: block; }</style></head>
        <body><p class="normal">Normally visible words.</p></body></html>
        """])
        defer { fixture.remove() }
        #expect(try EPUBAnnotationLocator(content: BookContent(root: fixture.root))
            .locate("visible").selectedText == "visible")
    }

    @Test
    func hiddenElementBoundaryAndHiddenFragmentNeverBecomeWritableSelection() throws {
        let fixture = try Fixture(chapters: ["""
        <html><head><title id="head-anchor">Private</title></head><body>
        <p>left<span hidden="hidden" id="hidden-anchor">concealed</span>right</p>
        <p>top<em style="display:none">secret</em>bottom</p>
        </body></html>
        """])
        defer { fixture.remove() }
        let locator = EPUBAnnotationLocator(content: try BookContent(root: fixture.root))
        for phrase in ["leftright", "concealed", "topbottom", "secret", "Private"] {
            #expect(throws: EPUBAnnotationLocatorError.noMatch) { _ = try locator.locate(phrase) }
        }
        let hiddenFragment = try Fixture(
            chapters: ["<html><body><p hidden=\"hidden\" id=\"secret\">Invisible</p><p>Visible</p></body></html>"],
            ncx: ["chapter.xhtml#secret"]
        )
        defer { hiddenFragment.remove() }
        #expect(throws: EPUBAnnotationLocatorError.fragmentNotFound) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: hiddenFragment.root)).locate("Visible")
        }
    }

    @Test
    func largeNodeCountsAndExternalEntitiesDoNotProduceSelections() throws {
        let many = String(repeating: "<span>x</span>", count: EPUBStructureBudget.maximumXHTMLNodes)
        let fixture = try Fixture(chapters: ["<html><body><p>\(many)</p></body></html>"])
        defer { fixture.remove() }
        #expect(throws: EPUBAnnotationLocatorError.tooComplex) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: fixture.root)).locate("x")
        }
        let entity = try Fixture(chapters: ["""
        <!DOCTYPE html [<!ENTITY outside SYSTEM "file:///etc/passwd">]>
        <html><body><p id="bad">&outside;</p></body></html>
        """])
        defer { entity.remove() }
        #expect(throws: EPUBAnnotationLocatorError.noMatch) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: entity.root)).locate("root")
        }
    }

    @Test
    func malformedMarkupDuplicateIDAndExcessiveDepthFailWithoutGuessing() throws {
        let duplicate = try Fixture(chapters: ["""
        <html><body><p id="duplicate">One</p><p id="duplicate">Two</p></body></html>
        """])
        defer { duplicate.remove() }
        #expect(throws: EPUBAnnotationLocatorError.invalidXHTML) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: duplicate.root)).locate("One")
        }
        let nested = String(repeating: "<span>", count: EPUBStructureBudget.maximumNestingDepth + 1) +
            "target" + String(repeating: "</span>", count: EPUBStructureBudget.maximumNestingDepth + 1)
        let deep = try Fixture(chapters: ["<html><body><p>\(nested)</p></body></html>"])
        defer { deep.remove() }
        #expect(throws: EPUBAnnotationLocatorError.tooComplex) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: deep.root)).locate("target")
        }
        let invalidChar = try Fixture(chapters: ["<html><body><p>bad\u{0}text</p></body></html>"])
        defer { invalidChar.remove() }
        #expect(throws: EPUBAnnotationLocatorError.invalidXHTML) {
            _ = try EPUBAnnotationLocator(content: BookContent(root: invalidChar.root)).locate("bad")
        }
    }

    private func independentCFISelection(xhtml: String, cfi: String) throws -> String {
        let xml = try XMLDocument(data: Data(xhtml.utf8), options: [.nodePreserveAll])
        let root = try #require(xml.rootElement())
        let body = try #require(cfi.split(separator: "!", maxSplits: 1).last)
        let fragments = body.dropLast().split(separator: ",", omittingEmptySubsequences: false)
        #expect(fragments.count == 3)
        guard fragments.count == 3 else { throw EPUBAnnotationLocatorError.invalidXHTML }
        func navigate(_ raw: String) throws -> XMLNode {
            var node: XMLNode = root
            for component in raw.split(separator: "/") where component.isEmpty == false {
                let digits = component.prefix(while: { $0.isNumber })
                guard let number = Int(digits), number > 0 else {
                    throw EPUBAnnotationLocatorError.invalidXHTML
                }
                let children = node.children ?? []
                if number.isMultiple(of: 2) {
                    node = try #require(children.filter { $0.kind == .element }.dropFirst(number / 2 - 1).first)
                } else {
                    var precedingElements = 0
                    let target = (number - 1) / 2
                    var selected: XMLNode?
                    for child in children {
                        if child.kind == .element { precedingElements += 1 }
                        if child.kind == .text && precedingElements == target { selected = child; break }
                    }
                    node = try #require(selected)
                }
            }
            return node
        }
        let shared = String(fragments[0])
        func endpoint(_ raw: Substring) throws -> (XMLNode, Int) {
            let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let offset = Int(parts[1]), offset >= 0 else {
                throw EPUBAnnotationLocatorError.invalidXHTML
            }
            return (try navigate(shared + String(parts[0])), offset)
        }
        let start = try endpoint(fragments[1])
        let end = try endpoint(fragments[2])
        var allText: [XMLNode] = []
        func collect(_ node: XMLNode) {
            if node.kind == .text { allText.append(node) }
            for child in node.children ?? [] { collect(child) }
        }
        collect(root)
        guard let startIndex = allText.firstIndex(where: { $0 === start.0 }),
              let endIndex = allText.firstIndex(where: { $0 === end.0 }),
              startIndex <= endIndex else {
            throw EPUBAnnotationLocatorError.invalidXHTML
        }
        var selection = ""
        for index in startIndex...endIndex {
            let value = (allText[index].stringValue ?? "") as NSString
            let lower = index == startIndex ? start.1 : 0
            let upper = index == endIndex ? end.1 : value.length
            guard lower <= upper, upper <= value.length else { throw EPUBAnnotationLocatorError.invalidXHTML }
            selection += value.substring(with: NSRange(location: lower, length: upper - lower))
        }
        return selection
    }

    private final class Fixture {
        let root: URL
        init(chapters: [String], ncx: [String]? = nil, nav: [String]? = nil, includeMetadata: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("epub")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("OPS"), withIntermediateDirectories: true)
            try write("""
                <container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
                <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
                </rootfiles></container>
                """, path: "META-INF/container.xml")
            let manifest = chapters.enumerated().map { index, _ in
                "<item id=\"\(index == 0 ? "chapter" : "ch\(index)")\" href=\"\(index == 0 ? "chapter" : "ch\(index)").xhtml\" media-type=\"application/xhtml+xml\"/>"
            }.joined()
            let spine = chapters.indices.map { index in
                "<itemref idref=\"\(index == 0 ? "chapter" : "ch\(index)")\"/>"
            }.joined()
            let toc = ncx == nil ? "" : "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>"
            let navManifest = nav == nil ? "" : "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
            let metadata = includeMetadata ? "<metadata/>" : ""
            try write("<package xmlns=\"http://www.idpf.org/2007/opf\">\(metadata)<manifest>\(manifest)\(toc)\(navManifest)</manifest><spine>\(spine)</spine></package>", path: "OPS/content.opf")
            for (index, text) in chapters.enumerated() { try write(text, path: "OPS/\(index == 0 ? "chapter" : "ch\(index)").xhtml") }
            if let nav {
                let links = nav.enumerated().map { i, ref in
                    "<li><a href=\"\(ref)\">Part \(i)</a></li>"
                }.joined()
                try write("<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"><body><nav epub:type=\"toc\"><ol>\(links)</ol></nav></body></html>", path: "OPS/nav.xhtml")
            }
            if let ncx {
                let points = ncx.enumerated().map { i, ref in
                    "<navPoint id=\"n\(i)\"><navLabel><text>Chapter \(i)</text></navLabel><content src=\"\(ref)\"/></navPoint>"
                }.joined()
                try write("<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\"><navMap>\(points)</navMap></ncx>", path: "OPS/toc.ncx")
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        private func write(_ text: String, path: String) throws { try Data(text.utf8).write(to: root.appendingPathComponent(path)) }
    }
}
