# Bleed Predict

Bleed Predict is a small Retail World of Warcraft addon for the Saprish encounter in Seat of the Triumvirate. It shows the possible next Shadow Pounce bleed targets in a movable box, using class-colored character names.

## Current Diagnostic Build

Version `0.1.8-blocked-hook` is intentionally stripped down to diagnose a Blizzard blocked-action popup.

The active `Core.lua` currently loads only:

- Saved variables
- `/bleedpredict status`
- `/bleedpredict blocked`
- A basic event frame for `ADDON_LOADED` and `PLAYER_LOGIN`
- `ADDON_ACTION_BLOCKED` and `ADDON_ACTION_FORBIDDEN` diagnostics

It does not load the prediction UI, movement, encounter tracking, combat-log tracking, or aura scanning. The previous full implementation is parked in `Core.full.lua` while this is being isolated.

Test this version with only Bleed Predict enabled:

1. Copy `BleedPredict.toc`, `Core.lua`, and `Core.full.lua` into the addon folder.
2. Run `/reload`.
3. If the popup still appears, the basic event frame or load/login handling is enough to trigger it.

The box is hidden by default. It appears automatically when Saprish tracking starts, or when you manually show/test it.

## How It Predicts

The addon keeps an ordered history of detected Shadow Pounce bleed targets.

- For the first two bleeds, the possible targets are any non-tanks that have not been targeted yet.
- After the first two bleeds, the possible targets are the two least recently chosen non-tanks.

Example with non-tanks `dk`, `dh`, `evo`, and `mw`:

```text
mw, dk -> next: dh or evo
dh     -> next: evo or mw
evo    -> next: mw or dk
dk     -> next: mw or dh
```

## How It Detects Shadow Pounce

The addon uses a hybrid detector:

1. It watches the combat log for Shadow Pounce spell ID `245742`.
2. If the combat log directly applies an aura to a party member, that player is recorded.
3. If the combat log only shows a cast or damage event, the addon opens a short detection window and watches party members for a new harmful non-player debuff.
4. If only one non-tank takes Shadow Pounce damage and no aura is visible, that player is recorded as a fallback.

Debug chat output is enabled by default because the exact current Mythic+ logging behavior may need one real Saprish pull to confirm.

## Install For Testing

1. Find your Retail addons folder. It is usually:

```text
C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns
```

2. Create this folder:

```text
C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\BleedPredict
```

3. Copy these files into that folder:

```text
BleedPredict.toc
Core.lua
README.md
```

4. Start or reload WoW.
5. On the character select screen, click `AddOns` and make sure `Bleed Predict` is enabled.
6. If WoW says it is out of date, enable `Load out of date AddOns`. You can also update the `## Interface:` number in `BleedPredict.toc` to match your current Retail client.

## In-Game Commands

```text
/bleedpredict
/bleedpredict show
/bleedpredict hide
/bleedpredict debug
/bleedpredict reset
/bleedpredict start
/bleedpredict stop
/bleedpredict clear
/bleedpredict test
/bleedpredict test stop
/bleedpredict status
/bleedpredict blocked
```

Useful first checks:

- `/bleedpredict test` simulates a bleed using your current non-tank roster so you can verify the box and prediction order before entering the dungeon.
- `/bleedpredict test stop`, `/bleedpredict stop`, or `/bleedpredict clear` stops test mode and hides the box.
- `/bleedpredict show` keeps the box visible outside Saprish until you hide it or reload.
- `/bleedpredict hide` returns the box to Saprish-only visibility.
- `/bleedpredict debug` toggles chat logging.
- `/bleedpredict status` prints the detected non-tank roster and current possible targets.
- `/bleedpredict blocked` prints any blocked-action diagnostics the addon saw.
- Movement is temporarily disabled while we isolate the Blizzard blocked-action popup.

## How To Test On Saprish

1. Enter current Mythic+ Seat of the Triumvirate.
2. Make sure party roles are assigned correctly. The addon excludes units whose role is `TANK`.
3. Before pulling Saprish, type `/bleedpredict status` and confirm the non-tank list is correct.
4. Pull Saprish.
5. Watch chat for debug lines like:

```text
Combat log: SPELL_CAST_SUCCESS Shadow Pounce -> no target (245742)
Shadow Pounce event seen; watching party debuffs for target inference.
Bleed #1 detected on Player via ...
```

6. After the run, the important information to keep is:

- Did the box update when each bleed happened?
- Did chat show `SPELL_AURA_APPLIED`, `SPELL_DAMAGE`, or only cast events?
- If detection failed, what debug lines appeared around Shadow Pounce?

## Notes

- This is intentionally dependency-free. It does not require DBM, BigWigs, or WeakAuras.
- The addon currently assumes English encounter naming for Saprish, but the Shadow Pounce spell ID detection should still work regardless of client language.
- Shadow Pounce spell ID source: [Wowhead spell 245742](https://www.wowhead.com/spell=245742/shadow-pounce).
