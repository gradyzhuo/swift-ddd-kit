import Testing

@testable import NotificationDefinition

@Suite("PlaceholderSubstitution")
struct PlaceholderSubstitutionTests {

    @Test func substitutesSingleToken() throws {
        let out = try PlaceholderSubstitution.substitute(
            "你已被加入案件「%QuotingCaseGroupName%」", values: ["QuotingCaseGroupName": "6666"])
        #expect(out == "你已被加入案件「6666」")
    }

    @Test func substitutesRepeatedAndAdjacentTokens() throws {
        let out = try PlaceholderSubstitution.substitute(
            "%A%%B%-%A%", values: ["A": "x", "B": "y"])
        #expect(out == "xy-x")
    }

    @Test func missingValueThrows() {
        #expect(throws: PlaceholderSubstitutionError.missingValue(placeholder: "Gone")) {
            _ = try PlaceholderSubstitution.substitute("hi %Gone%", values: [:])
        }
    }

    @Test func nonTokenPercentSignsPassThrough() throws {
        let out = try PlaceholderSubstitution.substitute(
            "50%% off %A% 100% sure", values: ["A": "v"])
        #expect(out == "50%% off v 100% sure")
    }

    @Test func valuesContainingPercentAreNotReSubstituted() throws {
        let out = try PlaceholderSubstitution.substitute(
            "%A% %B%", values: ["A": "%B%", "B": "z"])
        #expect(out == "%B% z")
    }

    @Test func textWithoutTokensPassesThrough() throws {
        #expect(try PlaceholderSubstitution.substitute("plain", values: [:]) == "plain")
    }

    // Demo-style end-to-end check for the escaping finding: a template that already contains raw
    // `"` and `\` characters (i.e. what a generated Swift string literal decodes to at runtime)
    // must render verbatim — the substitution engine has no escaping logic of its own to trip on.
    @Test func quotesAndBackslashesRenderVerbatim() throws {
        let template = #"He said "hi" and used \ backslash, then %Name% replied."#
        let out = try PlaceholderSubstitution.substitute(template, values: ["Name": "she"])
        #expect(out == #"He said "hi" and used \ backslash, then she replied."#)
    }
}

// MARK: - `.markdown` escaping mode

// Security-critical: `escaping: .markdown` is the FIRST half of the content-rendering safety
// story (see docs/superpowers/specs/2026-09-09-markdown-notification-content-design.md §3) — a
// substituted value must become inert literal text once the merged Markdown is parsed, never
// live Markdown syntax. `MarkdownRenderingTests` covers the second half (the HTML emitter).
@Suite("PlaceholderSubstitution.substitute(_:values:escaping:.markdown)")
struct PlaceholderSubstitutionMarkdownEscapingTests {

    @Test func plainValueIsUnaffected() throws {
        // Only the substituted VALUE is escaped — the template's own "!" is trusted and passes
        // through untouched.
        let out = try PlaceholderSubstitution.substitute("Hi %Name%!", values: ["Name": "Grady"], escaping: .markdown)
        #expect(out == "Hi Grady!")
        #expect(MarkdownRendering.html(from: out) == "<p>Hi Grady!</p>")
    }

    @Test func valueContainingMarkdownSpecialCharsIsBackslashEscaped() throws {
        let out = try PlaceholderSubstitution.substitute("Note: %V%", values: ["V": "wow!"], escaping: .markdown)
        #expect(out == #"Note: wow\!"#)
        // The escaped "!" still reads as a literal "!" once rendered.
        #expect(MarkdownRendering.html(from: out) == "<p>Note: wow!</p>")
    }

    @Test func linkSyntaxInValueIsInert() throws {
        let template = "%Payload%"
        let out = try PlaceholderSubstitution.substitute(template, values: ["Payload": "[evil](http://x)"], escaping: .markdown)
        let html = MarkdownRendering.html(from: out)
        #expect(!html.contains("<a"))
        #expect(html.contains("[evil](http://x)"))
    }

    @Test func scriptTagInValueIsInert() throws {
        let template = "%Payload%"
        let out = try PlaceholderSubstitution.substitute(
            template, values: ["Payload": "<script>alert(1)</script>"], escaping: .markdown)
        let html = MarkdownRendering.html(from: out)
        #expect(!html.contains("<script>"))
        #expect(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    @Test func javascriptURLReachingAnHrefPositionIsNeutralized() throws {
        // Template author writes a link whose destination is a placeholder; a hostile value
        // tries to smuggle a `javascript:` URL into the href position.
        let template = "[click](%Url%)"
        let out = try PlaceholderSubstitution.substitute(template, values: ["Url": "javascript:alert(1)"], escaping: .markdown)
        let html = MarkdownRendering.html(from: out)
        #expect(!html.contains("<a"))
        #expect(!html.contains("javascript:alert(1)\""))
    }

    @Test func markdownStructuralCharactersAreEscaped() throws {
        let out = try PlaceholderSubstitution.substitute(
            "%V%", values: ["V": #"*_{}[]()#+-.!`\<>"#], escaping: .markdown)
        // Every character from the input must reappear (escaped), and none of it should parse
        // as Markdown syntax once rendered.
        let html = MarkdownRendering.html(from: out)
        #expect(!html.contains("<em>"))
        #expect(!html.contains("<strong>"))
        #expect(!html.contains("<code>"))
        #expect(!html.contains("<ul>"))
    }

    @Test func plainSubstituteLeavesAmpersandAndAngleBracketLiteral() throws {
        // Regression lock: subject/title fields use plain `substitute(_:values:)` — no
        // Markdown escaping, no HTML escaping. `&` and `<` must pass through verbatim.
        let out = try PlaceholderSubstitution.substitute("Case %Name%", values: ["Name": "A & B < C"])
        #expect(out == "Case A & B < C")
    }
}
