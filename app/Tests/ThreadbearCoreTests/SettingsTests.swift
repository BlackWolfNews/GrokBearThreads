import XCTest
@testable import ThreadbearCore

final class SettingsTests: XCTestCase {
    func testSettingsDecodeFullAndTolerateUnknownFields() throws {
        let json = """
        {"defaultCwd":"/Users/m/dev/me/misc","idleMinutes":45,"maxLiveCLIs":4,"followMain":false,"somethingNew":1,
         "models":{"openRouterKey":{"set":true,"hint":"a1b2","extra":true},"dailyBudgetUsd":2.5,"spentTodayUsd":0.0123,
                   "spentMonthUsd":0.4,"privateFolders":["~/dev/client",3,"/tmp/x"],"later":{}}}
        """
        let settings = try JSONDecoder().decode(RunnerSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.defaultCwd, "/Users/m/dev/me/misc")
        XCTAssertEqual(settings.idleMinutes, 45)
        XCTAssertEqual(settings.maxLiveCLIs, 4)
        XCTAssertFalse(settings.followMain)
        XCTAssertEqual(settings.models.openRouterKey, RunnerSettings.Key(set: true, hint: "a1b2"))
        XCTAssertEqual(settings.models.dailyBudgetUsd, 2.5)
        XCTAssertEqual(settings.models.spentTodayUsd, 0.0123)
        XCTAssertEqual(settings.models.spentMonthUsd, 0.4)
        XCTAssertEqual(settings.models.privateFolders, ["~/dev/client", "/tmp/x"], "a folder that isn't a string is skipped")
        XCTAssertFalse(settings.models.poolSupported, "an older runner sends no pool")
        XCTAssertNil(settings.models.pool)
    }

    func testPoolDecodesAsAnIdOrNull() throws {
        let on = try JSONDecoder().decode(RunnerSettings.self, from: Data(#"{"models":{"pool":"claude"}}"#.utf8))
        XCTAssertTrue(on.models.poolSupported)
        XCTAssertEqual(on.models.pool, "claude")
        let off = try JSONDecoder().decode(RunnerSettings.self, from: Data(#"{"models":{"pool":null}}"#.utf8))
        XCTAssertTrue(off.models.poolSupported, "null is OpenRouter only, from a runner that knows pools")
        XCTAssertNil(off.models.pool)
    }

    func testEmptySettingsTakeTheDefaults() throws {
        let settings = try JSONDecoder().decode(RunnerSettings.self, from: Data(#"{"models":{"openRouterKey":{"hint":""}}}"#.utf8))
        XCTAssertEqual(settings, RunnerSettings())
        XCTAssertEqual(settings.models.dailyBudgetUsd, 1, "the budget defaults to a dollar a day")
        XCTAssertNil(settings.models.openRouterKey.hint, "an empty hint is no hint")
    }

    func testUpdateSendsOnlyWhatChanged() {
        XCTAssertEqual(SettingsUpdate(idleMinutes: 20).params, ["idleMinutes": .number(20)])
        XCTAssertEqual(SettingsUpdate(followMain: false, dailyBudgetUsd: 0).params,
                       ["followMain": .bool(false), "models": .object(["dailyBudgetUsd": .number(0)])])
        XCTAssertEqual(SettingsUpdate(privateFolders: []).params, ["models": .object(["privateFolders": .array([])])],
                       "an empty list clears the folders, so it's still sent")
        XCTAssertEqual(SettingsUpdate(pool: "convex").params, ["models": .object(["pool": .string("convex")])])
        XCTAssertEqual(SettingsUpdate(pool: .some(nil)).params, ["models": .object(["pool": .null])],
                       "OpenRouter only is sent as null")
        XCTAssertEqual(SettingsUpdate().params, [:])
    }

    func testSetKeySendsNullToRemove() async throws {
        let transport = FakeTransport()
        transport.onSend = { request in
            [E.json(["jsonrpc": "2.0", "id": request["id"]!, "result": ["settings": ["models": ["openRouterKey": ["set": false]]]]])]
        }
        let client = RPCClient(transport: transport)
        try await client.start()
        let settings = try await client.settingsSetKey(key: nil)
        XCTAssertFalse(settings.models.openRouterKey.set)
        let sent = try XCTUnwrap(transport.sent.last)
        XCTAssertEqual(sent["method"] as? String, "settings.setKey")
        let params = try XCTUnwrap(sent["params"] as? [String: Any])
        XCTAssertEqual(params["provider"] as? String, "openrouter")
        XCTAssertTrue(params["key"] is NSNull, "removing sends key: null, not a missing key")
    }

    func testSettingsUpdatedNotification() async throws {
        let transport = FakeTransport()
        let client = RPCClient(transport: transport)
        try await client.start()
        transport.push(E.json(["jsonrpc": "2.0", "method": "settings.updated",
                               "params": ["settings": ["idleMinutes": 10, "models": ["spentTodayUsd": 0.2]]]]))
        var iterator = client.notifications.makeAsyncIterator()
        guard case .settingsUpdated(let settings)? = await iterator.next() else { return XCTFail("no settings.updated") }
        XCTAssertEqual(settings.idleMinutes, 10)
        XCTAssertEqual(settings.models.spentTodayUsd, 0.2)
    }
}

final class SettingsTextTests: XCTestCase {
    func testMoney() {
        XCTAssertEqual(SettingsText.money(0), "$0")
        XCTAssertEqual(SettingsText.money(0.0004), "under $0.01")
        XCTAssertEqual(SettingsText.money(0.4187), "$0.42")
        XCTAssertEqual(SettingsText.money(1), "$1.00")
        XCTAssertEqual(SettingsText.money(.nan), "$0")
    }

    func testFolder() {
        XCTAssertEqual(SettingsText.folder("/Users/m/dev/x", home: "/Users/m"), "~/dev/x")
        XCTAssertEqual(SettingsText.folder("/Users/m", home: "/Users/m"), "~")
        XCTAssertEqual(SettingsText.folder("/Users/mo/dev", home: "/Users/m"), "/Users/mo/dev", "a sibling home isn't inside it")
        XCTAssertEqual(SettingsText.folder("~/already", home: "/Users/m"), "~/already")
    }
}
