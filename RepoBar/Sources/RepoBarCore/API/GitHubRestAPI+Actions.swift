import Foundation

extension GitHubRestAPI {
    static let queuedWorkflowRunStatuses = ["queued", "waiting", "pending"]

    func selfHostedRunners(owner: String, repo: String?) async throws -> ActionsRunnerInfo {
        let token = try await tokenProvider()
        let baseURL = await apiHost()
        let now = Date()
        let pageSize = 100
        var page = 1
        var collected: [RunnerResponse] = []
        var totalCount = 0

        while true {
            let url = Self.selfHostedRunnersURL(
                baseURL: baseURL,
                owner: owner,
                repo: repo,
                page: page,
                perPage: pageSize
            )
            let (data, _) = try await authorizedGet(
                url: url,
                token: token,
                allowedStatuses: [200, 304, 404]
            )
            let decoded = try GitHubDecoding.decode(RunnersResponse.self, from: data)
            if page == 1 {
                totalCount = decoded.totalCount
            }
            collected.append(contentsOf: decoded.runners)

            if collected.count >= totalCount || decoded.runners.count < pageSize {
                break
            }
            page += 1
        }

        return ActionsRunnerInfo(
            totalCount: totalCount,
            runners: collected.map(Self.runnerSummary(from:)),
            fetchedAt: now
        )
    }

    func actionsQueueStatus(owner: String, name: String) async throws -> ActionsQueueStatus {
        let token = try await tokenProvider()
        let baseURL = await apiHost()
        let now = Date()
        async let inProgressData = self.authorizedGet(
            url: self.actionsRunsURL(baseURL: baseURL, owner: owner, name: name, status: "in_progress"),
            token: token,
            allowedStatuses: [200, 304, 404]
        )
        let queuedStatuses = Self.queuedWorkflowRunStatuses
        async let queuedData = self.authorizedGet(
            url: self.actionsRunsURL(baseURL: baseURL, owner: owner, name: name, status: queuedStatuses[0]),
            token: token,
            allowedStatuses: [200, 304, 404]
        )
        async let waitingData = self.authorizedGet(
            url: self.actionsRunsURL(baseURL: baseURL, owner: owner, name: name, status: queuedStatuses[1]),
            token: token,
            allowedStatuses: [200, 304, 404]
        )
        async let pendingData = self.authorizedGet(
            url: self.actionsRunsURL(baseURL: baseURL, owner: owner, name: name, status: queuedStatuses[2]),
            token: token,
            allowedStatuses: [200, 304, 404]
        )

        let (ipData, _) = try await inProgressData
        let (qData, _) = try await queuedData
        let (waitingDataValue, _) = try await waitingData
        let (pendingDataValue, _) = try await pendingData
        let ipResponse = try? GitHubDecoding.decode(ActionsRunsResponse.self, from: ipData)
        let qResponse = try? GitHubDecoding.decode(ActionsRunsResponse.self, from: qData)
        let waitingResponse = try? GitHubDecoding.decode(ActionsRunsResponse.self, from: waitingDataValue)
        let pendingResponse = try? GitHubDecoding.decode(ActionsRunsResponse.self, from: pendingDataValue)
        let queuedResponses = [qResponse, waitingResponse, pendingResponse]
        let repoFullName = "\(owner)/\(name)"
        let queuedRuns = queuedResponses.flatMap { $0?.workflowRuns ?? [] }
        let runs = ((ipResponse?.workflowRuns ?? []) + queuedRuns).compactMap { run in
            Self.activeWorkflowRun(from: run, fallbackRepoFullName: repoFullName)
        }
        return ActionsQueueStatus(
            inProgressCount: ipResponse?.totalCount ?? 0,
            queuedCount: queuedResponses.reduce(0) { $0 + ($1?.totalCount ?? 0) },
            runs: runs,
            fetchedAt: now
        )
    }

    func actionsBillingUsage(owner: String, isOrg: Bool) async throws -> ActionsUsageInfo {
        let token = try await tokenProvider()
        let baseURL = await apiHost()
        let now = Date()
        let path = isOrg
            ? "/organizations/\(owner)/settings/billing/usage"
            : "/users/\(owner)/settings/billing/usage"
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "product", value: "actions")]
        let (data, _) = try await authorizedGet(
            url: components.url!,
            token: token,
            allowedStatuses: [200],
            headers: ["X-GitHub-Api-Version": "2026-03-10"],
            useETag: false
        )
        let decoded = try GitHubDecoding.decode(BillingUsageResponse.self, from: data)
        return ActionsUsageInfo(items: decoded.usageItems.map(Self.usageItem(from:)), fetchedAt: now)
    }

    func hostedRunnerLimits(org: String) async throws -> HostedRunnerLimits {
        let token = try await tokenProvider()
        let baseURL = await apiHost()
        let now = Date()
        let (data, _) = try await authorizedGet(
            url: baseURL.appending(path: "/orgs/\(org)/actions/hosted-runners/limits"),
            token: token,
            allowedStatuses: [200, 304, 403, 404]
        )
        let decoded = try GitHubDecoding.decode(HostedRunnerLimitsResponse.self, from: data)
        return HostedRunnerLimits(
            publicIPs: decoded.publicIps.map {
                HostedRunnerLimits.ResourceLimit(maximum: $0.maximum, currentUsage: $0.currentUsage)
            },
            fetchedAt: now
        )
    }

    func actionsCacheUsage(org: String) async throws -> ActionsCacheUsage {
        let token = try await tokenProvider()
        let baseURL = await apiHost()
        let (data, _) = try await authorizedGet(
            url: baseURL.appending(path: "/orgs/\(org)/actions/cache/usage"),
            token: token,
            allowedStatuses: [200, 304],
            useETag: false
        )
        let decoded = try GitHubDecoding.decode(ActionsCacheUsageResponse.self, from: data)
        return ActionsCacheUsage(
            totalCachesCount: decoded.totalActiveCachesCount,
            totalCachesSizeBytes: decoded.totalActiveCachesSizeInBytes
        )
    }

    func artifactRetentionPolicy(org: String) async throws -> ArtifactRetentionPolicy {
        let token = try await tokenProvider()
        let baseURL = await apiHost()
        let (data, _) = try await authorizedGet(
            url: baseURL.appending(path: "/orgs/\(org)/actions/permissions/artifact-and-log-retention"),
            token: token,
            allowedStatuses: [200, 304, 404],
            useETag: false
        )
        let decoded = try GitHubDecoding.decode(ArtifactRetentionResponse.self, from: data)
        return ArtifactRetentionPolicy(retentionDays: decoded.days, maxAllowedDays: decoded.maximumAllowedDays ?? decoded.days)
    }

    private func actionsRunsURL(baseURL: URL, owner: String, name: String, status: String) -> URL {
        var components = URLComponents(url: baseURL.appending(path: "/repos/\(owner)/\(name)/actions/runs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "status", value: status),
            URLQueryItem(name: "per_page", value: "10")
        ]
        return components.url!
    }

    static func selfHostedRunnersURL(baseURL: URL, owner: String, repo: String?, page: Int, perPage: Int = 100) -> URL {
        let path = if let repo {
            "/repos/\(owner)/\(repo)/actions/runners"
        } else {
            "/orgs/\(owner)/actions/runners"
        }
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "per_page", value: "\(perPage)"),
            URLQueryItem(name: "page", value: "\(page)")
        ]
        return components.url!
    }

    private static func runnerSummary(from runner: RunnerResponse) -> RunnerSummary {
        RunnerSummary(
            id: runner.id,
            name: runner.name,
            os: runner.os,
            status: runner.status,
            busy: runner.busy,
            labels: runner.labels.map(\.name)
        )
    }

    private static func activeWorkflowRun(from run: ActionsRunsResponse.WorkflowRun, fallbackRepoFullName: String) -> ActiveWorkflowRun? {
        guard let id = run.id else { return nil }

        return ActiveWorkflowRun(
            id: id,
            name: run.name ?? "Workflow",
            repoFullName: run.repository?.fullName ?? fallbackRepoFullName,
            headBranch: run.headBranch ?? "",
            status: run.status ?? "unknown",
            event: run.event ?? "",
            actor: run.actor?.login ?? "",
            htmlURL: run.htmlUrl,
            startedAt: run.createdAt
        )
    }

    private static func usageItem(from item: BillingUsageItemResponse) -> ActionsUsageItem {
        ActionsUsageItem(
            date: item.date,
            product: item.product,
            sku: item.sku,
            quantity: item.quantity,
            unitType: item.unitType,
            pricePerUnit: item.pricePerUnit,
            grossAmount: item.grossAmount,
            netAmount: item.netAmount,
            organizationName: item.organizationName,
            repositoryName: item.repositoryName
        )
    }
}

private struct RunnersResponse: Decodable {
    let totalCount: Int
    let runners: [RunnerResponse]

    enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case runners
    }
}

private struct RunnerResponse: Decodable {
    let id: Int
    let name: String
    let os: String
    let status: String
    let busy: Bool
    let labels: [RunnerLabelResponse]
}

private struct RunnerLabelResponse: Decodable {
    let name: String
}

private struct BillingUsageResponse: Decodable {
    let usageItems: [BillingUsageItemResponse]

    enum CodingKeys: String, CodingKey {
        case usageItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usageItems = (try? container.decode([BillingUsageItemResponse].self, forKey: .usageItems)) ?? []
    }
}

private struct BillingUsageItemResponse: Decodable {
    let date: String
    let product: String
    let sku: String
    let quantity: Double
    let unitType: String
    let pricePerUnit: Double
    let grossAmount: Double
    let netAmount: Double
    let organizationName: String?
    let repositoryName: String?
}

private struct HostedRunnerLimitsResponse: Decodable {
    let publicIps: PublicIPLimit?

    enum CodingKeys: String, CodingKey {
        case publicIps = "public_ips"
    }
}

private struct PublicIPLimit: Decodable {
    let maximum: Int
    let currentUsage: Int

    enum CodingKeys: String, CodingKey {
        case maximum
        case currentUsage = "current_usage"
    }
}

private struct ActionsCacheUsageResponse: Decodable {
    let totalActiveCachesCount: Int
    let totalActiveCachesSizeInBytes: Int

    enum CodingKeys: String, CodingKey {
        case totalActiveCachesCount = "total_active_caches_count"
        case totalActiveCachesSizeInBytes = "total_active_caches_size_in_bytes"
    }
}

private struct ArtifactRetentionResponse: Decodable {
    let days: Int
    let maximumAllowedDays: Int?

    enum CodingKeys: String, CodingKey {
        case days
        case maximumAllowedDays = "maximum_allowed_days"
    }
}
