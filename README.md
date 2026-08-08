# MissionObjectiveCounter

**Version 1.0**

A toggleable in-mission panel for Ready or Not that shows live suspect,
civilian, evidence, report, score group and objective counts while you play.
Press **F7** in a mission to show it, press F7 again to hide it.

- **Type:** UE4SS Lua mod. No `.pak`, nothing in `Content/Paks/`, no game file
  modified.
- **Read-only.** It reads scoring and objective state through UE4SS and draws
  a panel with it. It does not alter scoring, does not write save data, and
  does not touch session or matchmaking state. It changes nothing about what
  the game records; it only displays what is already there.
- **Single player and co-op**, as host or as a joining client.

## Requirements

**UE4SS** is an injectable Lua scripting system for UE4/UE5 games. It is not
included in this zip; install it yourself from the source project:

- Releases: <https://github.com/UE4SS-RE/RE-UE4SS/releases>

This mod was built and tested against **UE4SS v3.0.1 Beta**. If your install
uses a different build and the mod does not load, check `UE4SS.log` first
(see "Verifying it loaded" below).

The reflected signatures this mod reads (`GetSuspectCount`, `GetScoreGroups`
and the rest) were read from and confirmed against **Ready or Not build
`23037110`**. That is a recorded baseline, not an enforced requirement: the
mod does not check the game's version and will still try to load on a
different build. If the game updates and the counters stop matching what you
see on screen, or `UE4SS.log` starts logging reads it could not complete,
that mismatch is the first thing to suspect, and it helps to say which game
build you are on when reporting it.

## Install

1. Find your game folder. In Steam: right-click **Ready or Not** then
   **Manage**, then **Browse local files**.

2. Go to `ReadyOrNot\Binaries\Win64\`. UE4SS should already be installed
   there, with a `ue4ss\Mods\` folder present. If it is not, install UE4SS
   first.

3. The zip contains a single `MissionObjectiveCounter` folder. Drag that
   folder straight into `ue4ss\Mods\`. Do not rename it: the name has to
   match the line you add in the next step exactly, or the mod will not
   load. You should end up with:

   ```
   ue4ss\Mods\MissionObjectiveCounter\
       README.md
       UE4SS-NOTES.md
       LICENSE
       Scripts\
           main.lua
           layout.lua
           source.lua
           panel.lua
   ```

   `UE4SS-NOTES.md` is not needed to run the mod and can be left where it is.
   It documents the UE4SS behaviour this mod depends on, along with the
   reflected game functions and enum values it reads, for anyone reading the
   source or writing their own UE4SS Lua mod. Code comments point at it by
   name.

4. Open `ue4ss\Mods\mods.txt` in a text editor and add this line, placed
   **above** the `Keybinds` line near the bottom of the file:

   ```
   MissionObjectiveCounter : 1
   ```

5. Restart the game if it was already running. `mods.txt` is only read at
   startup, so an already-running game will not pick up the new line.

## Using it

Press **F7** in a mission to show the panel, and press it again to hide it.
F7 is only the default; see `CONFIG.TOGGLE_KEY` under "Configuration" to
change it.

F7 was chosen to stay clear of F8 and of UE4SS's own built-in dumper keybinds
on Ctrl+J, Ctrl+H and Ctrl+Numpad. If F7 does nothing at all, even outside a
mission, something else may already hold it: check `UE4SS.log` for the line
described under "Verifying it loaded", which says explicitly whether the key
bound or was already taken.

The panel is only drawn while you are in a mission. It does not appear in
menus or the ready room, and it never intercepts a mouse click.

## What the panel shows

While visible, the panel lists:

- **Counters:** suspects (reported, arrested, killed, and a combined total
  against the mission total), civilians (reported, injured, killed, arrested,
  and total; civilians carry an injured count that suspects do not), evidence
  collected against total, and reports collected against total.
- **Score groups:** the game's own graded objective taxonomy (primary,
  secondary, tertiary), each with a given/total score line.
- **Objectives:** each mission objective's live status (active, done,
  failed), including hidden objectives unless you turn that off in `CONFIG`.

A missing value is shown as `-`, never as `0`, so a value the mod could not
read is never mistaken for a real empty count.

A whole row is hidden when its total is zero, so a mission with nothing in a
category does not show a meaningless `0 / 0`.

A section whose data source cannot be found is **left out of the panel
entirely** rather than shown full of placeholders, and `UE4SS.log` names the
source that was missing. With no live `ScoringManager`, for example, the
counters and score groups sections do not appear at all. If that source turns
up on a later poll, which on a co-op client is normal rather than unusual,
the log says so too, on its own line.

**A dash means something different from an omitted section.** A whole section
is omitted only when every value in it is unavailable. A `-` marks a single
value that could not be read, whatever the reason, and that "whatever the
reason" is why the OBJECTIVES header can read `- / -` above a perfectly
readable list of objectives: on a client with a `GameState` but no
`ScoringManager`, the header's complete, failed and total counts have no
source to read from and dash individually, while the list itself reads from
`GameState` and renders in full. The same dash also covers a value whose
source was present but whose read still failed. Both cases are recoverable
and both are something `UE4SS.log` will explain; the log is what tells them
apart, by naming which source was missing.

**The EVIDENCE row is normally absent at mission start, and that is correct.**
Evidence in Ready or Not is largely weapons dropped by suspects, so a mission
begins with none in existence and the total is genuinely zero. The row appears
on its own once the first evidence exists, and then counts up. This is the
zero-total rule working, not a fault, so please do not report it as one.

## Limitations

**Spectating is not supported.** The spectator view uses a different HUD,
`W_SpectatorCharacter_HUD`, and is out of scope for this version.

**On a joining client the panel can start incomplete and fill in.** A client
usually receives the `GameState` a moment before the `ScoringManager`, so
seeing the missing-`ScoringManager` line in `UE4SS.log` followed shortly by
its matching arrival line is the normal, healthy sequence, not a fault.

**The mod does its game reads and widget updates on the game thread.**
Everything that crosses into the game, the twice-a-second counter reads and
every change to the panel's own widgets, is scheduled onto Unreal's game
thread rather than run from the background thread UE4SS uses for ordinary mod
timers. Doing that work off the game thread crashed a co-op client during
development, which is why it is done this way. The mod checks at load for the
two routes onto the game thread it knows about and takes the first one your
UE4SS build offers: `ExecuteInGameThreadWithDelay`, or `ExecuteWithDelay`
paired with `ExecuteInGameThread`. `UE4SS.log` gets one line on load naming
which. On a build offering neither, that line says so and **the panel's
repeating updates are switched off**, because the only other option is the
off-thread behaviour and shipping that knowingly is worse than shipping a
panel that does not update; the panel may still attach and show a single
reading. Updating UE4SS is the fix for that. Once you are in a mission the
log also states, once per mission for each of the three entry points, whether
it is actually running on the game thread.

## What is confirmed about this build

Confirmed in game on this version:

- The panel attaches and reads correctly in single player, and in co-op for
  both the host and a joining client.
- The counters, the score groups and the objective list all populate, with
  correct values.
- The mod does its game reads and widget updates on the game thread, and says
  so in `UE4SS.log` (see "Which thread the mod is running on" below).

What that does not cover: this build has had limited play time, across a
limited set of missions, on a limited set of UE4SS builds. Everything else in
this README describes how the mod is designed to behave rather than something
measured over many hours. If you hit a problem, `UE4SS.log` is the thing to
send with the report, posted to this mod's Nexus page in the Posts or Bugs
tab (or wherever else you got it); the sections below say which lines matter.

## Configuration

Open `Scripts\main.lua` and edit the `CONFIG` table near the top of the
file. Each field:

| Field | Default | What it does |
|---|---|---|
| `TOGGLE_KEY` | `Key.F7` | The key that shows and hides the panel. |
| `MODIFIER_KEYS` | `{}` (none) | Optional modifier keys (for example `Ctrl`) to combine with `TOGGLE_KEY`. Empty means the hotkey needs no modifier. |
| `START_VISIBLE` | `false` | Whether the panel is already visible the moment a mission's HUD loads, instead of waiting for the first press of the hotkey. |
| `SCALE` | `1.0` | Overall panel scale. **If the panel reads small on a high-resolution display, raise this.** For example `1.5` or `2.0`. |
| `ANCHOR` | `"TopRight"` | Which HUD corner the panel attaches to. One of `TopLeft`, `TopRight`, `BottomLeft`, `BottomRight`. |
| `MARGIN` | `24` | Spacing between the panel and the chosen corner. |
| `POLL_MS` | `500` | How often, in milliseconds, the panel re-reads mission stats while it is visible. Lower is more up to date but does slightly more work. |
| `SHOW_COUNTERS` | `true` | Show or hide the suspects / civilians / evidence / reports section. |
| `SHOW_SCOREGROUPS` | `true` | Show or hide the score groups section. |
| `SHOW_OBJECTIVES` | `true` | Show or hide the objectives section. |
| `SHOW_HIDDEN` | `true` | When objectives are shown, whether hidden objectives are included in the list. |
| `VERBOSE` | `false` | Extra diagnostic logging to `UE4SS.log`. Off by default so a normal run stays quiet; turn it on only while troubleshooting. |
| `DIAGNOSTICS` | `false` | Extra one-time diagnostics in `UE4SS.log`, useful when something is not working. Off by default; see "Diagnostic lines" below. |

Changing `main.lua` takes effect on the next mod load. Check whether your
UE4SS install has hot reload enabled (`EnableHotReloadSystem` in
`ue4ss\UE4SS-settings.ini`); if it is off, a game restart is needed to pick
up an edit.

## Hot reload

This mod supports UE4SS hot reload. With `EnableHotReloadSystem` on you can
reload it with `Ctrl+R`, and with `EnableAutoReloadingLuaMods` on it reloads
by itself whenever a file in `Scripts\` changes, both without restarting the
game.

Reloading in the middle of a mission works: the mod looks for a HUD that is
already on screen and re-attaches its panel to it straight away, rather than
waiting for the next level to load. It also removes the panel its previous
instance left behind, so reloading repeatedly does not stack panels on top of
each other, and it leaves the hotkey alone if it is already bound, so one
press stays one toggle. The panel starts hidden after a reload, the same as
on a fresh load, unless `START_VISIBLE` is set.

## Uninstall

Delete `ue4ss\Mods\MissionObjectiveCounter\`, or set its line in `mods.txt`
to `0`. Steam's **Properties then Installed Files then Verify integrity of
game files** restores a clean install if anything else is ever in doubt.

## Verifying it loaded

Open `ue4ss\UE4SS.log` and look for a line naming the mod near the top of the
log, followed by lines prefixed `[MissionObjectiveCounter]` once you are in
a mission and have pressed the hotkey. The mod logs its own version on load,
so that line also tells you which build is actually installed. If the hotkey
does nothing, the log will still show whether `RegisterKeyBind` reported
success or failure, which tells you whether the mod loaded at all versus
loaded but did not bind.

If the log shows the mod loaded and the key bound but no panel ever appears,
which lines are **absent** narrows it down on its own:

- **Neither `panel attached to HUD overlay` nor `gave up attaching`.**
  Nothing ever tried to attach, which means the HUD widget class this mod
  watches for was never constructed on that machine. That is itself a
  diagnosis rather than a dead end. It is the expected outcome in the
  spectator view, which uses a different HUD (see "Limitations" above). In
  co-op as a client it is not expected, and it says that client is running
  a different HUD widget. Pressing the hotkey in this state also logs
  `no panel is attached yet`, which confirms the mod is alive and the key
  is firing, so the two together separate this from a mod that never
  loaded.
- **`gave up attaching` is present.** A HUD was found, but its widget tree
  never offered anywhere to attach to. That line names the HUD and the
  reason.

The HUD's widget tree is built a moment after the HUD object itself exists,
so the mod re-checks it every 250 ms for up to 15 seconds before concluding
there is nothing to attach to. Nothing is logged while it waits. If it does
run out of attempts you get a single `gave up attaching` line naming the HUD
and the reason, and if it succeeds on a later attempt you get a single line
saying which attempt worked.

### Which thread the mod is running on

Search `UE4SS.log` for the literal text `game thread`. These lines are always
written, whatever `VERBOSE` and `DIAGNOSTICS` are set to, and they are the
ones that matter if the game ever crashes with this mod installed:

- **One line on load**, naming the route this UE4SS build gives the mod onto
  the game thread, or saying it offers none and the panel's repeating updates
  are therefore switched off.
- **Three lines per mission**, one for each entry point that crosses into the
  game: `the attach path`, `the hotkey path` and `the poll loop`. Each says
  once, and only once per mission, whether that entry point is running on the
  game thread.

A line reading `is NOT running on the game thread` is the condition that
crashed a co-op client during development, and is worth reporting. On a UE4SS
build without `IsInGameThread` these lines say the question cannot be answered
instead, which is not itself a fault.

### When the counters will not read

If `UE4SS.log` never shows an `out-param call shape resolved:` line anywhere
in the mission, the mod found no working way to read a scoring function's
out-parameters on your UE4SS build. That line is logged only once a shape
actually resolves, so on this failure mode it is absent rather than present
with a value, and an absent line is easy to miss if you are scanning the log
for a match rather than for a gap: its absence is itself the signal. The
second, unconditional signal is a `[diag] could not read <fn>: ...` line, one
per affected function, logged regardless of the `DIAGNOSTICS` setting despite
its `[diag]` prefix. Together these are the single most likely failure mode,
and the `could not read` line names the specific function that could not be
read.

### Diagnostic lines

If something is not working and the above does not explain why, set
`CONFIG.DIAGNOSTICS = true` in `main.lua`, reproduce the problem, and search
`UE4SS.log` for the literal text `[diag]`. With `DIAGNOSTICS = false` (the
default) none of these lines are ever emitted. A genuine, ongoing read
failure, such as a function that could not be read by any known call shape,
is logged unconditionally either way, so you do not need `DIAGNOSTICS` on
just to see that. The same goes for the thread lines described above: they
carry no `[diag]` prefix and are written on every run, so searching for
`[diag]` will not turn them up. Search for `game thread` instead. Each
`[diag]` line fires at most once per mission:

- The running Lua dialect: `_VERSION`, and whether `table.unpack` and the
  global `unpack` each exist. UE4SS embeds Lua 5.4.7, not LuaJIT.
- The resolved scoring manager's full name and class name, to confirm the
  mod is calling on the object it believes it is.
- Whether `GetSuspectCount` is reachable by indexing the object for it, and
  separately whether `StaticFindObject` can resolve it by path.
- Once each out-param function resolves, which UE4SS calling convention
  actually worked, for example `out-param table for GetSuspectCount
  resolved via by-name: OutArrested=0, OutKilled=5, OutReported=0,
  OutTotal=18`.
- Which route the score group reader actually used and what it found, for
  example `score groups read via :get() route, 5 groups, first is
  MissionObjectives`.

## Licence

MIT. The full text is in the `LICENSE` file next to this README.

## Credits

This mod was written with AI assistance. A large language model did a
substantial part of the drafting and review of the Lua and of this README;
the design, the in-game testing and the decisions about what ships were mine.
