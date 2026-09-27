import XCTest
@testable import LLMTrayCore

final class ToolArgumentsTests: XCTestCase {
    private let weather = ToolSchema("get_weather", "Weather.", [
        .init("city", .string, aliases: ["location"]),
        .init("country_code", .string),
        .init("kind", .oneOf(["forecast", "hourly", "air", "sun"]), valueAliases: ["daily": "forecast", "sunset": "sun"]),
        .init("days", .integer),
        .init("units", .oneOf(["metric", "imperial"]), valueAliases: ["fahrenheit": "imperial"]),
    ])
    private let currency = ToolSchema("convert_currency", "Convert.", [
        .init("amount", .number, required: true),
        .init("from", .string, required: true, aliases: ["from_currency"]),
        .init("to", .string, required: true, aliases: ["to_currency"]),
    ])
    private let flags = ToolSchema("t", "T.", [.init("on", .boolean), .init("index", .integer)])

    private func parse(_ raw: String, _ schema: ToolSchema?) -> ParsedToolArguments {
        ToolArgumentParser.parse(raw, schema: schema)
    }

    // MARK: - JSON

    func testStrictJSONTakesNoRepair() {
        let p = parse(#"{"city": "Kyiv", "days": 3}"#, weather)
        XCTAssertTrue(p.isValid)
        XCTAssertEqual(p.repairs, [])
        XCTAssertEqual(p.values["city"] as? String, "Kyiv")
        XCTAssertEqual(p.values["days"] as? Int, 3)
    }

    func testEmptyAndNullAreNoArguments() {
        for raw in ["", "  ", "null", "{}"] {
            let p = parse(raw, weather)
            XCTAssertTrue(p.isValid, raw)
            XCTAssertTrue(p.values.isEmpty, raw)
        }
    }

    func testFenceAndSurroundingProse() {
        let fenced = parse("```json\n{\"city\": \"Oslo\"}\n```", weather)
        XCTAssertEqual(fenced.values["city"] as? String, "Oslo")
        XCTAssertEqual(fenced.repairs, [.fenced])
        let bare = parse("```\n{\"city\": \"Oslo\"}\n```", weather)
        XCTAssertEqual(bare.values["city"] as? String, "Oslo")
        let prose = parse(#"Sure, here you go: {"city": "Oslo"} Let me know!"#, weather)
        XCTAssertEqual(prose.values["city"] as? String, "Oslo")
        XCTAssertEqual(prose.repairs, [.surroundingText])
    }

    func testSingleQuotesTrailingCommasPythonLiteralsBareKeys() {
        let p = parse("{'city': 'Rome', units: 'metric', 'country_code': None, 'days': 2,}", weather)
        XCTAssertTrue(p.isValid)
        XCTAssertEqual(p.values["city"] as? String, "Rome")
        XCTAssertEqual(p.values["units"] as? String, "metric")
        XCTAssertNil(p.values["country_code"])
        XCTAssertEqual(p.values["days"] as? Int, 2)
        XCTAssertEqual(Set(p.repairs), [.singleQuotes, .unquotedKey, .pythonLiteral, .nullDropped, .trailingComma])
        let b = parse("{'on': True, 'index': 1}", flags)
        XCTAssertEqual(b.values["on"] as? Bool, true)
    }

    func testEscapesAndRawNewlines() {
        let p = parse("{\"city\": \"Kyiv \\u2014 \\\"UA\\\" \\ud83d\\ude00\", 'country_code': 'it\\'s'}", weather)
        XCTAssertEqual(p.values["city"] as? String, "Kyiv \u{2014} \"UA\" \u{1F600}")
        XCTAssertEqual(p.values["country_code"] as? String, "it's")
        let lyrics = ToolSchema("m", "M.", [.init("lyrics", .string)])
        let raw = parse("{\"lyrics\": \"[Verse]\nline one\n\tline two\"}", lyrics)
        XCTAssertEqual(raw.values["lyrics"] as? String, "[Verse]\nline one\n\tline two")
        XCTAssertTrue(raw.repairs.contains(.rawControlCharacter))
    }

    func testDoubleEncodedAndNestedArguments() {
        let encoded = parse(#""{\"city\": \"Lviv\"}""#, weather)
        XCTAssertEqual(encoded.values["city"] as? String, "Lviv")
        XCTAssertTrue(encoded.repairs.contains(.doubleEncoded))
        let nested = parse(#"{"name": "get_weather", "arguments": {"city": "Lviv"}}"#, weather)
        XCTAssertEqual(nested.values["city"] as? String, "Lviv")
        XCTAssertEqual(nested.repairs, [.nestedArguments])
        let nestedString = parse(#"{"arguments": "{\"city\": \"Lviv\"}"}"#, weather)
        XCTAssertEqual(nestedString.values["city"] as? String, "Lviv")
        let byName = parse(#"{"get_weather": {"city": "Lviv"}}"#, weather)
        XCTAssertEqual(byName.values["city"] as? String, "Lviv")
        // A tool whose own field is called "input" keeps it.
        let own = ToolSchema("x", "X.", [.init("input", .string)])
        XCTAssertEqual(parse(#"{"input": "abc"}"#, own).values["input"] as? String, "abc")
        // A wrapper beside real fields: which were meant is a guess.
        for raw in [#"{"arguments": {"city": "A"}, "city": "B"}"#, #"{"kind": "hourly", "arguments": {"city": "Paris"}}"#,
                    #"{"arguments": "{\"city\": \"Paris\"}", "extra": 1}"#] {
            guard case .badJSON = parse(raw, weather).problems.first else { return XCTFail("expected badJSON for \(raw)") }
        }
        // A wrapper's name holding a plain value is an unknown field.
        let plain = parse(#"{"city": "Paris", "params": "metric"}"#, weather)
        XCTAssertTrue(plain.isValid)
        XCTAssertEqual(plain.values["city"] as? String, "Paris")
        // An empty wrapper, or prose in a wrapper-named field, leaves nothing to choose.
        for raw in [#"{"city": "Paris", "params": {}}"#, #"{"city": "Paris", "arguments": "{}"}"#,
                    #"{"city": "Paris", "input": "use {\"a\": 1} here"}"#] {
            XCTAssertEqual(parse(raw, weather).values["city"] as? String, "Paris", raw)
        }
        XCTAssertTrue(parse(#"{"name": "get_weather", "arguments": {}}"#, weather).isValid)
        // "name" as a field's alias: the tool's name beside a wrapper still
        // describes the call; any other value is the field.
        let country = ToolSchema("get_country_info", "C.", [.init("country", .string, required: true, aliases: ["name"])])
        for raw in [#"{"name": "get_country_info", "arguments": {"country": "France"}}"#,
                    #"{"type": "function", "name": "Get_Country_Info", "parameters": "{\"country\": \"France\"}"}"#,
                    #"{"name": "functions.get_country_info", "arguments": {"country": "France"}}"#] {
            XCTAssertEqual(parse(raw, country).values["country"] as? String, "France", raw)
        }
        XCTAssertEqual(parse(#"{"name": "France"}"#, country).values["country"] as? String, "France")
        XCTAssertFalse(parse(#"{"name": "Spain", "arguments": {"country": "France"}}"#, country).isValid)
    }

    func testAmbiguousWrappersAreProblemsNotEmptyArguments() {
        // Two wrappers: which one was meant isn't ours to pick.
        let two = parse(#"{"args": {"city": "A"}, "arguments": {"city": "B"}}"#, weather)
        XCTAssertEqual(two.problems, [.badJSON(#"arguments wrapped twice: "args" and "arguments""#)])
        XCTAssertTrue(two.values.isEmpty)
        XCTAssertFalse(parse(#"{"arguments": {"city": "A"}, "get_weather": {"city": "A"}}"#, weather).isValid)
        // A wrapper that isn't an object, nested wrappers included.
        for raw in [#"{"arguments": "city=Lviv"}"#, #"{"arguments": "[1]"}"#, #"{"arguments": 5}"#,
                    #"{"arguments": null}"#, #"{"arguments": ""}"#, #"{"name": "get_weather", "arguments": "null"}"#,
                    #"{"name": "get_weather", "arguments": {"args": "{city"}}"#] {
            let p = parse(raw, weather)
            guard case .badJSON = p.problems.first else { return XCTFail("expected badJSON for \(raw)") }
        }
        XCTAssertNotNil(parse(#"{"arguments": 5}"#, weather).errorMessage(tool: weather))
        // Without a schema they may be the tool's own fields.
        let loose = parse(#"{"input": "abc", "params": "x"}"#, nil)
        XCTAssertTrue(loose.isValid)
        XCTAssertEqual(loose.values["input"] as? String, "abc")
        XCTAssertEqual(parse(#"{"input": "abc"}"#, nil).values["input"] as? String, "abc")
    }

    func testLargeIntegersCompareExactly() {
        let ids = ToolSchema("i", "I.", [.init("id", .string, aliases: ["ident"])])
        // Differ above 2^53, where Doubles are equal.
        XCTAssertFalse(parse(#"{"id": 9007199254740993, "id": 9007199254740992}"#, ids).isValid)
        XCTAssertEqual(parse(#"{"ID": 9007199254740993, "ident": 9007199254740992}"#, ids).problems, [.conflicting("id")])
        let same = parse(#"{"ident": 9007199254740993, "ID": 9007199254740993}"#, ids)
        XCTAssertTrue(same.isValid)
        XCTAssertEqual(same.values["id"] as? String, "9007199254740993")
        XCTAssertTrue(LenientJSON.same(3, 3.0))
        XCTAssertFalse(LenientJSON.same(9007199254740993, 9007199254740992.0))
        XCTAssertFalse(LenientJSON.same(NSNumber(value: 9007199254740993), NSNumber(value: 9007199254740992)))
        XCTAssertTrue(LenientJSON.same(NSNumber(value: 9007199254740993), 9007199254740993))
        // Beyond Int: no nearby Double stands in for it.
        guard case .badJSON(let reason) = parse(#"{"id": 123456789012345678901234}"#, ids).problems.first else {
            return XCTFail("expected badJSON")
        }
        XCTAssertTrue(reason.contains("too large"), reason)
    }

    func testNotJSONIsAProblemNotAGuess() {
        for raw in ["not json", "{city: }", "{\"city\": \"x\"", "[1, 2]", "42", "{\"a\": 1} {\"b\": 2"] {
            let p = parse(raw, weather)
            XCTAssertFalse(p.isValid, raw)
            guard case .badJSON = p.problems.first else { return XCTFail("expected badJSON for \(raw)") }
        }
        // A field twice with different values, an unknown escape: guesses.
        XCTAssertEqual(parse(#"{"city": "Kyiv", "city": "Paris"}"#, weather).problems,
                       [.badJSON(#""city" given twice with different values"#)])
        XCTAssertEqual(parse(#"{"city": "Kyiv", "city": "Kyiv"}"#, weather).values["city"] as? String, "Kyiv")
        XCTAssertFalse(parse(#"{"city": "C:\Users"}"#, weather).isValid)
        XCTAssertFalse(parse(#"{"index": true, "index": 1}"#, flags).isValid, "true isn't 1")
        XCTAssertFalse(parse(#"{"index": "1", "index": 1}"#, flags).isValid)
        // A fence with another object outside it; ``` inside a string value.
        XCTAssertFalse(parse("{\"city\":\"A\"} ```json\n{\"city\":\"B\"}\n```", weather).isValid)
        XCTAssertFalse(parse("Use this: ```json\n{\"city\":\"B\"}\n``` or {\"city\":\"A\"}", weather).isValid)
        let lyrics = ToolSchema("m", "M.", [.init("lyrics", .string)])
        XCTAssertEqual(parse(#"{"lyrics": "```verse```"}"#, lyrics).values["lyrics"] as? String, "```verse```")
        // Unbalanced nesting stays bounded.
        XCTAssertFalse(parse(String(repeating: "[", count: 500), nil).isValid)
    }

    func testNoSchemaReadsJSONOnly() {
        let p = parse("{'anything': 5, 'other': 'x',}", nil)
        XCTAssertTrue(p.isValid)
        XCTAssertEqual(p.values["anything"] as? Int, 5)
        XCTAssertEqual(p.values["other"] as? String, "x")
    }

    // MARK: - Fields

    func testAliasesAndSpellings() {
        let p = parse(#"{"location": "Kyiv", "Country-Code": "UA", "KIND": "air"}"#, weather)
        XCTAssertEqual(p.values["city"] as? String, "Kyiv")
        XCTAssertEqual(p.values["country_code"] as? String, "UA")
        XCTAssertEqual(p.values["kind"] as? String, "air")
        XCTAssertEqual(p.repairs, [.fieldAlias])
        let camel = parse(#"{"countryCode": "UA"}"#, weather)
        XCTAssertEqual(camel.values["country_code"] as? String, "UA")
    }

    func testDeclaredNameWinsOverAlias() {
        let p = parse(#"{"from_currency": "EUR", "from": "USD", "to": "JPY", "amount": 1}"#, currency)
        XCTAssertEqual(p.values["from"] as? String, "USD")
        XCTAssertTrue(p.repairs.contains(.unknownField))
        // Two aliases disagreeing: neither is picked.
        let place = ToolSchema("w", "W.", [.init("city", .string, aliases: ["location", "place"])])
        let conflict = parse(#"{"location": "Kyiv", "place": "Paris"}"#, place)
        XCTAssertEqual(conflict.problems, [.conflicting("city")])
        XCTAssertEqual(conflict.problems.first?.statsKind, "bad_value")
        XCTAssertTrue(conflict.errorMessage(tool: place)?.contains(#"Retry: w({"city":"<city>"})"#) == true)
        XCTAssertEqual(parse(#"{"location": "Kyiv", "place": "Kyiv"}"#, place).values["city"] as? String, "Kyiv")
    }

    func testUnknownFieldsAreIgnored() {
        let p = parse(#"{"city": "Kyiv", "limit": 5, "verbose": true}"#, weather)
        XCTAssertTrue(p.isValid)
        XCTAssertNil(p.values["limit"])
        XCTAssertEqual(p.repairs, [.unknownField])
    }

    func testTypeCoercion() {
        let p = parse(#"{"amount": "12.5", "from": " usd ", "to": "EUR"}"#, currency)
        XCTAssertTrue(p.isValid)
        XCTAssertEqual(p.values["amount"] as? Double, 12.5)
        XCTAssertEqual(p.values["from"] as? String, "usd")
        XCTAssertEqual(Set(p.repairs), [.typeCoerced, .whitespace])
        let ints = parse(#"{"days": "4"}"#, weather)
        XCTAssertEqual(ints.values["days"] as? Int, 4)
        let integral = parse(#"{"days": 4.0}"#, weather)
        XCTAssertEqual(integral.values["days"] as? Int, 4)
        XCTAssertEqual(integral.repairs, [.typeCoerced])
        let intAmount = parse(#"{"amount": 100, "from": "USD", "to": "EUR"}"#, currency)
        XCTAssertEqual(intAmount.values["amount"] as? Double, 100)
        XCTAssertEqual(intAmount.repairs, [])
        let numberAsString = parse(#"{"city": 1905}"#, weather)
        XCTAssertEqual(numberAsString.values["city"] as? String, "1905")
        let bools = parse(#"{"on": "TRUE"}"#, flags)
        XCTAssertEqual(bools.values["on"] as? Bool, true)
    }

    func testAmbiguousValuesAreProblems() {
        // A decimal comma or a thousands separator: either reading is a guess.
        for (amount, shown) in [(#""1,5""#, #""1,5""#), (#""1,000""#, #""1,000""#), (#""ten""#, #""ten""#), ("true", "true"), ("[1]", "a list")] {
            let p = parse(#"{"amount": \#(amount), "from": "USD", "to": "EUR"}"#, currency)
            XCTAssertEqual(p.problems, [.wrongType("amount", shown)], amount)
        }
        XCTAssertEqual(parse(#"{"days": 2.5}"#, weather).problems, [.wrongType("days", "2.5")])
        // A boolean isn't an index (true would read as 1).
        XCTAssertEqual(parse(#"{"index": true}"#, flags).problems, [.wrongType("index", "true")])
        XCTAssertEqual(parse(#"{"on": "yes"}"#, flags).problems, [.wrongType("on", "\"yes\"")])
    }

    func testEnumsCaseAndAliases() {
        XCTAssertEqual(parse(#"{"kind": " Hourly "}"#, weather).values["kind"] as? String, "hourly")
        XCTAssertEqual(parse(#"{"kind": "daily"}"#, weather).values["kind"] as? String, "forecast")
        XCTAssertEqual(parse(#"{"units": "Fahrenheit"}"#, weather).values["units"] as? String, "imperial")
        XCTAssertEqual(parse(#"{"kind": "rain"}"#, weather).problems, [.notAllowed("kind", "\"rain\"")])
        XCTAssertEqual(parse(#"{"kind": 3}"#, weather).problems, [.wrongType("kind", "3")])
    }

    func testMissingRequired() {
        let p = parse(#"{"amount": 5, "from": "USD", "to": null}"#, currency)
        XCTAssertEqual(p.problems, [.missing("to")])
        XCTAssertEqual(p.problems.first?.statsKind, "missing_field")
    }

    // MARK: - Errors

    func testErrorNamesTheFieldAndShowsARetry() throws {
        let p = parse(#"{"amount": "ten", "from_currency": "USD"}"#, currency)
        let message = try XCTUnwrap(p.errorMessage(tool: currency))
        XCTAssertEqual(message, #"convert_currency: "amount" must be a number, not "ten"; "to" is required (string). "#
                       + #"Retry: convert_currency({"amount":<number>,"from":"USD","to":"<to>"})"#)
        let e = parse(#"{"city": "Rome", "kind": "rain"}"#, weather)
        XCTAssertEqual(e.errorMessage(tool: weather), #"get_weather: "kind" must be one of forecast, hourly, air, sun, not "rain". "#
                       + #"Retry: get_weather({"city":"Rome","kind":"forecast|hourly|air|sun"})"#)
        let bad = parse("nope", currency)
        XCTAssertEqual(bad.errorMessage(tool: currency), #"convert_currency: arguments aren't a JSON object (unexpected word nope). "#
                       + #"Retry: convert_currency({"amount":<number>,"from":"<from>","to":"<to>"})"#)
        XCTAssertNil(parse(#"{"city": "Rome"}"#, weather).errorMessage(tool: weather))
    }

    func testLongValuesAreCutInErrors() {
        let long = String(repeating: "x", count: 200)
        let p = parse(#"{"kind": "\#(long)"}"#, weather)
        XCTAssertLessThan(try XCTUnwrap(p.errorMessage(tool: weather)).count, 200)
    }

    // MARK: - Declaration

    func testDefinitionShape() throws {
        let def = currency.definition
        let function = try XCTUnwrap(def["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "convert_currency")
        let parameters = try XCTUnwrap(function["parameters"] as? [String: Any])
        XCTAssertEqual(parameters["required"] as? [String], ["amount", "from", "to"])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["amount"]?["type"] as? String, "number")
        XCTAssertNil(properties["amount"]?["description"])
        let w = try XCTUnwrap((weather.definition["function"] as? [String: Any])?["parameters"] as? [String: Any])
        XCTAssertNil(w["required"], "no empty required list")
        XCTAssertEqual((w["properties"] as? [String: [String: Any]])?["kind"]?["enum"] as? [String], ["forecast", "hourly", "air", "sun"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(def))
    }

    // MARK: - Tool names

    func testToolNames() {
        let known = ["calculate", "web_search", "get_weather"]
        let former: [String: (tool: String, arguments: [String: String])] = ["news": ("web_search", ["source": "news"])]
        XCTAssertEqual(ToolNameResolver.resolve("calculate", known: known, former: former)?.repair, nil)
        XCTAssertEqual(ToolNameResolver.resolve("Calculate", known: known, former: former)?.name, "calculate")
        XCTAssertEqual(ToolNameResolver.resolve("functions.web_search", known: known, former: former)?.repair, .toolName)
        let old = ToolNameResolver.resolve("news", known: known, former: former)
        XCTAssertEqual(old?.name, "web_search")
        XCTAssertEqual(old?.impliedArguments, ["source": "news"])
        XCTAssertEqual(old?.repair, .formerToolName)
        XCTAssertEqual(ToolNameResolver.resolve("get-weather", known: known, former: former)?.name, "get_weather")
        let hn: [String: (tool: String, arguments: [String: String])] = ["hackernews": ("web_search", ["source": "hackernews"])]
        XCTAssertEqual(ToolNameResolver.resolve("hacker_news", known: known, former: hn)?.impliedArguments, ["source": "hackernews"])
        XCTAssertNil(ToolNameResolver.resolve("calc", known: known, former: former), "no fuzzy guesses")
        XCTAssertNil(ToolNameResolver.resolve("news", known: ["calculate"], former: former), "former target not declared")
    }
}
