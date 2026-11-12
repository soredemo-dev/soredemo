import Capture
import Foundation
import Framing
import Observation
import Surface
import Timeline

/// The agent panel's state: the conversation, the turn running now, what the agent is doing this
/// moment, and each turn's checkpoint.
///
/// **Streamed text is coalesced**, not drawn per delta: a model writes in fragments of a few
/// characters, many times a second, and laying the panel out for each one is what makes a chat
/// stutter. Fragments gather here and reach the view every `flushInterval`.
///
/// **A turn is checkpointed at the history depth it began at**, and "revert this turn" undoes back
/// to it — but only while every step above that mark is one of this turn's own, which the recorded
/// step names and the depth together check. See the design document's "How it works".
@Observable
@MainActor
final class AgentPanelModel {
    /// One thing shown in a turn, in the order it happened.
    enum Item: Identifiable, Equatable {
        case text(id: Int, String)
        case thinking(id: Int, String, done: Bool)
        case tool(id: String, name: String, input: String?, state: ToolState, output: String?)
        case edit(AgentEditRecord)
        case note(PinnedNote)

        var id: String {
            switch self {
            case .text(let id, _): "text-\(id)"
            case .thinking(let id, _, _): "thinking-\(id)"
            case .tool(let id, _, _, _, _): id
            case .edit(let record): "edit-\(record.id)"
            case .note(let note): "note-\(note.id)"
            }
        }
    }

    enum ToolState: Equatable { case running, done, failed }

    /// What the agent is doing right now, for the live line under the turn and the pill over the
    /// preview.
    enum Activity: Equatable {
        case starting, thinking, writing
        case tool(String)
    }

    struct Turn: Identifiable, Equatable {
        /// Counted by the panel: the app reads no ambient value.
        let id: Int
        let request: String
        var items: [Item] = []
        var running = true
        var failure: String?
        var seconds: Double?
        /// The history depth before the turn's first edit.
        let checkpoint: Int
        var edits: [AgentEditRecord] {
            items.compactMap { if case .edit(let record) = $0 { record } else { nil } }
        }
    }

    enum Availability: Equatable { case checking, ready(String), notInstalled }

    /// How full the conversation is and how much of the account's windows are used, as the
    /// agent's provider last said. Each part is `nil` until it has been said.
    struct Usage: Equatable {
        var contextUsed: Int?
        var contextWindow: Int?
        var windows: [UsageWindow] = []
        /// Why there is no fresh reading, when there is not one: an expired or missing sign-in.
        var note: AccountUsageReader.Outcome?
        /// True when what is shown is older than thirty minutes.
        var isStale = false

        /// The share of the window in use, 0–100, unclamped; `nil` without both counts.
        var contextPercent: Double? {
            guard let contextUsed, let contextWindow, contextWindow > 0 else { return nil }
            return Double(contextUsed) / Double(contextWindow) * 100
        }
    }

    /// One agent the panel can drive, as the picker lists it.
    struct Choice: Identifiable, Equatable {
        let id: Int
        let name: String
        let mark: String
        let markIsTemplate: Bool
    }

    /// Where the chosen agent is remembered between launches: a per-person convenience, not data.
    static let providerDefaultsKey = "agentPanelProvider"

    /// How often streamed fragments reach the view.
    static let flushInterval: Duration = .milliseconds(50)

    private(set) var turns: [Turn] = []
    private(set) var availability = Availability.checking
    private(set) var activity: Activity?
    /// Whole seconds the running turn has taken, counted by a ticking task rather than read from a
    /// clock — for "Thinking · 6s" while it works.
    private(set) var elapsed = 0
    /// Bumped once per edit the agent lands, so the preview can sweep a band of light across.
    private(set) var editsLanded = 0
    /// `nil` is the person's own default model in their agent.
    var model: String?
    /// The models the chosen agent offers, beside the person's default.
    private(set) var models: [AgentModel] = []
    private(set) var usage = Usage()
    private(set) var providerIndex: Int
    /// Whether the person has asked to see their plan's usage before a message. **Off until they
    /// press "Show plan usage"**: it reads their agent's sign-in and makes a request, and the
    /// privacy pane promises nothing is sent unless they ask. Remembered once asked.
    var readsAccountUsage: Bool {
        didSet { defaults.set(readsAccountUsage, forKey: Self.readsAccountUsageDefaultsKey) }
    }
    static let readsAccountUsageDefaultsKey = "agentPanelReadsAccountUsage"

    /// When the plan's usage was last read or tried, and so when to read it next.
    @ObservationIgnored private var usageRefresh = UsageRefresh()
    @ObservationIgnored private var usageReading = false

    /// Reads the plan's usage with the panel's agent's own sign-in, when the policy says it is
    /// time — called while the panel is open; the panel's open state is the caller's to say.
    func refreshAccountUsage(panelOpen: Bool) async {
        guard readsAccountUsage else { return }
        let now = Minting.continuousNow().rawValue
        usage.isStale = usageRefresh.isStale(now: now)
        guard !usageReading, usageRefresh.shouldAsk(now: now, panelOpen: panelOpen) else { return }
        usageReading = true
        defer { usageReading = false }
        let outcome = await AccountUsageReader.read(provider: provider.name)
        let then = Minting.continuousNow().rawValue
        switch outcome {
        case .windows(let windows):
            usage.windows = windows
            usage.note = nil
            usage.isStale = false
            usageRefresh.answered(at: then)
        case .refused(let seconds):
            usageRefresh.refused(at: then, retryAfterSeconds: seconds)
        case .notSignedIn, .expired, .failed:
            usageRefresh.failed(at: then)
            usage.note = outcome
        }
    }

    /// Whether what is on screen goes with the next message.
    var includesContext = true
    /// Whether the agent may search the web, read pages and bring in pictures. **On by default**,
    /// because it is what the person's own agent does everywhere else; remembered; and said in
    /// the panel with what it costs (`docs/design/2026-11-13-the-agent-may-search-the-web.md`).
    var webAccess: Bool {
        didSet { defaults.set(webAccess, forKey: Self.webAccessDefaultsKey) }
    }
    static let webAccessDefaultsKey = "agentPanelWebAccess"

    var isRunning: Bool { turns.last?.running == true }

    @ObservationIgnored private let providers: [any AgentProvider]
    @ObservationIgnored private let defaults: UserDefaults
    private var provider: any AgentProvider { providers[providerIndex] }
    @ObservationIgnored private var session: String?
    @ObservationIgnored private var relay: AgentRelay?
    @ObservationIgnored private var bridge: AgentEditorBridge?
    @ObservationIgnored private var toolbox: (any MCPToolbox)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var counted = 0
    @ObservationIgnored private var pendingText = ""
    @ObservationIgnored private var pendingThinking = ""
    @ObservationIgnored private var flush: Task<Void, Never>?

    init(providers: [any AgentProvider] = [ClaudeCodeProvider(), CodexProvider()], defaults: UserDefaults = .standard) {
        self.providers = providers
        self.defaults = defaults
        let remembered = defaults.string(forKey: Self.providerDefaultsKey)
        providerIndex = providers.firstIndex { $0.name == remembered } ?? 0
        webAccess = defaults.object(forKey: Self.webAccessDefaultsKey) as? Bool ?? true
        readsAccountUsage = defaults.bool(forKey: Self.readsAccountUsageDefaultsKey)
    }

    var providerName: String { provider.name }
    var providerMark: String { provider.mark }
    var providerMarkIsTemplate: Bool { provider.markIsTemplate }
    var choices: [Choice] {
        providers.enumerated().map { Choice(id: $0.offset, name: $0.element.name, mark: $0.element.mark,
                                            markIsTemplate: $0.element.markIsTemplate) }
    }

    func checkAvailability() async {
        availability = .checking
        let checked = provider
        let found = await checked.availability()
        let offered = await checked.models()
        // The person may have switched agents while this one was being looked for.
        guard checked === provider else { return }
        models = offered
        switch found {
        case .ready(let version): availability = .ready(version)
        case .notInstalled: availability = .notInstalled
        }
    }

    /// Drives another agent from the next message. A new conversation, since one agent cannot
    /// resume another's; the turns already shown stay, and so do their cuts and their revert.
    func choose(_ index: Int) {
        guard !isRunning, providers.indices.contains(index), index != providerIndex else { return }
        close()
        providerIndex = index
        defaults.set(provider.name, forKey: Self.providerDefaultsKey)
        model = nil
        models = []
        usage = Usage()
        // Another agent is another account: its usage is read afresh.
        usageRefresh = UsageRefresh()
        Task { await checkAvailability() }
    }

    /// Sends one message. The relay is started on the first, against this editor.
    func send(_ text: String, editor: EditorViewModel, context: AgentPrompt.Context?) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, !isRunning, case .ready = availability else { return }
        do {
            try connect(to: editor)
        } catch {
            turns.append(Turn(id: nextID(), request: words, running: false, failure: "\(error)",
                              checkpoint: editor.timeline.historyDepth))
            return
        }
        guard let relay, let toolbox else { return }
        turns.append(Turn(id: nextID(), request: words, checkpoint: editor.timeline.historyDepth))
        activity = .starting
        startTicking()
        let message = AgentPrompt.message(words, context: includesContext ? context : nil)
        let stream = provider.run(message: message, session: session, model: model,
                                  tools: AgentTurnTools(relayConfigPath: relay.configPath, toolbox: toolbox,
                                                        webAccess: webAccess))
        task = Task { [weak self] in
            for await event in stream { self?.receive(event) }
            self?.finishTurn()
        }
    }

    func stop() {
        provider.stop()
    }

    /// Clears the conversation and starts a new session; edits already made stay in the history.
    func startOver() {
        guard !isRunning else { return }
        turns = []
        session = nil
        // A new conversation reads nothing yet; the account's windows are the same account's.
        usage.contextUsed = nil
    }

    /// Undoes the turn's edits — its cuts newest first while each is still the step on top, and
    /// its caption edits and its changes to the look each at once, back to before its first one,
    /// while they are still exactly as its last one left them. **Both checks before either acts**, so a turn is
    /// reverted whole or not at all. Returns why it could not, or `nil` when it did.
    func revert(_ turn: Turn, editor: EditorViewModel) -> String? {
        // Cuts and zooms both live on the timeline's history, in the order they were made.
        let cuts = turn.edits.filter(\.isTimelineStep).map(\.stepName)
        let captionEdits = turn.edits.compactMap { record -> (before: CaptionsModel.Snapshot, after: CaptionsModel.Snapshot)? in
            if case .caption(_, let before, let after) = record.kind { (before, after) } else { nil }
        }
        let lookEdits = turn.edits.compactMap { record -> (before: EditorLook, after: EditorLook)? in
            if case .look(_, let before, let after) = record.kind { (before, after) } else { nil }
        }
        guard !cuts.isEmpty || !captionEdits.isEmpty || !lookEdits.isEmpty else { return nil }
        let cutsOnTop = cuts.isEmpty
            || (editor.timeline.historyDepth == turn.checkpoint + cuts.count && editor.timeline.undoStepName == cuts.last)
        let captionsUntouched = captionEdits.last.map { editor.captions.snapshot == $0.after } ?? true
        let lookUntouched = lookEdits.last.map { editor.look == $0.after } ?? true
        guard cutsOnTop, captionsUntouched, lookUntouched else {
            return String(localized: "Something was edited after this turn, so it cannot be reverted at once. Undo its steps one at a time instead.")
        }
        for _ in cuts { editor.timeline.undo() }
        if let first = captionEdits.first {
            editor.captions.restore(first.before, named: String(localized: "Revert the Agent's Caption Edits"))
        }
        if let first = lookEdits.first { editor.restoreLook(first.before) }
        if let index = turns.firstIndex(where: { $0.id == turn.id }) {
            turns[index].items.removeAll { if case .edit = $0 { true } else { false } }
        }
        return nil
    }

    /// An edit the agent just made, listed under the running turn.
    func record(_ edit: AgentEditRecord) {
        flushNow()
        appendToCurrent(.edit(edit))
        editsLanded += 1
    }

    /// Ends the session: the relay's socket and its directory are removed.
    func close() {
        provider.close()
        task?.cancel()
        ticker?.cancel()
        flush?.cancel()
        relay?.close()
        relay = nil
        bridge = nil
        toolbox = nil
        session = nil
        activity = nil
    }

    // MARK: - events

    private func connect(to editor: EditorViewModel) throws {
        guard relay == nil else { return }
        let bridge = AgentEditorBridge(editor: editor, agentName: provider.name)
        bridge.onEdit = { [weak self] record in self?.record(record) }
        bridge.onNote = { [weak self] note in
            self?.flushNow()
            self?.appendToCurrent(.note(note))
        }
        let executable = Bundle.main.executableURL?.path(percentEncoded: false) ?? CommandLine.arguments[0]
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let toolbox = bridge.toolbox()
        relay = try AgentRelay(toolbox: toolbox, version: version, executable: executable)
        self.bridge = bridge
        self.toolbox = toolbox
    }

    private func receive(_ event: AgentEvent) {
        switch event {
        case .started(let id, _, _):
            session = id
        case .textDelta(let delta):
            activity = .writing
            pendingText += delta
            scheduleFlush()
        case .text(let text):
            // The finished block replaces what its deltas built, so a dropped delta heals.
            pendingText = ""
            settleThinking()
            replaceOrAppendText(text)
        case .thinkingDelta(let delta):
            activity = .thinking
            pendingThinking += delta
            scheduleFlush()
        case .thinking(let text):
            pendingThinking = ""
            replaceOrAppendThinking(text)
        case .toolStarted(let id, let name):
            flushNow()
            settleThinking()
            let short = ClaudeStream.shortName(name)
            activity = .tool(short)
            appendToCurrent(.tool(id: id, name: short, input: nil, state: .running, output: nil))
        case .toolCalled(let id, let name, let input):
            updateTool(id) { _ in .tool(id: id, name: ClaudeStream.shortName(name), input: input, state: .running, output: nil) }
        case .toolFinished(let id, let isError, let output):
            activity = .thinking
            updateTool(id) { item in
                guard case .tool(_, let name, let input, _, _) = item else { return item }
                return .tool(id: id, name: name, input: input, state: isError ? .failed : .done, output: output)
            }
        case .finished(let isError, let milliseconds, _, let id):
            if let id { session = id }
            updateCurrent { turn in
                turn.seconds = milliseconds.map { Double($0) / 1000 }
                if isError, turn.failure == nil { turn.failure = String(localized: "The agent stopped with an error.") }
            }
        case .failed(let message):
            updateCurrent { $0.failure = message }
        case .contextUsage(let used, let window):
            if let used { usage.contextUsed = used }
            if let window { usage.contextWindow = window }
        case .limits(let windows):
            usage.windows = windows
            usage.note = nil
            usage.isStale = false
            // A reading from the stream is an answer: the provider is not asked as well.
            usageRefresh.answered(at: Minting.continuousNow().rawValue)
        }
    }

    private func finishTurn() {
        flushNow()
        settleThinking()
        updateCurrent { $0.running = false }
        activity = nil
        ticker?.cancel()
    }

    // MARK: - coalescing

    private func scheduleFlush() {
        guard flush == nil else { return }
        flush = Task { [weak self] in
            try? await Task.sleep(for: Self.flushInterval)
            self?.flushNow()
        }
    }

    private func flushNow() {
        flush?.cancel()
        flush = nil
        if !pendingThinking.isEmpty {
            let more = pendingThinking
            pendingThinking = ""
            appendThinking(more)
        }
        if !pendingText.isEmpty {
            let more = pendingText
            pendingText = ""
            appendText(more)
        }
    }

    private func appendText(_ more: String) {
        let fresh = nextID()
        updateCurrent { turn in
            if case .text(let id, let text)? = turn.items.last {
                turn.items[turn.items.count - 1] = .text(id: id, text + more)
            } else {
                turn.items.append(.text(id: fresh, more))
            }
        }
    }

    private func replaceOrAppendText(_ whole: String) {
        let fresh = nextID()
        updateCurrent { turn in
            if case .text(let id, _)? = turn.items.last {
                turn.items[turn.items.count - 1] = .text(id: id, whole)
            } else {
                turn.items.append(.text(id: fresh, whole))
            }
        }
    }

    private func appendThinking(_ more: String) {
        let fresh = nextID()
        updateCurrent { turn in
            if case .thinking(let id, let text, false)? = turn.items.last {
                turn.items[turn.items.count - 1] = .thinking(id: id, text + more, done: false)
            } else {
                turn.items.append(.thinking(id: fresh, more, done: false))
            }
        }
    }

    private func replaceOrAppendThinking(_ whole: String) {
        let fresh = nextID()
        updateCurrent { turn in
            if let index = turn.items.lastIndex(where: { if case .thinking(_, _, false) = $0 { true } else { false } }),
               case .thinking(let id, _, _) = turn.items[index] {
                turn.items[index] = .thinking(id: id, whole, done: true)
            } else {
                turn.items.append(.thinking(id: fresh, whole, done: true))
            }
        }
    }

    /// Reasoning that has been followed by anything else is finished, whatever the stream said.
    private func settleThinking() {
        updateCurrent { turn in
            for index in turn.items.indices {
                if case .thinking(let id, let text, false) = turn.items[index] {
                    turn.items[index] = .thinking(id: id, text, done: true)
                }
            }
        }
    }

    private func startTicking() {
        elapsed = 0
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.elapsed += 1
            }
        }
    }

    // MARK: - turns

    private func nextID() -> Int {
        counted += 1
        return counted
    }

    private func appendToCurrent(_ item: Item) {
        updateCurrent { $0.items.append(item) }
    }

    private func updateTool(_ id: String, _ change: (Item) -> Item) {
        updateCurrent { turn in
            if let index = turn.items.firstIndex(where: { $0.id == id }) {
                turn.items[index] = change(turn.items[index])
            } else {
                turn.items.append(change(.tool(id: id, name: "", input: nil, state: .running, output: nil)))
            }
        }
    }

    private func updateCurrent(_ change: (inout Turn) -> Void) {
        guard !turns.isEmpty else { return }
        change(&turns[turns.count - 1])
    }
}
