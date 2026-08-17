# Kiroshi Smart Targeting Protocol

A Cyberpunk 2077 2.31 mod that gives smart weapons a target list you control. Vanilla smart guns
decide for themselves: they sweep the cone, take the nearest torso, and will happily spend a
magazine on a passing civilian or a Trauma Team medic standing behind the ganger you came for.
KSTP adds a piece of ripperdoc cyberware that puts a policy layer in front of the smart link. Tick
the component classes you will allow and pick a targeting protocol, and the gun spends its lock time
only on those components, and only on the factions and threat classes cleared for engagement. Every
target the weapon is tracking carries an IFF label, so the verdict is readable before the trigger is
pulled.

Script only. No `.archive`, no C++ plugin, no `@replaceMethod`.

## Features

- **Six targeting protocols.** `AUTO`, `PRECISION`, `CRIPPLE`, `ANTI-MACHINE`, `ORGANIC` and
  `SURGICAL`. Each carries a lock policy and an engagement attitude, which take effect wherever the
  matching setting is left on `INHERIT`; which component classes the gun may lock is decided by the
  seven class toggles, and selecting a protocol does not rewrite them (ADR 0009). Cycle with a
  hotkey or select in the settings menu, where the box follows the hotkey and the hotkey follows the
  box (ADR 0010). The active protocol is saved with the game.
- **Two lock policies.** `STRICT` drives a denied class's tracking stat to zero, so the weapon
  never acquires it. `PREFERRED` leaves the class acquirable and inflates its time to lock, so a
  permitted class wins the race for the same target. Vehicle is the one exception: it is hard
  denied under either policy, lock-time inflation having been measured to do nothing to a car
  (ADR 0013).
- **Seven target classes.** Head, chest, limbs, weak spot, mechanical, breach and vehicle, each
  switched on or off individually. Whatever is ticked is the class mask, whichever protocol is
  selected and with no second switch gating it (ADR 0009). A class the installed implant tier does
  not unlock stays untrackable whatever the mask allows.
- **Faction filtering.** An allow list covering the vanilla corporations, gangs and law factions,
  with a catch-all for unlisted affiliations and a separate switch for civilians. Android variants
  fold into their parent faction. Enforced at every coprocessor grade, and on by default with NCPD,
  Trauma Team, Aldecaldos and Afterlife mercs unticked (ADR 0009).
- **Threat and attitude filtering.** Restrict locks to hostile targets, to hostile and neutral, or
  to anything. Attitude is read live from the target's AI rather than cached.
- **IFF overlay.** A label over every tracked target showing faction, threat class, attitude, and
  whether the active protocol permits or refuses it. Visibility is one setting with four answers:
  always, only while aiming, only with the overlay key, or never (ADR 0011). The overlay key works
  as hold-to-show or as a toggle.
- **Ripperdoc cyberware on an eleven-tier ladder.** The Kiroshi IFF Targeting Coprocessor is a
  frontal-cortex implant running the full vanilla quality ladder from Common to Legendary++, bought
  and upgraded at a ripperdoc. Each tier reaches further into the target classes vanilla ignores,
  and tier 3 and above carry an Intelligence attunement; the capacity cost is 6 at every tier.
  Nothing the mod does takes effect unless the implant is installed and a smart weapon is in hand.
- **Clean teardown.** Every stat modifier the mod applies is tracked and removed before the next
  one goes on. Nothing stacks and nothing is left behind in the save.

## Requirements

**Required.** Without all four nothing the mod does can take effect.

| Component | Notes |
|---|---|
| Cyberpunk 2077 2.31 | Other game versions are untested |
| RED4ext | Plugin loader |
| redscript | Compiles the mod's scripts |
| TweakXL | Registers the cyberware and its stat records |

**For configuration.** Mod Settings (`red4ext\plugins\mod_settings`). Every option lives on its
page. Without the plugin the mod runs on its compiled defaults and nothing can be changed in game.

**For hotkeys.** Input Loader, or REDmod, to merge `r6\input\kstp_inputs.xml`. Without one the two
hotkeys never fire; the rest of the mod, including the protocol picker in the settings menu, is
unaffected.

**Optional.**

- Cyber Engine Tweaks, for the console grant below and for the developer lab in
  `experiments/cet/kstp_lab`.
- Codeware. Registers the implant's display name, which the item record cites as a LocKey token
  (ADR 0008), and supplies an alternative NPC-spawn hook. Without it the coprocessor renders with a
  blank name in the ripperdoc and inventory panels; the spawn hook falls back to a vanilla path that
  is equivalent, and no mechanic changes.

## Installation

1. Install the required frameworks listed above.
2. Extract the archive into the Cyberpunk 2077 install folder, so that `r6\` and `bin\` land on top
   of the folders already there.
3. Launch the game and acquire the implant. Buy the Kiroshi IFF Targeting Coprocessor from Viktor
   Vektor's clinic in Little China, or grant any tier from the CET console:

   ```lua
   Game.AddToInventory("Items.KSTPKiroshiIFFCoprocessorCommon", 1)
   Game.AddToInventory("Items.KSTPKiroshiIFFCoprocessorLegendaryPlusPlus", 1)
   ```

   The eleven record names are listed under [The implant](#the-implant).

To remove the mod, delete `r6\scripts\KSTP`, `r6\tweaks\KSTP`, `r6\input\kstp_inputs.xml` and
`r6\config\redsUserHints\KSTP.toml`. The implant carries no permanent state, and its stat modifiers
are stripped when it is unequipped.

### From source

The repository ships three PowerShell helpers. Windows refuses to run an unsigned `.ps1` under the
default execution policy, so invoke them with an explicit bypass.

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -WhatIf
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1
```

`verify-env.ps1` reports which frameworks are present and where the redscript compile log lives.
`deploy.ps1` copies `src\r6` and the CET lab into the game and records a manifest; `-Clean` replays
that manifest and removes exactly the files it wrote. `watch.ps1` re-runs the deploy whenever a
deployable source file changes. Pass `-GamePath`, or set `$env:KSTP_GAME_PATH`, if the install is
not in the default location.

## The implant

The Kiroshi IFF Targeting Coprocessor ships as eleven quality grades covering the same ladder every
vanilla implant uses, Common through Legendary++. What scales is reach: how much of the targeting
layer the implant switches on.

| Tier | Quality grades | Unlocks |
|---|---|---|
| 1 | Common, Common+ | Head tracking |
| 2 | Uncommon, Uncommon+ | Weak spot tracking |
| 3 | Rare, Rare+ | Breach tracking, and the Intelligence attunement |
| 4 | Epic, Epic+ | Vehicle tracking |
| 5 | Legendary, Legendary+, Legendary++ | Every component class, and faster locks on the four the implant unlocks |

Each tier keeps everything the tier below it granted. The classes the table does not name are ones
a vanilla smart weapon already tracks; what the coprocessor adds is the classes vanilla ignores,
plus the protocol layer that arbitrates between them.

**The faction and threat axis is not part of the ladder.** It runs at every grade, so the shipped
defaults hold from the cheapest coprocessor upward: faction filtering is on, and NCPD, Trauma Team,
Aldecaldos and Afterlife mercs are unticked (ADR 0009). The ladder buys target-class coverage and
the tier 3 attunement, not the right to choose who to engage. The overlay classifies every tracked
target and labels it `PERMIT` or `REFUSE` at every grade; a refusal that nothing acts on, because
the faction-axis experiment gate is off, is labelled `REFUSE*`.

**Capacity cost is 6 at every tier**, matching the vanilla convention where an implant charges the
same capacity from its first grade to its last. Bioconductor costs 16 at tier 1 and 16 at tier 5++.
Only the price in eddies scales with quality, through the standard cyberware price chain, so a
higher tier costs money rather than headroom.

Stock and upgrades run through the ripperdoc. One grade is stocked, the tier 3 Rare, at Viktor
Vektor's clinic in Little China, Watson, which is the one ripperdoc vendor ID confirmable against
the decompiled 2.31 scripts. Ripperdoc inventories are filtered by player level, so it appears once
the player is high enough for it. The other ten grades are reached through the ripperdoc upgrade
panel: each record chains to the next, so an installed implant is upgraded in place at the clinic
rather than replaced.

All eleven grades share one `cyberwareType`, so only one can be installed at a time. The mod reads
the highest installed grade and treats a plus grade as its base tier: Rare and Rare+ are both
tier 3.

| Quality | Record |
|---|---|
| Common | `Items.KSTPKiroshiIFFCoprocessorCommon` |
| Common+ | `Items.KSTPKiroshiIFFCoprocessorCommonPlus` |
| Uncommon | `Items.KSTPKiroshiIFFCoprocessorUncommon` |
| Uncommon+ | `Items.KSTPKiroshiIFFCoprocessorUncommonPlus` |
| Rare | `Items.KSTPKiroshiIFFCoprocessorRare` |
| Rare+ | `Items.KSTPKiroshiIFFCoprocessorRarePlus` |
| Epic | `Items.KSTPKiroshiIFFCoprocessorEpic` |
| Epic+ | `Items.KSTPKiroshiIFFCoprocessorEpicPlus` |
| Legendary | `Items.KSTPKiroshiIFFCoprocessorLegendary` |
| Legendary+ | `Items.KSTPKiroshiIFFCoprocessorLegendaryPlus` |
| Legendary++ | `Items.KSTPKiroshiIFFCoprocessorLegendaryPlusPlus` |

## Usage

Equip the coprocessor in a frontal cortex slot and carry a smart weapon. The mod is inert until both
are true. The overlay exists only while a smart weapon's crosshair is up, and with one in hand and
no coprocessor installed every label reads `OFFLINE`.

Configuration is at **Settings > Mods > Kiroshi Targeting Protocol**. Groups whose name begins
`Debug -` sort below what a player tunes (ADR 0009).

| Category | Contains |
|---|---|
| General | Master switch, active protocol |
| Target classes | The seven class toggles, lock policy |
| Faction filter | Faction allow list, attitude mask, civilian and unlisted catch-alls |
| Key bindings | Cycle protocol, show overlay, hold-versus-toggle behaviour |
| Debug | Multi-target tracking in ADS, unread by the 2.31 scripts and left on `INHERIT` |
| Debug - IFF overlay | Overlay visibility, refused-only filter, distance and lock state |
| Debug - overlay layout | Anchor, offsets, font size, background opacity, label count |
| Debug - experiment gates | Switches for behaviour that is unproven on arbitrary builds; leave them alone unless testing |

Both hotkeys are rebindable on the key bindings page.

## Known limitations

Which classes the installed tier unlocks is a progression gate on a working feature rather than a
limitation, and it is documented under [The implant](#the-implant).

- **A denied target still draws a bracket that never completes.** Smart-gun candidate selection is
  native and exposes no per-candidate veto to redscript, so the mod can prevent a lock from
  finishing but cannot take a candidate out of the native handler's list. The bracket appears and
  sits there.
- **Unticking every class a target carries does not exclude it.** Disabling every component class a
  target possesses does not stop it being targeted; it triggers a native fallback to a default
  slot (`weapon.script:1526`), so a human left with no permitted class is still locked on the chest.
  The class mask decides where a lock lands, not whether one happens (ADR 0006). Vehicle is the one
  class that does exclude, because a car carries a single lockable class and zeroing it takes the
  car off the candidate list (ADR 0013).
- **Faction suppression is target-scoped.** The faction axis works by inflating the time to lock on
  the target NPC, which is a property of that NPC rather than of the player's weapon. An allied NPC
  firing a smart weapon at a target the player has denied is impaired in the same way.
- **Display strings are English in every locale.** The mod ships no `.archive`, so the implant's
  name and flavour text are registered from script through Codeware, which serves the English
  package whatever the game language (ADR 0008). Without Codeware the name renders blank, and the
  gameplay logic package's own strings still resolve because a different native backs them.
- **Hotkey defaults can collide with another mod's bindings.** The defaults are the bracket keys,
  chosen because vanilla claims every letter key across its own contexts. A key claimed twice fires
  both actions, since nothing here consumes the input. Rebind either under Key bindings.

## Compatibility

KSTP uses `@wrapMethod` and `@addField` only. There is no `@replaceMethod` anywhere, so the mod
chains with anything else hooking the same methods instead of displacing it, and it declares no
native functions of its own.

Known interaction: mods that write `SmartGunTrack*` stats on the same weapon contend for the same
values. ChipwareExpansion and the misoru weapon packs both do this, as vanilla does through
`Items.KiroshiOpticsFragment1`. A class denied under `STRICT`, and VEHICLE under either policy, is
zeroed with a `Multiplier` 0 modifier whatever another mod added to the same stat; under
`PREFERRED` the track stats are untouched and the time-to-lock multiplier is inflated instead.
Neither side leaks: every modifier KSTP applies is removed by its own handle rather than by
sweeping the stat.

The cyberware occupies one frontal cortex slot and defines its own `cyberwareType`, shared across
all eleven grades, so it does not compete with any vanilla implant for the same exclusivity group
and two grades of it cannot be installed together.

## Credits

Built against the decompiled 2.31 game scripts. The cyberware follows the vanilla precedent set by
`Items.KiroshiOpticsFragment1`, which applies a smart-gun tracking modifier to the held weapon
through `Prereqs.SmartWeaponHeldPrereq`.

Thanks to the authors of RED4ext, redscript, TweakXL, Mod Settings, Input Loader, Cyber Engine
Tweaks and Codeware, without which none of this is possible.

Cyberpunk 2077 is a trademark of CD PROJEKT S.A. This mod is unofficial and unaffiliated.

## License

MIT. See [LICENSE](LICENSE).
