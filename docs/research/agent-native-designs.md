# How agent-native editors are built — read from source, 2026-11-08

Five open-source projects that put an agent inside an editor were read in full where it mattered:
two that drive the person's own coding-agent CLI, one native macOS video editor with its own
model clients, one Electron screen recorder with an MCP server, and one desktop assistant that
drives a coding agent's app-server. Read for ideas only; no code was taken. What follows is the
pattern, then what Soredemo does with it.

## The patterns

### Connecting the agent

| Pattern | Seen as | Trade |
| --- | --- | --- |
| Drive the person's installed CLI through its SDK or headless mode, under their own login | a slide framework (Claude Code and Codex, one provider interface); a desktop assistant (Codex `app-server` over JSON-RPC) | no key held, no bill of ours; depends on the CLI's wire format, which moves |
| The app holds the person's API key and calls the model itself | a native video editor (Anthropic and OpenAI clients, plus its own cloud) | full control of the loop; the app now stores secrets and owns retries |
| An MCP server for outside agents | all of them; HTTP with sessions in one, stdio in two | stdio reaches only the process that started it; HTTP reaches every local process |
| The app is the authority when it runs | an MCP server that forwards each document call to the running app over a local channel, and edits the file only when the app is closed | the agent always sees the document the person sees |

### What the agent may do

- **Edits inside a declared scope are allowed; anything else asks.** One framework passes the
  workspace's writable roots and routes every other tool call to an allow/deny card in the panel,
  with an "auto-approve" switch for commands.
- **Refusal that teaches.** One server refuses any edit to a project the person cannot undo until
  the agent has created a checkpoint, and the refusal says exactly that — "call createCheckpoint,
  then retry" — so the agent corrects itself instead of failing.
- **A confirmation argument the agent can set itself** (`confirmed: true`) is no gate: the agent
  sets it. Seen once; not a pattern to follow.
- **The child's environment is built from an allow-list** — PATH, HOME, USER, SHELL, TMPDIR,
  locale, proxies — so the agent's shell commands cannot read the operator's cloud keys and tokens.
- **Required tools**: a server the first turn depends on is marked required, so the agent does not
  start its first turn before the tools exist.

### What the agent can see

- **The selection and the page go with every message**, in escaped tags, frozen at send time and
  sorted, so the prompt prefix stays byte-stable for caching.
- **@-mentions** of a clip, an asset or a selected time range, resolved into structured context.
- **A frame**: one editor gives its agent `capture_frame` / `inspect_media`, so it can look at the
  picture it is editing, not only at the timeline's numbers.
- **The transcript, word by word**, with tools to remove words and silences by index.

### What the agent tells the person

- **Streaming text, coalesced** off the main thread (one editor flushes every 50 ms).
- **Tool calls as quiet rows** that shimmer while running, fold into "N steps" when done, and open
  to their arguments and result.
- **A presence pill over the canvas** — "Claude is editing · Reading steps" — and a sweep of light
  across the picture when an edit lands.
- **Questions as a form**: an agent that cannot ask interactively ends its turn with a tagged block
  of questions; the panel draws them as choices with an "other" field and sends the answers back.
- **Every tool result reports what moved** (one editor's mutation delta), so the next step starts
  from the timeline as it is.
- **The agent reports its own failures** — a feedback tool for "missing capability", "confusing",
  "wrong result" — so the product learns where agents get stuck.

### Turns, sessions and taking it back

- **A checkpoint before each response, and Revert under it** (a commercial transcript editor; one
  framework uses the provider's own rewind).
- **Edit an earlier message** and the conversation is cut back to it and re-run from there.
- **Sessions are kept**, listed per document, resumable, deletable; a message sent while a turn
  runs waits and joins the same conversation.
- **Skills**: reusable, named workflows the person or the agent saves and reads back — "apply the
  comments", "make a theme" — shipped for terminal agents too.

## What Soredemo takes, and in what order

Already built (stages 7 and 8): the person's own CLI under their login; the app as the authority
through a relay; no built-in tool in the session; context in escaped tags; coalesced streaming;
quiet tool rows that fold; a presence pill and a sweep; edit cards; per-turn revert; pinned notes
addressed in one pass with an answer for each.

Next, each a change this reading made the case for:

1. **The child's environment from an allow-list.** Today the agent inherits the app's whole
   environment. Fix first: it is a security defect, not a feature.
2. **Codex as a second provider**, behind the same protocol, with the provider's mark beside its
   name and a picker between them.
3. **The agent can look at a frame** — a `look` tool returning the composited picture at a time,
   so "is the button readable after the zoom?" has an answer.
4. **Refusals that teach** throughout the live tools: every failure names the next call to make.
5. **Questions as a form**, for an agent that needs a choice before it cuts.
6. **Sessions kept with the project**, resumable, and an edited message re-runs from there.
7. **Skills**: saved instructions — "my house style" — sent with every turn, and editable.
8. **A feedback tool** for the agent to say what it could not do, kept on this Mac for the person
   to read; nothing is sent anywhere.

Not taken: the app holding API keys (Soredemo holds none and keeps it so); an HTTP MCP server; a
confirmation flag the agent can set itself.

## Codex, measured: what `app-server` lets a host close — 2026-11-09

Measured with a throwaway JSON-RPC client against the installed `codex app-server`, one ephemeral
read-only thread, `approvalPolicy: "untrusted"`, one dynamic tool (`soredemo_steps`), and a turn that
asked the agent to call it **and then list `~` with any tool it had**. The host declined every
server request. Each row is one run; the agent's answer and every item it produced were read in full.

| Configuration | Dynamic tool | What else ran | Home listed? |
| --- | --- | --- | --- |
| feature disables only (shell, unified exec, apps, browser, computer use, in-app browser) | called, answered | `cua_repl` ran `cua.getState()` **with no approval asked**; its next call (Finder) raised an elicitation, which was declined | no |
| as above, `--disable code_mode_host` | **unreachable** — "code-mode host is disabled" | the same `cua_repl` call | no |
| as the first, `--disable plugins remote_plugin multi_agent` | called, answered | Codex's own `list_mcp_resources` / `list_mcp_resource_templates` (read-only) | no |

What follows from it:

- **Dynamic tools are reached through code mode.** `functions.exec` is how the model calls them, so
  `code_mode_host` must stay on. In these runs it had no filesystem: the agent reported so, and no
  file name appeared in any item.
- **Turning `computer_use` off does not remove computer use.** `cua_repl` arrives as a *plugin*
  (`unified-computer-use`) and as an MCP server in the person's own `~/.codex/config.toml`, put there
  by another app. Only `--disable plugins` removed it here, and the person's configured MCP servers
  (`codex mcp list` showed `cua_repl` and `node_repl` enabled) must each be turned off with
  `-c mcp_servers.<name>.enabled=false`, read from that listing at start rather than from a list we
  write down — a list of what we close rots by omission.
- **A host's decline arrives too late for a call that asks nothing.** `cua.getState()` completed
  without a request reaching the host. So prevention is configuration, and the host's job is the
  second line: decline every approval and elicitation, and **end the turn** (`turn/interrupt`) on any
  `mcpToolCall` item from a server that is not Soredemo's, saying which one, rather than letting it
  run on.
- **Re-measure on every Codex update.** None of this is a documented contract; it is what this
  version did, which is the D6b shape.
