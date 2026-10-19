import Foundation

private final class RetryTestClock {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
}

private final class RetryTestClient: QuotaReadingClient {
    var completions: [(Result<QuotaReading, Error>) -> Void] = []
    var requests: [String] = []
    var cancellationCallsBack = false
    var cancellationCount = 0

    func read(completion: @escaping (Result<QuotaReading, Error>) -> Void) { requests.append("quota"); completions.append(completion) }
    func readAccount(completion: @escaping (Result<QuotaReading, Error>) -> Void) { requests.append("account"); completions.append(completion) }
    func cancel() {
        cancellationCount += 1
        if cancellationCallsBack { completions.last?(.failure(QuotaClientError.cancelled)) }
    }
    func complete(_ index: Int, with result: Result<QuotaReading, Error>) { completions[index](result) }
}

func runRetryStateTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw MonitorTestError(description: message) }
    }
    let identity = try QuotaClient.parseAccount(["account": ["type": "chatgpt", "email": "retry@example.test", "planType": "plus"]])
    let success = QuotaReading(windows: [WeeklyQuota(id: "codex.primary", label: "Codex", usedPercent: 20, resetsAt: nil)],
                               receivedAt: Date(), account: identity)

    // A periodic event must not replenish the bounded retry budget or overlap a read.
    do {
        let clock = RetryTestClock()
        let client = RetryTestClient()
        let model = MonitorModel(quotaClient: client, clock: { clock.now })
        model.applyQuotaResult(.success(success))
        model.refreshQuota()
        model.refreshQuota()
        model.refreshQuotaAutomatically()
        try check(client.completions.count == 1, "Manual/periodic refresh must not overlap an active query")
        client.complete(0, with: .failure(QuotaClientError.timedOut))
        try check(model.reading == nil && model.nextQuotaRetryAt == clock.now.addingTimeInterval(3), "First transient failure must clear old identity and retry after three seconds")
        try check(model.quotaStatus == "额度 · " + QuotaClientError.timedOut.shortDescription, "The footer must show the task and concrete failure category")
        model.refreshQuotaAutomatically()
        clock.now.addTimeInterval(2)
        model.checkQuotaTimers()
        try check(client.completions.count == 1 && model.quotaDetailStatus.hasPrefix("1 秒"), "Retry countdown must follow the clock and not fire early")
        clock.now.addTimeInterval(1)
        model.checkQuotaTimers()
        try check(client.completions.count == 2 && model.nextQuotaRetryAt == nil, "First retry must start once at its deadline")
        client.complete(1, with: .failure(QuotaClientError.processExited(stage: "quota")))
        try check(model.nextQuotaRetryAt == clock.now.addingTimeInterval(8), "Second retry must back off for eight seconds")
        clock.now.addTimeInterval(8)
        model.checkQuotaTimers()
        client.complete(2, with: .failure(QuotaClientError.serviceUnavailable))
        clock.now.addTimeInterval(40)
        model.checkQuotaTimers()
        try check(client.completions.count == 3 && model.nextQuotaRetryAt == nil, "A cycle must stop after the initial attempt and two retries")
        model.refreshQuotaAutomatically()
        try check(client.completions.count == 4, "The next regular refresh must be able to begin a new cycle")
        client.complete(3, with: .success(success))
        try check(model.quotaError == nil && model.nextQuotaRetryAt == nil && model.remaining == 80, "Recovery must clear error and pending retries")
        try check(model.lastQueryFailure != nil && model.queryErrorDetails.contains("当前查询已恢复"), "Safe failure history must remain inspectable after recovery")
        model.stop()
    }

    // Manual refresh supersedes an upcoming retry and starts with a fresh budget.
    do {
        let clock = RetryTestClock()
        let client = RetryTestClient()
        let model = MonitorModel(quotaClient: client, clock: { clock.now })
        model.refreshQuota()
        client.complete(0, with: .failure(QuotaClientError.timedOut))
        clock.now.addTimeInterval(1)
        model.refreshQuota()
        try check(client.completions.count == 2 && model.nextQuotaRetryAt == nil, "Manual refresh must replace the queued retry")
        client.complete(1, with: .failure(QuotaClientError.timedOut))
        try check(model.nextQuotaRetryAt == clock.now.addingTimeInterval(3), "Manual refresh must reset the retry budget")
        model.stop()
    }

    // Authentication, rate-limit and installation errors require action or normal polling.
    for error in [QuotaClientError.authenticationRequired, .rateLimited, .cliUnavailable, .invalidResponse] {
        let client = RetryTestClient()
        let model = MonitorModel(quotaClient: client)
        model.refreshQuota()
        client.complete(0, with: .failure(error))
        try check(model.nextQuotaRetryAt == nil, "Non-transient failures must not trigger fast retries")
        model.stop()
    }

    // No private underlying diagnostic may escape through the view or error alert.
    do {
        let model = MonitorModel(quotaClient: RetryTestClient())
        let secretMarker = "SYNTHETIC_PRIVATE_ERROR_TEXT"
        model.applyQuotaResult(.failure(NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: secretMarker])))
        try check(!model.queryErrorDetails.contains(secretMarker) && !(model.quotaError ?? "").contains(secretMarker), "Unknown underlying errors must be classified before display")
        model.stop()
    }

    // Cancellation can synchronously call back; old generations must not change UI state.
    do {
        let client = RetryTestClient()
        client.cancellationCallsBack = true
        let model = MonitorModel(quotaClient: client)
        model.start()
        model.start()
        try check(client.completions.count == 1, "Starting twice must not create duplicate timers/requests")
        model.stop()
        client.complete(0, with: .success(success))
        try check(model.reading == nil && model.quotaError == nil && model.nextQuotaRetryAt == nil && !model.isRefreshing, "Stopped model must ignore both synchronous cancellation and late success")
        model.start()
        client.complete(0, with: .failure(QuotaClientError.timedOut))
        try check(model.isRefreshing && model.quotaError == nil, "An old generation must not interfere with a restarted model")
        client.complete(1, with: .success(success))
        model.stop()
        let count = client.completions.count
        model.refreshQuota()
        model.refreshQuotaAutomatically()
        model.checkQuotaTimers()
        try check(client.completions.count == count && model.nextQuotaRetryAt == nil, "No refresh may begin after stop")
    }
    try runIndependentIntervalTests()
}

private func runIndependentIntervalTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw MonitorTestError(description: message) }
    }
    let identity = try QuotaClient.parseAccount(["account": ["type": "chatgpt", "email": "same.alice@example.test", "planType": "plus"]])
    func snapshot(_ time: Date, key: String = "identity-a", quota: Bool = true) -> QuotaReading {
        QuotaReading(windows: quota ? [WeeklyQuota(id: "codex.primary", label: "Codex", usedPercent: 20, resetsAt: nil)] : [],
                     receivedAt: time, account: identity, identityKey: key)
    }

    // Account polling does not query quota; a same-mask identity change clears old usage.
    do {
        let clock = RetryTestClock(), client = RetryTestClient()
        let start = clock.now
        let model = MonitorModel(quotaClient: client, clock: { clock.now }, accountIntervalMinutes: 1, quotaIntervalMinutes: 5)
        model.refreshQuota(); client.complete(0, with: .success(snapshot(clock.now)))
        clock.now = start.addingTimeInterval(60); model.checkQuotaTimers()
        try check(client.requests == ["quota", "account"], "One-minute account polling must use the account-only API")
        client.complete(1, with: .success(snapshot(clock.now, quota: false)))
        try check(model.remaining == 80 && model.reading?.receivedAt == start, "Same identity preserves the original quota snapshot and timestamp")
        clock.now = start.addingTimeInterval(120); model.checkQuotaTimers()
        client.complete(2, with: .success(snapshot(clock.now, key: "identity-b", quota: false)))
        try check(model.reading == nil && model.account == identity && model.remaining == nil, "Different identity keys must clear old quota even when masked identity is identical")
        try check(client.requests.filter { $0 == "quota" }.count == 1, "An account change must not trigger an early quota query")
        clock.now = start.addingTimeInterval(299); model.checkQuotaTimers()
        client.complete(3, with: .success(snapshot(clock.now, key: "identity-b", quota: false)))
        let nextAccount = model.nextAccountPeriodicAt
        clock.now = start.addingTimeInterval(300); model.checkQuotaTimers()
        try check(client.requests == ["quota", "account", "account", "account", "quota"], "The five-minute quota deadline must remain independent")
        client.complete(4, with: .success(snapshot(clock.now, key: "identity-b")))
        try check(model.nextAccountPeriodicAt == nextAccount, "Quota verification must not postpone a still-future account deadline")
        model.stop()
    }

    // Frequent quota reads must not postpone the less frequent account schedule.
    do {
        let clock = RetryTestClock(), client = RetryTestClient()
        let start = clock.now
        let model = MonitorModel(quotaClient: client, clock: { clock.now }, accountIntervalMinutes: 5, quotaIntervalMinutes: 1)
        model.refreshQuota(); client.complete(0, with: .success(snapshot(clock.now)))
        for seconds in [60, 120] {
            clock.now = start.addingTimeInterval(Double(seconds)); model.checkQuotaTimers()
            client.complete(client.completions.count - 1, with: .success(snapshot(clock.now)))
            try check(model.nextAccountPeriodicAt == start.addingTimeInterval(300), "A quota-only deadline must not move account polling")
        }
        clock.now = start.addingTimeInterval(300); model.checkQuotaTimers(); model.checkQuotaTimers()
        try check(client.requests == ["quota", "quota", "quota", "quota"] && model.nextAccountPeriodicAt == start.addingTimeInterval(600),
                  "Both due tasks must coalesce into one quota request without overlap")
        client.complete(3, with: .success(snapshot(clock.now))); model.stop()
    }

    // Saving one interval affects only its future periodic deadline, even mid-request.
    do {
        let clock = RetryTestClock(), client = RetryTestClient()
        let start = clock.now
        let model = MonitorModel(quotaClient: client, clock: { clock.now }, accountIntervalMinutes: 1, quotaIntervalMinutes: 5)
        model.refreshQuota()
        clock.now = start.addingTimeInterval(10)
        try check(model.setQueryIntervals(accountMinutes: 2, quotaMinutes: 5), "Valid integer intervals must be accepted")
        try check(model.nextAccountPeriodicAt == start.addingTimeInterval(130) && model.nextQuotaPeriodicAt == start.addingTimeInterval(300),
                  "Only the changed interval must be rescheduled from save time")
        client.complete(0, with: .success(snapshot(clock.now)))
        try check(model.nextAccountPeriodicAt == start.addingTimeInterval(130) && client.cancellationCount == 0, "Completion must not overwrite settings saved during the query")
        clock.now = start.addingTimeInterval(130); model.checkQuotaTimers()
        clock.now = start.addingTimeInterval(140)
        let accountDeadline = model.nextAccountPeriodicAt
        try check(model.setQueryIntervals(accountMinutes: 2, quotaMinutes: 7), "Quota interval edit must succeed during account-only read")
        try check(model.nextAccountPeriodicAt == accountDeadline && model.nextQuotaPeriodicAt == start.addingTimeInterval(560), "Changing quota interval must leave account deadline and active query intact")
        client.complete(1, with: .success(snapshot(clock.now, quota: false)))
        let before = (model.nextAccountPeriodicAt, model.nextQuotaPeriodicAt)
        for values in [(0, 7), (-1, 7), (2, 10081), (10081, 1)] {
            try check(!model.setQueryIntervals(accountMinutes: values.0, quotaMinutes: values.1), "Out-of-range interval must be rejected atomically")
            try check(model.accountIntervalMinutes == 2 && model.quotaIntervalMinutes == 7 && model.nextAccountPeriodicAt == before.0 && model.nextQuotaPeriodicAt == before.1, "Rejected settings must not mutate either interval")
        }
        clock.now.addTimeInterval(10)
        _ = model.setQueryIntervals(accountMinutes: 2, quotaMinutes: 7)
        try check(model.nextAccountPeriodicAt == before.0 && model.nextQuotaPeriodicAt == before.1, "Saving unchanged intervals must not postpone polling")
        model.stop()
    }

    // Account retries have their own budget, preserve settings, and never call quota.
    do {
        let clock = RetryTestClock(), client = RetryTestClient()
        let start = clock.now
        let model = MonitorModel(quotaClient: client, clock: { clock.now }, accountIntervalMinutes: 1, quotaIntervalMinutes: 5)
        model.refreshQuota(); client.complete(0, with: .success(snapshot(clock.now)))
        clock.now = start.addingTimeInterval(60); model.checkQuotaTimers()
        client.complete(1, with: .failure(QuotaClientError.timedOut))
        try check(model.account == nil && model.reading == nil && model.nextAccountRetryAt == start.addingTimeInterval(63) && model.nextQuotaRetryAt == nil,
                  "Account failure must fail closed and schedule only an account retry")
        try check(model.quotaStatus.hasPrefix("账号") && model.quotaDetailStatus.contains("账号"), "Account error and retry footer must identify the task")
        clock.now = start.addingTimeInterval(62)
        _ = model.setQueryIntervals(accountMinutes: 2, quotaMinutes: 5)
        try check(model.nextAccountRetryAt == start.addingTimeInterval(63), "Changing intervals must not change an existing retry deadline")
        clock.now = start.addingTimeInterval(63); model.checkQuotaTimers()
        client.complete(2, with: .failure(QuotaClientError.timedOut))
        try check(model.nextAccountRetryAt == start.addingTimeInterval(71), "Account second retry must back off eight seconds")
        clock.now = start.addingTimeInterval(71); model.checkQuotaTimers()
        client.complete(3, with: .failure(QuotaClientError.timedOut))
        clock.now = start.addingTimeInterval(80); model.checkQuotaTimers()
        try check(model.nextAccountRetryAt == nil && client.requests == ["quota", "account", "account", "account"], "Account retry budget must stop after two retries without consuming quota")
        clock.now = start.addingTimeInterval(182); model.checkQuotaTimers()
        client.complete(4, with: .success(snapshot(clock.now, quota: false)))
        try check(model.account == identity && model.reading == nil && model.nextQuotaPeriodicAt == start.addingTimeInterval(300), "Account recovery must not resurrect quota cleared by a failed identity check")
        model.stop()
    }

    // A quota due while an account retry is still in the future does not erase that retry.
    do {
        let clock = RetryTestClock(), client = RetryTestClient()
        let start = clock.now
        let model = MonitorModel(quotaClient: client, clock: { clock.now }, accountIntervalMinutes: 1, quotaIntervalMinutes: 5)
        model.refreshQuota(); client.complete(0, with: .success(snapshot(clock.now)))
        clock.now = start.addingTimeInterval(299); model.checkQuotaTimers()
        client.complete(1, with: .failure(QuotaClientError.timedOut))
        clock.now = start.addingTimeInterval(300); model.checkQuotaTimers()
        client.complete(2, with: .success(snapshot(clock.now)))
        try check(model.nextAccountRetryAt == start.addingTimeInterval(302), "Quota success must preserve the other task's future retry")
        clock.now = start.addingTimeInterval(302); model.checkQuotaTimers()
        try check(client.requests == ["quota", "account", "quota", "account"], "Independent account retry must still use account-only read")
        model.stop(); client.complete(3, with: .success(snapshot(clock.now, key: "identity-b", quota: false)))
        try check(model.reading?.identityKey == "identity-a", "Stopped model must suppress a late account result")
    }

    do {
        let clock = RetryTestClock(), client = RetryTestClient()
        let model = MonitorModel(quotaClient: client, clock: { clock.now }, quotaIntervalMinutes: 5)
        model.applyQuotaResult(.success(snapshot(clock.now)))
        model.now = clock.now.addingTimeInterval(181)
        try check(!model.quotaIsStale, "Long quota intervals must scale the stale threshold")
        model.now = clock.now.addingTimeInterval(901)
        try check(model.quotaIsStale, "Scaled stale threshold still detects missed polling")
        model.stop()
    }

    // A regular quota read at reset time already serves the one-off expiry check.
    do {
        let clock = RetryTestClock(), client = RetryTestClient()
        let start = clock.now, reset = clock.now.addingTimeInterval(60)
        let model = MonitorModel(quotaClient: client, clock: { clock.now }, accountIntervalMinutes: 5)
        let expired = QuotaReading(windows: [WeeklyQuota(id: "codex.primary", label: "Codex", usedPercent: 20, resetsAt: reset)],
                                   receivedAt: start, account: identity, identityKey: "identity-a")
        model.refreshQuota(); client.complete(0, with: .success(expired))
        clock.now = reset; model.checkQuotaTimers()
        client.complete(1, with: .success(expired))
        clock.now.addTimeInterval(1); model.checkQuotaTimers()
        try check(client.requests == ["quota", "quota"], "An expired quota response must not immediately duplicate the periodic request")
        model.stop()
    }
}
