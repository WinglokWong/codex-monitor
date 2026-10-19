import Foundation

private final class RetryTestClock {
    var now = Date(timeIntervalSince1970: 2_000_000_000)
}

private final class RetryTestClient: QuotaReadingClient {
    var completions: [(Result<QuotaReading, Error>) -> Void] = []
    var cancellationCallsBack = false
    var cancellationCount = 0

    func read(completion: @escaping (Result<QuotaReading, Error>) -> Void) { completions.append(completion) }
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
        try check(model.quotaStatus == QuotaClientError.timedOut.shortDescription, "The footer must show the concrete failure category")
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
        clock.now.addTimeInterval(100)
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
}
