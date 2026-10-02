import Testing

@testable import TemplateVariables

@Suite("PlaceholderSubstitution")
struct PlaceholderSubstitutionTests {

    @Test func substitutesSingleToken() throws {
        let out = try PlaceholderSubstitution.substitute(
            "%CustomerName% 您好", values: ["CustomerName": "6666"])
        #expect(out == "6666 您好")
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

    // A template that already contains raw `"` and `\` characters must render verbatim:
    // the substitution engine performs no escaping of its own.
    @Test func quotesAndBackslashesRenderVerbatim() throws {
        let template = #"He said "hi" and used \ backslash, then %Name% replied."#
        let out = try PlaceholderSubstitution.substitute(template, values: ["Name": "she"])
        #expect(out == #"He said "hi" and used \ backslash, then she replied."#)
    }
}
