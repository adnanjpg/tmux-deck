import AppKit
import SwiftUI

/// At-a-glance state of one GitHub pull request.
struct PRInfo: Identifiable, Equatable {
    var repo: String            // "owner/name"
    var number: Int
    var title: String
    var url: String
    var state: String           // OPEN, MERGED, CLOSED
    var isDraft: Bool
    var reviewDecision: String? // APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED
    var approvedBy: [String]
    var changesRequestedBy: [String]
    var author: String
    var updatedAt: Date?
    var checksPassed = 0
    var checksFailed = 0
    var checksPending = 0
    var failedChecks: [String] = []

    var id: String { "\(repo)#\(number)" }
    var checksTotal: Int { checksPassed + checksFailed + checksPending }
    var shortRepo: String { repo.split(separator: "/").last.map(String.init) ?? repo }
}

/// Fetches PR status with the GitHub CLI (`gh`), which is already signed in on this Mac.
@MainActor
final class PRStore: ObservableObject {
    static let shared = PRStore()

    @Published private(set) var byID: [String: PRInfo] = [:]
    @Published private(set) var mine: [PRInfo] = []
    @Published private(set) var reviewRequested: [PRInfo] = []
    @Published private(set) var listUpdated: Date?
    @Published private(set) var loadingList = false
    @Published private(set) var error: String?

    private var fetchedAt: [String: Date] = [:]
    private var inflight: Set<String> = []

    /// Matches https://github.com/owner/repo/pull/123
    static let urlPattern = try! Regex(#"https?://github\.com/([\w.-]+)/([\w.-]+)/pull/(\d+)"#)

    static func parse(url: String) -> (owner: String, repo: String, number: Int)? {
        guard let m = url.firstMatch(of: urlPattern),
              let o = m[1].substring, let r = m[2].substring, let n = m[3].substring.flatMap({ Int($0) }) else { return nil }
        return (String(o), String(r), n)
    }

    static func id(owner: String, repo: String, number: Int) -> String { "\(owner)/\(repo)#\(number)" }

    private static let barePattern = try! Regex(#"(?:\bPR\s*#?|#)(\d{2,6})\b"#)

    /// PR ids mentioned in `texts` (newest first): full links, plus "#2258" / "PR 2260"
    /// when the window's repository is known.
    static func mentions(in texts: [String], repo: String?) -> [String] {
        var ids: [String] = []
        func add(_ id: String) { if !ids.contains(id) { ids.append(id) } }
        for text in texts {
            for m in text.matches(of: urlPattern) {
                if let o = m[1].substring, let r = m[2].substring, let n = m[3].substring { add("\(o)/\(r)#\(n)") }
            }
            if let repo {
                for m in text.matches(of: barePattern) {
                    if let n = m[1].substring { add("\(repo)#\(n)") }
                }
            }
        }
        return ids
    }

    /// Fetches a PR given an id like "owner/repo#123".
    func fetch(id: String, maxAge: TimeInterval = 120) {
        let parts = id.split(separator: "#")
        let path = parts.first?.split(separator: "/") ?? []
        guard parts.count == 2, path.count == 2, let n = Int(parts[1]) else { return }
        fetch(owner: String(path[0]), repo: String(path[1]), number: n, maxAge: maxAge)
    }

    // MARK: Fetching

    func refreshList() async {
        guard !loadingList else { return }
        loadingList = true
        defer { loadingList = false }
        let query = Self.fragment + """
        query {
          viewer { pullRequests(states: OPEN, first: 40, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } } }
          review: search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 30) { nodes { ...pr } }
        }
        """
        guard let data = await graphQL(query, variables: [:]) else { return }
        let viewer = (data["viewer"] as? [String: Any])?["pullRequests"] as? [String: Any]
        mine = ((viewer?["nodes"] as? [[String: Any]]) ?? []).compactMap(Self.parse(node:))
        reviewRequested = (((data["review"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).compactMap(Self.parse(node:))
        let now = Date()
        for pr in mine + reviewRequested {
            byID[pr.id] = pr
            fetchedAt[pr.id] = now
        }
        listUpdated = now
        error = nil
    }

    /// Fetches one PR unless it was fetched within `maxAge` seconds.
    func fetch(owner: String, repo: String, number: Int, maxAge: TimeInterval = 60) {
        let id = Self.id(owner: owner, repo: repo, number: number)
        if let t = fetchedAt[id], Date().timeIntervalSince(t) < maxAge { return }
        guard !inflight.contains(id) else { return }
        inflight.insert(id)
        Task {
            defer { inflight.remove(id) }
            let query = Self.fragment + """
            query($owner: String!, $repo: String!, $number: Int!) {
              repository(owner: $owner, name: $repo) { pullRequest(number: $number) { ...pr } }
            }
            """
            guard let data = await graphQL(query, variables: ["owner": owner, "repo": repo, "number": "\(number)"]),
                  let node = (data["repository"] as? [String: Any])?["pullRequest"] as? [String: Any],
                  let pr = Self.parse(node: node) else { return }
            byID[id] = pr
            fetchedAt[id] = Date()
        }
    }

    private func graphQL(_ query: String, variables: [String: String]) async -> [String: Any]? {
        var args = ["api", "graphql", "-f", "query=\(query)"]
        for (k, v) in variables { args += [k == "number" ? "-F" : "-f", "\(k)=\(v)"] }
        let result = await Self.gh(args)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any] else {
            error = result.err.isEmpty ? "Couldn't reach GitHub." : result.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return nil
        }
        if let errors = obj["errors"] as? [[String: Any]], obj["data"] == nil {
            error = errors.first?["message"] as? String ?? "GitHub returned an error."
            return nil
        }
        return obj["data"] as? [String: Any]
    }

    static var ghPath: String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func gh(_ args: [String]) async -> (out: String, err: String) {
        guard let path = ghPath else {
            return ("", "The GitHub CLI (gh) isn't installed. Install it with `brew install gh`, then run `gh auth login`.")
        }
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            guard (try? p.run()) != nil else { return ("", "Couldn't run gh.") }
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }.value
    }

    private static let fragment = """
    fragment pr on PullRequest {
      number title url state isDraft reviewDecision updatedAt
      repository { nameWithOwner }
      author { login }
      latestOpinionatedReviews(first: 20) { nodes { state author { login } } }
      commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {
        __typename
        ... on CheckRun { status conclusion name }
        ... on StatusContext { state context }
      } } } } } }
    }

    """

    private static func parse(node: [String: Any]) -> PRInfo? {
        guard let number = node["number"] as? Int, let url = node["url"] as? String else { return nil }
        let reviews = ((node["latestOpinionatedReviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        func who(_ state: String) -> [String] {
            reviews.filter { $0["state"] as? String == state }
                .compactMap { ($0["author"] as? [String: Any])?["login"] as? String }
        }
        var pr = PRInfo(
            repo: (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? "",
            number: number,
            title: node["title"] as? String ?? "",
            url: url,
            state: node["state"] as? String ?? "OPEN",
            isDraft: node["isDraft"] as? Bool ?? false,
            reviewDecision: node["reviewDecision"] as? String,
            approvedBy: who("APPROVED"),
            changesRequestedBy: who("CHANGES_REQUESTED"),
            author: (node["author"] as? [String: Any])?["login"] as? String ?? "",
            updatedAt: (node["updatedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        )
        let commits = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let rollup = ((commits.first?["commit"] as? [String: Any])?["statusCheckRollup"] as? [String: Any])
        let contexts = ((rollup?["contexts"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        for c in contexts {
            let name = c["name"] as? String ?? c["context"] as? String ?? "check"
            if c["__typename"] as? String == "CheckRun" {
                if c["status"] as? String != "COMPLETED" { pr.checksPending += 1; continue }
                switch c["conclusion"] as? String {
                case "SUCCESS", "NEUTRAL", "SKIPPED": pr.checksPassed += 1
                default: pr.checksFailed += 1; pr.failedChecks.append(name)
                }
            } else {
                switch c["state"] as? String {
                case "SUCCESS": pr.checksPassed += 1
                case "PENDING", "EXPECTED": pr.checksPending += 1
                default: pr.checksFailed += 1; pr.failedChecks.append(name)
                }
            }
        }
        return pr
    }
}

// MARK: Pieces shared by the panel, chips and hover card

struct ReviewBadge: View {
    let pr: PRInfo

    var body: some View {
        let (icon, text, color): (String, String, Color) = {
            if pr.state == "MERGED" { return ("arrow.triangle.merge", "Merged", .purple) }
            if pr.state == "CLOSED" { return ("xmark.circle", "Closed", .secondary) }
            switch pr.reviewDecision {
            case "APPROVED": return ("checkmark.seal.fill", "Approved", .green)
            case "CHANGES_REQUESTED": return ("exclamationmark.bubble.fill", "Changes requested", .red)
            case "REVIEW_REQUIRED": return ("eye", "Review required", .orange)
            default: return ("minus.circle", "No review needed", .secondary)
            }
        }()
        Label(text, systemImage: icon).foregroundStyle(color)
    }
}

/// "30/32 passed" with a coloured bar: green passed, red failed, amber running.
struct ChecksSummary: View {
    let pr: PRInfo
    var compact = false

    var body: some View {
        if pr.checksTotal == 0 {
            Text("No checks").foregroundStyle(.secondary)
        } else {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                if !compact {
                    GeometryReader { g in
                        HStack(spacing: 0) {
                            Rectangle().fill(.green).frame(width: g.size.width * frac(pr.checksPassed))
                            Rectangle().fill(.red).frame(width: g.size.width * frac(pr.checksFailed))
                            Rectangle().fill(.orange).frame(width: g.size.width * frac(pr.checksPending))
                        }
                        .clipShape(Capsule())
                    }
                    .frame(width: 60, height: 5)
                }
                Text("\(pr.checksPassed)/\(pr.checksTotal)").monospacedDigit()
                if !compact {
                    if pr.checksFailed > 0 { Text("\(pr.checksFailed) failed").foregroundStyle(.red) }
                    if pr.checksPending > 0 { Text("\(pr.checksPending) running").foregroundStyle(.orange) }
                }
            }
        }
    }

    private func frac(_ n: Int) -> CGFloat { CGFloat(n) / CGFloat(max(pr.checksTotal, 1)) }
    private var icon: String {
        pr.checksFailed > 0 ? "xmark.circle.fill" : pr.checksPending > 0 ? "clock.fill" : "checkmark.circle.fill"
    }
    private var color: Color { pr.checksFailed > 0 ? .red : pr.checksPending > 0 ? .orange : .green }
}

/// Everything about a PR at a glance, for the hover card.
struct PRCard: View {
    let pr: PRInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(verbatim: "#\(pr.number)").font(.headline.monospacedDigit())
                Text(pr.shortRepo).foregroundStyle(.secondary)
                if pr.isDraft { Text("Draft").font(.caption).padding(.horizontal, 6).background(Capsule().fill(.quaternary)) }
                Spacer()
                if let d = pr.updatedAt { Text(d, style: .relative).font(.caption).foregroundStyle(.tertiary) + Text(" ago").font(.caption).foregroundStyle(.tertiary) }
            }
            Text(pr.title).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ReviewBadge(pr: pr)
                if !pr.approvedBy.isEmpty {
                    Text("Approved by " + pr.approvedBy.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                if !pr.changesRequestedBy.isEmpty {
                    Text("Changes requested by " + pr.changesRequestedBy.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
                ChecksSummary(pr: pr)
                if !pr.failedChecks.isEmpty {
                    Text("Failing: " + pr.failedChecks.prefix(4).joined(separator: ", ") + (pr.failedChecks.count > 4 ? "…" : ""))
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }
}

// MARK: Chip for PR links in chats

/// A PR link as a live chip: number, title and status. Hover for the full card, click to open.
struct PRChip: View {
    let url: String
    @ObservedObject private var store = PRStore.shared
    @State private var hovering = false
    @State private var showCard = false

    var body: some View {
        let ref = PRStore.parse(url: url)
        let pr = ref.flatMap { store.byID[PRStore.id(owner: $0.owner, repo: $0.repo, number: $0.number)] }
        Button { if let u = URL(string: url) { NSWorkspace.shared.open(u) } } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.pull").foregroundStyle(.secondary)
                Text(verbatim: "#\(ref?.number ?? 0)").fontWeight(.semibold).monospacedDigit()
                if let pr {
                    Text(pr.title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 320, alignment: .leading)
                    ReviewBadge(pr: pr).labelStyle(.iconOnly)
                    ChecksSummary(pr: pr, compact: true)
                } else {
                    Text(ref.map { "\($0.repo)" } ?? url).foregroundStyle(.secondary)
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(hovering ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .help(url)
        .onAppear { if let r = ref { store.fetch(owner: r.owner, repo: r.repo, number: r.number, maxAge: 300) } }
        .onHover { inside in
            hovering = inside
            if inside {
                if let r = ref { store.fetch(owner: r.owner, repo: r.repo, number: r.number, maxAge: 30) }
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    if hovering { showCard = true }
                }
            } else {
                showCard = false
            }
        }
        .popover(isPresented: $showCard, arrowEdge: .bottom) {
            if let pr { PRCard(pr: pr) } else { ProgressView().padding(20) }
        }
    }
}

// MARK: Side panel

/// Picks the panel's inputs from the window on screen: its repository and the PRs its chat mentions.
struct PRPanelHost: View {
    @EnvironmentObject private var model: TmuxModel
    @State private var repo: String?
    @State private var repoPath: String?

    var body: some View {
        let w = model.selectedWindow
        Group {
            if let w, let sid = w.claude?.sessionID {
                PRPanelForChat(store: model.chatStore(for: sid), title: model.displayTitle(w), repo: repo)
            } else {
                PRPanel(repo: repo, mentions: PRStore.mentions(in: w.map { [model.displayTitle($0)] } ?? [], repo: repo))
            }
        }
        .task(id: "\(model.host):\(w?.path ?? "")") {
            guard let path = w?.path, !path.isEmpty else { repo = nil; return }
            repo = await model.repository(for: path)
        }
    }
}

private struct PRPanelForChat: View {
    @ObservedObject var store: ChatStore
    let title: String
    let repo: String?

    var body: some View {
        PRPanel(repo: repo, mentions: PRStore.mentions(in: texts, repo: repo))
    }

    /// What you and Claude wrote, newest first (tool output is left out: it's noisy).
    private var texts: [String] {
        var out: [String] = []
        for item in store.items.suffix(400).reversed() {
            switch item.kind {
            case .user(let t), .assistant(let t): out.append(t)
            default: break
            }
        }
        return out + [title]
    }
}

struct PRPanel: View {
    let repo: String?
    let mentions: [String]
    @ObservedObject private var store = PRStore.shared
    @AppStorage("prs.allRepos") private var allRepos = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pull requests").font(.headline)
                Spacer()
                if let t = store.listUpdated {
                    Text(t, style: .time).font(.caption).foregroundStyle(.tertiary)
                }
                Button { Task { await store.refreshList() } } label: {
                    if store.loadingList { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            if let repo {
                Picker("", selection: $allRepos) {
                    Text(repo.split(separator: "/").last.map(String.init) ?? repo).tag(false)
                    Text("All repos").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .help("Show PRs for this window's repository (\(repo)) or all of yours")
            }
            Divider().padding(.top, 10)
            List {
                if let e = store.error { Text(e).font(.caption).foregroundStyle(.red) }
                if !mentioned.isEmpty {
                    Section("In this chat") {
                        ForEach(mentioned) { PRRow(pr: $0, highlighted: true) }
                    }
                }
                section("Yours", filter(store.mine))
                let review = filter(store.reviewRequested)
                if !review.isEmpty { section("Waiting for your review", review) }
            }
            .listStyle(.sidebar)
            .overlay {
                if store.listUpdated == nil && store.loadingList { ProgressView("Loading from GitHub…") }
            }
        }
        .task {
            while !Task.isCancelled {
                await store.refreshList()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onAppear(perform: fetchMentions)
        .onChange(of: mentions) { _, _ in fetchMentions() }
    }

    /// Mentioned PRs we know about, newest mention first. Bare numbers that turn out
    /// not to be PRs (issues, other things) simply never show up.
    private var mentioned: [PRInfo] { mentions.prefix(12).compactMap { store.byID[$0] } }

    private func filter(_ prs: [PRInfo]) -> [PRInfo] {
        let hidden = Set(mentioned.map(\.id))
        return prs.filter { pr in
            !hidden.contains(pr.id) && (allRepos || repo == nil || pr.repo.caseInsensitiveCompare(repo!) == .orderedSame)
        }
    }

    private func fetchMentions() {
        for id in mentions.prefix(12) where store.byID[id] == nil { store.fetch(id: id) }
    }

    @ViewBuilder private func section(_ title: String, _ prs: [PRInfo]) -> some View {
        Section(title) {
            if prs.isEmpty && store.listUpdated != nil {
                Text(allRepos || repo == nil ? "None open" : "None open in this repo").foregroundStyle(.secondary)
            }
            ForEach(prs) { pr in
                PRRow(pr: pr)
            }
        }
    }
}

private struct PRRow: View {
    let pr: PRInfo
    var highlighted = false

    var body: some View {
        Button { if let u = URL(string: pr.url) { NSWorkspace.shared.open(u) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pr.number)").fontWeight(.semibold).monospacedDigit()
                    Text(pr.shortRepo).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if pr.isDraft { Text("Draft").font(.caption2).padding(.horizontal, 5).background(Capsule().fill(.quaternary)) }
                    Spacer()
                }
                Text(pr.title).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    ReviewBadge(pr: pr)
                    ChecksSummary(pr: pr, compact: true)
                }
                .font(.caption)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, highlighted ? 8 : 0)
            .background {
                if highlighted {
                    RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12))
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.35))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open in browser")
    }
}
