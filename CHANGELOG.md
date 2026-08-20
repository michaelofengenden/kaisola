# Changelog

## 0.1.130 — 2026-08-17

- The launch sheet grew up. Starting a chat or an agent used to open a system alert stuffed with four popups; it now opens a sheet in the same design language as the Start a Session chooser: pick a subscription, pick where it runs, go. Each subscription row carries its own headroom — "38% used · 5-hour limit" — right where the choice is made, the router's suggestion arrives preselected with its reason written underneath, and locations are real rows showing their branch and path instead of entries buried in a popup. The Run Profile popup left the launch flow entirely: new chats start on the default profile, and policies are edited in Settings, not re-decided at every launch.

## 0.1.129 — 2026-08-17

- "Session Connection Unavailable" is dead, this time at the root. Three releases of broker fixes each cleared a real blockage, and the message kept coming back, because the last cause was a deadlock rather than a stale record: connecting dials every broker generation the registry remembers, a dead one's leftover socket answers "connection refused", and one corpse failed the whole connection — healthy brokers included. Meanwhile the cleanup that removes dead records only ran after a successful connection, so the app could never bury the very record that kept it from connecting. One machine carried four such corpses, back to v0.1.105, in exactly this loop. Startup now buries provably dead records before anything dials; if one dies in the moment between that check and the dial, both the reading and the writing connection skip the corpse instead of dying on it; and a living broker that refuses its dial still fails loudly, because skipping it would silently drop real terminals. The "provably dead" judgment also grew a second witness — the kernel's own record of when the process started — so a clock correction can never get a living broker's records reaped.

## 0.1.128 — 2026-08-16

- Six subscriptions no longer read as one. Every account card in Usage was showing the default login's numbers with a different name on top, because the helper that reads each account rebuilt its environment from a compatibility allowlist that silently deleted the very variable naming which account to read — and the Codex reader dropped it a second time on its own. The account pointer now rides the helper invocation as an explicit argument, which no environment filter can strip, so each card shows the account it names: its own plan, its own percentages, its own reset times, and its own signed-in state.
- Signing in stopped being chopped. The sheet's phases now flow into each other instead of rebuilding the whole layout per step, a live spinner replaces the static hourglass that made a twelve-second shell probe look like a hang, and success closes the sheet by itself once you've read it — no Done to click, no card behind it stuck saying "Not signed in" until some later refresh. A sign-in that goes quiet says so, opens its transcript, and offers Retry right there — including after you've pasted a code and the CLI went silent; retry keeps the previous attempt's output under a divider instead of destroying the evidence; and a rewording of the CLI's paste-the-code prompt can no longer strand the flow.
- A blocked chat's Sign In actually works now. The five-second verification window used to start the moment the sheet opened, so any real sign-in — browser, approval, code — outlived it and the chat flipped to "could not confirm in time" while you were still signing in. The window is now sized for the real check and runs from when you finish, not from when you start.
- Usage cards and the Accounts list agree. They derived signed-in state from different fields, so the same account could wear green on one screen and orange on the other. Both now speak through one resolver, and a card that needs a sign-in carries the button on its face instead of hiding it behind the ellipsis menu.
- Kaisola routes your subscriptions. A "New sessions" policy on the Accounts card decides how launches pick an account: Manual is exactly what you had; Remember last choice preselects the account you last used with that agent — the default, and invisible until you pick something once; Balance by headroom suggests the signed-in account with the most limit left and says why, right under the picker. Under the balanced policy a Mesh fans its columns across your subscriptions freest-first instead of stacking every column on the project default. Suggestions preselect, never override: your explicit pick always wins, and an account the router can't verify is never suggested at all. Kaisola still holds no provider tokens — every account's credentials stay with its own CLI, in its own directory.

## 0.1.127 — 2026-08-15

- Tinted comes in five colourways. A Tint palette menu joins Settings when the theme is Tinted: Meadow is exactly the composition you already had, Dusk crosses warm sand into a dusty rose, Harbor a powder blue into seafoam, Graphite two quiet greys, and Desktop takes your wallpaper's own hue and holds it to a pastel — fixed softness, fixed brightness, only the hue is yours, so a saturated wallpaper can never turn the window flat blue the way raw sampling once did. Dark mode keeps each palette recognisably itself rather than falling back to one shared look.
- The living tint is finally visible. The breath was shipped at a depth nobody ever reported seeing; it now swings twice as deep on a curve that lingers at each end, and the whole field swells about three percent on its own slower rhythm. Three motions, three periods, none of them multiples — so nothing ever pulses. Still opt-in, still stilled by Reduce Motion.
- Every theme sits on frosted glass, the way Safari's window does. Solid and Tinted painted their background as one flat plate to the window's edge; now the ground under everything is the same behind-window material Glass uses, with Solid keeping its exact white (or near-black) at nine parts in ten and Tinted flowing its gradient over the material. Your work surfaces — terminals, chats, documents — stay fully opaque in Solid; that promise moved to where it matters. Reduce Transparency still gets the flat plate everywhere, including one Tinted branch that previously ignored it.
- The window is rounder where you actually look. Every corner in the app steps up — the content card most of all — and that card finally casts a shadow into the gutter around it, plus a hairline that closes its lower edge in light mode. It reads as a card floating on the ground instead of a differently-tinted region. With Reduce Transparency or Increased Contrast the card keeps a flat, high-contrast border and no shadow.
- Session rows sit tighter under their projects. Titles drop a point, the little brand marks scale down with them, and each session row gives back six points of height — so the list reads as projects with their sessions tucked underneath, not two lists fighting at the same size.
- The chat looks like it was built this decade. While the agent works, a light sweeps through the status word — Thinking, Working, or the tool's own name — the way Claude Code and Codex do it, owned entirely by the render server and frozen the moment the window is covered or Reduce Motion asks. Your messages sit in proper bubbles with room to breathe, replies keep a steadier rhythm between turns, tool-call headers say less and show more, and the agent's inner thoughts carry a quiet quote rule.

- Connecting no longer loses to the ghosts of brokers past. After a restart, the process numbers of long-dead brokers get handed out again — sometimes to system processes the app has no right to signal, which it read as "still alive". One such phantom from v0.1.105 could never be cleaned up, the cleanup that worked around it kept rewriting the shared registry, and every connection attempt noticed the rewrite mid-handshake and aborted as a safety measure — so the app sat on "Session Connection Unavailable" while a perfectly healthy broker waited to be asked. A broker recorded as started before the last boot is now known dead no matter who holds its old number, every dead record is cleared in one pass instead of one per heartbeat, and a failed handshake closes its connection instead of leaving it dangling.

## 0.1.125 — 2026-08-14

- Terminals survive a restart of your Mac. Each session broker leaves a lock file while it runs and removes it as it exits — but a broker that dies with the machine never gets to remove anything. On the next launch the new broker saw the old lock, concluded another copy of itself was already running, and quit without writing a single line of log, over and over, all day. A lock now names the process that took it from the moment it exists, one written before the last boot is never mistaken for a living owner however its process number has been recycled, and a lock whose owner is provably gone is cleared and taken over. A lock whose owner is genuinely alive is still respected, and now says so in the log instead of saying nothing.
- Groundwork for a faster, native session engine. The app can now build, package, sign, and launch its Swift terminal broker through the same production contract as the Node one — but only when a developer explicitly asks for it with an environment variable. Nothing changes for normal use: Node remains the engine every launch gets, and the new binary rides along inert in the app bundle until the native engine has earned the switch.
- Glass stays bright when you click away. The window dimmed to grey the moment it lost focus, because the material was treating focus as something to indicate. Glass is the app's surface, not a focus light; it now stays as white unfocused as focused, the way the desktop apps beside it do, and the light veils are brighter across the board.
- Tinted can breathe. Settings has a "Living tint" switch, off by default, that lets the gradient swell and settle about three times a minute — shallow enough that you feel it rather than see it. It stays out of step with the drift so the two motions never pulse together, and it holds still with Reduce Motion on or while the window is covered.
- Other Macs keeps quiet until you have another Mac. The section was showing "The saved Firebase session is unavailable." to people who had never paired a second computer — an error about a connection that was never made. Errors there now appear only once this Mac has actually seen another one, and that knowledge survives relaunches even when the saved snapshot does not load.
- The project sidebar opens at the width long titles need, and remembers yours. Drag it and the width sticks across launches — a stray click on the divider does not count as a choice — and a double-click on the divider goes back to the default.
- The Files rail sits flush against the window. It was drawn as a rounded box floating inside the pane, the only surface in the window with its own frame; it now runs straight to the edges like the project rail on the other side.
- Starting a session answers your pointer everywhere. The chooser's keyboard focus draws a visible ring instead of leaving the first card looking exactly like the other three, Escape steps back before it cancels, and a card or agent row that cannot be clicked visibly dims instead of pretending it might. Project tabs, session tabs, and both + buttons brighten under the pointer, and the New Session row in the sidebar shows its cancel control when you hover it.

## 0.1.124 — 2026-08-14

- Terminals connect again after updates. A broker with no terminals quits on its own to give its memory back — that part is deliberate — but the app would only replace it if no older brokers were still running. After a few updates there always are: they hold the terminals you had open before. So every launch started a new broker, refused to publish it, watched it give up after thirty seconds, and started another, forever — high CPU and not a single working terminal, while your old sessions sat reachable the whole time. The app now replaces the missing broker and keeps every older one exactly as it was, so the terminals they own survive the same fix that brings new ones back.
- Glass in light mode shows your desktop again. The middle of the window had been made an exact white plane — deliberately, one refinement at a time — until Glass and Solid were the same picture. The canvas is still the brightest surface in the window, but a third of the softened desktop now comes through it.
- Tinted moves. Its colours were in the code and invisible on screen: at eleven percent over white, the sage and the lilac both rounded to white. They are three times stronger now — still pastel — and the gradient drifts, slowly enough that you will never catch it moving, only notice it is somewhere else. In dark mode the tint comes from your desktop's own colour and flows into a neighbouring hue of the same family. With Reduce Motion on, it holds still.
- The session cards light up under the pointer. Terminal, Agent Terminal, Chat and Mesh answered a click but not a hover; they now brighten as you pass over them, and a card that cannot be clicked no longer pretends it might.
- The sidebar opens wider. New windows get the width long project and session titles need; if you dragged yours to a size you like, it stays where you put it.

## 0.1.120 — 2026-08-12

- Solid and Tinted have a white canvas. The middle of the window was grey in both of them while the sidebar right beside it was white, and those two are meant to be the same surface. The panel holding your terminals and chats was laying a frosted layer over the background no matter which theme you picked, and a frosted layer over white comes out grey. That layer only earns its place over Glass, the one theme that really does show your desktop, so Glass is now the only theme that gets it. Glass itself is a little clearer than it was, for the same reason.
- The account menu is readable. Under your name it was printing four or five lines of engineering detail, several of them carrying a sixty-four character fingerprint and a process number, which is what stretched the menu across the whole window and buried the one clause that meant anything at the end of the longest line. It now says the version, whether you are connected, and one plain sentence if a terminal update is waiting on something. None of the detail is gone: "Copy Diagnostics" puts all of it on the clipboard, in full, which is the form it was wanted in anyway.
- The bottom of the sidebar is bigger. Your picture, your name, and the settings, usage and notification buttons had all been shrunk a point at a time to buy room for a name that no longer needs it, and the three buttons were the faintest things in the window despite being among the few you can actually click. They are larger now and drawn in the same ink as the text beside them.
- A single terminal is no longer framed in blue. The accent border marks which pane you are typing in, which tells you nothing when there is only one pane, so it sat around the terminal all day distinguishing it from nothing while the sidebar was already marking that same session in that same colour. It appears now only when you have a split, which is the only time it answers a question.

## 0.1.119 — 2026-08-12

- Terminals come back after an update that did not finish announcing itself. Every session broker writes itself down twice, once in the shared list of brokers and once in a file of its own, and one that is interrupted between the two leaves the newest entry in that list with no file beside it. The app read that single missing file as proof the whole list was corrupt. It threw away the healthy brokers named further down the same list, and because a corrupt list is not something it is willing to overwrite, it would not start a fresh broker either. Every terminal you had open went unreachable and relaunching changed nothing. An entry with no file written for it is now read as a broker that never finished starting, which the app already knows how to replace, and the working brokers listed beside it stay available to reconnect to. A file that exists but describes a different broker is still refused, exactly as before.
- The account menu at the bottom of the sidebar reads as a menu. Your email, the version and the connection status sat among the buttons as plain rows, and since a menu row that does nothing is drawn greyed out, all three looked like commands somebody had disabled. They are headings now: sign-out sits under your name, settings and usage go together, reconnect sits with the retained terminal versions, and the build details sit under the version.
- Settings has a third theme, Tinted. Glass shows what is actually behind the window and Solid shows none of it. Tinted sits between the two, taking the colour of your desktop and carrying it across the canvas and both side panels, so the window picks up the hue of the picture behind it without going transparent.

## 0.1.118 — 2026-08-12

- The sidebar highlights the tab you are on in blue. It used to paint a grey bar behind it and put the colour in the text, which is backwards from every other sidebar on the Mac, and the grey ran the full width of the column while the row it was marking started well to the right of it. The fill is now the accent colour, the name and the little mark beside it match, and the highlight starts where the row does.
- Project names read as headings again. They were the largest, darkest, heaviest text in the column, which meant the folder names shouted over the sessions inside them. They are smaller and quieter now, with a little air above each one so you can see where one project ends and the next begins.
- Opening a second surface beside the first marks both of them. The row for the pane you were not typing in has never been marked at all, so half of a split always looked closed.
- Scrolling the sidebar when there is nothing below the fold no longer makes it jitter. The list was being yanked back into place on every frame of its own bounce, so it fought your finger the whole way.
- Settings has one theme control — Glass or Solid — instead of seven separate glass menus. The recipe behind Glass is now fixed, and it is a better one: the surface shows what is genuinely behind the window, live, rather than a blurred copy of a wallpaper file the app had to go looking for and could not find at all on a rotating or dynamic desktop. Dark mode is properly dark, which it was not, because the panel covering most of the window had been lightening everything under it.
- The notification bell stops moving. It appeared only when something needed you, which shoved the settings gear and the usage percentage sideways every time an agent finished a turn. It now keeps its place and only changes colour. Passing notices no longer land in the middle of the window on top of whatever you are typing into.

## 0.1.117 — 2026-08-11

- A terminal running an agent no longer shakes when you pull past the newest line. Overscrolling at the bottom is meant to give a little and spring back. Instead, every batch of output the agent produced cancelled the gesture and snapped the view flat, and your next movement pushed it out again, so the pane vibrated in time with the output. The stretch now stays where you put it while the rows keep scrolling underneath it.

## 0.1.116 — 2026-08-11

- Agent output is cheaper to show, again. Repairing damaged Unicode used to rebuild every chunk of every terminal one character at a time, even when there was nothing to repair — which is nearly always. It now checks first and rebuilds only when a chunk really was split mid-character, about five times faster on a chunk of agent output.
- The window no longer redraws itself for every word an agent types. A running chat published to the whole app on each chunk, so the sidebar, the session strip and everything around them were rebuilt tens of times a second to show a transcript none of them display. They now hear about the things they actually show: titles, running state, permissions.

## 0.1.115 — 2026-08-11

- Terminals you had open before updating can be typed into again. When a broker from the previous version was still running as 0.1.114 arrived, every restored terminal came back read-only and at the wrong size: the app asked that older broker a question it had no way to answer, then read the silence as a refusal. It now only asks brokers that can answer, and a terminal that comes back owned gets resized to its pane the way it always did.
- Showing agent output costs the machine much less. A CLI agent redrawing a spinner had the broker building every terminal's output twice — one copy went to a reader that threw it away — and handing the other over a few hundred times a second. It now builds it once and sends it a frame at a time.

## 0.1.113 — 2026-08-08

- Every side pane now hides from its own minus button at its top-right — the file tree's old accent toggle and the preview's tab-less close are gone. While a pane is hidden, its show button floats quietly over the open terminal or chat at the top-right corner, and disappears entirely when everything is open.
- Hiding the document column is non-destructive: your tabs and the open file come back exactly as they were, and unsaved edits still get the save prompt first.

## 0.1.112 — 2026-08-07

- Fixed the evening's stuck typing for real: the app had been quietly tearing down and rebuilding its terminal streams every ten seconds whenever an emptied-out old terminal service stayed registered. Typing kept going mute mid-word; now the poll loop treats a deliberately-disconnected empty service as what it is, and old services actually get retired instead of waiting behind a busy one forever.
- Keystrokes that arrive while a terminal's ownership is mid-handoff now show the "connection is recovering" notice instead of vanishing silently.

## 0.1.111 — 2026-08-07

- A terminal that cannot accept input says so — a notice with a reload hint instead of silently eating keystrokes — and input now heals itself within seconds once the blocker releases, announcing when typing is back.
- Signing in shares one authentication context across the keychain, so unlocking once is enough.

## 0.1.110 — 2026-08-07

- Fixed a crash that hit about twenty seconds into a usage refresh.
- Sign-in works again on installed builds: the account store now falls back to the classic keychain when the system store refuses it.

## 0.1.109 — 2026-08-07

- Settings reorganized into grouped categories, with honest update status and live usage inside.
- A serious memory diet: terminal scrollback keeps a sensible default depth, parked surfaces trim themselves, and the app responds to system memory pressure instead of hoarding.
- The serif reading face gets a proper measure — long Markdown reads like a page, not a terminal.

## 0.1.108 — 2026-08-07

- Closed things stay closed: a terminal or project you close can never flicker back after a restart, a quit mid-close, or a reconnect.
- Terminal history is continuous across app updates — scrollback from before a restart pages in seamlessly, and ended terminals still serve their history without respawning.
- Markdown gains a serif reading face. Sign-in moved to the modern protected keychain.

## 0.1.107 — 2026-08-06

- Terminals survive reboots: after a restart they return as dormant panes that respawn in place — shells automatically, agent CLIs with a resume chip so a paid session never restarts itself.
- Live Preview renders Markdown as you edit, and scrollback recovered from disk pages in cleanly.

## 0.1.106 — 2026-08-05

- Builds are Apple Silicon-only now, which cut release times roughly in half; a canary lane installs locally-signed builds in one minute.
- Reading old transcript pages no longer re-renders everything already on screen — scrolling deep history is smooth.

## 0.1.105 — 2026-08-04

- The glass is a quarter less saturated everywhere — the wallpaper's colour arrives calmer while its texture and detail stay exactly as they were. The idle canvas keeps its transparency but reads as glass over the picture rather than the picture at full strength.
- The project now introduces itself as what it is: an open-source IDE GUI for coding agents, native in Swift.

## 0.1.104 — 2026-08-04

- Custom agents can now reach the chat surface — safely. Declare an npm ACP adapter and whose accounts it uses, then enable it: Kaisola installs the exact package with scripts disabled, pins its whole dependency graph, and runs only that pinned code. If anything about the install changes, chat turns off and says why until you approve again.
- A gentle heads-up when a project's CLAUDE.md or AGENTS.md hasn't changed in months — models move faster than instruction files, and stale ones quietly mislead. Once per project per launch, only when you open a chat there.

## 0.1.103 — 2026-08-04

- Summon Kaisola from any app with ⌥⌘K — it comes forward and lands in your last chat's composer. Off by default; turn it on in Settings next to notifications.
- Every chat's usage card now shows a per-turn ledger: what each recent turn added to the context (negative when compaction shrank it) and what it cost.

## 0.1.102 — 2026-08-04

- Switch a chat's model from inside the chat — Opus, Sonnet, Haiku, or any typed model id — and the conversation resumes under it. The account stays put, so nothing restarts from scratch.
- Move a terminal to another project: right-click it in the sidebar or its pane header. It keeps running exactly where it was; only where you see it changes, its tooltip names where it came from, and Return puts it back.
- Decide per event when notifications arrive: permission asks, finished turns, and terminal bells each get Never / When in background / Always.

## 0.1.101 — 2026-08-04

- The bell is now the all-agents center: every session that needs you, across every project, grouped by project with Permissions / Done / Bells filters. Entries whose session is gone dim and clear with one click.
- Terminal themes are yours to add: import a JSON theme (light and dark palettes, 16 ANSI colors) and switch to it; a theme that can't be used says exactly which color failed.
- New languages highlight without an app update: import a grammar naming its file extensions, fence tokens, and coloring rules. Built-in languages can't be overridden.
- Route unfamiliar file extensions to the preview you want — a .geojson to the JSON table, a .svelte to HTML. Text previews only, by design: nothing can be routed into the PDF or image parsers.
- Every hosted terminal and chat exports KAISOLA=1 and KAISOLA_SESSION_ID, so shell profiles and CLIs can detect they're running inside Kaisola and adapt.

## 0.1.100 — 2026-08-03

- Switch a chat's subscription account from inside the chat — even mid-conversation. The transcript, draft, and queued prompts stay; the agent restarts on the account you picked.
- An empty canvas is now genuinely transparent to the wallpaper. Open a terminal or a document and the frosted glass fades back in; close everything and the desktop shows through.
- Crisp and Clear go as far as measurement allows: Clear keeps a fifth of its old veil, Crisp sharpens from 18pt of blur to 5.
- Pin a picture for the glass when the desktop rotates or shuffles, and shuffled aerial desktops paint the right still instead of grey.
- The wallpaper's texture survives the veil, and its colour is measured where it is strongest rather than averaged away.
- Usage shows one card per subscription with one meter style, reset times in their own column, and nothing spare.
- Starting an agent session on a nearly-spent subscription says so and names an account with room.
- Split panes mark every session they show in the sidebar, not only the focused one.
- The iPhone Companion runs on the Simulator (`npm run companion:sim`), so pairing work no longer waits on hardware.

## 0.1.1 — 2026-08-03

Version numbers restart here. Kaisola was at 1.3.3; this release is the same
app, renumbered. Updates are unaffected — they are decided by an internal build
number that keeps counting up, not by the version shown in the app.

## 1.3.3 — 2026-08-03

- Signing in to an account now finds the Claude and Codex commands wherever they are installed, instead of failing with "command not found".

## 1.3.2 — 2026-08-03

- Sign in to Claude and Codex accounts inside Settings, instead of a terminal opening in whatever project was in front.
- Each subscription keeps its own credentials, so several accounts can be signed in at once and Usage shows them side by side.
- Starting a session on a nearly-spent account now says so, and names one with room left.
- Settings opens large, and Accounts and Usage match the rest of Settings instead of using their own look.
- Usage cards are compact enough to compare several at a glance, with one meter style throughout.
- Software updates have their own place in Settings.
- Clicking a file an agent mentions opens it, even when the file sits deeper than the name suggests.
- Reveal in Finder lands in the nearest real folder rather than an empty window.
- Images copied or dragged into a terminal arrive as the picture, not as the file's icon.
- Drop an image anywhere on an agent chat, not only on the composer.
- Agent replies stream smoothly instead of arriving in lurches.
- The glass backdrop follows a window drag at the display's own refresh rate, and rests when the window does.
- Codex reports a weekly limit only, and it is now named and drawn as one.
- The project mark is a folder, and a working agent is announced once rather than twice.
- Long file names in the Files rail fade out instead of colliding with the options button.

## 1.2.0 — 2026-08-02

- Glass tracks the desktop behind the window, so moving Kaisola slides the wallpaper underneath it like real glass.
- Glass reads the same on any wallpaper — blues no longer wash out to white, greens no longer oversaturate.
- Glass follows the wallpaper's texture, not just its colour, and re-reads it whenever the wallpaper changes.
- New Appearance controls for glass clarity, blur, and colour.
- The active project reads bold instead of filled, and the open session is marked in blue.
- The sidebar no longer scrolls the first project out of view at launch.
- Real ChatGPT and Claude marks, and a terminal running Claude Code now shows the Claude one.
- Tinted canvas is actually tinted, and Solid is named for what it does.
- Markdown edits as one continuous document, tables and all — no block-by-block, no jumping to the top.
- Panels run to the window's top edge, reclaiming the empty band above them.
- A rebuilt agent composer: model, provider, and reasoning effort all change mid-conversation from one menu.
- Queued messages can be steered into a turn that is already running.

## 1.1.9 — 2026-08-01

- Text and HTML files edit in a fast offline editor, with the exact bytes on disk still Kaisola's to keep.
- Outlines navigate Markdown, Swift, Python, JavaScript, TypeScript, HTML, CSS, shell, JSON, and YAML.
- PDFs open in a native viewer with selection, scrolling, and zoom.
- Switching files can no longer lose text — the newest edit is saved first.
- Restored drafts, disk conflicts, and save failures explain themselves in notices you can dismiss.
- Rendered Markdown refuses links carrying credentials and paths that leave the project.
- Files and folders move between project directories with collision checks and real Undo.
- Chat and Mesh share one transcript: headings, tables, highlighted code, copy buttons, and clickable project citations.
- Long histories move to a private database, reopen quickly, and page back without losing your place.
- Oversized images are scaled down instead of refused.
- A pop-out that fails to open offers Try Again rather than a blank window.
- Queued Mesh prompts keep their order across restarts, and stay inspectable, removable, and resumable.
- Hide, Stop, Close, and Delete are properly distinct — only Delete discards anything.
- Status reads by shape as well as colour, and Reduce Motion is respected throughout.
- An ended terminal can be recreated in place with its agent, account, title, and draft intact.
- Menus, the command palette, and workspace controls run off one registry, so shortcuts and unavailable states agree everywhere.
- Keyboard shortcuts can be remapped in Settings; a bad override fails safely and leaves the defaults standing.
- Settings unifies app defaults, provider accounts, and per-project overrides, and can check an API key without revealing it.
- First run is a live readiness checklist, and Help opens a real user guide.
- Git stages or unstages everything in one reversible step, and pulls stay to safe fast-forwards.
- Pull-request review shows the full changed-file set and stops if the destination changes under it.
- Agent permission prompts show exactly what was asked for and what a new rule would cover.
- Broker updates roll over to a new generation without disturbing terminals that are still running.

## 1.1.8 — 2026-08-01

- Projects stay in their saved order instead of moving when selected.
- A slimmer sidebar keeps the hierarchy clear and shows only your first name in the footer.
- Document and Files controls now sit together, and Document closes either a file preview or browser card correctly.
- Both right-side dividers keep their resize cursor and drag behavior along their full height, even beside rendered documents.
- Glass is calmer, subtly warmer, and consistently rounded.

## 1.1.7 — 2026-07-31

- Cleaner sidebar: slimmer default width, deeper session indentation, and no row highlight boxes.
- Brand icons drawn plain, without background tiles.
- Panel dividers are draggable along their entire length.
- Glass is fully color-neutral — the only tint comes from your wallpaper.

## 1.1.6 — 2026-07-31

- Glass now reflects your desktop wallpaper only — other windows never show through.
- The active project gets a subtly tinted glass highlight.
- Terminals running Claude or Codex show their brand icon, and the OpenAI logo is now the real one.
- Settings and usage are one click away in the sidebar footer.
- Clearer status colors: blue means working, green means done.

## 1.1.5 — 2026-07-31

- The sidebar matches its intended design: full-width titles, quieter chrome, visible wallpaper tint.
- Smooth, stable cursor around panel dividers.

## 1.1.4 — 2026-07-31

- Sidebar rows are fully readable by VoiceOver and automation.
- Terminals hold less memory for long histories.
- Development builds keep their data separate from the released app.

## 1.1.3 — 2026-07-31

- Terminal bells now mark a session as needing your attention.
- Long terminal histories open much faster.
- Friendlier wording across the app and a working Help menu.

## 1.1.2 — 2026-07-31

- Large files open instantly in read mode, with Find built in.
- Previews no longer re-parse files while you move around.
- A damaged workspace layout now explains itself and keeps a recoverable copy.

## 1.1.1 — 2026-07-31

- The Git panel refreshes live and lets you review a pull request before creating it.
- Terminal polish: your chosen font in transcripts, a Clear command, and a jump-to-latest button.
- Safer clipboard handling for terminal applications.

## 1.1.0 — 2026-07-31

- A redesigned sidebar: your active project on top, other projects below, and live agent status at a glance.
- A broad reliability pass across terminals, chats, previews, Git, and settings.

## 1.0.0 — 2026-07-30T02:41:50-0700 (PDT)

Kaisola 1.0.0 is the first release from the native-only repository. It contains
the Swift macOS app, iPhone Companion, shared Swift protocols, and the sealed
transitional terminal broker; no Electron renderer or React application ships
in this repository.

### Terminal and app experience

- Made Claude Code, Codex, and ordinary shell streaming stable while scrolling:
  output is coalesced on a 16 ms lane, contiguous bytes feed SwiftTerm directly,
  parsed terminal surfaces survive tab switches, and deliberate user scrolling
  remains unpinned until the user returns to live output.
- Raised ordinary terminal history to 20,000 rows with a bounded 100,000-row
  maximum and preserved access to older disk-backed transcript pages.
- Removed redundant semantic-terminal work from plain output. Buffer cursor
  searches now run only for an active OSC 133/633 input region, and semantic
  decorations paint once after final scroll positioning.
- Increased the project sidebar's default/ideal width to 200 points and made
  project headers visually distinct from their nested session rows.
- Added direct, persistent controls to switch projects and sessions between the
  left sidebar and Chrome-like top bars in either direction.
- Moved local browser cards into the same right-hand preview slot as files, so
  the active terminal stays mounted and visible.
- Made terminal file citations resolve relative, absolute, and `file:` paths,
  including line/column targets. A citation outside every open project adopts
  the nearest Git root (or a safe directory fallback), activates it, expands
  its ancestors, and highlights the exact file in the workspace rail.

### Markdown and previews

- Fixed Markdown wrapping in narrow preview panes and added both trackpad pinch
  and Command-mouse-wheel zoom to rendered documents and direct editing.
- Replaced the plain block source box with a styled native TextKit editor that
  preserves exact Markdown bytes while rendering headings, emphasis, links,
  code, and visible list markers during editing.
- Added automatic continuation and clean exit behavior for bullet, task, and
  ordered lists.
- Rebuilt README table separators as real cell boundaries so rules no longer
  cross through values.
- Split the workspace rail from the large preview implementation and preserved
  selected-file highlighting and ancestor expansion.

### Broker/app parity and continuity

- Added a deterministic lowercase SHA-256 content digest to every sealed broker
  generation and carried it through the helper manifest, launch configuration,
  `broker.json`, authenticated hello, status, development, and probe receipts.
- Added an authenticated atomic `broker.shutdownForUpdate` operation. It
  rechecks PID, start time, digest, activity epoch, in-flight work, child tasks,
  and live PTYs inside the broker before allowing an empty generation to stop.
- Automatically replaces a stale empty broker, retries pending upgrades on a
  2.5-second heartbeat, and reports precise pending/current generation details.
  A broker that owns any live terminal is preserved and never presented as
  current merely because every agent is idle.
- Sealed broker package generation is `1.1.0`, implementation version `1`,
  protocol `2`, and security epoch `1`. The immutable release provenance receipt
  records its digest alongside the final app build, source commit, signatures,
  notarization, and artifact hashes.

### Faster development and testing

- Added deterministic changed-file-to-test selection with printed plans,
  focused native selectors, Swift-package routing, Node routing, and a broad
  fallback for shared or unmapped changes.
- Added path-isolated reusable SwiftPM test caches and fixed no-argument behavior
  on the macOS system Bash.
- Added cold/warm build timing receipts. The measured native edit build was
  35.461 seconds cold, then 3.014 and 2.937 seconds warm.
- The integrated changed-file lane completed in 27.97 seconds with 540 passing
  checks, one intentionally skipped UI check, and no failures.

### One-to-two-minute release promotion

- Added a main-commit candidate workflow that builds, tests, Developer ID signs,
  notarizes, staples, Sparkle-signs, and stores one immutable app candidate plus
  a machine-readable provenance receipt.
- Replaced tag-time rebuilding with a serialized promotion workflow that checks
  the tag, exact source commit, version/build, helper digest, Ed25519 signature,
  notarization, and SHA-256 inventory before publishing those exact bytes.
- Made the permanent Sparkle appcast monotonic, verified remote GitHub asset
  digests after upload, and added safe first-release/interrupted-promotion
  recovery. Expensive candidate validation is reported separately from the
  target one-to-two-minute public promotion.
- Tightened notarization credential preflight after the first protected-main
  candidate exposed an invalid assumption: Apple individual API keys are now
  rejected before building, team API-key authentication always requires its
  issuer UUID, and a complete Apple-ID/app-specific-password pair can serve as
  the explicit fallback.
- Made unattended visual, memory, and cadence fixtures ignore AppKit crash-state
  restore prompts without accepting unrelated output, and aligned their broker
  metadata lookup with the private native fixture layout.

### Release validation completed before publication

- Node contracts: 127 passed, 0 failed.
- Shared KaisolaCore contracts: 25 passed, 0 failed.
- Full macOS suite: 856 passed, 8 intentionally skipped, 0 failed.
- Universal arm64/x86_64 app preflight and sealed broker/PTTY continuity probe:
  passed.
- Broker-free 64 MiB/100,000-row terminal resource gate: 434.8 MiB p95 against
  a 512 MiB ceiling.
- Streaming 120 Hz cadence gate: 99.78% callback coverage, 8.49 ms p95,
  19.73 ms maximum interval, and 4.44 ms/s deadline loss while 965 KiB of
  terminal output advanced during the measured interval.
