# Bleed Predict

Bleed Predict is a Retail World of Warcraft addon for the Saprish encounter in Seat of the Triumvirate. It shows only the possible next Shadow Pounce bleed targets in a small movable box.

Version `0.3.1-polished-silent` is an aura-only build for final dungeon testing.

## Current Behavior

- The box is hidden outside Saprish unless manually shown.
- During Saprish, the box shows the possible next bleed targets only.
- Character names are class-colored.
- Previous bleed targets are not shown in the UI.
- The addon is quiet by default and does not automatically print encounter or detection messages.
- Combat-log detection is disabled because this client forbids `COMBAT_LOG_EVENT_UNFILTERED` registration from this addon.
- Bleed detection uses Saprish-gated `UNIT_AURA` scanning for new harmful non-player debuffs.

Darkfang may be the aura source during Saprish; detection focuses on which player receives the aura.

## Prediction Logic

- First two bleeds: any non-tank that has not been targeted yet.
- After the first two bleeds: the two least recently chosen non-tanks.

## Install

Copy these files into:

```text
C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\BleedPredict
```

Required files:

```text
BleedPredict.toc
Core.lua
```

Then reload WoW:

```text
/reload
```

## Commands

```text
/bp show
/bp hide
/bp lock
/bp roster
/bp status
/bp start
/bp stop
/bp test
/bp test stop
/bp blocked
/bp blocked clear
```

Diagnostic commands are still available if needed:

```text
/bp debug
/bp auras
/bp auradebug
```

## Final Test Flow

Before the key:

```text
/bp blocked clear
/bp roster
```

Optional UI placement:

```text
/bp show
/bp lock
/bp hide
```

During Saprish, the box should appear automatically and update as bleeds are detected.
