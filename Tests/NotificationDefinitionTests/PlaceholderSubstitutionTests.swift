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
