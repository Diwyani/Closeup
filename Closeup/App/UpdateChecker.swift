import AppKit
import Observation
import SwiftUI

/// Tells you when there's a newer Closeup on GitHub, and runs the updater.
///
/// Once a day (and when you choose Check for Updates) it asks GitHub for the
/// date of the latest change and compares it with when this copy was built.
/// That's the only thing sent or received: no recordings, no personal data.
@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle, checking, available, upToDate, failed
    }

    static let repository = "Diwyani/Closeup"
    static let whatsNew = URL(string: "https://github.com/\(repository)/commits/main")!
    private static let latestCommit = URL(string: "https://api.github.com/repos/\(repository)/commits/main")!
    private static let updaterScript = URL(string:
        "https://raw.githubusercontent.com/\(repository)/main/Update%20Closeup.command")!

    private(set) var status = Status.idle
    private let defaults = UserDefaults.standard

    /// When this copy of Closeup was built: the newest file in Contents/MacOS.
    private var builtAt: Date {
        let folder = Bundle.main.bundleURL.appending(path: "Contents/MacOS")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max() ?? .distantFuture
    }

    /// At most once a day, in the background.
    func checkIfDue() {
        let last = defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 24 * 60 * 60 else { return }
        Task { await check(manually: false) }
    }

    func check(manually: Bool) async {
        status = .checking
        defaults.set(Date.now, forKey: "lastUpdateCheck")
        do {
            var request = URLRequest(url: Self.latestCommit, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let latest = try Self.commitDate(from: data)
            // Ten minutes of slack: a build made right after a change isn't "old".
            let newer = latest.timeIntervalSince(builtAt) > 10 * 60
            let dismissed = defaults.object(forKey: "dismissedUpdate") as? Date
            if newer, manually || dismissed.map({ latest > $0 }) ?? true {
                status = .available
            } else {
                status = manually ? .upToDate : .idle
            }
        } catch {
            status = manually ? .failed : .idle
        }
        if status == .upToDate || status == .failed {
            try? await Task.sleep(for: .seconds(4))
            if status == .upToDate || status == .failed { status = .idle }
        }
    }

    /// "Later": hide it until there's something newer still.
    func dismiss() {
        defaults.set(Date.now, forKey: "dismissedUpdate")
        status = .idle
    }

    /// Downloads the updater and opens it in Terminal, where you can watch it
    /// build. It quits Closeup and opens the new one when it's done.
    func installUpdate() {
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: Self.updaterScript)
                let script = FileManager.default.temporaryDirectory.appending(path: "Update Closeup.command")
                try data.write(to: script)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                NSWorkspace.shared.open(script)
            } catch {
                status = .failed
            }
        }
    }

    private static func commitDate(from data: Data) throws -> Date {
        struct Response: Decodable {
            struct Commit: Decodable {
                struct Person: Decodable { let date: Date }
                let committer: Person
            }
            let commit: Commit
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response.self, from: data).commit.committer.date
    }
}

/// The strip at the top of the window while there's news about updates.
struct UpdateBanner: View {
    let checker: UpdateChecker

    var body: some View {
        switch checker.status {
        case .available:
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("A new version of Closeup is available.")
                Link("What's new", destination: UpdateChecker.whatsNew)
                Spacer()
                Button("Later") { checker.dismiss() }
                Button("Update") { checker.installUpdate() }
                    .buttonStyle(.borderedProminent)
                    .help("Opens a Terminal window that downloads, builds and installs the new version, then reopens Closeup")
            }
            .bannerStyle()
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates").foregroundStyle(.secondary)
                Spacer()
            }
            .bannerStyle()
        case .upToDate:
            Label("You have the latest version.", systemImage: "checkmark.circle.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
                .bannerStyle()
        case .failed:
            Label("Couldn't reach GitHub. Check your internet connection.", systemImage: "exclamationmark.triangle.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
                .bannerStyle()
        case .idle:
            EmptyView()
        }
    }
}

private extension View {
    func bannerStyle() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .bottom) { Divider() }
    }
}
