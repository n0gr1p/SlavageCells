SalvageCells 0.5.0
===================

Purpose
-------
Automates original level-75 Salvage imbued-cell distribution for a multibox party.

New in 0.5.0: per-cell job priority
------------------------------------
Characters that still NEED a cell are ranked by their current main job and
the type of cell in the treasure pool. There are four priority tiers per cell:
three explicit tiers in CELL_JOB_TIERS (inside SalvageCells.lua), with all
unlisted jobs in tier 4. Characters in the same tier are sorted alphabetically,
so allocation remains deterministic across Windower clients.

Examples:
- Magic: WHM/SCH/RDM/BLM rank ahead of WAR/SAM.
- Abilities / WS: SAM/WAR/DRK/DRG/MNK/COR/PUP/RNG rank ahead of WHM.
- Ranged / ammo: BRD/GEO/RNG/COR rank ahead of jobs that rarely use it.
- Maximum HP: PLD/RUN rank first.

Every job remains eligible for every cell: no automatic SKIP states, no
character-name hardcoding, no tank/healer overrides. The existing NEED,
OWNED, DONE and SKIP semantics and duplicate-slot allocation remain unchanged.

Main-job metadata travels with the existing IPC snapshots as an optional
comma-separated field; legacy state parsers ignore it. Disk recovery data
remains unchanged. Unknown job information falls into tier 4.

  //sc priority magic
  //sc priority abilities

These read-only commands show the currently known eligible characters
in their calculated lot order, including their jobs and tiers.

For consistent allocations, update/reload all SalvageCells clients to 0.5.0
before entering Salvage. Mixed old and new versions can disagree on lot order.

State machine
-------------
    LOCK / LOT
        This character still needs the cell.

    LOCK / USE
        This character won the cell and is trying to consume it.
        Additional copies are passed.

    OPEN / PASS
        The cell was successfully consumed.
        This character passes that cell for the rest of the run.

    SKIP / PASS
        This character was manually configured to ignore that cell for this run.

New in 0.4.0: automatic stale-cell cleanup
---------------------------------------------
If SalvageCells loads or the character logs in while OUTSIDE the four original
Salvage zones, it scans Inventory for any tracked imbued cells and drops them.

The drops are throttled at 0.30 seconds per inventory slot and each scheduled
drop re-checks both:
- that the character is still outside Salvage, and
- that the inventory slot still contains the expected cell.

This avoids old run-specific cells hanging around and interfering with a later
Salvage entry.

Manual cleanup is also available:

    //sc cleanup

The command refuses to run while inside original Salvage.

New in 0.3.0: DC / reload recovery
-----------------------------------
Each character now writes its current Salvage state to:

    Windower\addons\SalvageCells\SalvageCells_<CharacterName>.state

The state file is updated whenever a cell changes state.

If the character:
- disconnects,
- logs out,
- crashes,
- restarts Windower, or
- runs //lua r SalvageCells

while still inside the SAME original Salvage run, the addon restores the saved
NEED / OWNED / DONE / SKIP state.

When the character actually zones OUT of original Salvage, the recovery file is
deleted and the next Salvage entry starts fresh.

Recovery reconciliation
-----------------------
On restore:

- A saved OWNED cell that is still in inventory remains OWNED and /item retries resume.
- A saved OWNED cell that is no longer in inventory is conservatively promoted
  to DONE so the character does not start lotting that already-consumed unlock again.
- A saved NEED cell that is already in inventory becomes OWNED.

The recovery record expires after two hours as an additional stale-state guard.

Multibox behavior
-----------------
All clients exchange state over Windower IPC.

v0.3.0 originally preserved the v0.2 alphabetical allocation order.
v0.5.0 replaces only the candidate sort with per-cell job priorities; the
underlying recovery and lot/pass state machines are unchanged.

Commands
--------
    //sc status
    //sc priority <cell>
    //sc reset
    //sc need <alias/name/id>
    //sc done <alias/name/id>
    //sc skip <alias/name/id>
    //sc on
    //sc off
    //sc sync
    //sc ui on
    //sc ui off
    //sc cleanup
    //sc help

Important
---------
Disable Treasury / LightLuggage rules that also lot/pass Salvage cells.
Two addons issuing treasure-pool decisions for the same item can conflict.
