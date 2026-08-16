# Kiroshi Smart Targeting Protocol

A Cyberpunk 2077 2.31 mod that gives smart weapons a target list you control. Vanilla smart guns
decide for themselves: they sweep the cone, take the nearest torso, and will happily spend a
magazine on a passing civilian or a Trauma Team medic standing behind the ganger you came for.
KSTP adds a piece of ripperdoc cyberware that puts a policy layer in front of the smart link. Pick
a targeting protocol and the gun spends its lock time only on the body parts that protocol allows,
and only on the factions and threat classes cleared for engagement. Every target the weapon is
tracking carries an IFF label, so the verdict is readable before the trigger is pulled.

Script only. No `.archive`, no C++ plugin, no `@replaceMethod`.

## Features

- **Six targeting protocols.** `AUTO` (vanilla behavior), `PRECISION` (head and weak spot),
  `CRIPPLE` (limbs), `ANTI-MACHINE` (mechanical and vehicle), `ORGANIC` (machines refused),
  `SURGICAL` (weak spot only). Cycle with a hotkey or select in the settings menu. The active
  protocol is saved with the game.
- **Two lock policies.** `STRICT` drives a denied class's tracking stat to zero, so the weapon
  never acquires it. `PREFERRED` leaves the class acquirable and inflates its time to lock, so a
  permitted class wins the race for the same target.
- **Per-class override.** The seven component classes (head, chest, limbs, weak spot, mechanical,
  breach, vehicle) can be switched individually, replacing the selected preset's mask. A class the
  installed implant tier does not unlock stays untrackable whatever the protocol allows.
- **Faction filtering.** An allow list covering the vanilla corporations, gangs and law factions,
  with a catch-all for unlisted affiliations and a separate switch for civilians. Android variants
  fold into their parent faction. Enforced from implant tier 3 upward.
- **Threat and attitude filtering.** Restrict locks to hostile targets, to hostile and neutral, or
  to anything. Attitude is read live from the target's AI rather than cached.
- **IFF overlay.** A label over every tracked target showing faction, threat class, attitude, and
  whether the active protocol permits or refuses it. Hold-to-show or toggle, optionally restricted
  to aim-down-sights.
- **Ripperdoc cyberware on an eleven-tier ladder.** The Kiroshi IFF Targeting Coprocessor is a
  frontal-cortex implant running the full vanilla quality ladder from Common to Legendary++, bought
  and upgraded at a ripperdoc. Each tier unlocks more of the targeting layer; the capacity cost is
  6 at every tier. Nothing the mod does takes effect unless the implant is installed and a smart
  weapon is in hand.
- **Clean teardown.** Every stat modifier the mod applies is tracked and removed before the next
  one goes on. Nothing stacks and nothing is left behind in the save.

## Requirements

**Required.** Without all four the mod does not load.

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
- Codeware. Used only as an alternative NPC-spawn hook. The vanilla path is equivalent, so
  installing it changes nothing a player can see.

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

To remove the mod, delete `r6\scripts\KSTP`, `r6\tweaks\KSTP` and `r6\input\kstp_inputs.xml`. The
implant carries no permanent state, and its stat modifiers are stripped when it is unequipped.

### From source

The repository ships two PowerShell helpers. Windows refuses to run an unsigned `.ps1` under the
default execution policy, so invoke them with an explicit bypass.

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\verify-env.ps1
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1 -WhatIf
powershell -ExecutionPolicy Bypass -File .\tools\deploy.ps1
```

`verify-env.ps1` reports which frameworks are present and where the redscript compile log lives.
`deploy.ps1` copies `src\r6` into the game and records a manifest; `-Clean` replays that manifest
and removes exactly the files it wrote. Pass `-GamePath`, or set `$env:KSTP_GAME_PATH`, if the
install is not in the default location.

## The implant

The Kiroshi IFF Targeting Coprocessor ships as eleven quality grades covering the same ladder every
vanilla implant uses, Common through Legendary++. What scales is reach: how much of the targeting
layer the implant switches on.

| Tier | Quality grades | Unlocks |
|---|---|---|
| 1 | Common, Common+ | Head tracking |
| 2 | Uncommon, Uncommon+ | Weak spot tracking |
| 3 | Rare, Rare+ | Breach tracking, and the faction and threat axis becomes enforceable |
| 4 | Epic, Epic+ | Vehicle tracking |
| 5 | Legendary, Legendary+, Legendary++ | Every component class, and permitted classes lock faster |

Each tier keeps everything the tier below it granted. The classes the table does not name are ones
a vanilla smart weapon already tracks; what the coprocessor adds is the classes vanilla ignores,
plus the protocol layer that arbitrates between them.

**The faction and threat axis requires tier 3 or better.** Below that the overlay still classifies
every tracked target and labels it `PERMIT` or `REFUSE`, so the feature is legible before it is
owned, and the lock itself is never suppressed. Faction filtering also stays off until it is
switched on in the settings menu, at any tier.

**Capacity cost is 6 at every tier**, matching the vanilla convention where an implant charges the
same capacity from its first grade to its last. Bioconductor costs 16 at tier 1 and 16 at tier 5++.
Only the price in eddies scales with quality, through the standard cyberware price chain, so a
higher tier costs money rather than headroom.

Stock and upgrades run through the ripperdoc. The ladder is stocked at Viktor Vektor's clinic in
Little China, Watson, which is the one ripperdoc vendor ID confirmable against the decompiled 2.31
scripts. Ripperdoc inventories are filtered by player level, so the lower grades show up first and
the higher ones become available as the player levels. Each record chains to the next, so an
installed implant is upgraded in place at the clinic rather than replaced.

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

Equip the coprocessor in a frontal cortex slot and carry a smart weapon. The mod is inert until
both are true, and the overlay reads `OFFLINE` in the meantime.

Configuration is at **Settings > Mods > Kiroshi Targeting Protocol**.

| Category | Contains |
|---|---|
| General | Master switch, active protocol |
| Target classes | Class-mask override, the seven class toggles, lock policy |
| Faction filter | Faction allow list, attitude mask, civilian and unlisted catch-alls |
| IFF overlay | Label visibility, aim-down-sights restriction, placement |
| Key bindings | Cycle protocol, show overlay, hold-versus-toggle behavior |
| Experiments | Switches for behavior that is unproven on arbitrary builds; leave them alone unless testing |

Both hotkeys are rebindable on the key bindings page.

## Known limitations

Tier requirements are not listed here. The faction axis needing a tier 3 implant is a progression
gate on a working feature, and it is documented under [The implant](#the-implant).

- **A denied target still draws a bracket that never completes.** Smart-gun candidate selection is
  native and exposes no per-candidate veto to redscript, so the mod can prevent a lock from
  finishing but cannot take a candidate out of the native handler's list. The bracket appears and
  sits there.
- **`ANTI-MACHINE` still locks the chest of human targets.** Disabling every component class a
  target possesses does not stop it being targeted; it triggers a native fallback to a default
  slot (`weapon.script:1526`). The protocol biases against organics rather than excluding them.
- **Faction suppression is target-scoped.** The faction axis works by inflating the time to lock on
  the target NPC, which is a property of that NPC rather than of the player's weapon. An allied NPC
  firing a smart weapon at a target the player has denied is impaired in the same way.
- **Display strings render as their internal keys.** The mod ships no `.archive`, so TweakXL has no
  localization archive to resolve against and the key text reaches the screen unchanged. Keys are
  named so that the text they print reads correctly, which makes every string English in every
  locale.
- **Hotkey defaults can collide with vanilla bindings.** The default keys may already be claimed by
  the base game's mapping file, in which case the action fires alongside whatever else is bound to
  that key. Rebind both under Key bindings.

## Compatibility

KSTP uses `@wrapMethod` and `@addMethod` only. There is no `@replaceMethod` anywhere, so the mod
chains with anything else hooking the same methods instead of displacing it, and it declares no
native functions of its own.

Known interaction: mods that write `SmartGunTrack*` stats on the same weapon contend for the same
values. ChipwareExpansion and the misoru weapon packs both do this. The last modifier applied wins,
so a protocol switch and the other mod's grant will override each other depending on order. There
is no crash or corruption, only a class that is on when it was expected off.

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
