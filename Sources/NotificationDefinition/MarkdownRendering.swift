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
//  Why a hand-rolled visitor instead of cmark-gfm's own `cmark_render_html`:
//  swift-markdown already parses full CommonMark + GFM (tables, strikethrough, task lists) via
//  its bundled `cmark_gfm`/`cmark_gfm_extensions` C targets (see
//  `Parser/CommonMarkConverter.swift`'s `cmark_parser_attach_syntax_extension` calls for
//  "table"/"strikethrough"/"tasklist") — no extra dependency is needed to get a complete AST.
//  `cmark_render_html` (importable directly via `import cmark_gfm`, transitively available
//  through this same swift-markdown dependency, and already Linux-clean since swift-markdown
//  itself ships and is tested on Linux) IS reachable from Swift, and its default/"safe" mode
//  (no `CMARK_OPT_UNSAFE`) does neutralize unsafe link schemes correctly. BUT its raw-HTML
//  handling replaces raw HTML with an HTML *comment placeholder* — i.e. it silently drops the
//  content — rather than emitting it as escaped, VISIBLE text. That fails this framework's
//  explicit contract (a template's raw HTML, or a code block, must survive as escaped text, never
//  vanish) and would reintroduce the same "content silently disappears" defect already fixed
//  once for `CodeBlock` here. So this file keeps walking the (already complete) `Markup` AST
//  itself and emits HTML through the allow-list below, which both fully supports CommonMark+GFM
//  AND preserves every text byte the author wrote as visible text.
//
//  See spec: docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3-4.
//

import Markdown

/// Renders Markdown to safe HTML via an allow-list emitter.
///
/// Emitted as live HTML markup: paragraph (`<p>`), emphasis (`<em>`), strong (`<strong>`),
/// line/soft break (`<br>`), link (`<a href="...">`, only when the destination starts with
/// `http://`/`https://`), unordered/ordered lists (`<ul>`/`<ol>`/`<li>`, including nested
/// lists and GFM task-list checkboxes as a disabled `<input type="checkbox">`), inline code
/// (`<code>`), fenced/indented code blocks (`<pre><code>`, content escaped), blockquote
/// (`<blockquote>`), headings (`<h1>`-`<h6>`), thematic breaks (`<hr>`), GFM strikethrough
/// (`<del>`), GFM tables (`<table>`/`<thead>`/`<tbody>`/`<tr>`/`<th>`/`<td>`, with column
/// alignment as a fixed `style="text-align:..."` value — never attacker-controlled), and images
/// (`<img src="..." alt="...">`, only when the source starts with `http://`/`https://`, and with
/// ONLY `src`/`alt` attributes — no width/height/`onerror`/anything else). Every text node is
/// HTML-escaped, and every attribute value is attribute-escaped. Anything else — including raw
/// HTML blocks/inline — is rendered as escaped, inert text (never dropped, never passed through
/// as markup).
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
        // Not on the allow list (raw HTML blocks/inline, DocC-only constructs like
        // BlockDirective/SymbolLink/InlineAttributes/Doxygen*, ...): never pass through as
        // markup. Collect whatever literal text the subtree carries and HTML-escape it as
        // inert text.
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
        // GFM task list: `checkbox` is non-nil only for `- [ ]`/`- [x]` items. The checkbox is
        // always exactly this fixed, constant markup — never influenced by document content —
        // so there is no attribute-injection surface here.
        let checkbox: String
        switch listItem.checkbox {
        case .checked: checkbox = "<input type=\"checkbox\" checked disabled> "
        case .unchecked: checkbox = "<input type=\"checkbox\" disabled> "
        case nil: checkbox = ""
        }
        return "<li>\(checkbox)\(children(of: listItem))</li>"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(HTMLEscaping.escape(inlineCode.code))</code>"
    }

    /// Fenced or indented code block. Not raw HTML — a code block's content is data to display,
    /// not markup to interpret — so, unlike raw HTML, it's allow-listed directly as `<pre><code>`
    /// rather than falling back to `defaultVisit`'s plain-text escaping. Its text is still fully
    /// HTML-escaped, so embedded `<script>`/`</code>` etc. cannot break out.
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        "<pre><code>\(HTMLEscaping.escape(codeBlock.code))</code></pre>"
    }

    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr>"
    }

    mutating func visitStrikethrough(_ strikethrough: Strikethrough) -> String {
        "<del>\(children(of: strikethrough))</del>"
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(children(of: blockQuote))</blockquote>"
    }

    /// GFM table. Handled monolithically here (rather than via separate `visitTableHead`/
    /// `visitTableRow`/`visitTableCell` overrides) because a cell's tag (`<th>` vs `<td>`) and
    /// its column's alignment depend on where the cell sits, not on the cell node itself —
    /// context that's easiest to track by walking `head`/`body` directly instead of through the
    /// generic dispatch. Column alignment is one of exactly three fixed, code-controlled
    /// strings — never attacker-controlled — so it carries no injection surface.
    mutating func visitTable(_ table: Table) -> String {
        let alignments = table.columnAlignments

        var result = "<table><thead><tr>"
        for (index, cell) in table.head.children.enumerated() {
            result += "<th\(alignmentAttribute(forColumn: index, in: alignments))>\(children(of: cell))</th>"
        }
        result += "</tr></thead>"

        var bodyRows = ""
        for row in table.body.rows {
            bodyRows += "<tr>"
            for (index, cell) in row.children.enumerated() {
                bodyRows += "<td\(alignmentAttribute(forColumn: index, in: alignments))>\(children(of: cell))</td>"
            }
            bodyRows += "</tr>"
        }
        if !bodyRows.isEmpty {
            result += "<tbody>\(bodyRows)</tbody>"
        }
        result += "</table>"
        return result
    }

    private func alignmentAttribute(forColumn index: Int, in alignments: [Table.ColumnAlignment?]) -> String {
        guard index < alignments.count, let alignment = alignments[index] else { return "" }
        switch alignment {
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
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
