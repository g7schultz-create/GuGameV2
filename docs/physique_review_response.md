# Response to the physique & root design review

Nothing here is implemented. Per instruction 13 these are proposals for review.

---

## 1. The duplication is real, and there is more of it

The review names one family. Querying `unmodelled` across the whole roster
finds **five**, and three of them are near-total — two bodies that are the same
body at two different bands.

| Duplicated claim | Bodies | Verdict |
|---|---|---|
| Every third landed strike | epic `heavenly_battle_body`, legendary `heavenly_giant_body`, mythic `eternal_dragon_body` | The one the review caught |
| Evasion **and** A failed escape | mythic `void_sovereign_body`, divine `infinite_immortal_body` | **Same body twice.** Both claims identical |
| At encounter start **and** Manual study | legendary `celestial_emperor_body`, mythic `celestial_sovereign_body` | **Same body twice** |
| Realm breakthroughs | mythic `chaos_immortal_body`, divine `supreme_dao_physique` | Near-total |
| Damage taken above 60% HP | epic `mountain_king_body`, divine `heaven_and_earth_physique` | Partial |

Nine of the sixteen new bodies are involved.

**Cause worth naming.** The spec's catalogs are templated by *Foundation focus*
— "A broad high-tier root that strengthens law comprehension and cross-system
balance" appears verbatim six times in §7.7 alone, and the physique sections do
the same. I transcribed them faithfully and imported the template with them.
Fidelity to that document was the wrong instinct: it is a tier-baseline
generator, not a catalog of distinct things.

---

## 2. What the engine can actually carry

Instruction 10. The important discovery is that **`battle_combatants.snapshot`
is a per-combatant JSONB bag written once at `battle_open`** — so per-fight
counters, stacks and once-per-battle flags need *no migration at all*. That
moves most of the review's ambitious mechanics from "needs a new system" to
"needs code".

| | Meaning | Examples from the review |
|---|---|---|
| **A. Live** | Wired and paying out today | Path attainment/damage, stat multipliers, cultivation/physique/attainment rates |
| **B. One hook** | The system exists; a physique term joins an existing sum. No schema change | Manual refinement harmony (`refine()`), Gu refinement (`refine_gu()`), flee chance, guard strength, evasion, damage reduction, lifesteal, crit, armour penetration, gathering yield, encounter-start stat changes (`battle_open` writes the snapshot) |
| **C. Snapshot state** | Needs per-fight bookkeeping, which `snapshot` already holds. No schema change | Third Blow's counter, Momentum, Dragon Might stacks, any once-per-battle trigger including the lethal-damage save |
| **D. Absent** | Needs a system that does not exist | Breakthrough backlash (breakthroughs cannot fail yet — that is the tribulation), temporary buffs outliving a fight, mining, secret realms, Insight Dust, manual previews, Dao Marks, servants, pets, equipment, formations |

**Answering instruction 11 directly: no schema change is required for any
mechanic in the review.** Category D is blocked on systems, not on columns.

---

## 3. Proposed replacements for the five duplicate families

Each keeps the body's fantasy, lands in A–C, and interacts with something that
already exists.

| Body | Band | Now | Proposed | Cat |
|---|---|---|---|---|
| `heavenly_battle_body` | Epic | Third Blow | **Keep.** A counter is the right weight for Epic, and it should be the only body that owns it | C |
| `heavenly_giant_body` | Legendary | Third Blow again | **Long Reach → armour penetration.** Strength that ignores defence rather than repeating a rhythm. 0037 made defence subtract from *every* strike, so this reinforces the build tension already there: the giant wants big hits, not many | B |
| `eternal_dragon_body` | Mythic | Third Blow again | **Dragon Might**, as the review proposes — stacks from dealing *or* taking damage, granting STR and DEF, peaking into a heightened state | C |
| `void_sovereign_body` | Mythic | Evasion + flee reroll | **Keep.** This is its whole identity and it should own it alone | B/C |
| `infinite_immortal_body` | Divine | The same two | **The lethal-damage save**, as the review proposes — see §5, it is cheaper than it looks | C |
| `celestial_emperor_body` | Legendary | Lowest stat rises at encounter start | **Keep.** `battle_open` writes the snapshot, so this is nearly free | B |
| `celestial_sovereign_body` | Mythic | The same | **The weakness is already known.** A Star/Wisdom body that opens a fight with the creature's weakness revealed, without spending the Observe round. Uses the bestiary and the reveal machinery that already exist | B |
| `mountain_king_body` | Epic | Damage taken above 60% HP | **Keep.** Simple threshold, right for Epic | B |
| `heaven_and_earth_physique` | Divine | The same, larger | **Defence cannot be penetrated below a floor.** 0037 lets armour penetration erase defence outright; a Divine earth body that sets a floor under it bends that rule rather than scaling it, and pushes directly against the Gu penetration axis | B |
| `chaos_immortal_body` | Mythic | Breakthrough vigour | **Softened matchup penalties.** A body too broad to be countered cleanly: Path resistances against it bite less. Reads the matchup chart the whole game already runs on | B |
| `supreme_dao_physique` | Divine | Breakthrough vigour again | **Reduced Harmony penalty on conflicting Paths when refining.** The review's own best idea — see §4 | B |

---

## 4. The single best suggestion in the document

> Supreme Dao Physique: reduced conflicting-Path Harmony penalty.

This is worth more than the rest combined, because **manual refinement is
finished and unhooked**. `refine()` already computes harmony from
`pair_harmony`, page traits, tier spread and refiner skill — a physique term
joins that sum in one line, with no migration and no new concept.

It also delivers exactly the emergent build the review describes: Fire + Water
is −22 on the chart, so an ordinary refiner cannot make Boiling Heaven
Scripture. A body that softens conflict can. That is a physique changing *what
a player can build* rather than how hard they hit, which is the stated goal for
Divine.

`refine_gu()` has the identical shape and could take the same term.

---

## 5. On the lethal-damage save

Endorsed, with a caveat the review should know: **it is currently worth much
less than it sounds.** Losing a fight in this game costs HP and nothing else —
the defeat card says so in as many words. So a death save mostly converts a
loss into a flee.

That makes it *safe* to ship now and *automatically* stronger later, the moment
losing costs anything. I would take it for that reason rather than despite it.

---

## 6. The four Mythic roots, checked against the roster

Instruction 8. Two are good, one collides, one needs a rename.

| Proposed | Paths | Verdict |
|---|---|---|
| **Heavenly Dream Root** | Dream / Wisdom | **Take it.** Dream is claimed by no root at any band — the only genuinely empty Path in the proposal. Rename off "Heavenly", which already prefixes four roots |
| **Ten Thousand Flame Root** | Fire / Refinement | **Take it.** Fire would be its fourth root, but no root pairs Fire with a craft Path, and it is the exact root the review's own Boiling Heaven example needs |
| **Ancient Sword Heart Root** | Sword / Rule | **Concept yes, name no.** `primordial_sword_heart` is Legendary and Sword — "Ancient Sword Heart" one band above "Primordial Sword Heart" is two names for one thing. Sword+Rule is a real differentiator; the name has to move |
| **Voidwalker Root** | Space / Theft | **Collides.** `thieving_heavens_inheritor` is Unique and is **theft+space** — the same pair, one band up. A Mythic version is a strictly weaker copy of a Venerable inheritance, which is the exact failure the review warns about. Repath it: Space+Formation or Space+Illusion are both unclaimed |

Existing Path coverage, for choosing: `dream`, `food`, `light`, `shadow`,
`star`, `bone`, `poison`, `enslavement`, `luck` (Unique only), `formation`,
`illusion`, `painting`, `heaven` (Divine only) are thin or empty across the
whole root roster.

---

## 7. Two recommendations against

**No implementation-status column.** The review floats ✅/⚠️/❌ and asks for it
only if it earns its keep. It does not: `unmodelled` already encodes the
distinction — a claim listed there is designed, and anything not listed is
wired, which is why the profile can render one in italics and the other plain.
A third state needs a consumer and there is none. The one thing worth adding is
a convention *inside* the existing field, free: prefix a claim with `soon:`
when a hook exists and only the code is missing.

**No renames without you.** Instruction: do not automatically rename. The
"Heavenly" count is real — four roots and several bodies — but the worksheet is
where that gets decided, not here.

---

## 8. What I would do, in order

1. **The five duplicate families** — §3, all `unmodelled` and `special_text`
   edits. One `UPDATE` migration, no risk.
2. **Wire Supreme Dao into `refine()`** — §4. The highest value per line in the
   whole review, and it makes one physique genuinely rule-bending today.
3. **The three Mythic roots** — §6, once the two names are settled.
4. **The battle-side hooks** — evasion, armour penetration, guard, flee. All
   category B, all joining sums `battle_act` already computes.
5. **Snapshot mechanics** — Third Blow, Dragon Might, the lethal-damage save.
   Category C: no migration, but real combat code and real tests.

1 and 2 are worth doing straight away. 4 and 5 are a session each.
