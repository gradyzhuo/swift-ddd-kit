//
//  MarkdownRendering.swift
//  NotificationDefinition
//
//  Markdown -> safe HTML, for the generated `render()` path. Content is authored in Markdown by a
//  trusted template author; `%placeholder%` values are untrusted data escaped before substitution
//  (see `PlaceholderSubstitution.substitute(_:values:escaping:)`). This renderer is the second half
//  of that safety story: it walks the parsed Markdown AST and emits HTML through a small, explicit
//  ALLOW-LIST — nothing outside that list is ever passed through as live markup, so even a
//  template author cannot smuggle arbitrary HTML into the rendered result.
//
//  See spec: docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3-4.
//

import Markdown

/// Renders Markdown to safe HTML via an allow-list emitter.
///
/// Only the following constructs are emitted as live HTML markup:
/// paragraph (`<p>`), emphasis (`<em>`), strong (`<strong>`), line/soft break (`<br>`),
/// link (`<a href="...">`, only when the destination starts with `http://`/`https://`),
/// unordered/ordered lists (`<ul>`/`<ol>`/`<li>`), inline code (`<code>`), blockquote
/// (`<blockquote>`), headings (`<h1>`-`<h6>`), and images (`<img src="..." alt="...">`, only
/// when the source starts with `http://`/`https://`, and with ONLY `src`/`alt` attributes — no
/// width/height/`onerror`/anything else). Every text node is HTML-escaped, and every attribute
/// value is attribute-escaped. Anything else — including raw HTML blocks/inline and
/// fenced/indented code blocks — is rendered as escaped, inert text (never dropped, never
/// passed through as markup).
public enum MarkdownRendering {

    /// Parses `markdown` and renders it to safe HTML using the allow-list emitter.
    public static func html(from markdown: String) -> String {
        let document = Document(parsing: markdown)
        var emitter = SafeHTMLEmitter()
        return emitter.visit(document)
    }
}

/// The allow-list HTML emitter. This type IS the safety guarantee described above: every
/// `visit*` override below corresponds to exactly one allowed construct, and `defaultVisit`
/// is the catch-all for everything else, which renders as escaped plain text instead of markup.
private struct SafeHTMLEmitter: MarkupVisitor {
    typealias Result = String

    mutating func defaultVisit(_ markup: Markup) -> String {
        // Not on the allow list (headings, images, raw HTML blocks/inline, tables, code
        // blocks, thematic breaks, ...): never pass through as markup. Collect whatever
        // literal text the subtree carries and HTML-escape it as inert text.
        var collector = PlainTextCollector()
        return HTMLEscaping.escape(collector.visit(markup))
    }

    mutating func visitDocument(_ document: Document) -> String {
        children(of: document)
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(children(of: paragraph))</p>"
    }

    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(children(of: emphasis))</em>"
    }

    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(children(of: strong))</strong>"
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br>"
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "<br>"
    }

    mutating func visitLink(_ link: Link) -> String {
        let inner = children(of: link)
        guard let destination = link.destination, let safeHref = SafeURL.httpOrHTTPS(destination) else {
            // Unsafe/absent scheme (e.g. `javascript:`, `data:`, relative, or no destination at
            // all): neutralize the link entirely — render its visible text, drop the anchor.
            return inner
        }
        return "<a href=\"\(HTMLEscaping.escapeAttribute(safeHref))\">\(inner)</a>"
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> String {
        "<ul>\(children(of: unorderedList))</ul>"
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> String {
        "<ol>\(children(of: orderedList))</ol>"
    }

    mutating func visitListItem(_ listItem: ListItem) -> String {
        "<li>\(children(of: listItem))</li>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(HTMLEscaping.escape(inlineCode.code))</code>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(children(of: blockQuote))</blockquote>"
    }

    mutating func visitHeading(_ heading: Heading) -> String {
        // ATX heading levels are always 1-6; clamp defensively since `level` is a plain Int.
        let level = min(max(heading.level, 1), 6)
        return "<h\(level)>\(children(of: heading))</h\(level)>"
    }

    mutating func visitImage(_ image: Image) -> String {
        // The alt text must be PLAIN text for the attribute, never HTML — collect it the same
        // way disallowed constructs collect their literal text, not via `children(of:)` (which
        // renders live HTML for allow-listed nested markup).
        var altCollector = PlainTextCollector()
        let altText = altCollector.visit(image)

        guard let source = image.source, let safeSrc = SafeURL.httpOrHTTPS(source) else {
            // Unsafe/absent src (e.g. `javascript:`, `data:`, relative, or no source at all):
            // neutralize entirely — no `<img>`, nothing that could carry an unsafe src. Render
            // the alt text (if any) as escaped inert text instead.
            return HTMLEscaping.escape(altText)
        }

        // ONLY `src` and `alt` — this is what makes an injected `onerror=`/extra attribute
        // impossible: there is no code path that emits any other attribute name.
        return "<img src=\"\(HTMLEscaping.escapeAttribute(safeSrc))\" alt=\"\(HTMLEscaping.escapeAttribute(altText))\">"
    }

    mutating func visitText(_ text: Text) -> String {
        HTMLEscaping.escape(text.string)
    }

    /// Raw HTML the Markdown parser surfaced (a block like `<div>...</div>` or an inline span
    /// like `<b>`): never emitted as markup, always escaped literal text.
    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        HTMLEscaping.escape(html.rawHTML)
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        HTMLEscaping.escape(inlineHTML.rawHTML)
    }

    private mutating func children(of markup: Markup) -> String {
        var result = ""
        for child in markup.children {
            result += visit(child)
        }
        return result
    }
}

/// Walks a disallowed subtree collecting its literal text content (never its structural
/// markup), so `SafeHTMLEmitter.defaultVisit` can render it as escaped, inert text.
private struct PlainTextCollector: MarkupVisitor {
    typealias Result = String

    mutating func defaultVisit(_ markup: Markup) -> String {
        var result = ""
        for child in markup.children {
            result += visit(child)
        }
        return result
    }

    mutating func visitText(_ text: Text) -> String {
        text.string
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        inlineCode.code
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        codeBlock.code
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        inlineHTML.rawHTML
    }
}

/// HTML escaping for text nodes and attribute values. There is exactly one escaper for both
/// uses today (attribute values need no extra characters escaped beyond the standard five).
enum HTMLEscaping {
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    static func escapeAttribute(_ text: String) -> String {
        escape(text)
    }
}

/// Validates a link destination's scheme is `http`/`https` before it may become a live `href`.
enum SafeURL {
    /// Returns `destination` unchanged if it STARTS WITH `http://` or `https://`
    /// (case-insensitive), `nil` otherwise (relative URLs, `javascript:`, `data:`, `mailto:`,
    /// malformed, or a scheme-confusable value like `http:javascript:alert(1)` whose text
    /// before the first colon reads "http" but which isn't actually an http(s) URL).
    static func httpOrHTTPS(_ destination: String) -> String? {
        let lowercased = destination.lowercased()
        guard lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") else { return nil }
        return destination
    }
}
