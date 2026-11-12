# The plan's usage, before a message is sent

*Written 2026-11-13. The owner asked for the agent panel to show how much of their Claude or Codex
plan is left the way another agent workspace does, and agreed to Soredemo reading the sign-in
those tools keep on the Mac to ask for it.*

## The question

The panel showed a plan's 5-hour and weekly windows only after a message, from what the agent's
own stream reported. Before the first message, and after a quiet hour, it showed nothing. Asking
the provider directly needs the person's sign-in. So: where is it, which endpoint, how often, and
what is shown when it cannot be had?

## What was measured, on this Mac, 2026-11-13

| | Claude Code 2.1.322 | Codex 0.167.1 |
| --- | --- | --- |
| Sign-in | the login keychain, service `Claude Code-credentials`, JSON `claudeAiOauth.accessToken` — and one more service per configuration directory, `Claude Code-credentials-<8 hex>` | `~/.codex/auth.json`, `tokens.access_token` and `tokens.account_id` |
| Endpoint | `GET https://api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20` | `GET https://chatgpt.com/backend-api/wham/usage`, `ChatGPT-Account-Id` |
| Answer | **401** — the stored token had expired 5869 minutes earlier; Claude Code renews it when it runs | **200** — `rate_limit.primary_window` / `secondary_window`, each `used_percent` 0–100, `limit_window_seconds`, `reset_at` in Unix seconds |

The Codex percentages agreed with the panel's own stream reading the same day (14 % against 13 %
a few hours earlier). **Claude's answer shape is not measured**: the only token on hand had
expired. The parser accepts `utilization` and `used_percentage` and treats a value of at most 1 as
a fraction — the stream reports `utilization` as a fraction — and is marked as unmeasured in
`docs/ARCHITECTURE.md`'s platform-premise register (D6b-36) until a live answer is seen.

## Decided

**1. The sign-in the panel's own agent uses, and no other.** The panel starts `claude` without
`CLAUDE_CONFIG_DIR`, so its sign-in is the unsuffixed keychain item; a suffixed one belongs to
some other configuration, possibly another account, and its usage would be a true number about
the wrong subject. Codex's is `~/.codex/auth.json` for the same reason.

**2. Read, never renewed.** An expired Claude token is not refreshed with the refresh token,
because that rewrites another program's credentials. The panel says the sign-in here has expired
and that the next message brings the numbers — which the stream does.

**3. Only after the person asks, only while someone is looking, and gently.** The strip offers
"Show plan usage" until it is pressed, and nothing is read before: the privacy pane promises that
nothing is sent unless the person asks, and the editor opens with the panel showing. Once pressed it
is remembered.

**3a.** A fetch when the panel appears, then at most
every 15 minutes while it stays open, never sooner than 5 minutes after the last answer; a
failure waits 30 s, doubling to 15 minutes; a `429` waits for its `Retry-After`. A reading from the
agent's own stream counts as an answer, so a conversation in progress asks the provider nothing.
The decision is a pure function of the times involved, tested without a clock.

**4. The last good reading stays, marked.** A failure does not blank the strip or show 0 %; it
keeps the last reading and says how old it is once it is older than 30 minutes.

**5. The token is never written, logged, shown or sent anywhere but its own provider's host.**
The request goes only to the two hosts above; the privacy pane names it; the app test that
holds the network rule admits the file only while those are its only hosts.

## Alternatives not taken

- **Refresh the token.** Above: it is another program's credential.
- **Read every keychain item and show the freshest.** The freshest may be another account's.
- **Ask the agent.** Each question costs a turn of the plan being measured.
