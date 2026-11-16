import Foundation

/// Reads and writes the global Git settings that make Twofold the diff tool or the merge tool.
///
/// Git is pointed at the launcher script inside this app bundle by its full path, so nothing has to
/// be installed on the `PATH`. `run` is the one place that starts `git`; `WorkingCopy` uses it too.
struct GitIntegration: Sendable {
    enum Tool: Sendable, CaseIterable {
        case diff, merge

        /// The setting that names the tool Git uses, e.g. `merge.tool`.
        var key: String { self == .diff ? "diff.tool" : "merge.tool" }
        /// The section that describes a tool, e.g. `mergetool.twofold`.
        var section: String { (self == .diff ? "difftool" : "mergetool") + "." + GitIntegration.name }
        var commandKey: String { section + ".cmd" }
    }

    enum State: Equatable, Sendable {
        /// Git does not use Twofold. `other` is the tool it uses instead, if any.
        case off(other: String?)
        /// Git uses this copy of Twofold.
        case on
        /// Git uses a tool called twofold, but starts it with another command than this app would set.
        case custom(command: String)
    }

    enum Unavailable: Error, Sendable {
        case noGit
        /// The app runs from a temporary, randomised location (downloaded and not yet moved), so its path cannot be stored.
        case translocated
        /// Not running from an app bundle that contains the launcher.
        case noLauncher
        case failed(String)

        var message: String {
            switch self {
            case .noGit: "Git was not found on this Mac. Install Xcode’s command line tools or Homebrew’s git, then open this window again."
            case .translocated: "Move Twofold to your Applications folder and open it again. Git needs a permanent location to start it from."
            case .noLauncher: "This copy of Twofold has no command line launcher. Build the app with make app."
            case .failed(let text): text
            }
        }
    }

    static let name = "twofold"

    let git: URL
    /// Full path of the `twofold` script inside the app bundle.
    let launcher: String

    /// Finds git and the bundled launcher. Runs a process, so call it off the main thread.
    static func locate() throws(Unavailable) -> GitIntegration {
        let bundle = Bundle.main
        guard !bundle.bundlePath.contains("/AppTranslocation/") else { throw .translocated }
        guard let launcher = bundle.url(forResource: name, withExtension: nil)?.path,
              FileManager.default.isExecutableFile(atPath: launcher) else { throw .noLauncher }
        guard let git = findGit() else { throw .noGit }
        return GitIntegration(git: git, launcher: launcher)
    }

    /// `/usr/bin/git` is a stub that asks to install developer tools when there are none, so it is only
    /// used when `xcode-select` reports a developer directory.
    static func findGit() -> URL? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: "/usr/bin/git"),
           (try? run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"]))?.status == 0 {
            return URL(fileURLWithPath: "/usr/bin/git")
        }
        return ["/opt/homebrew/bin/git", "/usr/local/bin/git"].first { fm.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// The command Git runs for a tool. Git passes it to the shell, which fills in the variables.
    func command(for tool: Tool) -> String {
        let quoted = Self.shellQuoted(launcher)
        switch tool {
        case .diff: return quoted + #" --wait "$LOCAL" "$REMOTE""#
        case .merge: return quoted + #" --wait --base "$BASE" --output "$MERGED" "$LOCAL" "$REMOTE""#
        }
    }

    static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+")
        if !path.isEmpty, path.unicodeScalars.allSatisfy(safe.contains) { return path }
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    // MARK: Reading

    func states() throws(Unavailable) -> [Tool: State] {
        let keys = Tool.allCases.flatMap { [$0.key, $0.commandKey] }
        let pattern = "^(" + keys.map { $0.replacingOccurrences(of: ".", with: "\\.") }.joined(separator: "|") + ")$"
        let result = try config(["-z", "--get-regexp", pattern])
        // Exit status 1 means nothing matched, which includes having no configuration file at all.
        guard result.status == 0 || result.status == 1 else { throw .failed(Self.describe(result)) }
        var values: [String: String] = [:]
        for entry in result.output.split(separator: "\0") {
            let parts = entry.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            values[parts[0].lowercased()] = parts.count > 1 ? String(parts[1]) : ""
        }
        var states: [Tool: State] = [:]
        for tool in Tool.allCases {
            let current = values[tool.key] ?? ""
            let command = values[tool.commandKey] ?? ""
            if current != Self.name || command.isEmpty {
                states[tool] = .off(other: current.isEmpty || current == Self.name ? nil : current)
            } else {
                states[tool] = command == self.command(for: tool) ? .on : .custom(command: command)
            }
        }
        return states
    }

    // MARK: Writing

    func enable(_ tool: Tool) throws(Unavailable) {
        try set(tool.key, Self.name)
        try set(tool.commandKey, command(for: tool))
        switch tool {
        case .diff:
            // Without this Git asks before opening each file. Someone's own choice is left alone.
            if try config(["--get", "difftool.prompt"]).status != 0 { try set("difftool.prompt", "false") }
        case .merge:
            // Twofold's exit status says nothing; Git checks whether the merged file was written instead.
            try set(tool.section + ".trustExitCode", "false")
        }
    }

    func disable(_ tool: Tool) throws(Unavailable) {
        let current = try config(["--get", tool.key])
        if current.status == 0, current.output.trimmingCharacters(in: .whitespacesAndNewlines) == Self.name {
            let result = try config(["--unset-all", tool.key])
            guard result.status == 0 else { throw .failed(Self.describe(result)) }
        }
        // Fails when the section is already gone, which is fine.
        _ = try config(["--remove-section", tool.section])
    }

    private func set(_ key: String, _ value: String) throws(Unavailable) {
        let result = try config([key, value])
        guard result.status == 0 else { throw .failed(Self.describe(result)) }
    }

    private func config(_ arguments: [String]) throws(Unavailable) -> Output {
        do {
            return try Self.run(git, ["config", "--global"] + arguments)
        } catch {
            throw .failed("Git could not be started: \(error.localizedDescription)")
        }
    }

    private static func describe(_ output: Output) -> String {
        let text = output.error.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Git could not change its configuration (exit status \(output.status))." : text
    }

    // MARK: Process

    struct Output: Sendable {
        var status: Int32
        var data: Data
        var error: String
        var output: String { String(decoding: data, as: UTF8.self) }
    }

    static func run(_ tool: URL, _ arguments: [String], in directory: URL? = nil) throws -> Output {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.currentDirectoryURL = directory
        // Reading a repository must not rewrite its index: that would wake whoever watches it, us included.
        process.environment = ProcessInfo.processInfo.environment.merging(["GIT_OPTIONAL_LOCKS": "0"]) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // These commands print a few lines at most, so reading one pipe after the other cannot stall.
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let error = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, data: output, error: String(decoding: error, as: UTF8.self))
    }
}
