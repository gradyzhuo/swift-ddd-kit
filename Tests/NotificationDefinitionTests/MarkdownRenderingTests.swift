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

    // MARK: - Code blocks: allow-listed as `<pre><code>`, content always HTML-escaped.

    @Test func fencedCodeBlockContentSurvivesAsPreCode() {
        #expect(MarkdownRendering.html(from: "```\nsecret\n```") == "<pre><code>secret\n</code></pre>")
    }

    @Test func fencedCodeBlockWithHTMLSpecialCharsIsEscaped() {
        let html = MarkdownRendering.html(from: "```\n<script>alert(1)</script>\n```")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    @Test func indentedCodeBlockContentSurvivesAsPreCode() {
        let html = MarkdownRendering.html(from: "    secret indented code")
        #expect(html.contains("<pre><code>"))
        #expect(html.contains("secret indented code"))
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

    @Test func schemeConfusableDestinationIsNeutralized() {
        // The text before the first colon reads "http", but this isn't an http(s) URL —
        // `SafeURL.httpOrHTTPS` must require the destination to actually START WITH
        // "http://"/"https://", not just have "http"/"https" as the substring before ":".
        let html = MarkdownRendering.html(from: "[click](http:javascript:alert(1))")
        #expect(!html.contains("<a"))
        #expect(!html.contains("javascript:alert(1)\""))
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

    // MARK: - Headings.

    @Test func h1Heading() {
        #expect(MarkdownRendering.html(from: "# H1") == "<h1>H1</h1>")
    }

    @Test func h6Heading() {
        #expect(MarkdownRendering.html(from: "###### H6") == "<h6>H6</h6>")
    }

    @Test func headingTextContentIsEscaped() {
        #expect(MarkdownRendering.html(from: "# Tom & Jerry <script>") == "<h1>Tom &amp; Jerry &lt;script&gt;</h1>")
    }

    // MARK: - Images: same http(s)-only safety rule as links, and an attribute allow-list of
    // exactly `src`/`alt` — this is what makes an injected `onerror=`/extra attribute impossible.

    @Test func httpsImageRendersAsImgTag() {
        #expect(
            MarkdownRendering.html(from: "![cat](https://example.com/c.png)")
                == "<p><img src=\"https://example.com/c.png\" alt=\"cat\"></p>")
    }

    @Test func imageEmitsOnlySrcAndAltAttributes() {
        let html = MarkdownRendering.html(from: "![cat](https://example.com/c.png)")
        // No other attribute name can appear — the emitter has no code path that writes one.
        #expect(!html.contains("onerror"))
        #expect(!html.contains("width"))
        #expect(!html.contains("height"))
        #expect(html.contains("<img src=\"https://example.com/c.png\" alt=\"cat\">"))
    }

    @Test func javascriptSchemeImageIsNeutralized() {
        let html = MarkdownRendering.html(from: "![x](javascript:alert(1))")
        #expect(!html.contains("<img"))
        #expect(!html.contains("javascript:"))
    }

    @Test func dataSchemeImageIsNeutralized() {
        let html = MarkdownRendering.html(from: "![x](data:text/html,evil)")
        #expect(!html.contains("<img"))
        #expect(!html.contains("data:"))
    }

    @Test func relativeImageSrcIsNeutralized() {
        let html = MarkdownRendering.html(from: "![x](/rel)")
        #expect(!html.contains("<img"))
    }

    @Test func imageAltTextInjectionIsAttributeEscaped() {
        // Alt text containing quote+tag syntax must never be able to break out of the `alt="..."`
        // attribute or introduce a live tag.
        let html = MarkdownRendering.html(from: #"![">\<script>](https://example.com/x.png)"#)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("onerror"))
        // Exactly one live tag (the `<img>` itself) — no attribute breakout introduced a second.
        #expect(html.contains("<img src=\"https://example.com/x.png\" alt="))
    }

    @Test func imageSrcWithEmbeddedQuoteIsAttributeEscaped() {
        // A destination containing a literal `"` (no injected extra attribute is possible: the
        // emitter only ever writes `src`/`alt`, and the quote itself is attribute-escaped).
        let html = MarkdownRendering.html(from: #"![x](https://example.com/a"b.png)"#)
        #expect(!html.contains("onerror"))
        if let range = html.range(of: "src=\"") {
            let afterSrc = html[range.upperBound...]
            guard let closingQuote = afterSrc.range(of: "\"") else {
                Issue.record("no closing quote found for src attribute")
                return
            }
            let srcValue = afterSrc[afterSrc.startIndex..<closingQuote.lowerBound]
            // The raw `"` must have been escaped to `&quot;`, not left as a literal delimiter.
            #expect(!srcValue.contains("\""))
        } else {
            Issue.record("no <img src=\"...\"> attribute found")
        }
    }

    // MARK: - Text escaping.

    @Test func ampersandAndAngleBracketsInPlainTextAreEscaped() {
        #expect(MarkdownRendering.html(from: "Tom & Jerry") == "<p>Tom &amp; Jerry</p>")
    }

    // MARK: - GFM: strikethrough, task lists, tables, thematic break, nested lists.

    @Test func strikethrough() {
        #expect(MarkdownRendering.html(from: "~~gone~~") == "<p><del>gone</del></p>")
    }

    @Test func taskListCheckedAndUnchecked() {
        let html = MarkdownRendering.html(from: "- [ ] todo\n- [x] done")
        #expect(html.contains(#"<input type="checkbox" disabled> "#))
        #expect(html.contains(#"<input type="checkbox" checked disabled> "#))
        #expect(html.contains("todo"))
        #expect(html.contains("done"))
    }

    @Test func thematicBreakBecomesHr() {
        #expect(MarkdownRendering.html(from: "a\n\n---\n\nb") == "<p>a</p><hr><p>b</p>")
    }

    @Test func nestedUnorderedList() {
        let html = MarkdownRendering.html(from: "- a\n  - nested\n- b")
        #expect(html.contains("<ul><li>"))
        // The nested list is itself an allow-listed <ul>, not flattened away or escaped.
        #expect(html.contains("<ul><li><p>nested</p></li></ul>"))
    }

    @Test func tableWithAlignment() {
        let markdown = """
        | Left | Center | Right |
        |:-----|:------:|------:|
        | a | b | c |
        """
        let html = MarkdownRendering.html(from: markdown)
        #expect(html.hasPrefix("<table><thead><tr>"))
        #expect(html.contains(#"<th style="text-align:left">Left</th>"#))
        #expect(html.contains(#"<th style="text-align:center">Center</th>"#))
        #expect(html.contains(#"<th style="text-align:right">Right</th>"#))
        #expect(html.contains(#"<td style="text-align:left">a</td>"#))
        #expect(html.contains(#"<td style="text-align:center">b</td>"#))
        #expect(html.contains(#"<td style="text-align:right">c</td>"#))
        #expect(html.contains("<tbody>"))
        #expect(html.hasSuffix("</table>"))
    }

    @Test func tableCellContentIsEscaped() {
        let markdown = """
        | H |
        |---|
        | <script>alert(1)</script> |
        """
        let html = MarkdownRendering.html(from: markdown)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    // MARK: - Injection: raw HTML written directly in the (trusted) template source must still
    // never execute, regardless of how "real" it looks (an <img onerror=...> is exactly the
    // classic raw-HTML XSS payload).

    @Test func rawImgWithOnerrorInSourceIsEscapedNotLive() {
        let html = MarkdownRendering.html(from: #"<img src=x onerror=alert(1)>"#)
        // The text survives (visible, inert) but there is no live `<img` tag — the `onerror`
        // text is just escaped literal characters, not a parsed attribute a browser could run.
        #expect(!html.contains("<img"))
        #expect(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    @Test func rawScriptTagInSourceIsEscapedNotLive() {
        let html = MarkdownRendering.html(from: "<script>alert(document.cookie)</script>")
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;alert(document.cookie)&lt;/script&gt;"))
    }
}
