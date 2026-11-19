import XCTest
@testable import ChippyCore

/// Issue #140: one description per host app. The table says how to recognise a host, which env vars the hook forwards
/// and what the jump does; generic code runs the plan.
final class HostAdapterTests: XCTestCase {
    let thread = "b7971675-6db6-4762-a036-05cdbcfed27a"
    let env = "5e4c7c40-3a61-4a1f-9a8e-1b6f9d0c2d11"
    let t3 = "com.t3tools.t3code"

    /// A context whose home-folder reads come from a dictionary, so no test touches the disk.
    func ctx(app: String? = "/Apps/X.app", files: [String: String] = [:]) -> JumpContext {
        JumpContext(appBundleURL: app.map { URL(fileURLWithPath: $0) }, readHomeFile: { files[$0] })
    }
    func host(_ bundle: String?, tty: String? = nil, cwd: String? = nil, env: [String: String] = [:]) -> HostInfo {
        HostInfo(pid: 10, bundle: bundle, tty: tty, cwd: cwd, env: env)
    }

    // MARK: plans per host

    func testTerminalAndITermSelectTheirTabByTTY() {
        for b in ["com.apple.Terminal", "com.googlecode.iterm2"] {
            guard case .appleScript(let src) = HostAdapters.plan(for: host(b, tty: "ttys004"), context: ctx()) else { return XCTFail(b) }
            XCTAssertTrue(src.contains("\"/dev/ttys004\""), b)
        }
    }

    func testTerminalWithoutAValidTTYJustActivates() {
        XCTAssertEqual(HostAdapters.plan(for: host("com.apple.Terminal"), context: ctx()), .activate)
        XCTAssertEqual(HostAdapters.plan(for: host("com.apple.Terminal", tty: "ttys1\"; do shell script \"x"), context: ctx()), .activate)
    }

    func testOrcaRunsItsCLIFromTheRunningAppForTheSessionsWorktree() {
        let plan = HostAdapters.plan(for: host(OrcaCLI.bundleId, cwd: "/wt/chippy"), context: ctx(app: "/Users/x/Orca Beta.app"))
        XCTAssertEqual(plan, .cli(executable: URL(fileURLWithPath: "/Users/x/Orca Beta.app/Contents/Resources/bin/orca"),
                                  arguments: ["worktree", "activate", "--worktree", "path:/wt/chippy", "--json"]))
    }

    func testOrcaWithoutAWorktreeJustActivatesAndWithoutAnAppIsNotLanded() {
        XCTAssertEqual(HostAdapters.plan(for: host(OrcaCLI.bundleId), context: ctx()), .activate)
        guard case .exactTargetUnavailable = HostAdapters.plan(for: host(OrcaCLI.bundleId, cwd: "/wt/x"), context: ctx(app: nil)) else {
            return XCTFail("no app bundle means no CLI, and that must not look like a success")
        }
    }

    func testT3OpensItsThreadLink() {
        let files = [T3Link.environmentIdPath: env + "\n"]
        let plan = HostAdapters.plan(for: host(t3, env: ["T3CODE_THREAD_ID": thread]), context: ctx(files: files))
        XCTAssertEqual(plan, .openURL(URL(string: "t3code://threads/\(env)/\(thread)")!))
    }

    func testT3WithoutAThreadJustActivates() {
        let files = [T3Link.environmentIdPath: env]
        XCTAssertEqual(HostAdapters.plan(for: host(t3), context: ctx(files: files)), .activate)
        XCTAssertEqual(HostAdapters.plan(for: host(t3, env: ["T3CODE_THREAD_ID": "a/../b"]), context: ctx(files: files)), .activate)
    }

    func testT3WithAThreadButNoReadableEnvironmentIdIsNotLanded() {
        for files in [[String: String](), [T3Link.environmentIdPath: "not an id!"]] {
            guard case .exactTargetUnavailable = HostAdapters.plan(for: host(t3, env: ["T3CODE_THREAD_ID": thread]), context: ctx(files: files)) else {
                return XCTFail("a link that cannot be built must not be reported as landed")
            }
        }
    }

    func testThreadIdFromAnotherHostNeverBuildsAT3Link() {
        let h = host("com.apple.Terminal", tty: "ttys001", env: ["T3CODE_THREAD_ID": thread])
        guard case .appleScript = HostAdapters.plan(for: h, context: ctx(files: [T3Link.environmentIdPath: env])) else { return XCTFail() }
    }

    func testUnknownAppOrNoHostJustActivates() {
        XCTAssertEqual(HostAdapters.plan(for: host("com.example.Unknown", tty: "ttys001", cwd: "/w"), context: ctx()), .activate)
        XCTAssertEqual(HostAdapters.plan(for: nil, context: ctx()), .activate)
    }

    // MARK: what the hook forwards

    func testHookForwardsOnlyTheNamedVarsOfTheRecognisedHost() {
        let environ = ["T3CODE_THREAD_ID": thread, "AWS_SECRET_ACCESS_KEY": "hunter2", "HOME": "/Users/x"]
        XCTAssertEqual(HostAdapters.forwardedEnv(bundle: t3, environment: environ), ["T3CODE_THREAD_ID": thread])
    }

    func testHookForwardsNothingForAHostThatListsNoVars() {
        let environ = ["T3CODE_THREAD_ID": thread]
        XCTAssertEqual(HostAdapters.forwardedEnv(bundle: "com.apple.Terminal", environment: environ), [:])
        XCTAssertEqual(HostAdapters.forwardedEnv(bundle: "com.example.Unknown", environment: environ), [:])
        XCTAssertEqual(HostAdapters.forwardedEnv(bundle: nil, environment: environ), [:])
    }

    func testHookDropsAnInvalidValue() {
        for bad in ["a/../b", "", "x y", String(repeating: "a", count: 129), "a\nb"] {
            XCTAssertEqual(HostAdapters.forwardedEnv(bundle: t3, environment: ["T3CODE_THREAD_ID": bad]), [:], bad)
        }
    }

    func testPayloadSideAcceptsOnlyListedNamesWithValidValues() {
        let raw: [String: Any] = ["T3CODE_THREAD_ID": thread, "HOME": "/Users/x", "EVIL": "x"]
        XCTAssertEqual(HostAdapters.sanitize(raw, bundle: t3), ["T3CODE_THREAD_ID": thread])
        XCTAssertEqual(HostAdapters.sanitize(["T3CODE_THREAD_ID": 42], bundle: t3), [:])
        XCTAssertEqual(HostAdapters.sanitize("not a dict", bundle: t3), [:])
        XCTAssertEqual(HostAdapters.sanitize(raw, bundle: "com.apple.Terminal"), [:])
    }

    // MARK: one verdict path for every exact-target step

    func testDoneKeepsTheAppVerdict() {
        for v: ActivationOutcome.Verdict in [.landed, .landedUnverified] { XCTAssertEqual(JumpPlan.finalVerdict(v, step: .done), v) }
    }

    func testUnconfirmedDowngradesLandedToUnverified() {
        XCTAssertEqual(JumpPlan.finalVerdict(.landed, step: .unconfirmed), .landedUnverified)
    }

    func testAFailedStepIsNeverLanded() {
        for v: ActivationOutcome.Verdict in [.landed, .landedUnverified] {
            XCTAssertEqual(JumpPlan.finalVerdict(v, step: .failed("x")), .workspaceNotSelected)
        }
    }

    func testAppLevelFailuresPassThrough() {
        XCTAssertEqual(JumpPlan.finalVerdict(.notFrontmost, step: .done), .notFrontmost)
        XCTAssertEqual(JumpPlan.finalVerdict(.offSpace, step: .failed("x")), .offSpace)
    }

    func testOrcaAndT3ShareTheSameVerdictPath() {
        for s: OrcaCLI.Select in [.selected, .unconfirmed, .failed("x")] {
            XCTAssertEqual(OrcaCLI.finalVerdict(.landed, select: s), JumpPlan.finalVerdict(.landed, step: s.step))
        }
    }

    // MARK: a new host is one table entry

    func testAStubHostNeedsOnlyATableEntry() {
        let stub = HostAdapter(bundleId: "com.stub.app", forwardedEnv: ["STUB_SESSION"]) { h, _ in
            h.env["STUB_SESSION"].flatMap { URL(string: "stub://open/\($0)") }.map(JumpPlan.openURL) ?? .activate
        }
        let table = [stub]
        let forwarded = HostAdapters.forwardedEnv(bundle: "com.stub.app", environment: ["STUB_SESSION": "s-1", "T3CODE_THREAD_ID": thread], in: table)
        XCTAssertEqual(forwarded, ["STUB_SESSION": "s-1"])
        let h = HostInfo(pid: 5, bundle: "com.stub.app", tty: nil, env: HostAdapters.sanitize(forwarded, bundle: "com.stub.app", in: table))
        XCTAssertEqual(HostAdapters.plan(for: h, context: ctx(), in: table), .openURL(URL(string: "stub://open/s-1")!))
        XCTAssertEqual(HostAdapters.plan(for: host(t3), context: ctx(), in: table), .activate, "hosts outside the table fall back to activate")
    }

    // MARK: logs never carry ids (#142)

    func testErrorReasonNamesDomainAndCodeOnly() {
        XCTAssertEqual(JumpPlan.reason(errorDomain: "NSOSStatusErrorDomain", code: -10814), "NSOSStatusErrorDomain -10814")
    }

    func testEveryPlanReasonIsFreeOfThreadAndEnvironmentIds() {
        // The reasons a plan can carry are fixed strings; none is built from a value the session supplied.
        let h = host(t3, env: ["T3CODE_THREAD_ID": thread])
        for files in [[String: String](), [T3Link.environmentIdPath: "bad id!"]] {
            guard case .exactTargetUnavailable(let why) = HostAdapters.plan(for: h, context: ctx(files: files)) else { return XCTFail() }
            XCTAssertFalse(why.contains(thread)); XCTAssertFalse(why.contains(env))
        }
    }
}
