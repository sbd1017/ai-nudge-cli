# ai-nudge-cli

Sends a short message to **Claude Code** or **Codex** at the times you choose, so your plan's
usage window starts before you sit down. Send "hi" at 06:00 and a 5-hour window resets at 11:00,
not five hours after you first type.

There's no app running in the background. A single launchd agent wakes the tool at each time
you've set; it sends what's due and exits. It works with the screen locked, and runs a missed time
as soon as the Mac wakes. The binary is about 250 KB.

Messages go through the CLIs' own sign-ins (your Claude Pro/Max or ChatGPT plan), not an API key,
because API usage doesn't count toward subscription limits.

> Prefer a menu bar app that also types into the Claude app (new or incognito chats), with a
> settings window, a web page and Keep Awake? See **[AI Nudge](https://github.com/sbd1017/ai-nudge)**.

```console
$ ai-nudge-cli add morning --at 06:00 --days weekdays --message "Morning! Starting the clock."
● morning  06:00 weekdays  -> claude
    "Morning! Starting the clock."  next: Fri 06:00  last sent: never

$ ai-nudge-cli add gpt --at 06:00 --via codex
$ ai-nudge-cli install
Installed. Nudges will be sent on schedule while you're logged in (missed ones within 180 min are sent on wake).

$ ai-nudge-cli list
● morning  06:00 weekdays  -> claude
    "Morning! Starting the clock."  next: Fri 06:00  last sent: Thu 06:00
● gpt  06:00 daily  -> codex
    "hi"  next: Fri 06:00  last sent: Thu 06:00

Scheduled (launchd agent installed).

$ ai-nudge-cli log
2026-10-22T06:00:07+01:00 morning: sent via claude -> ok: Good morning! How can I help today?
2026-10-22T06:00:15+01:00 gpt: sent via codex -> ok: Hi! What would you like to work on?
```

## Install

You need macOS 13 or later, and Claude Code and/or Codex signed in to your plan.

### Download

```sh
curl -LO https://github.com/sbd1017/ai-nudge-cli/releases/latest/download/ai-nudge-cli.zip
unzip ai-nudge-cli.zip && mkdir -p ~/.local/bin && mv ai-nudge-cli ~/.local/bin/
xattr -d com.apple.quarantine ~/.local/bin/ai-nudge-cli 2>/dev/null   # not notarized
ai-nudge-cli doctor
```

### Build it yourself

Needs Xcode or its command-line tools.

```sh
git clone https://github.com/sbd1017/ai-nudge-cli.git
cd ai-nudge-cli
make install          # builds, copies to ~/.local/bin, installs the launchd agent
ai-nudge-cli doctor   # checks the CLIs are found and signed in
```

### Finding Claude Code and Codex

`ai-nudge-cli` looks on your `PATH` (plus `~/.local/bin`, `/opt/homebrew/bin` and `/usr/local/bin`)
and inside the desktop apps: Claude.app keeps a copy of Claude Code, and ChatGPT.app ships `codex`.
If `doctor` says one isn't signed in, run the command it prints. To point at a specific binary, set
`"claudePath"` or `"codexPath"` in the settings file.

## Commands

```sh
ai-nudge-cli add NAME --at HH:MM [--days daily|weekdays|weekends|mon,wed,...]
                      [--via claude|codex] [--message TEXT] [--model MODEL] [--resume SESSION_ID]
ai-nudge-cli edit NAME [same options] [--no-resume]
ai-nudge-cli remove NAME | enable NAME | disable NAME
ai-nudge-cli list
ai-nudge-cli send NAME [--dry-run]      # send it now (--dry-run prints the command instead)
ai-nudge-cli install | uninstall        # start or stop sending on schedule
ai-nudge-cli doctor                     # which CLIs were found, and whether they're signed in
ai-nudge-cli log                        # recent activity
```

The defaults are `--days daily`, `--via claude` and `--message "hi"`.

- **`--model`:** any model the CLI accepts. `--model haiku` uses the smallest Claude model; it
  still starts the same window.
- **`--resume`:** continues one conversation (a Claude Code session id, or a Codex session id or
  thread name). Without it, each message is a throwaway session that isn't saved.
- Claude runs with no tools and no MCP servers, and Codex in a read-only sandbox, both in an empty
  folder. A nudge only gets a reply; it can't do anything on your Mac.

## Good to know

- **Sleep:** if the Mac was asleep at a scheduled time, launchd runs the agent when it wakes. A
  nudge up to 3 hours late is still sent; an older one is skipped. Change this with
  `"catchUpMinutes"` in the settings file. The agent only runs while you're logged in. A Mac that
  is shut down, or asleep with the lid closed, sends nothing until it's back.
- **Which window starts:** Claude Code shares its usage limits with claude.ai, so a Claude nudge
  starts the claude.ai window too. A Codex nudge is a Codex request, so it starts the Work + Codex
  allowance; ChatGPT chat has separate limits, and a chat message doesn't start that window.
- **No double sends:** each scheduled time is sent once, even if launchd runs the agent again.
  Adding or editing a nudge doesn't send for a time that has already passed today.
- **Files:**
  - settings: `~/.config/ai-nudge-cli/nudges.json`
  - send history: `state.json` in the same folder
  - log: `~/Library/Logs/ai-nudge-cli.log`
  - agent: `~/Library/LaunchAgents/local.ai-nudge-cli.plist`

  `make uninstall` removes the binary and the agent and keeps your settings.

## How it works

`install` writes one launchd agent with a `StartCalendarInterval` entry for every nudge time, plus
`RunAtLoad`. Each run (`ai-nudge-cli tick`) sends every enabled nudge whose latest scheduled time
has passed, hasn't been sent and is within the catch-up window, then exits. Any change to your
nudges rewrites and reloads the agent.

## License

MIT. See [LICENSE](LICENSE).
