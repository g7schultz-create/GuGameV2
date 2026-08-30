"""Generates db/migrations/0003_seed_path_data.sql from the design spec's chart."""

import pathlib

OUT = (pathlib.Path(__file__).resolve().parent.parent
    / "db" / "migrations" / "0003_seed_path_data.sql"
)

# code, Name, category, uses_matchups, description
PATHS = [
    ("fire",           "Fire Path",           "combat",  True,  "Burning, consuming force."),
    ("water",          "Water Path",          "combat",  True,  "Flowing, adaptive force."),
    ("ice",            "Ice Path",            "combat",  True,  "Freezing stillness."),
    ("wood",           "Wood Path",           "combat",  True,  "Growth, vitality and life."),
    ("lightning",      "Lightning Path",      "combat",  True,  "Sudden, piercing speed."),
    ("earth",          "Earth Path",          "combat",  True,  "Weight, stability and mass."),
    ("metal",          "Metal Path",          "combat",  True,  "Hardness, edge and sharpness."),
    ("sword",          "Sword Path",          "combat",  True,  "The edge that severs all things."),
    ("strength",       "Strength Path",       "combat",  True,  "Raw physical might."),
    ("blood",          "Blood Path",          "combat",  True,  "Vitality drawn from blood and flesh."),
    ("soul",           "Soul Path",           "combat",  True,  "Attacks upon the spirit itself."),
    ("wisdom",         "Wisdom Path",         "combat",  True,  "Insight, deduction and stratagem."),
    ("space",          "Space Path",          "combat",  True,  "Distance, position and displacement."),
    ("time",           "Time Path",           "combat",  True,  "Acceleration, delay and sequence."),
    ("luck",           "Luck Path",           "combat",  True,  "Fortune bent toward the wielder."),
    ("refinement",     "Refinement Path",     "combat",  True,  "Purification and reforging."),
    ("formation",      "Formation Path",      "combat",  True,  "Arrays, wards and battlefield structure."),
    ("enslavement",    "Enslavement Path",    "combat",  True,  "Domination and control of others."),
    ("transformation", "Transformation Path", "combat",  True,  "Change of shape and nature."),
    ("theft",          "Theft Path",          "combat",  True,  "Taking what belongs to another."),
    ("poison",         "Poison Path",         "combat",  True,  "Corruption that spreads and lingers."),
    # Section 4: Human and Heaven have a special mutual interaction rather than
    # behaving like ordinary elemental Paths. They still sit in the chart.
    ("human",          "Human Path",          "special", True,  "The strength and cunning of humankind."),
    ("heaven",         "Heaven Path",         "special", True,  "The will of heaven and fate itself."),
    # Section 12: exotic Paths draw their value from unique mechanics, so they
    # sit outside the matchup chart until given deliberate interactions.
    ("qi",             "Qi Path",             "exotic",  False, "Manipulation of raw qi."),
    ("dream",          "Dream Path",          "exotic",  False, "Intrusion into sleep and illusion."),
    ("painting",       "Painting Path",       "exotic",  False, "Reality rendered and rewritten."),
    ("food",           "Food Path",           "exotic",  False, "Sustenance, flavour and nourishment."),
    ("rule",           "Rule Path",           "exotic",  False, "Law imposed upon reality."),
]

# From spec section 4. BOTH columns are attacker-perspective, so the entries are
# directed and independent - no reciprocity is implied or required.
CHART = {
    "fire":           (["wood", "ice", "poison"],                  ["water", "earth"]),
    "water":          (["fire", "lightning", "blood"],             ["ice", "earth"]),
    "ice":            (["water", "wood", "transformation"],        ["fire", "strength"]),
    "wood":           (["earth", "soul", "water"],                 ["fire", "poison"]),
    "lightning":      (["metal", "transformation", "soul"],        ["earth", "time"]),
    "earth":          (["lightning", "fire", "strength"],          ["wood", "space"]),
    "sword":          (["soul", "transformation", "formation"],    ["metal", "strength"]),
    "strength":       (["sword", "ice", "transformation"],         ["wisdom", "soul"]),
    "blood":          (["strength", "human", "wood"],              ["fire", "soul"]),
    "soul":           (["blood", "strength", "wisdom"],            ["sword", "lightning"]),
    "wisdom":         (["strength", "formation", "enslavement"],   ["soul", "luck"]),
    "space":          (["earth", "formation", "sword"],            ["time", "wisdom"]),
    "time":           (["space", "lightning", "transformation"],   ["wisdom", "luck"]),
    "luck":           (["wisdom", "time", "theft"],                ["human", "formation"]),
    "refinement":     (["metal", "poison", "formation"],           ["theft", "fire"]),
    "formation":      (["luck", "refinement", "enslavement"],      ["wisdom", "space"]),
    "enslavement":    (["strength", "soul", "human"],              ["wisdom", "formation"]),
    "transformation": (["wood", "enslavement", "poison"],          ["sword", "ice"]),
    "theft":          (["refinement", "formation", "human"],       ["luck", "wisdom"]),
    "poison":         (["wood", "blood", "enslavement"],           ["fire", "refinement"]),
    "human":          (["luck", "enslavement", "theft"],           ["blood", "heaven"]),
    # Heaven's "Weak Against" cell reads "Human / special counters" - a note
    # about bespoke rules, not an ordinary resistance, so nothing is seeded.
    "heaven":         (["human", "luck", "transformation"],        []),
}

# tier, code, Name, damage_bonus, resistance_bonus, insight_required
TIERS = [
    (0,  "uninitiated",               "Uninitiated",               "0.0000", "0.0000",          0),
    (1,  "ordinary",                  "Ordinary",                  "0.0000", "0.0000",          0),
    (2,  "expert",                    "Expert",                    "0.0300", "0.0000",       1000),
    (3,  "quasi_master",              "Quasi-Master",              "0.0600", "0.0000",       3000),
    (4,  "master",                    "Master",                    "0.1000", "0.0000",       8000),
    (5,  "quasi_grandmaster",         "Quasi-Grandmaster",         "0.1500", "0.0000",      20000),
    (6,  "grandmaster",               "Grandmaster",               "0.2000", "0.1000",      50000),
    (7,  "quasi_great_grandmaster",   "Quasi-Great Grandmaster",   "0.2700", "0.1000",     120000),
    (8,  "great_grandmaster",         "Great Grandmaster",         "0.3500", "0.1500",     300000),
    (9,  "quasi_supreme_grandmaster", "Quasi-Supreme Grandmaster", "0.4500", "0.1500",     750000),
    (10, "supreme_grandmaster",       "Supreme Grandmaster",       "0.6000", "0.2500",    2000000),
]

INTERACTIONS = [
    ("major_advantage", "Major Advantage",         "0.5000",  1),
    ("advantage",       "Advantage",               "0.2500",  2),
    ("neutral",         "Neutral",                 "0.0000",  3),
    ("resistance",      "Resistance",             "-0.2000",  4),
]

CONFIG = [
    ("matchup_bonus_cap", "0.50",
     "Maximum total matchup bonus a single technique can receive (spec 5)."),
    ("matchup_penalty_floor", "-0.50",
     "PLACEHOLDER - floor on total matchup penalty. Not specified; mirrors the cap."),
    ("path_cultivation_xp_rate", "0.85",
     "Cultivation XP multiplier when cultivating toward a specific Path (spec 10)."),
    ("path_physique_xp_rate", "0.80",
     "Physique XP multiplier when training toward a specific Path (spec 11)."),
    ("dual_path_primary_weight", "0.50",
     "Default weight of a dual-Path technique's primary Path. 0.50 = simple average (spec 5)."),
]


def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"


def main() -> None:
    lines: list[str] = []
    w = lines.append

    w("-- 0003_seed_path_data")
    w("--")
    w("-- Reference data for the Path system: the Paths themselves, the matchup")
    w("-- chart from design spec section 4, attainment tiers from section 1, and the")
    w("-- global tunables sections 5/10/11 call out.")
    w("--")
    w("-- GENERATED - see scratchpad/gen_seed.py. Values marked PLACEHOLDER are not")
    w("-- specified by the design doc and exist to be tuned.")
    w("--")
    w("-- Forward-only. Rebalancing later means a new migration with UPDATEs, not an")
    w("-- edit to this file (the runner checksums applied files and will refuse).")
    w("")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- Matchup interaction magnitudes (spec section 3)")
    w("-- ---------------------------------------------------------------------------")
    w("-- Deliberately NOT Pokemon's 2x: with attainment, Dao Marks, equipment, Gu,")
    w("-- physiques and crits all stacking, doubling would dominate every other system.")
    w("")
    w("INSERT INTO matchup_interactions (code, name, damage_modifier, sort_order) VALUES")
    rows = [f"    ({q(c)}, {q(n)}, {m}, {o})" for c, n, m, o in INTERACTIONS]
    w(",\n".join(rows) + ";")
    w("")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- Paths")
    w("-- ---------------------------------------------------------------------------")
    w("")
    w("INSERT INTO paths (code, name, category, uses_matchups, description, sort_order) VALUES")
    rows = [
        f"    ({q(c)}, {q(n)}, {q(cat)}, {'TRUE ' if um else 'FALSE'}, {q(d)}, {i * 10})"
        for i, (c, n, cat, um, d) in enumerate(PATHS, start=1)
    ]
    w(",\n".join(rows) + ";")
    w("")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- Path matchup chart (spec section 4)")
    w("-- ---------------------------------------------------------------------------")
    w("-- Directed attacker -> defender. Neutral pairings are absent rows, not stored")
    w("-- zeroes. Every Path gets ~3 advantages and ~2 resistances so no single type is")
    w("-- strictly best, which is what makes covering several Paths worth the effort.")
    w("--")
    w("-- NOTE: Metal appears only as a DEFENDER in the design chart (Lightning and")
    w("-- Refinement beat it; it resists Sword). It has no attacking row of its own, so")
    w("-- Metal techniques are currently neutral into everything. Add its offensive")
    w("-- matchups in a later migration once decided.")
    w("")
    w("INSERT INTO path_matchups (attacker_path, defender_path, interaction) VALUES")

    entries: list[tuple[str, str, str]] = []
    for attacker, (strong, weak) in CHART.items():
        for defender in strong:
            entries.append((attacker, defender, "advantage"))
        for defender in weak:
            entries.append((attacker, defender, "resistance"))

    seen = set()
    for a, d, _ in entries:
        assert a != d, f"reflexive matchup {a}"
        assert (a, d) not in seen, f"duplicate pair {a}->{d}"
        seen.add((a, d))
    known = {p[0] for p in PATHS}
    for a, d, _ in entries:
        assert a in known, f"unknown attacker {a}"
        assert d in known, f"unknown defender {d}"

    grouped: list[str] = []
    for attacker, (strong, weak) in CHART.items():
        grouped.append(f"    -- {attacker}")
        for defender in strong:
            grouped.append(f"    ({q(attacker)}, {q(defender)}, 'advantage'),")
        for defender in weak:
            grouped.append(f"    ({q(attacker)}, {q(defender)}, 'resistance'),")
    grouped[-1] = grouped[-1].rstrip(",") + ";"
    w("\n".join(grouped))
    w("")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- Attainment tiers (spec section 1)")
    w("-- ---------------------------------------------------------------------------")
    w("-- damage_bonus is taken verbatim from the design doc's scaling table.")
    w("--")
    w("-- resistance_bonus: only the Grandmaster value (+10%) is specified, by the")
    w("-- section 8 example. Higher tiers are PLACEHOLDER.")
    w("--")
    w("-- insight_required: entirely PLACEHOLDER - the doc gives no curve. Roughly")
    w("-- 2.5x per tier so each rank costs meaningfully more than the last. Expect to")
    w("-- retune once there are real numbers for insight per hour of cultivation.")
    w("")
    w("INSERT INTO attainment_tiers (tier, code, name, damage_bonus, resistance_bonus, insight_required) VALUES")
    rows = [
        f"    ({t:2d}, {q(c) + ',':<29} {q(n) + ',':<31} {dmg}, {res}, {ins:>9})"
        for t, c, n, dmg, res, ins in TIERS
    ]
    w(",\n".join(rows) + ";")
    w("")
    w("")
    w("-- ---------------------------------------------------------------------------")
    w("-- Global tunables")
    w("-- ---------------------------------------------------------------------------")
    w("")
    w("INSERT INTO game_config (key, value, description) VALUES")
    rows = [f"    ({q(k)}, {v}, {q(d)})" for k, v, d in CONFIG]
    w(",\n".join(rows) + ";")
    w("")

    OUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {OUT}")
    print(f"  {len(PATHS)} paths, {len(entries)} matchups, {len(TIERS)} tiers, {len(CONFIG)} config keys")


if __name__ == "__main__":
    main()
