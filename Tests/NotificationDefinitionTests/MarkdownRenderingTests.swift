//
//  MarkdownRenderingTests.swift
//  NotificationDefinitionTests
//
//  Security-critical: `MarkdownRendering.html(from:)` is the allow-list emitter that makes it
//  safe for downstream consumers to treat rendered notification content as trusted HTML. Every
//  test here either locks in an allowed construct's exact output or proves a disallowed
//  construct/injection attempt never reaches the result as live markup.
//  See spec: docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3-4.
//

import Testing

@testable import NotificationDefinition

@Suite("MarkdownRendering")
struct MarkdownRenderingTests {

    // MARK: - Golden path: allowed constructs render as expected.

    @Test func paragraphBecomesPTag() {
        #expect(MarkdownRendering.html(from: "hello world") == "<p>hello world</p>")
    }

    @Test func emphasisAndStrong() {
        #expect(MarkdownRendering.html(from: "*em* and **strong**") == "<p><em>em</em> and <strong>strong</strong></p>")
    }

    @Test func softBreakAndHardBreakBothBecomeBr() {
        // Two spaces + newline is a hard line break in CommonMark; a bare newline is a soft break.
        #expect(MarkdownRendering.html(from: "line one  \nline two") == "<p>line one<br>line two</p>")
        #expect(MarkdownRendering.html(from: "line one\nline two") == "<p>line one<br>line two</p>")
    }

    @Test func unorderedList() {
        // swift-markdown always models list-item content as block children (here, one
        // Paragraph per item) regardless of CommonMark "tight"/"loose" list styling, which it
        // doesn't expose — so each `<li>` wraps its text in `<p>`. Still safe, still `<ul>`/`<li>`.
        #expect(MarkdownRendering.html(from: "- a\n- b") == "<ul><li><p>a</p></li><li><p>b</p></li></ul>")
    }

    @Test func orderedList() {
        #expect(MarkdownRendering.html(from: "1. a\n2. b") == "<ol><li><p>a</p></li><li><p>b</p></li></ol>")
    }

    @Test func inlineCode() {
        #expect(MarkdownRendering.html(from: "run `swift build`") == "<p>run <code>swift build</code></p>")
    }

    @Test func blockQuote() {
        #expect(MarkdownRendering.html(from: "> quoted") == "<blockquote><p>quoted</p></blockquote>")
    }

    @Test func httpsLinkRendersAsAnchor() {
        #expect(
            MarkdownRendering.html(from: "[前往查看](https://example.com)")
                == "<p><a href=\"https://example.com\">前往查看</a></p>")
    }

    @Test func httpLinkAlsoAllowed() {
        #expect(
            MarkdownRendering.html(from: "[go](http://example.com)")
                == "<p><a href=\"http://example.com\">go</a></p>")
    }

    // MARK: - Neutralized/unsafe link schemes.

    @Test func javascriptSchemeLinkIsNeutralized() {
        let html = MarkdownRendering.html(from: "[click me](javascript:alert(1))")
        #expect(!html.contains("<a"))
        #expect(!html.contains("javascript:"))
        #expect(html.contains("click me"))
    }

    @Test func dataSchemeLinkIsNeutralized() {
        let html = MarkdownRendering.html(from: "[open](data:text/html,evil)")
        #expect(!html.contains("<a"))
        #expect(!html.contains("data:"))
    }

    @Test func relativeLinkIsNeutralized() {
        let html = MarkdownRendering.html(from: "[relative](/some/path)")
        #expect(!html.contains("<a"))
    }

    // MARK: - Raw HTML in the (trusted) template is never passed through.

    @Test func rawHTMLBlockIsEscapedNotEmitted() {
        let html = MarkdownRendering.html(from: "<b>x</b>")
        #expect(!html.contains("<b>"))
        #expect(html.contains("&lt;b&gt;x&lt;/b&gt;"))
    }

    @Test func rawInlineHTMLIsEscapedNotEmitted() {
        let html = MarkdownRendering.html(from: "before <span>middle</span> after")
        #expect(!html.contains("<span>"))
        #expect(html.contains("&lt;span&gt;"))
    }

    @Test func scriptTagIsEscapedNeverLive() {
        let html = MarkdownRendering.html(from: "<script>alert(1)</script>")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    // MARK: - Excluded constructs (images, headings) render as inert text, never as markup.

    @Test func imageIsNotEmittedAsImgTag() {
        let html = MarkdownRendering.html(from: "![alt text](https://example.com/x.png)")
        #expect(!html.contains("<img"))
    }

    @Test func headingIsNotEmittedAsHeadingTag() {
        let html = MarkdownRendering.html(from: "# Heading")
        #expect(!html.contains("<h1>"))
        #expect(html.contains("Heading"))
    }

    // MARK: - Text escaping.

    @Test func ampersandAndAngleBracketsInPlainTextAreEscaped() {
        #expect(MarkdownRendering.html(from: "Tom & Jerry") == "<p>Tom &amp; Jerry</p>")
    }
}
