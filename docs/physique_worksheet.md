# Roots & physiques — second pass

Regenerated from the database after the design review. Everything is a row:
edit here, hand it back, and it becomes one `UPDATE` migration.

**Leave `code` alone** — it is the key I match your edits against.

## What moved since the first worksheet

| | |
|---|---|
| **Five duplicated mechanics split apart** | Nine of sixteen bodies were involved; three pairs were the same body at two bands. 0051 |
| **Four Mythic roots added** | The last band that could not award a root. 0052 |
| **Supreme Dao Physique is wired** | It really does soften Path conflict when refining — its row below reads `WIRED` instead of a promise. 0053 |
| **`physique_effects` exists** | Physique effects are rows in the shared vocabulary now, so the next cross-system effect is a row and one consumer |

`WIRED` in the last column means the effect is live in the engine. Anything
else in that column is designed and rendered in italics until something reads
it.

---

## A — physiques, identity and numbers

| code | Band | Name | Path | HP | DEF | STR | Cult | Phys | Att | Path package |
|---|---|---|---|---|---|---|---|---|---|---|
| `endless_ocean_body` | Epic | Endless Ocean Body | water | 1.16 | 1.05 | 1 | 0.1 | 0.1 | — | water 0.1200/0.1500 |
| `heavenly_battle_body` | Epic | Heavenly Battle Body | strength | 1.16 | 1.05 | 1.16 | — | 0.15 | — | strength 0.1200/0.1500 + heaven 0.0600/0.0800 |
| `mountain_king_body` | Epic | Mountain King Body | earth | 1.16 | 1.16 | 1 | — | 0.1 | — | earth 0.1200/0.1500 |
| `phoenix_rebirth_body` | Epic | Phoenix Rebirth Body | fire | 1.05 | 1 | 1.16 | — | 0.15 | — | fire 0.1200/0.1500 |
| `celestial_emperor_body` | Legendary | Celestial Emperor Body | star | 1.18 | 1.18 | 1.08 | — | 0.15 | 0.1 | star 0.2000/0.1500 + wisdom 0.1000/0.0800 |
| `heaven_defying_body` | Legendary | Heaven Defying Body | heaven | 1.18 | 1.12 | 1.12 | 0.15 | 0.1 | — | heaven 0.2000/0.1500 + rule 0.1000/0.0800 |
| `heavenly_giant_body` | Legendary | Heavenly Giant Body | strength | 1.18 | 1.1 | 1.18 | — | 0.2 | — | strength 0.2000/0.1500 + heaven 0.1000/0.0800 |
| `primordial_chaos_body` | Legendary | Primordial Chaos Body | qi | 1.18 | 1.08 | 1.08 | 0.2 | 0.15 | — | qi 0.2000/0.1500 |
| `celestial_sovereign_body` | Mythic | Celestial Sovereign Body | star | 1.22 | 1.22 | 1.1 | 0.1 | 0.15 | 0.15 | star 0.2500/0.1500 + wisdom 0.1200/0.0800 |
| `chaos_immortal_body` | Mythic | Chaos Immortal Body | heaven | 1.22 | 1.15 | 1.15 | 0.2 | 0.15 | — | heaven 0.2500/0.1500 + qi 0.1200/0.0800 |
| `eternal_dragon_body` | Mythic | Eternal Dragon Body | strength | 1.22 | 1.15 | 1.22 | — | 0.25 | — | strength 0.2500/0.1500 + transformation 0.1200/0.0800 |
| `void_sovereign_body` | Mythic | Void Sovereign Body | space | 1.12 | 1.1 | 1.1 | 0.15 | — | 0.1 | space 0.2500/0.1500 |
| `heaven_and_earth_physique` | Divine | Heaven and Earth Physique | earth | 1.25 | 1.25 | 1 | — | 0.2 | — | earth 0.3000/0.1500 + heaven 0.1500/0.0800 |
| `infinite_immortal_body` | Divine | Infinite Immortal Body | space | 1.1 | 1.05 | 1.05 | 0.15 | — | — | space 0.3000/0.1500 + heaven 0.1500/0.0800 |
| `primordial_origin_body` | Divine | Primordial Origin Body | human | 1.15 | 1.15 | 1.15 | 0.1 | 0.1 | 0.1 | human 0.3000/0.1500 + heaven 0.1500/0.0800 |
| `supreme_dao_physique` | Divine | Supreme Dao Physique | heaven | 1.2 | 1.15 | 1.25 | 0.2 | — | — | heaven 0.3000/0.1500 + rule 0.1500/0.0800 |

---

## B — physiques, the words

| code | Special | Special text | Description | Effect |
|---|---|---|---|---|
| `endless_ocean_body` | Returning Tide | Qi comes back the way a tide does — not quickly, and not once. | It does not win quickly. It wins by still being there. | Guarding: restores 6% of battle Qi, once an encounter |
| `heavenly_battle_body` | Third Blow | A body that finds the rhythm of a fight and then keeps it. | Built for the part of a fight that comes after the first exchange. | Damage to beasts: +4%; Every third landed strike: +12% damage |
| `mountain_king_body` | Unmoved | While it is still mostly whole, very little gets through. | The mountain does not brace itself. It is simply where it was. | Damage taken above 60% HP: -6%; Mining yield: +8% |
| `phoenix_rebirth_body` | Ashes First | The worse it is going, the harder this body hits. | Every account of one of these is told by somebody who nearly died. | Below 50% HP: +11% strength; Guard: 5 points weaker; On a kill: 5% battle Qi returned |
| `celestial_emperor_body` | Rule of the Vault | Whatever this body is worst at, it is briefly not worst at. | It has no weakest point for long enough to matter. | At encounter start: the lowest foundation stat gains 7%; Manual study: +8% |
| `heaven_defying_body` | Refusal | The heavens have a rate at which they take things back. This body argues. | Not a body that heaven favours. A body heaven has not managed to correct. | Breakthrough backlash: reduced, never removed |
| `heavenly_giant_body` | Long Reach | Reach that goes through a guard rather than around it. | The kind of body that ends an argument by being present during it. | Armour penetration: +15% |
| `primordial_chaos_body` | Bottomless | Holds more qi than the aperture it is standing in should allow. | Whatever it was made of came before the rules about what bodies are made of. | Battle Qi capacity: +15% |
| `celestial_sovereign_body` | Read at a Glance | The shape of a thing is legible before it moves. | Read the way a constellation is read: not one bright thing, but the shape between them. | At encounter start: the creature's weakness is already known, without spending Observe |
| `chaos_immortal_body` | Nothing Settles | Too unfinished a thing to be countered cleanly. | It has not decided what it is yet, and it has had several centuries. | Path resistances against this body: bite less |
| `eternal_dragon_body` | Dragon Might | Every blow given or taken feeds it, and what it feeds keeps growing while the fight lasts. | Dragons do not get weaker. That is most of what makes them dragons. | At full stacks: a heightened state, and Transformation techniques gain an effect; Dealing or taking damage: builds Dragon Might; Each stack: strength and defence |
| `void_sovereign_body` | Nowhere to Strike | Distance is a suggestion, and so is being cornered. | Fights it loses are fights it was still standing at the end of. | A failed escape: may be attempted once more; Evasion: +14% |
| `heaven_and_earth_physique` | Weight of the World | Armour that cannot be argued all the way down. | A body that has agreed with the ground about which of them gives way. | Armour penetration against this body: cannot take defence below half; Healing below 30% HP: -3% |
| `infinite_immortal_body` | No Fixed Position | A killing blow lands where the body has already stopped being. | It is not that the blow misses. It is that there was nothing at the end of it. | Once a battle: a lethal blow leaves 1 HP and breaks the engagement instead; Space techniques: a chance to cost no Qi |
| `primordial_origin_body` | Nothing Refused | Every pillar advances, and none of them leads. | The body before anyone decided what a body was for. It can become anything, which is also the most that can be said for it. | Every realm crossed: two foundation stats rise permanently |
| `supreme_dao_physique` | Broad as the Dao | Paths that will not sit together sit together here. Half of what they take out of a refinement, this body absorbs. | It does nothing better than the body built for that one thing, and there is nothing it does badly. | **WIRED** |

---

## C — the eight new roots

Roots carry no flat rate bonuses in this game — all thirty-one have zero in
every rate column, and identity lives entirely in the Path package.

| code | Band | Name | Path package | Special | Special text | Description | Effect |
|---|---|---|---|---|---|---|---|
| `blade_decree_root` | Mythic | Blade Decree Root | sword 0.3500/0.2200 + rule 0.1700/0.1100 | The Cut Is the Law | What it severs stays severed, and argues about it afterwards with nobody. | A sword that cuts because it is entitled to, which is a different thing from cutting well. | A severed technique: cannot be resumed the same round |
| `dream_sea_root` | Mythic | Dream Sea Root | dream 0.3500/0.2200 + wisdom 0.1700/0.1100 | Night Study | What is understood while asleep is understood on waking, and the hours were going to pass anyway. | Sleep is not time lost to a cultivator who can work in it. | A dream realm: attainment in a Path pursued while asleep |
| `ten_thousand_flame_root` | Mythic | Ten Thousand Flame Root | fire 0.3500/0.2200 + refinement 0.1700/0.1100 | Every Fire Is One Fire | Flame answers whether it was lit for warmth, for war, or for the crucible. | Ten thousand fires, and the root has an opinion about every one of them. | Fire pages: hold together more readily in a refinement |
| `void_lattice_root` | Mythic | Void Lattice Root | space 0.3500/0.2200 + formation 0.1700/0.1100 | Gates Without Walls | Arrays laid across distance rather than across ground. | Space is not empty to this one. It is a structure, and structures have doors. | Formations: may be anchored at a distance; Travel: shorter than the map allows |
| `dao_ancestor_root` | Divine | Dao Ancestor Root | wisdom 0.4000/0.2500 + heaven 0.2000/0.1200 | Ancestral Comprehension | Insight into a Path comes faster than the hours spent on it can explain. | Not a mind that learns quickly. A mind that was already there when the thing was made. | Insight Dust: +8%; Manual previews: reveal one further flaw |
| `heaven_and_earth_root` | Divine | Heaven and Earth Root | earth 0.4000/0.2500 + heaven 0.2000/0.1200 | Unshifting Ground | A foundation that a failed step costs less to keep. | The oldest pairing there is. What it builds does not move, and neither does the cultivator. | Mining yield: +8%; Qi lost to a failed breakthrough: -4% |
| `heavens_will_root` | Divine | Heaven's Will Root | heaven 0.4000/0.2500 + rule 0.2000/0.1200 | Mandate of Heaven | The heavens are slower to punish what they arranged themselves. | Heaven does not speak. It arranges, and a cultivator carrying this is one of the arrangements. | Breakthrough backlash: reduced, never removed |
| `infinite_dao_root` | Divine | Infinite Dao Root | space 0.4000/0.2500 + heaven 0.2000/0.1200 | The Shorter Road | Ways through are found that were not there for anybody else. | Every road is shorter than it looks to whoever is holding the map. | Mismatched manual penalty: -12%; Secret realm clues: +8% |

---

## Where the walls are

Six rules the suite enforces. Everything else is yours.

| Rule | |
|---|---|
| Physique peak stat climbs by band | rare 1.15 < epic < legendary < mythic < divine ≤ extreme 1.40 |
| Physique whole package climbs by band | the sum of the three multipliers |
| Physique Path attainment climbs by band | epic 0.12 < legendary 0.20 < mythic 0.25 < divine 0.30 |
| Root Path attainment climbs by band | legendary 0.30 < mythic 0.35 < divine 0.40 < unique 0.50 |
| No two bodies rare-and-above make the same claim | commons may be plain and alike; above that a body is a reason to want it |
| No divine trait is silent | it does something, or it says what it will do |

Also: `affinity_path` set ⟺ a Path package exists. And no two roots within
two bands of each other may own the same pair of Paths — the rule that sent
Voidwalker Root back.

**Valid Path codes**

`blood` `bone` `dream` `earth` `enslavement` `fire` `food` `formation` `heaven`
`human` `ice` `illusion` `light` `lightning` `luck` `metal` `painting` `poison`
`qi` `refinement` `rule` `shadow` `soul` `space` `star` `strength` `sword`
`theft` `time` `transformation` `water` `wind` `wisdom` `wood`

No `moon`, no `sun`. Nearest homes are `light` and `fire`.

## Still thin or empty across the whole root roster

Paths no root touches at any band: `bone`, `enslavement`, `food`, `human`, `illusion`, `light`, `lightning`, `painting`, `poison`, `qi`, `shadow`, `soul`, `star`, `wind`.
