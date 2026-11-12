import Foundation
import Testing

@testable import LeoKit

private func engine(_ verbs: [LeoPluginAgentVerb]) -> LeoPluginPermissionEngine {
    LeoPluginPermissionEngine(permissions: LeoPluginPermissions(agents: verbs))
}

private func object(_ value: LeoJSONValue) -> [String: LeoJSONValue] {
    guard case .object(let fields) = value else {
        Issue.record("expected an object, got \(value)")
        return [:]
    }
    return fields
}

struct LeoPluginUsageSnapshotTests {
    private static let full = LeoAgentUsage(
        session: LeoUsageTotals(tokens: 9_000, costUSD: 35.36),
        context: LeoContextUsage(
            tokens: 154_000, window: 200_000, percent: 77,
            breakdown: LeoContextBreakdown(system: 3000, tools: 12_000, messages: 139_000), compactAt: 0.9),
        model: "observed-model", effort: "high",
        rateLimits: [LeoRateLimit(kind: .fiveHour, percentUsed: 42.5, resetsAt: Date(timeIntervalSince1970: 1_794_459_600))],
        git: LeoGitDelta(added: 120, removed: 7))

    private func value(
        _ usage: LeoAgentUsage?, configured: String? = nil, reports: Bool = true, verbs: [LeoPluginAgentVerb] = [.usage]
    ) throws -> LeoJSONValue {
        try LeoPluginUsageSnapshot.value(
            reading: LeoPluginUsageReading(configuredModel: configured, usage: usage, harnessReportsUsage: reports), engine: engine(verbs))
    }

    // MARK: Permission

    @Test(arguments: [[LeoPluginAgentVerb](), [.read], [.read, .send, .spawn]])
    func usageNeedsTheUsagePermission(_ verbs: [LeoPluginAgentVerb]) {
        #expect(throws: LeoPluginAgentsSnapshotError.self) { _ = try value(Self.full, verbs: verbs) }
        #expect(throws: LeoPluginAgentsSnapshotError.self) {
            _ = try LeoPluginUsageSnapshot.value(reading: nil, engine: engine(verbs))
        }
    }

    @Test func usageAloneIsEnoughAndNeedsNoReadGrant() throws {
        _ = try value(Self.full, verbs: [.usage])
    }

    // MARK: Mapping

    @Test func aFullUsageMapsToTheDocumentedCamelCaseShape() throws {
        let fields = object(try value(Self.full))
        #expect(fields["model"] == .string("observed-model"))
        #expect(fields["effort"] == .string("high"))
        #expect(fields["git"] == .object(["added": .int(120), "removed": .int(7)]))
        #expect(fields["session"] == .object(["tokens": .int(9_000), "costUsd": .double(35.36)]))
        #expect(fields["rateLimits"] == .array([
            .object(["kind": .string("five_hour"), "percentUsed": .double(42.5), "resetsAt": .string("2026-11-12T05:00:00Z")])
        ]))
        #expect(fields["context"] == .object([
            "tokens": .int(154_000), "window": .int(200_000), "percent": .double(77), "compactAt": .double(0.9),
            "breakdown": .object(["system": .int(3000), "tools": .int(12_000), "messages": .int(139_000)]),
        ]))
    }

    @Test func theSnapshotNeverCarriesAKeyOutsideTheContract() throws {
        let top = Set(object(try value(Self.full)).keys)
        #expect(top == ["model", "effort", "context", "session", "rateLimits", "git"])
        let context = object(object(try value(Self.full))["context"] ?? .null)
        #expect(Set(context.keys) == ["tokens", "window", "percent", "breakdown", "compactAt"])
    }

    @Test func absentFieldsStayAbsentNeverNullOrZero() throws {
        let bare = LeoAgentUsage(session: LeoUsageTotals(tokens: 5, costUSD: 0.1))
        let fields = object(try value(bare))
        #expect(Set(fields.keys) == ["session"])

        let ctx = LeoAgentUsage(session: LeoUsageTotals(tokens: 5, costUSD: 0.1), context: LeoContextUsage(tokens: 1, window: 2, percent: 50))
        let context = object(object(try value(ctx))["context"] ?? .null)
        #expect(Set(context.keys) == ["tokens", "window", "percent"])
    }

    @Test func aMissingCostIsAbsentButAReportedZeroCostIsKept() throws {
        let noCost = try JSONDecoder().decode(
            LeoAgentUsage.self, from: Data(#"{"session":{"tokens":5},"model":"m"}"#.utf8))
        let withoutCost = object(try value(noCost))
        #expect(withoutCost["session"] == nil)
        #expect(withoutCost["model"] == .string("m"))

        let zero = try JSONDecoder().decode(LeoAgentUsage.self, from: Data(#"{"session":{"tokens":5,"cost_usd":0}}"#.utf8))
        #expect(object(try value(zero))["session"] == .object(["tokens": .int(5), "costUsd": .double(0)]))
    }

    @Test(arguments: [Double.nan, .infinity, -1, 1e8])
    func anImplausibleCostDropsTheSession(_ cost: Double) throws {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 5, costUSD: cost), model: "m")
        let fields = object(try value(usage))
        #expect(fields["session"] == nil)
        #expect(fields["model"] == .string("m"))
    }

    @Test func anImplausibleContextNumberDropsTheContext() throws {
        let usage = LeoAgentUsage(
            session: LeoUsageTotals(tokens: 1, costUSD: 1), context: LeoContextUsage(tokens: 1, window: 2, percent: .nan))
        #expect(object(try value(usage))["context"] == nil)
    }

    // MARK: Model

    @Test func theObservedModelWinsOverTheConfiguredOne() throws {
        #expect(object(try value(Self.full, configured: "configured-model"))["model"] == .string("observed-model"))
    }

    @Test func theConfiguredModelIsTheFallback() throws {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 1, costUSD: 1))
        #expect(object(try value(usage, configured: "configured-model"))["model"] == .string("configured-model"))
        #expect(object(try value(usage))["model"] == nil)
    }

    @Test func aModelWithControlCharactersOrNonASCIIIsDropped() throws {
        let usage = LeoAgentUsage(session: LeoUsageTotals(tokens: 1, costUSD: 1), model: "evil\nmodel", effort: "hé")
        let fields = object(try value(usage, configured: "also\u{0}bad"))
        #expect(fields["model"] == nil)
        #expect(fields["effort"] == nil)
    }

    // MARK: null vs {}

    @Test func noDataYetIsNull() throws {
        #expect(try value(nil) == .null)
        #expect(try LeoPluginUsageSnapshot.value(reading: nil, engine: engine([.usage])) == .null)
    }

    @Test func aHarnessThatDoesNotReportUsageIsAnEmptyObject() throws {
        #expect(try value(nil, reports: false) == .object([:]))
        // Even a stale usage must not leak once the harness is known not to report.
        #expect(try value(Self.full, reports: false) == .object([:]))
    }

    @Test func aUsageWithNothingMappableIsNullNotAnEmptyObject() throws {
        let noCost = try JSONDecoder().decode(LeoAgentUsage.self, from: Data(#"{"session":{"tokens":5}}"#.utf8))
        #expect(try value(noCost) == .null)
    }
}
