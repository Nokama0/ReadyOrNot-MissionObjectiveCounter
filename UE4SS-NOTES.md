# UE4SS-NOTES.md

Technical notes on the UE4SS behaviour this mod depends on, and on the
reflected game surface it reads. Written for someone with this mod's source
open, or writing their own UE4SS Lua mod and running into the same things.
Most of what follows is not documented anywhere and was established by
running it.

Everything here was observed against the **UE4SS experimental build** (which
reports itself as `v3.0.1 Beta`; the SHAs actually checked are `c838a8ac` and
`1c1a1497`) and **Ready or Not build `23037110`** unless stated otherwise.
Treat the build stamps as what was actually checked, not as a claim about every
version. The tagged stable v3.0.1 release is a different build with a different
folder layout and a smaller Lua API; see section 7.

**Contents**

1. [Lua dialect](#1-lua-dialect)
2. [Calling UFunctions with out-parameters](#2-calling-ufunctions-with-out-parameters)
3. [Struct elements of a returned TArray](#3-struct-elements-of-a-returned-tarray)
4. [The game thread requirement](#4-the-game-thread-requirement)
5. [Widget attach timing](#5-widget-attach-timing)
6. [UMG details worth knowing](#6-umg-details-worth-knowing)
7. [Object lookup and hot reload](#7-object-lookup-and-hot-reload)
8. [Verified reflected signatures](#8-verified-reflected-signatures)
9. [Enum values](#9-enum-values)
10. [Design rules this mod's code depends on](#10-design-rules-this-mods-code-depends-on)

---

## 1. Lua dialect

**UE4SS embeds Lua 5.4.7, not LuaJIT.** `UE4SS.dll` carries the string
`$LuaVersion: Lua 5.4.7 Copyright (C) 1994-2024 Lua.org, PUC-Rio` and contains
no LuaJIT strings at all.

The practical consequence is that **there is no global `unpack`**. Lua 5.4 has
only `table.unpack`. A bare `unpack(...)` raises:

```
attempt to call a nil value (global 'unpack')
```

This mod was originally written against the assumption that the runtime was
LuaJIT, which cost a debugging cycle: the failure is silent until the line
actually runs, and if you test under a 5.1-dialect interpreter your test suite
will happily pass code that raises in game. Two things follow:

- Run headless tests under a real Lua 5.4 interpreter, not LuaJIT.
- If you want to be safe under both dialects, resolve it once at the top of the
  file rather than at each call site:

  ```lua
  local unpackList = table.unpack or unpack
  ```

Other 5.4 differences that catch people out: integer division is `//`, `goto`
exists, and the length operator on a table with `nil` holes is undefined
(relevant below, where return-value counts matter).

---

## 2. Calling UFunctions with out-parameters

This is the single most awkward part of the binding, and the error messages are
the fastest route to getting it right.

**The convention: one fresh Lua table per out-parameter, passed positionally.**

```lua
-- GetEvidenceCount(int32& EvidenceCollected, int32& TotalEvidence)
local a, b = {}, {}
mgr:GetEvidenceCount(a, b)
```

**UE4SS fills the tables keyed by each parameter's declared name.** A live run
showed every out-param landing in the *first* table, keyed by its real
parameter name, so after the call above the value is at `a.EvidenceCollected`
and `a.TotalEvidence`, not at `a[1]` and `b[1]`. Reading each parameter by its
own declared name, searching the tables you passed in order, is correct whether
the binding fills one table with everything or fills each table with only its
own key.

### The two error strings

Passing numbers (or anything that is not a table) as placeholders raises,
verbatim:

```
Tried storing reference to a Lua table for an 'Out' parameter when calling a UFunction but no table was on the stack.
```

That message is UE4SS itself stating the rule: it stores a *reference* to a Lua
table and writes the result into it, so the argument has to be a table.

Passing no arguments at all raises, verbatim:

```
UFunction expected N parameters, received 0
```

where `N` is the declared parameter count, so `GetSuspectCount` reports
`expected 4 parameters, received 0`. If you are searching a log or a search
engine for either of these, the strings above are what to search for.

### Practical rules

- **Fresh tables per call.** Do not hoist the tables to file scope and reuse
  them. UE4SS keeps a reference to what you passed, and a stale value left in a
  reused table is indistinguishable from a value the engine just wrote, so a
  read that silently fails renders as the previous poll's number.
- **Do not trust `#` on the returned values.** Capture the count with
  `select('#', ...)` before packing into a table. Trailing `nil` returns make
  the packed table's length undefined.
- **Verify what actually came back rather than assuming the shape.** A
  reflected call that runs cleanly and reads nothing at all is a failure with no
  symptom. This mod resolves each field independently and records which
  convention won, so a binding that mixes conventions per field still comes out
  whole and the log names what happened.
- `GetScoreCountFromGroup` mixes ordinary input parameters with out-parameters.
  This mod deliberately avoids it and uses the array-taking variants instead,
  which return a plain `int32` and need no out-param handling at all.

---

## 3. Struct elements of a returned TArray

**Elements of a returned `TArray` of structs come back as userdata wrappers
whose fields all read as `nil` until you call `:get()` on the element.**

For `GetScoreGroups() -> TArray<FScoreGroup>`, indexing the array gives a
userdata on which `GroupName`, `ObjectiveLevel` and `Scores` all read as `nil`.
That same userdata carries a callable `get()` which yields a second
userdata, and it is *that* value whose fields are readable.

```lua
local groups = mgr:GetScoreGroups()
local element = groups[i]:get()   -- fields are nil without this
local name = element.GroupName:ToString()
```

Two cautions:

- **Confirm the inner value is actually readable** rather than assuming `get()`
  succeeded. It can return another opaque wrapper. This mod tests one known
  field on the result and falls back to the raw element when that read comes
  back `nil` or raises, so a build where direct field access already works, or
  where `get()` is absent, is left alone.
- **Gate on `get()` being callable, not on `type(x) == "userdata"`.** A build
  exposing the same wrapper pattern through an ordinary table should take the
  same path.

Note also that the *elements* need this while the array itself indexes and
takes `#` normally, and that plain values (an `int32` returned by an ordinary
function, for instance) need nothing of the sort.

---

## 4. The game thread requirement

**`ExecuteWithDelay` does not marshal onto the game thread.** It schedules its
callback back onto a UE4SS thread. `ExecuteInGameThread` and
`ExecuteInGameThreadWithDelay` do marshal.

The evidence is that they exist as separate functions rather than as a flag on
`ExecuteWithDelay`. Confirmed present in UE4SS v3.0.1 Beta's `UE4SS.dll`
alongside `ExecuteInGameThreadAfterFrames`,
`RetriggerableExecuteInGameThreadWithDelay` and `GetGameThreadId`.

### Why it matters

Calling UObject methods, or mutating UMG, from a non-game thread crashes the
game intermittently. An early version of this mod polled with
`ExecuteWithDelay`, so twice a second it called reflected UFunctions, walked an
actor array, unwrapped struct elements and mutated UMG widgets from a
background thread while the game was ticking, replicating and collecting those
same objects.

That crashed twice, with the same faulting stack both times: a CRT-spawned
thread inside `RC::LuaMadeSimple::process_lua_function`, calling through a
vtable slot that is no longer readable, a few seconds after the poll loop
started. Both crashes were on a **co-op client**, and the host running the same
mod did not crash. That fits: a client sees far more actor churn, because
replication creates and destroys actors as relevancy changes, so the window in
which a read lands on an object mid-destruction is much wider there. UMG is
game-thread-only regardless of any of that.

**Intermittent is the dangerous part.** Off-thread reads work most of the time,
which is exactly why the contract has to be checked rather than believed.

### The tiering this mod uses

The functions are probed, not assumed, because a redistributed mod meets more
than one UE4SS build:

| Tier | Condition | Behaviour |
|---|---|---|
| 1, `delayed` | `ExecuteInGameThreadWithDelay` exists | Delay and marshal in one call. Preferred. |
| 2, `composed` | `ExecuteWithDelay` and `ExecuteInGameThread` both exist | Take the delay on the UE4SS thread, then hand the body to the marshaller. Needs only primitives that predate the delayed variant. |
| 3, `none` | neither | **No repeating poll at all.** |

Tier 2 is safe because the outer closure deliberately touches nothing in
Unreal. It reads nothing, writes nothing and calls into no UObject; it only
hands the body to the marshaller, so there is nothing in it for the game thread
to protect.

**Tier 3 refuses to poll rather than falling back to raw `ExecuteWithDelay`.**
That fallback would be exactly the configuration that crashed a co-op client,
reached automatically, with a log line most players never open as the only
thing between them and it. A panel that does not update is a disappointment; a
panel that takes the game down is a defect shipped knowingly. Tier 3 says so
once on load and stops there.

### Related points

- **`IsInGameThread` is not on every build.** When it is absent, treat "cannot
  say" as "no" and marshal anyway. Guessing the other way reintroduces the
  assumption the whole design exists to remove.
- **`RegisterKeyBind` and `RegisterKeyBindAsync` exist as separate functions**,
  which says the two differ in threading without saying which way round. Rather
  than settle it, make a keybind callback flip a Lua boolean and marshal, so it
  touches nothing in Unreal and the question stops mattering.
- **`NotifyOnNewObject` most likely already fires on the game thread**, since
  UObject construction happens there. "Most likely" is not a basis for building
  a UMG subtree, so marshal anyway. Where the thread is provably the game
  thread already, running inline costs nothing.
- **Mod load runs on a UE4SS thread**, not the game thread. Anything at file
  scope that walks live UObjects or calls into them needs marshalling too.
- **A Lua error unwinding back into UE4SS from a callback is its own hazard.**
  Wrap anything that can raise inside a scheduler callback or a keybind
  handler.

---

## 5. Widget attach timing

**A `UUserWidget`'s named child bindings are not populated when
`NotifyOnNewObject` fires.** The notification arrives when the UObject is
constructed; named children such as `CanvasPanel_Root` are bound later, during
`Initialize`/`RebuildWidget`.

Reading the property at construction time gets `nil`. Taking that single `nil`
as proof the widget is unsuitable means logging one line, returning, and never
looking again, which leaves nothing attached for the whole mission.

**Attachment must therefore retry.** This mod re-checks every 250 ms for up to
15 seconds, which is cheap enough to cost nothing and patient enough to outlast
a slow level load. It stops early on any of the three things that make further
attempts pointless: the attach succeeded, the widget stopped being valid
because the level moved on, or a newer attach superseded it.

Log nothing per attempt. Sixty lines saying the same thing bury the one line
that says which attempt worked.

---

## 6. UMG details worth knowing

**`USizeBox` gates `WidthOverride` behind a bitfield.**
`SynchronizeProperties` builds an `FOptionalSize` from
`bOverride_WidthOverride`, so assigning the raw float alone leaves the override
unset and the column silently falls back to auto-size. `SetWidthOverride` sets
the bitfield and synchronises, so it is the real call. `UScaleBox` has no
override bitfield behind `Stretch`, so there the plain field assignment is
correct.

**`UBorder` ships with an opaque brush tinted white.** An unstyled `Border`
renders as a solid rectangle over the HUD rather than a translucent backing.

**`SetColorAndOpacity` on a `UTextBlock` takes an `FSlateColor`, not a bare
`FLinearColor`.** `FSlateColor` is `{ SpecifiedColor = FLinearColor,
ColorUseRule = ESlateColorStylingMode }`, and `ColorUseRule` must be
`UseColor_Specified` (0) for a specified colour to apply at all.

**Which Lua table shape the binding accepts for a nested struct is not
knowable from a header dump.** Probe more than one shape, the same way you
probe out-param conventions: try each in order inside a `pcall`, cache
whichever works, and only give up once every known shape has failed. This mod
tries an `FLinearColor` constructor and a bare `{ R = , G = , B = , A = }`
field table.

**Slate units, not pixels.** Padding and `SizeBox` widths are Slate units,
which the game's own DPI curve scales, because your widgets live inside its
tree. Position by slot alignment and let content auto-size, and the layout is
resolution independent without a single pixel coordinate.

**`GetChildAt` is zero-based** while Lua arrays are one-based.

**Removing children while indexing forward skips entries**, because each
removal shifts the remaining children down a slot. Collect the matches first,
remove afterwards.

---

## 7. Object lookup and hot reload

**Never use `ForEachUObject`.** It visits every live UObject in the process,
and doing that repeatedly has been seen to destabilise the game. `FindAllOf`
and `FindFirstOf` do not walk the whole object array.

**`FindFirstOf` can hand back the class default object**, and then there is no
second candidate to try. Prefer `FindAllOf` and pick the first live instance,
keeping `FindFirstOf` as a fallback for a binding that does not surface
`FindAllOf`.

**Class default objects carry the properties but none of the live state**, and
have no widget tree. Their full name contains `Default__`, which is the test
this mod uses.

**`NotifyOnNewObject` takes the full object path; `FindAllOf` and `FindFirstOf`
take the generated class short name.** For this mod's HUD those are
`/Game/Blueprints/Widgets/HUD/W_HumanCharacter_HUD_V2.W_HumanCharacter_HUD_V2_C`
and `W_HumanCharacter_HUD_V2_C` respectively.

### Hot reload

UE4SS hot reload re-runs your `main.lua` in the same process with a **fresh Lua
state**, and does not restart the game or touch the widget tree. Three
consequences:

- **`NotifyOnNewObject` fires on construction only**, so on its own it cannot
  see an object that already exists. After a hot reload mid-mission, that is
  every object you care about. Look for an already-constructed instance at load
  as well, or you see nothing until the next level load.
- **Widgets from the previous script instance are still parented and no longer
  tracked.** Without cleanup, every reload stacks another copy on screen. Give
  the widget you attach to the HUD a distinctive prefix so the old ones are
  identifiable, and match on that prefix so an unrelated child can never be
  removed. Only that outermost widget needs a name: cleanup walks the overlay's
  direct children, and everything nested below is removed with its parent.
  Naming the whole subtree costs an interned string per widget for nothing (see
  below).
- **Widget names must be unique within their outer, and your counters restart
  at zero while the old widgets are still alive.** Asking
  `StaticConstructObject` for a name that is still taken makes the engine
  **replace the existing object in place**, which is not something to do to a
  widget you no longer track. Seed the counter per script instance, for example
  by mixing a fresh table's address (which differs between Lua states) with the
  process clock (which differs between reloads).
- **The name argument is optional.** `StaticConstructObject(class, outer)` is a
  valid call and lets the engine name the object. Prefer it for every widget
  that does not have to be found again by name.

**Every string handed to `FName` is interned by UE4SS, and builds before
2026-06-14 keyed that pool on a `string_view` into the caller's buffer.** Once
Lua collected the string, the key dangled and later lookups compared against
freed memory, which surfaces as an `EXCEPTION_ACCESS_VIOLATION` with no Lua
error, because `pcall` cannot catch a native fault. A mod that builds a widget
tree in one tick is the worst case: this panel constructed 108 widgets for a
typical mission, each with a freshly concatenated name, which is 108 chances to
hit it on the first keypress. Fixed upstream in
[#1271](https://github.com/UE4SS-RE/RE-UE4SS/pull/1271).

Two defences, both cheap and worth applying regardless of build. Name only what
must be findable, per the point above. Then hold a permanent Lua reference to
each string you do pass to `FName`, so the buffer the pool points at cannot be
collected out from under it. Neither makes a process immune, since the pool is
shared and any mod can poison it, but together they remove your own
contribution.
- **Keybinds survive the reload.** An unconditional `RegisterKeyBind` leaves two
  handlers on one key: both fire on one press, the panel toggles twice, and the
  key reads as doing nothing at all. Guard with `IsKeyBindRegistered`, probing
  for it first since it is not on every build.

**`RegisterKeyBind(key, modifiers, callback)` with an empty modifier table is
not known to work.** The two-argument form is the one known to work when no
modifier is wanted, so pass a modifier list only when one is actually present.

**Whether `RegisterKeyBind` reports failure by raising or by silently doing
nothing is not established.** Wrap it for the raising case and log the outcome
unconditionally for the silent one, so "registration failed" and "registration
succeeded but the key never fires" are two different lines in the log rather
than one identical message either way.

### Logging

Log through UE4SS only, so output lands in `UE4SS.log` with no path baked in. A
mod that writes to a hardcoded path works on the machine it was written on and
nowhere else. Assume the UE4SS consoles are disabled and `UE4SS.log` is the
only diagnostic surface there is.

---

## 8. Verified reflected signatures

Read from a UE4SS `CXXHeaderGenerator` dump on Ready or Not build `23037110`,
and confirmed by calling them in game.

```
AScoringManager : AInfo
    GetSuspectCount             (int32& OutReported, int32& OutArrested,
                                 int32& OutKilled, int32& OutTotal)
    GetCivilianCount            (int32& OutReported, int32& OutInjured,
                                 int32& OutKilled, int32& OutArrested,
                                 int32& OutTotal)
    GetEvidenceCount            (int32& EvidenceCollected, int32& TotalEvidence)
    GetReportCount              (int32& ReportedCount, int32& TotalReports)
    GetObjectiveCompletionStatus(int32& ObjectivesComplete,
                                 int32& ObjectivesFailed,
                                 int32& TotalObjectives)
    GetScoreGroups              () -> TArray<FScoreGroup>
    GetGivenScoreCountFromArray (const TArray<FScoreData>&, bool) -> int32
    GetTotalScoreCountFromArray (const TArray<FScoreData>&, bool) -> int32
    GetScoreCountFromGroup      (FName InGroupName, bool bRequiredOnly, ...)

AReadyOrNotGameState : AGameStateBase
    TArray<AObjective*> MissionObjectives

FScoreGroup
    FName             GroupName
    <enum>            ObjectiveLevel
    TArray<FScoreData> Scores
    bool              bRequiredToClearMission

AObjective
    FName  ObjectiveName          (call :ToString() on it)
    <enum> ObjectiveStatus
    bool   bHiddenObjective
```

Object paths used for lookup:

```
FindFirstOf("ScoringManager")
FindFirstOf("ReadyOrNotGameState")
StaticFindObject("/Script/ReadyOrNot.ScoringManager:GetSuspectCount")
```

`GetScoreCountFromGroup` is listed for completeness only. It mixes input
parameters with out-parameters, and this mod uses the two array-taking counters
instead, which take the group's own `Scores` array plus a bool and return a
plain `int32`.

Note that the same class exposes functions that mutate scoring state. This mod
calls none of them. Everything above is a read.

---

## 9. Enum values

Game enums, as this mod relies on them, confirmed by the panel's readings
matching what the game itself displays:

| Enum | Values |
|---|---|
| `FScoreGroup.ObjectiveLevel` | `0` primary, `1` secondary, `2` tertiary |
| `AObjective.ObjectiveStatus` | `0` active, `1` done, `2` failed |

Engine enums, as declared in Unreal's own headers. They are written as plain
integers in the Lua because a bare integer is what the binding hands back to
the engine:

| Enum | Values |
|---|---|
| `ESlateVisibility` | `1` Collapsed, `3` HitTestInvisible |
| `EHorizontalAlignment` | `0` Fill, `1` Left, `2` Center, `3` Right |
| `EVerticalAlignment` | `0` Fill, `1` Top, `2` Center, `3` Bottom |
| `EStretch` | `7` UserSpecified |
| `ESlateColorStylingMode` | `0` UseColor_Specified |

An enum that arrives as anything other than a Lua number will silently miss
every lookup table keyed by it, so coerce with `tonumber` at the boundary and
say so when the coercion fails.

---

## 10. Design rules this mod's code depends on

Three rules the code is built around. Breaking any of them changes behaviour
that people rely on, so they are worth knowing before editing.

**A failed read is `nil` and renders as a dash, never zero.** `0` is a real,
meaningful count in this game: zero civilians killed is a good run. A read that
failed and a genuine zero must never look the same on screen. Values are
coerced with `tonumber` at the boundary from the engine, which turns anything
unusable into `nil`, and every consumer downstream renders `nil` as `-`.

**A section whose source is absent is omitted, not dashed.** With no live
`ScoringManager` the counters and score groups sections do not appear at all,
and the log names the missing source. A dash marks a *single* value that could
not be read; a missing section marks a source that is not there. Those are
different conditions with different causes, and collapsing them into one
appearance destroys the distinction a user needs in order to report a problem
usefully. This is also why a section reports again when its source turns up on
a later poll, which on a joining client is normal rather than unusual: the
`GameState` replicates before the `ScoringManager`.

**Nothing may log per poll.** The poll loop runs twice a second. A single
unlatched line in it fills `UE4SS.log` with one fault repeated thousands of
times and buries whatever else was in there, which is worst precisely when the
log is the only thing available to diagnose from. Every unconditional line is
latched once per mission (or deduplicated on its formatted text), and the
latches are cleared on each new attach so a second mission reports afresh.
Anything added inside the poll path has to carry a latch of its own.

A fourth, smaller rule: a category whose total is zero is not present in this
mission and its row is omitted, so a mission with no evidence in it does not
show a meaningless `0 / 0`.
