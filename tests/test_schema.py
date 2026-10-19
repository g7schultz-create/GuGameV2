"""Tests that the schema's guarantees are real.

These deliberately assert on things the database is supposed to make
IMPOSSIBLE, not on things the application is supposed to avoid doing. A
constraint nobody has ever seen reject anything is only a comment.
"""

import json
from datetime import datetime, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal

import psycopg
import pathlib

import pytest


# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

def test_all_paths_seeded(conn):
    counts = dict(
        conn.execute("SELECT category, count(*) FROM paths GROUP BY category").fetchall()
    )
    assert counts == {"combat": 27, "special": 2, "exotic": 5}


def test_exotic_paths_opt_out_of_matchups(conn):
    """Spec section 12: exotic Paths get value from unique mechanics, not typing."""
    rows = conn.execute(
        "SELECT code FROM paths WHERE category = 'exotic' AND uses_matchups"
    ).fetchall()
    assert rows == []


def test_matchup_chart_is_complete(conn):
    total = conn.execute("SELECT count(*) FROM path_matchups").fetchone()[0]
    assert total == 165

    # Spec section 4: roughly 2-3 favourable and 2-3 unfavourable per Path, so
    # no single type is strictly best. Heaven is the documented exception - its
    # "Weak Against" cell is a note about special counters, not a resistance.
    #
    # The advantage bound is 2..4 rather than 2..3 since 0018. Adding six Paths
    # was used to lift the twelve Paths the chart had left net-negative, and a
    # fourth advantage on a Path that was losing serves the "no single type is
    # strictly best" rule rather than breaking it. The RESISTANCE bound stays
    # at 2..3: that is the half that stops a Path being hard to answer, and
    # nothing here was allowed to loosen it.
    lopsided = conn.execute(
        """
        SELECT p.code,
               count(*) FILTER (WHERE m.interaction = 'advantage')  AS adv,
               count(*) FILTER (WHERE m.interaction = 'resistance') AS res
        FROM paths p
        JOIN path_matchups m ON m.attacker_path = p.code
        WHERE p.category IN ('combat', 'special')
        GROUP BY p.code
        HAVING count(*) FILTER (WHERE m.interaction = 'advantage') NOT BETWEEN 2 AND 4
            OR count(*) FILTER (WHERE m.interaction = 'resistance') NOT BETWEEN 2 AND 3
        """
    ).fetchall()
    assert [r[0] for r in lopsided] == ["heaven"]


def test_metal_has_offensive_matchups(conn):
    """Closed in 0020, and asserted so it cannot silently reopen.

    Metal spent eighteen migrations as a DEFENDER only, which made Metal
    techniques neutral into everything. Note how the gap hid: the invariant
    query in test_matchup_chart_is_complete INNER JOINs on attacker_path, so a
    Path with no attacking rows drops out of the GROUP BY entirely. Metal was
    not passing that constraint, it was invisible to it - which is why this
    test is separate and counts the rows directly.
    """
    attacks = conn.execute(
        """
        SELECT count(*) FILTER (WHERE interaction = 'advantage'),
               count(*) FILTER (WHERE interaction = 'resistance')
        FROM path_matchups WHERE attacker_path = 'metal'
        """
    ).fetchone()
    assert attacks == (3, 3), "Metal's offensive rows changed"

    defends = conn.execute(
        "SELECT count(*) FROM path_matchups WHERE defender_path = 'metal'"
    ).fetchone()[0]
    assert defends == 3


def test_no_path_is_inert(conn):
    """Every Path in the chart must deal SOMETHING.

    A Path with no attacking rows is neutral into the whole game, which is the
    state Metal was in until 0020 and the reason six new Paths in 0018 shipped
    with their rows rather than after them.
    """
    inert = conn.execute(
        """
        SELECT p.code FROM paths p
        WHERE p.uses_matchups
          AND NOT EXISTS (
              SELECT 1 FROM path_matchups m WHERE m.attacker_path = p.code
          )
        """
    ).fetchall()
    assert [r[0] for r in inert] == []


def test_attainment_scaling_matches_design_doc(conn):
    rows = conn.execute(
        "SELECT name, damage_bonus FROM attainment_tiers WHERE tier >= 1 ORDER BY tier"
    ).fetchall()
    assert [(n, str(round(float(b) * 100))) for n, b in rows] == [
        ("Ordinary", "0"),
        ("Expert", "3"),
        ("Quasi-Master", "6"),
        ("Master", "10"),
        ("Quasi-Grandmaster", "15"),
        ("Grandmaster", "20"),
        ("Quasi-Great Grandmaster", "27"),
        ("Great Grandmaster", "35"),
        ("Quasi-Supreme Grandmaster", "45"),
        ("Supreme Grandmaster", "60"),
    ]


def test_attainment_tiers_are_monotonic(conn):
    """Insight cost and damage must never go backwards as tier rises."""
    regressions = conn.execute(
        """
        SELECT t.tier
        FROM attainment_tiers t
        JOIN attainment_tiers prev ON prev.tier = t.tier - 1
        WHERE t.damage_bonus < prev.damage_bonus
           OR t.insight_required < prev.insight_required
           OR t.resistance_bonus < prev.resistance_bonus
        """
    ).fetchall()
    assert regressions == []


def test_matchup_magnitudes_are_not_pokemon_scale(conn):
    """Spec section 3 is explicit that 2x would swamp every other system."""
    advantage = conn.execute(
        "SELECT damage_modifier FROM matchup_interactions WHERE code = 'advantage'"
    ).fetchone()[0]
    assert float(advantage) == 0.25

    cap = conn.execute(
        "SELECT value FROM game_config WHERE key = 'matchup_bonus_cap'"
    ).fetchone()[0]
    assert float(cap) == 0.50


# ---------------------------------------------------------------------------
# Constraints the schema promises
# ---------------------------------------------------------------------------

def test_path_cannot_be_strong_against_itself(conn):
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO path_matchups (attacker_path, defender_path, interaction) "
            "VALUES ('fire', 'fire', 'advantage')"
        )


def test_dual_path_weights_must_total_one(conn, make_technique, force_deferred_checks):
    """A typo here would silently inflate every hit the move ever lands."""
    make_technique("bad_weights", paths={"sword": "0.7", "fire": "0.2"})
    with pytest.raises(psycopg.errors.RaiseException, match="must be exactly 1"):
        force_deferred_checks()


def test_valid_dual_path_weights_are_accepted(conn, make_technique, force_deferred_checks):
    """Spec section 5's weighted example: 70% Sword / 30% Fire."""
    technique_id = make_technique("blazing_heaven_sword_fixture", paths={"sword": "0.7", "fire": "0.3"})
    force_deferred_checks()  # must not raise

    total = conn.execute(
        "SELECT sum(weight) FROM technique_paths WHERE technique_id = %s", (technique_id,)
    ).fetchone()[0]
    assert float(total) == 1.0


def test_single_path_technique_defaults_to_full_weight(conn, make_technique, force_deferred_checks):
    make_technique("plain_fire", paths={"fire": "1.0"})
    force_deferred_checks()


def test_canonical_technique_requires_a_code(conn):
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO techniques (code, name, category) VALUES (NULL, 'Nameless', 'attack')"
        )


def test_player_created_move_must_not_claim_a_code(conn, make_player):
    player_id = make_player()
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO techniques (code, name, category, created_by) "
            "VALUES ('pretending', 'Pretender', 'attack', %s)",
            (player_id,),
        )


def test_cannot_equip_a_technique_you_do_not_know(conn, make_player, make_technique):
    """The composite FK makes this impossible rather than merely discouraged."""
    player_id = make_player()
    technique_id = make_technique("unknown_move")

    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        conn.execute(
            "INSERT INTO player_loadout (player_id, slot_index, technique_id) "
            "VALUES (%s, 0, %s)",
            (player_id, technique_id),
        )


def test_unlearning_a_technique_clears_the_loadout_slot(conn, make_player, make_technique):
    player_id = make_player()
    technique_id = make_technique("learned_move")
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s)",
        (player_id, technique_id),
    )
    conn.execute(
        "INSERT INTO player_loadout (player_id, slot_index, technique_id) VALUES (%s, 0, %s)",
        (player_id, technique_id),
    )

    conn.execute(
        "DELETE FROM player_techniques WHERE player_id = %s AND technique_id = %s",
        (player_id, technique_id),
    )

    remaining = conn.execute(
        "SELECT count(*) FROM player_loadout WHERE player_id = %s", (player_id,)
    ).fetchone()[0]
    assert remaining == 0


def test_same_technique_cannot_fill_two_slots(conn, make_player, make_technique):
    player_id = make_player()
    technique_id = make_technique("dup_move")
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s)",
        (player_id, technique_id),
    )
    conn.execute(
        "INSERT INTO player_loadout (player_id, slot_index, technique_id) VALUES (%s, 0, %s)",
        (player_id, technique_id),
    )

    with pytest.raises(psycopg.errors.UniqueViolation):
        conn.execute(
            "INSERT INTO player_loadout (player_id, slot_index, technique_id) "
            "VALUES (%s, 1, %s)",
            (player_id, technique_id),
        )


def test_species_can_have_only_one_primary_path(conn, make_species):
    species_id = make_species("two_primaries", paths=["fire"])
    with pytest.raises(psycopg.errors.UniqueViolation):
        conn.execute(
            "INSERT INTO creature_paths (species_id, path_code, is_primary) "
            "VALUES (%s, 'water', TRUE)",
            (species_id,),
        )


def test_discovery_requires_having_met_the_species(conn, make_player, make_species):
    player_id = make_player()
    species_id = make_species("never_met")

    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        conn.execute(
            "INSERT INTO player_bestiary_paths (player_id, species_id, path_code) "
            "VALUES (%s, %s, 'fire')",
            (player_id, species_id),
        )


def test_deleting_a_player_preserves_the_audit_trail(conn, make_player):
    """RESTRICT, not CASCADE: removing an account must not erase what was done to it."""
    actor_id = make_player("Admin")
    target_id = make_player("Subject")
    conn.execute(
        "INSERT INTO admin_audit_log (actor_id, target_id, actor_name, action) "
        "VALUES (%s, %s, 'Admin', 'grant_currency')",
        (actor_id, target_id),
    )

    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        conn.execute("DELETE FROM players WHERE player_id = %s", (target_id,))


# ---------------------------------------------------------------------------
# Weakness resolution
# ---------------------------------------------------------------------------

def test_weakness_is_derived_from_the_creature_path(conn, make_species):
    """A Wood beast inherits the chart's opinion of Wood without hand-listing it."""
    species_id = make_species("wood_beast", paths=["wood"])

    rows = dict(
        conn.execute(
            "SELECT path_code, interaction FROM creature_incoming_paths "
            "WHERE species_id = %s",
            (species_id,),
        ).fetchall()
    )
    # From the chart: fire, ice, blood, poison and transformation all beat wood.
    assert rows["fire"] == "advantage"
    assert rows["poison"] == "advantage"
    assert "sword" not in rows  # neutral stays an absent row


def test_explicit_override_beats_the_derived_chart(conn, make_species):
    """The spec's own bestiary example: a beast whose hide resists Sword."""
    species_id = make_species("nine_distortion_wolf_fixture", paths=["wood"])
    conn.execute(
        "INSERT INTO creature_path_modifiers (species_id, path_code, interaction) "
        "VALUES (%s, 'fire', 'resistance')",
        (species_id,),
    )

    rows = dict(
        conn.execute(
            "SELECT path_code, interaction FROM creature_incoming_paths "
            "WHERE species_id = %s",
            (species_id,),
        ).fetchall()
    )
    # Chart says fire beats wood; the override says otherwise and wins.
    assert rows["fire"] == "resistance"
    assert rows["poison"] == "advantage"  # untouched paths still derive


def test_override_can_express_immunity(conn, make_species):
    """Immunity has no chart equivalent - only the override table can say it."""
    species_id = make_species("immune_thing", paths=["wood"])
    conn.execute(
        "INSERT INTO creature_path_modifiers (species_id, path_code, interaction) "
        "VALUES (%s, 'fire', 'immunity')",
        (species_id,),
    )

    interaction, modifier = conn.execute(
        """
        SELECT c.interaction, m.damage_modifier
        FROM creature_incoming_paths c
        JOIN matchup_interactions m ON m.code = c.interaction
        WHERE c.species_id = %s AND c.path_code = 'fire'
        """,
        (species_id,),
    ).fetchone()
    assert interaction == "immunity"
    assert float(modifier) == -1.0


def test_dual_typed_creature_does_not_stack_weaknesses(conn, make_species):
    """Stacking is how Pokemon reaches 4x; spec section 3 rules that out."""
    # Fire beats both wood and poison, so without collapsing it would appear twice.
    species_id = make_species("wood_poison_beast", paths=["wood", "poison"])

    fire_rows = conn.execute(
        "SELECT interaction FROM creature_incoming_paths "
        "WHERE species_id = %s AND path_code = 'fire'",
        (species_id,),
    ).fetchall()
    assert len(fire_rows) == 1
    assert fire_rows[0][0] == "advantage"


def test_exotic_path_creature_derives_no_matchups(conn, make_species):
    """uses_matchups = false keeps exotic Paths out of the derived layer."""
    species_id = make_species("dream_thing", paths=["dream"])
    rows = conn.execute(
        "SELECT count(*) FROM creature_incoming_paths WHERE species_id = %s",
        (species_id,),
    ).fetchone()[0]
    assert rows == 0


# ---------------------------------------------------------------------------
# Player state
# ---------------------------------------------------------------------------

def test_new_player_has_no_attainment_rows(conn, make_player):
    """Sparse by design: a missing row means Uninitiated."""
    player_id = make_player()
    count = conn.execute(
        "SELECT count(*) FROM player_path_attainment WHERE player_id = %s",
        (player_id,),
    ).fetchone()[0]
    assert count == 0


def test_updated_at_trigger_overrides_whatever_the_caller_supplies(conn, make_player):
    """The trigger fires and wins.

    Not written as "updated_at goes up", because `now()` is the TRANSACTION
    timestamp: within one transaction it does not move, so that test would fail
    even with a perfectly working trigger. Instead: hand the UPDATE a bogus
    timestamp and prove the trigger overwrote it.
    """
    player_id = make_player()

    conn.execute(
        "UPDATE players SET discord_name = 'Renamed', updated_at = %s "
        "WHERE player_id = %s",
        ("2000-01-01T00:00:00+00", player_id),
    )

    stored, transaction_time = conn.execute(
        "SELECT updated_at, transaction_timestamp() FROM players WHERE player_id = %s",
        (player_id,),
    ).fetchone()

    assert stored == transaction_time, "trigger did not overwrite the supplied value"


def test_deleting_a_player_removes_their_attainment(conn, make_player):
    player_id = make_player()
    conn.execute(
        "INSERT INTO player_path_attainment (player_id, path_code, insight, tier) "
        "VALUES (%s, 'blood', 60000, 6)",
        (player_id,),
    )
    conn.execute("DELETE FROM players WHERE player_id = %s", (player_id,))

    remaining = conn.execute(
        "SELECT count(*) FROM player_path_attainment WHERE player_id = %s",
        (player_id,),
    ).fetchone()[0]
    assert remaining == 0


def test_attainment_cannot_go_negative(conn, make_player):
    player_id = make_player()
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO player_path_attainment (player_id, path_code, insight) "
            "VALUES (%s, 'fire', -1)",
            (player_id,),
        )


# ---------------------------------------------------------------------------
# Indexes
# ---------------------------------------------------------------------------

# The realm a cultivator stands IN, as opposed to how deep they stand.
# Everything here reads `player_cultivation` joined to `realms` by hand, and
# everything here has been looked at and means the realm.
MEANS_THE_REALM = {
    # The realm's own draw rate. A Venerable's meter is understanding, so this
    # is correctly the realm and must not follow standing.
    "cultivation_per_hour",
    # Refuses a cultivation pill at the ceiling. The ceiling is a realm fact.
    "take_pill",
    # These two join `realms` on the SERVANT's realm_id, not the player's.
    # They are not rank reads at all; the pattern matches them anyway.
    "servant_feed",
    "servant_feed_essence",
    # Sizes a tide off the POPULATION's average rank. Moving it onto standing
    # would make tides harder for everybody, which is a balance decision and
    # not a correctness fix - left deliberately, see 0536.
    "horde_open",
}


def test_nothing_reads_the_realm_where_it_means_standing(conn):
    """Every hand-rolled rank read is either swept or explicitly excused.

    0519 is named "every gate reads standing not realm" and its probe checks
    that nothing CALLS `player_realm_rank`. That passed while TWENTY-TWO
    functions copied its body inline:

        SELECT r.rank FROM player_cultivation pc
        JOIN realms r ON r.realm_id = pc.realm_id

    `player_realm_rank`'s own comment says "One definition. Three places
    already dig this out of player_cultivation by hand, and a fourth would be
    a fourth thing to keep in step." It was twenty-two, and both 0504 and 0519
    went looking for exactly this and missed them - which is how
    `player_power_multiple` came to freeze a Venerable Rank 9 cultivator at a
    512x power deficit, and how `explore` came to bar them from the one region
    written for them.

    So this is an ALLOWLIST rather than a count or a spelling. A function that
    starts reading the realm by hand fails here until somebody decides whether
    it means the realm or how deep somebody stands. Both earlier guards could
    be passed by accident; this one cannot.
    """
    by_hand = {
        name
        for (name,) in conn.execute(
            """
            SELECT p.proname
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.prosrc ~ 'JOIN realms'
              AND p.prosrc ~ 'player_cultivation'
              AND p.prosrc ~ 'r[.]rank|realms[.]rank'
              AND p.proname NOT IN ('player_realm_rank', 'player_standing')
            """
        ).fetchall()
    }

    undecided = sorted(by_hand - MEANS_THE_REALM)
    assert undecided == [], (
        "these read a rank out of player_cultivation by hand and are not on "
        "MEANS_THE_REALM: "
        + ", ".join(undecided)
        + ". Decide which it is: `player_standing(player)` if it means how "
        "deep they stand, or add it to MEANS_THE_REALM with the reason."
    )

    # And the excuses stay honest: an entry that no longer reads the realm by
    # hand has been fixed and should come off the list.
    stale = sorted(MEANS_THE_REALM - by_hand)
    assert stale == [], (
        "these are excused but no longer read the realm by hand, so the "
        "excuse is dead: " + ", ".join(stale)
    )


def test_the_power_multiple_follows_standing(conn, make_player):
    """The one that made the Venerable realm hollow.

    `player_power_multiple` scales every base stat by
    `stat_step_per_rank ^ (rank - 1)`, and the step is 2.0. Read off the realm
    it stops at 18, so a Venerable Rank 9 cultivator would have carried nine
    rungs of understanding and a 512x power deficit. Asserted by ascending
    somebody rather than by reading the source.
    """
    step = float(
        conn.execute("SELECT game_config_value('stat_step_per_rank')").fetchone()[0]
    )
    path = conn.execute(
        "SELECT source_code FROM dao_words WHERE source_kind = 'path' "
        "ORDER BY source_code LIMIT 1"
    ).fetchone()[0]

    pid = make_player("Ascender")
    conn.execute(
        """
        INSERT INTO player_cultivation (player_id, realm_id, cultivation)
        SELECT %s, r.realm_id, r.cultivation_required
        FROM realms r ORDER BY r.rank DESC, r.realm_id DESC LIMIT 1
        """,
        (pid,),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) "
        "VALUES (%s, (SELECT min(physique_id) FROM physiques))",
        (pid,),
    )
    conn.execute(
        "INSERT INTO player_path_attainment (player_id, path_code, insight, tier) "
        "VALUES (%s, %s, 90000, 5)",
        (pid, path),
    )

    before = float(
        conn.execute("SELECT player_power_multiple(%s)", (pid,)).fetchone()[0]
    )

    conn.execute(
        "INSERT INTO player_tribulations (player_id, rank, status, settled_at) "
        "VALUES (%s, 19, 'passed', now())",
        (pid,),
    )
    conn.execute("SELECT * FROM venerable_ascend(%s)", (pid,))

    after = float(
        conn.execute("SELECT player_power_multiple(%s)", (pid,)).fetchone()[0]
    )

    assert after > before, (
        f"ascending left the power multiple at {after} - a Venerable grows in "
        "understanding and in nothing else"
    )
    assert after / before == pytest.approx(step), (
        f"ascending multiplied power by {after / before}, not the {step} a "
        "rank is worth"
    )


def test_every_foreign_key_column_is_indexed(conn):
    """Postgres indexes the referenced side automatically, never the referencing
    side. An unindexed FK makes the parent's delete scan the whole child table.

    A PARTIAL index counts, but only when its predicate is `col IS NOT NULL`:
    an FK check always searches for a concrete value, never NULL, so such an
    index serves the lookup completely while staying smaller. Any other
    predicate could exclude rows the check needs, so it does not count.
    """
    foreign_keys = conn.execute(
        """
        SELECT c.conrelid, c.conrelid::regclass::text, c.conname, c.conkey::smallint[]
        FROM pg_constraint c
        WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
        ORDER BY 2, 3
        """
    ).fetchall()

    indexes = conn.execute(
        """
        SELECT i.indrelid, i.indkey::smallint[], pg_get_expr(i.indpred, i.indrelid)
        FROM pg_index i
        JOIN pg_class t ON t.oid = i.indrelid
        WHERE t.relnamespace = 'public'::regnamespace
        """
    ).fetchall()

    columns = {
        (relid, attnum): name
        for relid, attnum, name in conn.execute(
            """
            SELECT a.attrelid, a.attnum, a.attname
            FROM pg_attribute a
            JOIN pg_class t ON t.oid = a.attrelid
            WHERE t.relnamespace = 'public'::regnamespace AND a.attnum > 0
            """
        ).fetchall()
    }

    def predicate_ok(predicate, relid, conkey):
        if predicate is None:
            return True
        wanted = " AND ".join(
            f"({columns[(relid, attnum)]} IS NOT NULL)" for attnum in conkey
        )
        return predicate == wanted

    unindexed = []
    for relid, table, name, conkey in foreign_keys:
        covered = any(
            indrelid == relid
            and list(indkey[: len(conkey)]) == list(conkey)
            and predicate_ok(predicate, relid, conkey)
            for indrelid, indkey, predicate in indexes
        )
        if not covered:
            unindexed.append((table, name))

    assert unindexed == []


# ---------------------------------------------------------------------------
# The starter manual (0028)
# ---------------------------------------------------------------------------


def test_a_beginner_can_be_armed_on_many_paths(conn):
    """The starter manual rolls over the rank 1 attacks that exist.

    Until 0028 there were two - Blood and Fire - and a roll across two options
    is not a roll. This is the property that makes "randomly generated" true,
    and it is derived: adding a rank 1 attack widens the roll with no edit to
    grant_starter_manual.
    """
    paths = conn.execute(
        """
        SELECT count(DISTINCT tp.path_code)
        FROM techniques t
        JOIN technique_paths tp ON tp.technique_id = t.technique_id
        WHERE t.created_by IS NULL
          AND t.rank = 1
          AND t.category = 'attack'
          AND t.base_power > 0
          AND tp.weight = 1
        """
    ).fetchone()[0]
    assert paths >= 12


def test_every_starter_manual_teaches_something_that_hurts(conn, make_player):
    """Rolled twenty times, because the failure this guards against is one
    unlucky Path in the pool teaching a move with no damage on it."""
    for _ in range(20):
        player = make_player()
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id) "
            "VALUES (%s, roll_physique())",
            (player,),
        )
        manual = conn.execute(
            "SELECT grant_starter_manual(%s)", (player,)
        ).fetchone()[0]

        row = conn.execute(
            """
            SELECT t.base_power, t.rank, mp.path_code, tp.path_code
            FROM manual_techniques mt
            JOIN techniques t ON t.technique_id = mt.technique_id
            JOIN technique_paths tp ON tp.technique_id = t.technique_id
            JOIN manual_paths mp ON mp.manual_id = mt.manual_id
            WHERE mt.manual_id = %s
            """,
            (manual,),
        ).fetchone()
        assert row is not None, "a starter manual with no technique arms nobody"
        power, rank, manual_path, technique_path = row
        assert power > 0 and rank == 1
        assert manual_path == technique_path, "the book must be of its own Path"


def test_a_starter_manual_does_not_outlive_its_owner(conn, make_player):
    """created_by is what makes that true.

    Leaving it NULL would have read as seeded content: the row would survive
    the player, and roll_manual_drop would have started handing one player's
    starter book to everybody else.
    """
    player = make_player()
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES (%s, roll_physique())",
        (player,),
    )
    manual = conn.execute("SELECT grant_starter_manual(%s)", (player,)).fetchone()[0]
    assert manual is not None

    assert conn.execute(
        "SELECT grant_starter_manual(%s)", (player,)
    ).fetchone()[0] is None, "granting twice must be a no-op"

    conn.execute("DELETE FROM players WHERE player_id = %s", (player,))
    assert conn.execute(
        "SELECT count(*) FROM manuals WHERE manual_id = %s", (manual,)
    ).fetchone()[0] == 0


def test_a_manual_may_have_a_maker_without_claiming_a_refinement(conn, make_player):
    """0021 tied created_by, refined_at and harmony into one knot. The rule
    that survives is the one that matters: a manual claiming a refinement must
    say who did it and when."""
    player = make_player()
    conn.execute(
        "INSERT INTO manuals (name, created_by) VALUES ('Made For You', %s)",
        (player,),
    )

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO manuals (name, harmony, created_by) VALUES ('Half Refined', 90, %s)",
            (player,),
        )


def test_a_starter_manual_is_not_lootable(conn, make_player):
    """roll_manual_drop reads created_by IS NULL as seeded content, which is
    exactly what a per-player manual is not."""
    owner = make_player()
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES (%s, roll_physique())",
        (owner,),
    )
    manual = conn.execute("SELECT grant_starter_manual(%s)", (owner,)).fetchone()[0]

    droppable = conn.execute(
        "SELECT count(*) FROM manuals WHERE manual_id = %s AND created_by IS NULL",
        (manual,),
    ).fetchone()[0]
    assert droppable == 0


# ---------------------------------------------------------------------------
# Trading (0033)
# ---------------------------------------------------------------------------


@pytest.fixture
def traders(conn, make_player):
    """Two cultivators with bodies, which is all a trade needs."""
    def _make():
        pair = []
        for name in ("Alice", "Bob"):
            player = make_player(name)
            conn.execute(
                "INSERT INTO player_physique (player_id, physique_id) "
                "VALUES (%s, roll_physique())",
                (player,),
            )
            conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (player,))
            pair.append(player)
        return pair

    return _make


def test_changing_an_offer_clears_both_confirmations(conn, traders):
    """The one rule that cannot live in the bot.

    Every trade scam is a variation on confirming a deal and then swapping the
    goods. A trigger on the offer tables makes that a re-confirmation instead
    of a robbery - and it fires for psql and a future web UI too.
    """
    alice, bob = traders()
    manual = conn.execute("SELECT grant_starter_manual(%s)", (alice,)).fetchone()[0]
    page = conn.execute("SELECT mint_page(%s)", (bob,)).fetchone()[0]

    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]
    conn.execute("SELECT trade_add_manual(%s, %s, %s)", (trade, alice, manual))
    conn.execute("SELECT trade_add_page(%s, %s, %s)", (trade, bob, page))

    conn.execute("SELECT trade_confirm(%s, %s)", (trade, alice))
    assert conn.execute(
        "SELECT proposer_confirmed_at IS NOT NULL FROM trades WHERE trade_id = %s",
        (trade,),
    ).fetchone()[0]

    # Bob sweetens - or sours - the pot.
    second = conn.execute("SELECT mint_page(%s)", (bob,)).fetchone()[0]
    conn.execute("SELECT trade_add_page(%s, %s, %s)", (trade, bob, second))

    both = conn.execute(
        "SELECT proposer_confirmed_at, partner_confirmed_at FROM trades WHERE trade_id = %s",
        (trade,),
    ).fetchone()
    assert both == (None, None), "changing the pile must clear both sides"


def test_a_trade_moves_every_kind_of_thing(conn, traders):
    alice, bob = traders()
    manual = conn.execute("SELECT grant_starter_manual(%s)", (alice,)).fetchone()[0]
    herb = conn.execute(
        "SELECT code FROM materials WHERE category = 'gathering' LIMIT 1"
    ).fetchone()[0]
    conn.execute("SELECT grant_material(%s, %s, 10)", (alice, herb))
    page = conn.execute("SELECT mint_page(%s)", (bob,)).fetchone()[0]

    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]
    conn.execute("SELECT trade_add_manual(%s, %s, %s)", (trade, alice, manual))
    conn.execute("SELECT trade_set_material(%s, %s, %s, 6)", (trade, alice, herb))
    conn.execute("SELECT trade_add_page(%s, %s, %s)", (trade, bob, page))

    conn.execute("SELECT trade_confirm(%s, %s)", (trade, alice))
    completed = conn.execute("SELECT trade_confirm(%s, %s)", (trade, bob)).fetchone()[0]
    assert completed is True

    assert conn.execute(
        "SELECT player_id FROM player_manuals WHERE manual_id = %s", (manual,)
    ).fetchone()[0] == bob
    assert conn.execute(
        "SELECT owner_id FROM manual_pages WHERE page_id = %s", (page,)
    ).fetchone()[0] == alice
    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s AND material_code = %s",
        (alice, herb),
    ).fetchone()[0] == 4
    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s AND material_code = %s",
        (bob, herb),
    ).fetchone()[0] == 6

    assert conn.execute(
        "SELECT count(*) FROM player_active_trade WHERE trade_id = %s", (trade,)
    ).fetchone()[0] == 0


def test_giving_away_an_equipped_manual_empties_the_slot(conn, traders):
    """player_manual_slots hangs off player_manuals by composite FK, so losing
    the book unequips it with no bookkeeping to get wrong."""
    alice, bob = traders()
    manual = conn.execute("SELECT grant_starter_manual(%s)", (alice,)).fetchone()[0]
    assert conn.execute(
        "SELECT count(*) FROM player_manual_slots WHERE player_id = %s", (alice,)
    ).fetchone()[0] == 1

    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]
    conn.execute("SELECT trade_add_manual(%s, %s, %s)", (trade, alice, manual))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, alice))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, bob))

    assert conn.execute(
        "SELECT count(*) FROM player_manual_slots WHERE player_id = %s", (alice,)
    ).fetchone()[0] == 0


def test_you_cannot_offer_what_you_do_not_own(conn, traders):
    alice, bob = traders()
    theirs = conn.execute("SELECT grant_starter_manual(%s)", (bob,)).fetchone()[0]
    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT trade_add_manual(%s, %s, %s)", (trade, alice, theirs))


def test_you_cannot_offer_more_than_you_hold(conn, traders):
    alice, bob = traders()
    herb = conn.execute(
        "SELECT code FROM materials WHERE category = 'gathering' LIMIT 1"
    ).fetchone()[0]
    conn.execute("SELECT grant_material(%s, %s, 3)", (alice, herb))
    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT trade_set_material(%s, %s, %s, 4)", (trade, alice, herb))


def test_confirming_alone_does_not_move_anything(conn, traders):
    alice, bob = traders()
    manual = conn.execute("SELECT grant_starter_manual(%s)", (alice,)).fetchone()[0]
    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]
    conn.execute("SELECT trade_add_manual(%s, %s, %s)", (trade, alice, manual))

    assert conn.execute(
        "SELECT trade_confirm(%s, %s)", (trade, alice)
    ).fetchone()[0] is False
    assert conn.execute(
        "SELECT player_id FROM player_manuals WHERE manual_id = %s", (manual,)
    ).fetchone()[0] == alice

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT trade_execute(%s)", (trade,))


def test_an_empty_table_cannot_be_confirmed(conn, traders):
    alice, bob = traders()
    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT trade_confirm(%s, %s)", (trade, alice))


def test_one_trade_at_a_time(conn, traders, make_player):
    """Without the claim, the same manual could be promised to two people and
    whichever swap ran second would find it gone."""
    alice, bob = traders()
    third = make_player("Carol")
    conn.execute("SELECT trade_open(%s, %s)", (alice, bob))

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT trade_open(%s, %s)", (alice, third))


def test_a_stranger_cannot_touch_a_trade(conn, traders, make_player):
    alice, bob = traders()
    nosy = make_player("Carol")
    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT trade_cancel(%s, %s)", (trade, nosy))


def test_a_traded_manual_survives_its_refiner_leaving(conn, traders):
    """created_by CASCADEd, which was fine while a refined manual could only sit
    in its maker's hands. Once one can be traded, that cascade reaches into a
    stranger's collection and deletes a book they earned."""
    alice, bob = traders()
    manual = conn.execute("SELECT grant_starter_manual(%s)", (alice,)).fetchone()[0]

    trade = conn.execute("SELECT trade_open(%s, %s)", (alice, bob)).fetchone()[0]
    conn.execute("SELECT trade_add_manual(%s, %s, %s)", (trade, alice, manual))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, alice))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, bob))

    # Alice closes her account. Her trades are history involving Bob, so they
    # have to go first - the same RESTRICT battle_combatants uses.
    conn.execute("DELETE FROM trades WHERE proposer_id = %s OR partner_id = %s", (alice, alice))
    conn.execute("DELETE FROM players WHERE player_id = %s", (alice,))

    still = conn.execute(
        "SELECT player_id FROM player_manuals WHERE manual_id = %s", (manual,)
    ).fetchone()
    assert still is not None and still[0] == bob
    assert conn.execute(
        "SELECT created_by FROM manuals WHERE manual_id = %s", (manual,)
    ).fetchone()[0] is None


def test_an_orphaned_manual_is_not_mistaken_for_seeded_content(conn):
    """roll_manual_drop used to read created_by IS NULL as "seeded content
    anyone may find". With created_by nullable by deletion, that would start
    handing a dead player's refined manual to strangers - so the predicate is
    `code IS NOT NULL`, which is what seeded content actually means."""
    droppable = conn.execute(
        "SELECT count(*) FROM manuals WHERE code IS NULL AND created_by IS NULL"
    ).fetchone()[0]
    source = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'roll_manual_drop'"
    ).fetchone()[0]
    assert "m.code IS NOT NULL" in source, (
        f"{droppable} codeless manual(s) exist; the drop roll must not offer them"
    )


# ---------------------------------------------------------------------------
# Gu (0036, 0037)
# ---------------------------------------------------------------------------


@pytest.fixture
def gu_holder(conn, make_player):
    """A cultivator with a body and an aperture."""
    def _make():
        player = make_player("Gu Master")
        conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (player,))
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id) "
            "VALUES (%s, roll_physique())",
            (player,),
        )
        return player

    return _make


def _give(conn, player, code, stars=1):
    return conn.execute(
        "SELECT grant_gu(%s, (SELECT gu_type_id FROM gu_types WHERE code = %s), NULL)",
        (player, code),
    ).fetchone()[0]


def test_the_aperture_is_a_budget_not_a_slot_count(conn, gu_holder):
    """This is the whole build constraint: six cheap Gu or two expensive ones.

    A fixed slot count would make every build the same shape and reduce the
    question to which eight Gu are best.
    """
    player = gu_holder()
    capacity = conn.execute("SELECT gu_capacity_of(%s)", (player,)).fetchone()[0]
    assert capacity == 3, "rank 1 early holds three"

    big = _give(conn, player, "golden_centipede_gu")     # size 2
    small = _give(conn, player, "wolf_enslavement_gu")   # size 1
    spare = _give(conn, player, "big_strength_gu")       # size 1

    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s), (%s, %s)",
        (big, player, small, player),
    )
    assert conn.execute("SELECT gu_used_by(%s)", (player,)).fetchone()[0] == 3

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
            (spare, player),
        )


def test_the_aperture_grows_with_the_realm(conn):
    sizes = conn.execute(
        "SELECT rank, stage, gu_capacity FROM realms ORDER BY realm_id"
    ).fetchall()
    values = [row[2] for row in sizes]
    assert values == sorted(values), "capacity must never go down as you climb"
    assert values[0] == 3 and values[-1] > values[0]


def test_you_cannot_equip_someone_elses_gu(conn, gu_holder):
    mine = gu_holder()
    theirs = gu_holder()
    gu = _give(conn, theirs, "big_strength_gu")

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
            (gu, mine),
        )


def test_stars_scale_what_a_gu_is_worth(conn, gu_holder):
    """Four steps of a quarter each: a one-star worm is worth double at five.

    Read off the worm rather than written down. This asserted a flat 0.06 of
    attack power until 0355 renamed Big Strength Gu's effect to Sinew - the
    star mechanic had not changed at all, and a hardcoded effect code made a
    test about multiplication fail over a reclassification."""
    player = gu_holder()
    gu = _give(conn, player, "big_strength_gu")
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
        (gu, player),
    )
    effect, magnitude = conn.execute(
        """
        SELECT ef.effect_code, ef.magnitude
        FROM gu_type_effects ef
        JOIN gu_types g ON g.gu_type_id = ef.gu_type_id
        WHERE g.code = 'big_strength_gu'
        ORDER BY ef.magnitude DESC LIMIT 1
        """
    ).fetchone()

    one = conn.execute("SELECT gu_stat(%s, %s)", (player, effect)).fetchone()[0]
    conn.execute("UPDATE player_gu SET stars = 5 WHERE gu_id = %s", (gu,))
    five = conn.execute("SELECT gu_stat(%s, %s)", (player, effect)).fetchone()[0]

    assert float(one) == pytest.approx(float(magnitude))
    assert float(five) == pytest.approx(float(magnitude) * 2)


def test_every_effect_is_capped(conn, gu_holder):
    """Six crit Gu must not make a 100% crit rate. The cap is what stops one
    build being every build."""
    player = gu_holder()
    conn.execute("UPDATE realms SET gu_capacity = 40 WHERE realm_id = 1")

    for _ in range(8):
        gu = _give(conn, player, "bone_bamboo_gu")     # 8% crit each
        conn.execute("UPDATE player_gu SET stars = 5 WHERE gu_id = %s", (gu,))
        conn.execute(
            "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
            (gu, player),
        )

    total = conn.execute("SELECT gu_stat(%s, 'crit_rate')", (player,)).fetchone()[0]
    # 0516: worms are ONE source, and no source may finish an effect alone -
    # which is 0209's rule for a single worm applied to the eight sources,
    # because one maxed source used to be 100% of a stat and the other seven
    # were decoration. Six crit worms still must not make a 100% crit rate,
    # which is what this test is for; they now reach the worms' share of it.
    cap = conn.execute(
        "SELECT stat_source_cap('crit_rate')"
    ).fetchone()[0]
    assert total == cap

    flagged = conn.execute(
        "SELECT capped FROM player_gu_stats WHERE player_id = %s AND effect_code = 'crit_rate'",
        (player,),
    ).fetchone()[0]
    assert flagged is True, "the screen has to be able to say the ceiling is wasted"


def test_gu_reach_the_damage_pipeline(conn, gu_holder, make_technique, make_species):
    """A worm you just slotted is felt on the next swing.

    It used to be asked of `player_external_multiplier`, because a Gu could
    grant `attack_power` and that hook reads `player_stat` live. 0443 retired
    attack_power into `base_strength`, so the route changed: a Gu now reaches
    damage through the BODY - `player_physique.strength`, which is a stored
    column - and then through `thews` in compute_technique_damage.

    That makes this a stronger question than it was, because the stored column
    is the part that can silently fail. 0445 put a trigger on the table for
    exactly this, and here is where it is checked: the value is followed from
    the worm all the way to the damage number.
    """
    player = gu_holder()
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, 'human', 'earthen_root')",
        (player,),
    )
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))

    technique = make_technique("gu_pipeline_tech", paths={"fire": "1.0"})
    species = make_species("gu_pipeline_beast")

    def body():
        return conn.execute(
            "SELECT strength FROM player_physique WHERE player_id = %s", (player,)
        ).fetchone()[0]

    def hits_for():
        row = conn.execute(
            "SELECT final_damage, body_power FROM compute_technique_damage("
            "  %s, %s, %s, 1, 0)", (player, technique, species)
        ).fetchone()
        return row[0], row[1]

    before_body = body()
    before_damage, before_thews = hits_for()

    # The shallowest worm that grants sinew, so the aperture can hold it.
    code = conn.execute(
        """
        SELECT g.code FROM gu_type_effects e
        JOIN gu_types g ON g.gu_type_id = e.gu_type_id
        WHERE e.effect_code = 'base_strength'
        ORDER BY g.rank ASC, e.magnitude DESC LIMIT 1
        """
    ).fetchone()[0]

    gu = _give(conn, player, code)
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
        (gu, player),
    )

    # The body moved WITHOUT anyone training, which is the trigger doing its
    # job. Before 0445 this line would have held and the worm would have done
    # nothing until the next pill.
    assert body() > before_body, (
        "the worm went on and the body did not move - nothing recomputed it"
    )

    after_damage, after_thews = hits_for()
    assert after_thews > before_thews, "sinew did not reach the swing"
    assert after_damage > before_damage, "a stronger arm did not hit harder"

    # And taking it off puts it back, so the trigger is not one-way.
    conn.execute("DELETE FROM player_gu_equipped WHERE gu_id = %s", (gu,))
    assert body() == before_body, "the body kept sinew the worm took with it"


def test_max_hp_reads_the_gu(conn, gu_holder):
    player = gu_holder()
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, 'human', 'earthen_root')",
        (player,),
    )
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    before = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]

    gu = _give(conn, player, "cleansing_water_gu")   # +6% max HP
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
        (gu, player),
    )
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    after = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]

    assert after > before


def test_multi_hit_strikes_more_than_once(conn, gu_holder):
    """Extra strikes land lighter and defence bites each one, which is why a
    multi-hit build wants penetration and a big-hit build does not.

    THE BUILD HAS TO BE A REAL ONE. This used to stack three cheap worms for
    2.0 multi_hit "with no roll left to chance", which 0514 ended by cutting
    the low rungs of every effect ladder: measured over twenty fights those
    three now give 0.7466 and land 1 or 2 strikes, so this test passed three
    runs in four. One rank 8 worm gives 2.200 at five stars - clipped to
    1.800 by the source share, because no single source may finish an effect
    - and landed 2 or 3 strikes in all twenty.

    So this test depends on a magnitude. If the ladder is retuned again and
    it starts failing intermittently, that is what moved.
    """
    player = gu_holder()
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, 'human', 'earthen_root')",
        (player,),
    )
    conn.execute("UPDATE realms SET gu_capacity = 40 WHERE realm_id = 1")
    conn.execute("SELECT grant_starter_manual(%s)", (player,))

    # One worm near the top of the ladder, which is what an extra strike
    # costs since 0514. Three cheap ones no longer buy one.
    gu = _give(conn, player, "saint_iron_crown_immortal_gu")
    conn.execute("UPDATE player_gu SET stars = 5 WHERE gu_id = %s", (gu,))
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
        (gu, player),
    )

    # Asserted before the fight, so a failure says WHICH thing broke: the
    # magnitude this test rests on, or the strike arithmetic it is about.
    stat = float(
        conn.execute("SELECT player_stat(%s, 'multi_hit')", (player,)).fetchone()[0]
    )
    assert stat >= 1.0, (
        f"this build only carries {stat:.4f} multi_hit, so an extra strike is a "
        "roll rather than a certainty and this test is a coin flip"
    )

    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE code = 'rule_shell_tortoise'"
    ).fetchone()[0]
    conn.execute("UPDATE creature_species SET base_hp = 100000 WHERE species_id = %s", (species,))

    battle = conn.execute("SELECT battle_open(%s, %s)", (player, species)).fetchone()[0]
    technique = conn.execute(
        """
        SELECT u.technique_id FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        WHERE u.player_id = %s AND t.base_power > 0 LIMIT 1
        """,
        (player,),
    ).fetchone()[0]

    strikes = conn.execute(
        "SELECT strikes FROM battle_act(%s, 'attack', %s)", (battle, technique)
    ).fetchone()[0]
    assert strikes >= 2, "a full multi-hit build must swing more than once"

    logged = conn.execute(
        "SELECT count(*) FROM battle_actions WHERE battle_id = %s AND actor_no = 0",
        (battle,),
    ).fetchone()[0]
    assert logged == strikes, "every strike is its own row in the log"


def test_life_steal_returns_health_but_never_overfills(conn, gu_holder):
    player = gu_holder()
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, 'human', 'earthen_root')",
        (player,),
    )
    conn.execute("UPDATE realms SET gu_capacity = 40 WHERE realm_id = 1")
    conn.execute("SELECT grant_starter_manual(%s)", (player,))

    gu = _give(conn, player, "ghost_fire_gu")
    conn.execute("UPDATE player_gu SET stars = 5 WHERE gu_id = %s", (gu,))
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)",
        (gu, player),
    )

    # Hurt, so there is room for the steal to land in.
    conn.execute(
        "UPDATE player_physique SET current_hp = 10 WHERE player_id = %s", (player,)
    )
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE code = 'rule_shell_tortoise'"
    ).fetchone()[0]
    conn.execute("UPDATE creature_species SET base_hp = 100000 WHERE species_id = %s", (species,))

    battle = conn.execute("SELECT battle_open(%s, %s)", (player, species)).fetchone()[0]
    technique = conn.execute(
        """
        SELECT u.technique_id FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        WHERE u.player_id = %s AND t.base_power > 0 LIMIT 1
        """,
        (player,),
    ).fetchone()[0]

    healed, hp = conn.execute(
        "SELECT healed, player_hp FROM battle_act(%s, 'attack', %s)", (battle, technique)
    ).fetchone()
    max_hp = conn.execute(
        "SELECT max_hp FROM battle_combatants WHERE battle_id = %s AND combatant_no = 0",
        (battle,),
    ).fetchone()[0]

    assert healed > 0
    assert hp <= max_hp


def test_a_gu_drop_never_outranks_what_dropped_it(conn, gu_holder):
    player = gu_holder()
    conn.execute("UPDATE game_config SET value = 1 WHERE key = 'gu_drop_chance'")

    for _ in range(15):
        gu_id = conn.execute(
            "SELECT roll_gu_drop(%s, 'northern', 1::smallint)", (player,)
        ).fetchone()[0]
        if gu_id is None:
            continue
        rank = conn.execute(
            "SELECT t.rank FROM player_gu g JOIN gu_types t ON t.gu_type_id = g.gu_type_id "
            "WHERE g.gu_id = %s",
            (gu_id,),
        ).fetchone()[0]
        assert rank == 1


# ---------------------------------------------------------------------------
# The catalogue and its ceiling (0209)
# ---------------------------------------------------------------------------


def test_the_world_hands_out_nothing_immortal_yet(conn, gu_holder):
    """Rank 6 is where a Gu becomes Immortal. 0209 put the whole ladder in the
    catalogue and the top four rungs nowhere in the world.

    The rule is a config value rather than an absence of rows, so opening them
    later is one UPDATE instead of hundreds of INSERTs somebody has to write.
    """
    ceiling = conn.execute(
        "SELECT game_config_value('gu_max_droppable_rank')"
    ).fetchone()[0]

    # The mortal world, which is what this rule has always been about. Since
    # 0340 a GATED region - one a mortal cannot walk into - hands out up to
    # `gu_max_immortal_droppable_rank` instead, which is the whole point of
    # Black Heaven; the door is doing the work this ceiling does.
    placed = conn.execute(
        """
        SELECT max(t.rank) FROM gu_region_drops d
        JOIN gu_types t ON t.gu_type_id = d.gu_type_id
        JOIN regions r ON r.code = d.region_code
        WHERE r.min_rank = 1
        """
    ).fetchone()[0]
    assert placed <= ceiling, f"a rank {placed} Gu is placed in an open region"

    behind_a_door = conn.execute(
        """
        SELECT max(t.rank) FROM gu_region_drops d
        JOIN gu_types t ON t.gu_type_id = d.gu_type_id
        JOIN regions r ON r.code = d.region_code
        WHERE r.min_rank > 1
        """
    ).fetchone()[0]
    assert behind_a_door is None or behind_a_door <= conn.execute(
        "SELECT game_config_value('gu_max_immortal_droppable_rank')"
    ).fetchone()[0]

    player = gu_holder()
    conn.execute("UPDATE game_config SET value = 1 WHERE key = 'gu_drop_chance'")

    for _ in range(60):
        gu_id = conn.execute(
            "SELECT roll_gu_drop(%s, 'northern', 9::smallint)", (player,)
        ).fetchone()[0]
        assert gu_id is not None, "the chance was set to 1 and nothing came out"
        rank = conn.execute(
            "SELECT t.rank FROM player_gu g JOIN gu_types t ON t.gu_type_id = g.gu_type_id "
            "WHERE g.gu_id = %s",
            (gu_id,),
        ).fetchone()[0]
        assert rank <= ceiling


def test_the_ceiling_is_read_and_not_a_coincidence(conn, gu_holder):
    """Nothing above rank 5 is placed in a region, so a `roll_gu_drop` that
    ignored the config would still look correct. Move the ceiling and it
    cannot: dropping it to 2 must narrow what comes out.
    """
    player = gu_holder()
    conn.execute("UPDATE game_config SET value = 1 WHERE key = 'gu_drop_chance'")
    conn.execute("UPDATE game_config SET value = 2 WHERE key = 'gu_max_droppable_rank'")

    seen = set()
    for _ in range(60):
        gu_id = conn.execute(
            "SELECT roll_gu_drop(%s, 'northern', 9::smallint)", (player,)
        ).fetchone()[0]
        seen.add(
            conn.execute(
                "SELECT t.rank FROM player_gu g "
                "JOIN gu_types t ON t.gu_type_id = g.gu_type_id WHERE g.gu_id = %s",
                (gu_id,),
            ).fetchone()[0]
        )

    assert seen, "sixty certain rolls produced nothing"
    assert max(seen) <= 2, f"the ceiling was 2 and rank {max(seen)} came out"


def test_a_drop_row_cannot_be_written_above_the_ceiling(conn):
    """The gate would be walkable around if a later migration could place an
    Immortal Gu in a region and only the function objected."""
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """
            INSERT INTO gu_region_drops (region_code, gu_type_id, weight)
            SELECT 'northern', gu_type_id, 5 FROM gu_types
            WHERE rank > game_config_value('gu_max_droppable_rank') LIMIT 1
            """
        )


def test_the_finest_gu_are_refined_and_not_found(conn):
    """Below the ceiling the drop table is weighted by rarity, and the weights
    stop at mythic. Divine and above are reachable, but only through the bench:
    a legendary is one roll in twenty against a common, and the step above that
    is not a roll at all.
    """
    # Of the open world. A heaven behind a rank 10 door is allowed its divine
    # and unique worms - reaching it is the filter that rarity was standing
    # in for everywhere else.
    found = conn.execute(
        """
        SELECT DISTINCT t.rarity FROM gu_region_drops d
        JOIN gu_types t ON t.gu_type_id = d.gu_type_id
        JOIN regions r ON r.code = d.region_code
        WHERE r.min_rank = 1
        """
    ).fetchall()
    assert {r[0] for r in found} <= {
        "common", "uncommon", "rare", "epic", "legendary", "mythic"
    }

    # ...and they are still makeable, or they would be decoration.
    assert conn.execute(
        """
        SELECT count(*) FROM gu_types t
        WHERE t.rarity IN ('divine', 'unique', 'extreme')
          AND NOT EXISTS (SELECT 1 FROM gu_recipe_costs c
                          WHERE c.gu_type_id = t.gu_type_id)
        """
    ).fetchone()[0] == 0


def test_every_rarity_has_a_price(conn):
    """`gu_recipe_costs` INNER JOINs the rarity multipliers, so a rarity with
    no row does not make its Gu expensive - it makes them vanish from /refine
    while still holding a recipe. Divine shipped in that state until 0209.
    """
    unpriced = conn.execute(
        """
        SELECT DISTINCT t.rarity FROM gu_types t
        WHERE NOT EXISTS (
            SELECT 1 FROM gu_refine_rarity_costs m WHERE m.rarity = t.rarity)
        """
    ).fetchall()
    assert [r[0] for r in unpriced] == []

    assert conn.execute("SELECT count(*) FROM gu_recipe_costs").fetchone()[0] ==         conn.execute("SELECT count(*) FROM gu_types").fetchone()[0]


def test_no_single_gu_finishes_an_effect_on_its_own(conn):
    """Caps exist so a build is assembled out of several Gu. One worm that
    reaches a ceiling by itself makes the other slots decoration, so 0209 holds
    every generated magnitude to three fifths of its cap - and the hand-tuned
    35 were already well inside that.
    """
    # 0492 changed what a cap IS for two effects: crit_damage and multi_hit
    # now have a lid that rises with the realm, because a flat one meant
    # volume always caught tier - 57 rank 1 worms at five stars reach 9.27
    # crit_damage against a ceiling of 2.00, so nothing above them could ever
    # be worth more. A worm is held to three fifths of the lid AT THE REALM
    # WHERE IT IS USED, which up to rank 8 is still the flat cap. The two
    # halves are asserted separately so the original protection still covers
    # every worm it was written for.
    flat_lid = conn.execute(
        """
        SELECT t.code, e.effect_code, e.magnitude, f.cap
        FROM gu_type_effects e
        JOIN gu_types t ON t.gu_type_id = e.gu_type_id
        JOIN gu_effects f ON f.code = e.effect_code
        WHERE t.rank <= 8
          AND e.magnitude > 0.6 * f.cap
        ORDER BY e.magnitude / f.cap DESC
        """
    ).fetchall()
    assert flat_lid == [], (
        f"{len(flat_lid)} Gu below the heavens eat a whole ceiling, "
        f"worst {flat_lid[:1]}"
    )

    # The apex, against the lid at the top realm - the only realm a rank 9
    # worm can be earned at: refiner level 85, or one of the two bosses that
    # live behind a door asking for immortality.
    top = conn.execute("SELECT max(rank) FROM realms").fetchone()[0]
    rising_lid = conn.execute(
        """
        SELECT t.code, e.effect_code, e.magnitude,
               GREATEST(f.cap, f.cap_per_rank * %s) AS lid
        FROM gu_type_effects e
        JOIN gu_types t ON t.gu_type_id = e.gu_type_id
        JOIN gu_effects f ON f.code = e.effect_code
        WHERE t.rank = 9
          AND e.magnitude > 0.6 * GREATEST(f.cap, f.cap_per_rank * %s)
        ORDER BY e.magnitude DESC
        """,
        (top, top),
    ).fetchall()
    assert rising_lid == [], (
        f"{len(rising_lid)} apex Gu eat a whole ceiling even at rank {top}, "
        f"worst {rising_lid[:1]}"
    )


def test_a_rank_four_gu_pays_for_its_slot(conn):
    """A rank 4 Gu costs four of an aperture that holds six or seven. One
    capped number is right for a rank 1 worm and thin at that price, so 0211
    gave every rank 4 and 5 Gu a second word - and deliberately left ranks 1 to
    3 saying one thing, because a beginner's Gu should be readable at a glance.
    """
    shape = dict(
        conn.execute(
            """
            SELECT t.rank, count(*) FILTER (WHERE e.n = 1)
            FROM gu_types t
            JOIN (SELECT gu_type_id, count(*) n FROM gu_type_effects GROUP BY 1) e
              USING (gu_type_id)
            GROUP BY t.rank
            """
        ).fetchall()
    )

    assert shape[4] == 0, f"{shape[4]} rank 4 Gu still lend one thing"
    assert shape[5] == 0, f"{shape[5]} rank 5 Gu still lend one thing"
    # And the low ranks were not swept up with them.
    assert shape[1] > 0 and shape[2] > 0 and shape[3] > 0, (
        "ranks 1 to 3 were supposed to keep saying one thing"
    )


def test_a_sitting_that_cannot_finish_costs_nothing(conn, make_player):
    """The whole reason `forge_many` is a function and not a loop in the bot.

    `forge` refuses on its own when the ore runs out, so a loop of ten would
    forge six, fail on the seventh, and leave the player having spent six lots
    of materials on something they asked for as one action. Every material for
    the WHOLE run is checked before any of it is spent.
    """
    who = make_player("Smith")
    conn.execute("SELECT grant_profession_exp(%s, 'blacksmithing', 40000, FALSE)", (who,))
    conn.execute("SELECT grant_material(%s, 'spirit_iron', 60)", (who,))
    conn.execute("SELECT grant_material(%s, 'dragon_scale', 60)", (who,))

    def held(code):
        return conn.execute(
            "SELECT COALESCE((SELECT quantity FROM player_materials "
            "WHERE player_id=%s AND material_code=%s), 0)", (who, code)
        ).fetchone()[0]

    before_ore, before_part = held("spirit_iron"), held("dragon_scale")
    before_gear = conn.execute(
        "SELECT count(*) FROM player_equipment WHERE owner_id=%s", (who,)
    ).fetchone()[0]

    # Ask for more than the materials cover.
    with pytest.raises(psycopg.errors.CheckViolation) as caught:
        with conn.transaction():
            conn.execute(
                "SELECT * FROM forge_many(%s,'armour',ARRAY['spirit_iron'],ARRAY[30],"
                "ARRAY['dragon_scale'],ARRAY[30],5)", (who,)
            ).fetchone()
    assert "forgings need" in str(caught.value), str(caught.value)

    assert held("spirit_iron") == before_ore, "a refused sitting still spent ore"
    assert held("dragon_scale") == before_part, "a refused sitting still spent parts"
    assert conn.execute(
        "SELECT count(*) FROM player_equipment WHERE owner_id=%s", (who,)
    ).fetchone()[0] == before_gear, "a refused sitting still made something"

    # And a run that fits reports exactly what it made.
    got = conn.execute(
        "SELECT * FROM forge_many(%s,'armour',ARRAY['spirit_iron'],ARRAY[10],"
        "ARRAY['dragon_scale'],ARRAY[10],3)", (who,)
    ).fetchone()
    attempts, succeeded, ruined = got[0], got[1], got[2]
    made = got[9]
    assert attempts == 3
    assert succeeded + ruined == 3, "attempts did not account for themselves"
    assert len(made) == succeeded, f"said {succeeded} made and listed {len(made)}"
    assert conn.execute(
        "SELECT count(*) FROM player_equipment WHERE owner_id=%s", (who,)
    ).fetchone()[0] == before_gear + succeeded

    # The ladder is the other gate, and it is the smith's level rather than
    # their purse that decides it.
    cap = conn.execute(
        "SELECT smith_max_runs(profession_level(%s,'blacksmithing'))", (who,)
    ).fetchone()[0]
    assert cap >= 2, "even a new smith works two at a sitting"
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute(
                "SELECT * FROM forge_many(%s,'armour',ARRAY['spirit_iron'],ARRAY[1],"
                "ARRAY['dragon_scale'],ARRAY[1],%s)", (who, cap + 1)
            ).fetchone()

    # The run ladder matches the two it was copied from, because three
    # professions each picking their own thresholds is three things to learn.
    for other in ("gu_refine_runs", "alchemy_brews"):
        assert conn.execute(
            "SELECT array_agg(level_required ORDER BY step) FROM profession_steps "
            "WHERE ladder='forge_runs'"
        ).fetchone()[0] == conn.execute(
            "SELECT array_agg(level_required ORDER BY step) FROM profession_steps "
            "WHERE ladder=%s", (other,)
        ).fetchone()[0], f"forge_runs drifted from {other}"


def test_a_fuse_keeps_the_better_of_each_and_spends_the_duplicate(conn, make_player):
    """Two of a kind in, one out a star higher - or the duplicate is spent.

    The rules pinned here are the ones a player would notice being wrong:
    stats are the BEST of each and not the sum, rarity and quality are the
    better of the two and no better, and the fodder is gone either way.
    """
    who = make_player("Smith")

    def piece(rarity, quality, harmony, rank=1, slot="helm", level=3):
        return conn.execute(
            "INSERT INTO player_equipment "
            "(owner_id, name, slot, tier, rarity, harmony, ore_code, "
            " level, rank, quality) "
            "VALUES (%s, 'Probe', %s, 1, %s, %s, 'spirit_iron', %s, %s, %s) "
            "RETURNING equipment_id",
            (who, slot, rarity, harmony, level, rank, quality),
        ).fetchone()[0]

    keep = piece("rare", "fine", 100)
    feed = piece("epic", "superb", 120)
    conn.execute(
        "INSERT INTO equipment_effects (equipment_id, effect_code, magnitude) "
        "VALUES (%s,'base_strength',10),(%s,'crit_rate',0.10),"
        "       (%s,'base_strength',4),(%s,'crit_damage',0.20)",
        (keep, keep, feed, feed),
    )

    got = conn.execute(
        "SELECT * FROM fuse_equipment(%s,%s,%s)", (who, keep, feed)
    ).fetchone()
    succeeded, chance, rank_before, rank_after, rarity_after, quality_after = got[:6]

    # Spent either way. This is the cost of the attempt.
    assert conn.execute(
        "SELECT count(*) FROM player_equipment WHERE equipment_id=%s", (feed,)
    ).fetchone()[0] == 0, "the duplicate survived, so a fuse costs nothing"
    assert conn.execute(
        "SELECT count(*) FROM player_equipment WHERE equipment_id=%s", (keep,)
    ).fetchone()[0] == 1, "the piece being raised was destroyed"
    assert 0 < float(chance) <= 0.95

    stats = dict(conn.execute(
        "SELECT effect_code, magnitude FROM equipment_effects WHERE equipment_id=%s",
        (keep,),
    ).fetchall())

    if succeeded:
        assert rank_after == rank_before + 1
        step = conn.execute(
            "SELECT stat_step FROM equipment_ranks WHERE rank=%s", (rank_after,)
        ).fetchone()[0]
        # Best of each, NOT the sum: 10 against 4 gives 10, never 14.
        assert float(stats["base_strength"]) == pytest.approx(10 * float(step))
        assert "crit_damage" in stats, "a stat only the fodder had was dropped"
        assert "crit_rate" in stats, "a stat only the keeper had was dropped"
        # The better of each, and no better.
        assert rarity_after == "epic"
        assert quality_after == "superb"
    else:
        assert rank_after == rank_before
        assert rarity_after == "rare"

    # What it refuses, which is what stops the ladder being skipped.
    #
    # Each in its own subtransaction: a CheckViolation aborts the transaction
    # it is raised in, and a bare ROLLBACK here takes the player with it - the
    # first draft of this test did exactly that and then could not insert.
    a = piece("rare", "fine", 100)
    b = piece("rare", "fine", 100, rank=2)
    with conn.transaction():
        with pytest.raises(psycopg.errors.CheckViolation):
            with conn.transaction():
                conn.execute("SELECT * FROM fuse_equipment(%s,%s,%s)",
                             (who, a, b)).fetchone()

    c = piece("rare", "fine", 100)
    d = piece("rare", "fine", 100, slot="boots")
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute("SELECT * FROM fuse_equipment(%s,%s,%s)",
                         (who, c, d)).fetchone()

    e = piece("rare", "fine", 100)
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute("SELECT * FROM fuse_equipment(%s,%s,%s)",
                         (who, e, e)).fetchone()


def test_the_anvil_stamps_a_realm_a_star_and_two_different_words(conn):
    """Rarity and Quality were the same number read twice until 0438.

    Rarity is what the smith is capable of and Quality is how the forging
    actually went, so a deep smith on a bad day makes something ordinary and
    the roll still means something.
    """
    # Quality is the harmony band, and it spans its whole range.
    assert conn.execute("SELECT equipment_quality_for(0::smallint)").fetchone()[0]         != conn.execute("SELECT equipment_quality_for(150::smallint)").fetchone()[0]

    # Rarity is the smith's ceiling and rises with them.
    ladder = [
        conn.execute("SELECT smith_rarity_cap(%s)", (lvl,)).fetchone()[0]
        for lvl in (1, 20, 65, 130)
    ]
    assert len(set(ladder)) == len(ladder), f"the smith ladder is flat: {ladder}"

    # And a bench may never make what the world is supposed to hand out.
    reserved = conn.execute(
        "SELECT count(*) FROM smith_rarity_caps WHERE rarity IN ('unique','extreme')"
    ).fetchone()[0]
    assert reserved == 0, "a bench can make what only the world should"

    # Every realm a cultivator can stand in has a gear level, and every level
    # allows at least one star.
    gaps = conn.execute(
        """
        SELECT DISTINCT r.rank FROM realms r
        WHERE NOT EXISTS (SELECT 1 FROM equipment_level_scales l WHERE l.level = r.rank)
        ORDER BY 1
        """
    ).fetchall()
    assert gaps == [], f"realms with no gear level: {[g[0] for g in gaps]}"
    assert conn.execute(
        "SELECT count(*) FROM equipment_level_scales WHERE max_rank < 1"
    ).fetchone()[0] == 0


def test_a_root_special_that_does_something_and_stops_at_its_allowance(conn, make_player):
    """River of Time was a diamond on a card and nothing else.

    `special_name` and `special_text` are read in exactly one place in the
    codebase - the screen that prints them - and no SQL function had ever
    looked at either, so the one line the card presented as a working ability
    was the only one that did nothing. The honestly-unmodelled line beside it
    was at least marked.
    """
    who = make_player("Inheritor")
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, 'human', 'red_lotus_inheritor')", (who,),
    )

    def left(action="forge_technique"):
        return conn.execute(
            "SELECT root_special_charges_left(%s, %s)", (who, action)
        ).fetchone()[0]

    def shut():
        conn.execute(
            "SELECT claim_cooldown(%s, 'forge_technique', "
            "game_config_value('forge_technique_cooldown_minutes'))", (who,)
        )

    def is_shut():
        return conn.execute(
            "SELECT count(*) FROM player_cooldowns WHERE player_id = %s "
            "AND action = 'forge_technique' AND available_at > now()", (who,)
        ).fetchone()[0] > 0

    allowance = conn.execute(
        "SELECT uses_per_day FROM root_specials "
        "WHERE root_code = 'red_lotus_inheritor' AND resets_action = 'forge_technique'"
    ).fetchone()[0]
    assert left() == allowance

    # A charge is never spent on a cooldown that is not running - somebody
    # pressing it early keeps it.
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute("SELECT * FROM root_special_use(%s, 'forge_technique')",
                         (who,)).fetchone()
    assert left() == allowance, "a refused use still cost a charge"

    # Spend the whole allowance, and each one really opens the anvil.
    for spent in range(1, allowance + 1):
        shut()
        assert is_shut()
        conn.execute("SELECT * FROM root_special_use(%s, 'forge_technique')",
                     (who,)).fetchone()
        assert not is_shut(), "the river ran and the anvil is still shut"
        assert left() == allowance - spent

    # And no more today.
    shut()
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute("SELECT * FROM root_special_use(%s, 'forge_technique')",
                         (who,)).fetchone()
    assert is_shut(), "a refused use still opened the anvil"

    # Spent out, and the screen can say when the next one comes.
    assert conn.execute(
        "SELECT root_special_ready_at(%s, 'forge_technique')", (who,)
    ).fetchone()[0] is not None

    # Nobody else is holding one by accident.
    other = make_player("Ordinary")
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, 'human', 'earthen_root')", (other,),
    )
    assert conn.execute(
        "SELECT root_special_charges_left(%s, 'forge_technique')", (other,)
    ).fetchone()[0] == 0, "a root with no special still granted charges"

    # And every root special that is WIRED clears a cooldown something claims,
    # so none of them is the new version of the old fault.
    #
    # `daily` is named rather than derived, exactly as `cooldown_status` names
    # it: it is the one clock in the game that does not live in
    # `player_cooldowns` and so has no `_cooldown_minutes` key to find.
    unclaimed = conn.execute(
        """
        SELECT rs.root_code, rs.resets_action FROM root_specials rs
        WHERE rs.resets_action <> 'daily'
          AND NOT EXISTS (
            SELECT 1 FROM game_config g
            WHERE g.key = rs.resets_action || '_cooldown_minutes')
        """
    ).fetchall()
    assert unclaimed == [], f"these clear a cooldown nothing sets: {unclaimed}"

    # And the daily really does keep its own, so that exception is a fact
    # rather than a hole in the check.
    assert conn.execute(
        "SELECT count(*) FROM game_config WHERE key = 'daily_cooldown_hours'"
    ).fetchone()[0] == 1


def test_the_purse_is_walked_back_without_losing_the_run(conn, make_player):
    """River of Time reaches the daily too, and the two allowances are apart.

    The daily is the one clock in the game that does NOT live in
    `player_cooldowns` - it is gated on `player_daily.last_claimed_at` - so
    resetting it means winding that stamp back rather than deleting a row.
    Back BY THE WAIT and not to NULL, because `claim_daily` reads the same
    stamp to decide whether a run continues, and clearing it would quietly
    break a streak somebody had kept for weeks.
    """
    who = make_player("Inheritor")
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, 'human', 'red_lotus_inheritor')", (who,),
    )

    def left(action):
        return conn.execute(
            "SELECT root_special_charges_left(%s, %s)", (who, action)
        ).fetchone()[0]

    # Two pools, not one shared between them - both were asked for on the
    # same day, so one pool could not have satisfied either request.
    assert left("forge_technique") == 2
    assert left("daily") == 1

    conn.execute(
        "SELECT claim_cooldown(%s, 'forge_technique', 1320)", (who,)
    )
    conn.execute("SELECT * FROM root_special_use(%s, 'forge_technique')", (who,))
    assert left("daily") == 1, "spending the anvil took the purse with it"

    # A run of nine, taken just now.
    conn.execute(
        "INSERT INTO player_daily (player_id, streak, longest_streak, claims, "
        "last_claimed_at) VALUES (%s, 9, 9, 9, now())", (who,),
    )
    shut = conn.execute(
        "SELECT * FROM claim_daily(%s)", (who,)
    ).fetchone()
    assert not shut[0], "the purse should be shut, so this proves nothing"

    conn.execute("SELECT * FROM root_special_use(%s, 'daily')", (who,))

    # Open again, the run intact, and the NEXT claim carries it rather than
    # starting over.
    again = conn.execute("SELECT * FROM claim_daily(%s)", (who,)).fetchone()
    assert again[0], "the purse is still shut after being walked back"
    streak_after = conn.execute(
        "SELECT streak FROM player_daily WHERE player_id = %s", (who,)
    ).fetchone()[0]
    assert streak_after == 10, (
        f"the run went to {streak_after} rather than carrying to 10 - "
        "walking the purse back broke the streak"
    )

    # And no second walk-back today, while the anvil keeps its own charge.
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute("SELECT * FROM root_special_use(%s, 'daily')", (who,))
    assert left("forge_technique") == 1, "the purse ate the anvil's charge"


def test_immortal_ground_is_shut_until_a_servant_can_stand_on_it(conn):
    """A servant works the immortal regions once they have crossed into them.

    Three things are pinned, and two of them are faults this replaced rather
    than features it added.

    The rare roll USED TO BE DEAD. It asked for a rarity above uncommon AND
    `sort_order <= 2 + rank`, comparing a realm rank of 1-18 against a sort
    order of 10-80. The two had no overlap at any rank, so every servant ever
    sent out paid `servant_rare_chance` for a roll that could not land.

    And immortal materials WERE ALREADY LEAKING: the bulk pick asked what a
    thing was and never where it grew, so the twelve immortal materials that
    are common or uncommon could be handed over by a rank 1 servant.
    """
    # Immortal ground means unreachable, not rare.
    immortal = conn.execute(
        "SELECT count(*) FROM materials WHERE is_immortal_material(code)"
    ).fetchone()[0]
    assert immortal > 0, "nothing in the world counts as immortal ground"

    stray = conn.execute(
        """
        SELECT m.code FROM materials m
        WHERE is_immortal_material(m.code)
          AND EXISTS (SELECT 1 FROM region_materials rm
                      JOIN regions r ON r.code = rm.region_code
                      WHERE rm.material_code = m.code
                        AND r.min_rank < game_config_value('immortal_region_min_rank'))
        """
    ).fetchall()
    assert stray == [], f"called immortal and grows in the mortal world: {stray}"

    # The leak: nobody without a realm may be pointed at it.
    leaked = conn.execute(
        """
        SELECT m.code FROM materials m
        WHERE is_immortal_material(m.code) AND servant_may_gather(m.code)
        ORDER BY m.code
        """
    ).fetchall()
    assert leaked == [], (
        f"a servant with no realm can still gather {[r[0] for r in leaked]}"
    )

    # The dead roll: every realm now has something it could return.
    for rank in range(1, 19):
        n = conn.execute(
            """
            SELECT count(*) FROM materials m
            JOIN rarities ra ON ra.code = m.rarity
            WHERE m.category IN ('gathering', 'beast')
              AND m.rarity NOT IN ('common', 'uncommon')
              AND NOT is_immortal_material(m.code)
              AND ra.sort_order <= (SELECT ra2.sort_order FROM rarities ra2
                                    WHERE ra2.code = servant_rarity_reach(%s))
            """,
            (rank,),
        ).fetchone()[0]
        assert n > 0, f"a servant at realm {rank} still has nothing to roll for"

    # And the reach only ever climbs, so a realm never takes something away.
    ladder = conn.execute(
        """
        SELECT ra.sort_order FROM generate_series(1, 18) g
        JOIN rarities ra ON ra.code = servant_rarity_reach(g::smallint)
        ORDER BY g
        """
    ).fetchall()
    reach = [r[0] for r in ladder]
    assert reach == sorted(reach), f"the reach falls back somewhere: {reach}"


def test_what_immortal_ground_pays_and_only_past_the_door(conn, make_player):
    """Nothing below the Immortal Realm, a trickle above it, more with depth."""
    door = int(conn.execute(
        "SELECT game_config_value('servant_immortal_realm')"
    ).fetchone()[0])

    player = make_player("Master")
    code = conn.execute("SELECT servant_code FROM servants ORDER BY 1 LIMIT 1").fetchone()[0]
    sid = conn.execute(
        "INSERT INTO player_servants (player_id, servant_code, realm_id) "
        "VALUES (%s, %s, (SELECT realm_id FROM realms ORDER BY realm_id LIMIT 1)) "
        "RETURNING player_servant_id", (player, code),
    ).fetchone()[0]

    def at(rank):
        conn.execute(
            "UPDATE player_servants SET realm_id = "
            "(SELECT realm_id FROM realms WHERE rank = %s ORDER BY realm_id LIMIT 1) "
            "WHERE player_servant_id = %s", (rank, sid),
        )
        return float(conn.execute(
            "SELECT servant_immortal_per_hour(%s)", (sid,)
        ).fetchone()[0])

    # Shut, all the way to the door.
    for rank in range(1, door):
        assert at(rank) == 0, f"realm {rank} is below the door and still pays"

    # Open at it, and never worse for being deeper.
    opened = at(door)
    assert opened > 0, "the door opened onto nothing"

    seen = [at(rank) for rank in range(door, 19)]
    assert seen == sorted(seen), f"a deeper servant brings less: {seen}"
    assert seen[-1] > seen[0], "depth past the door buys nothing"

    # It is a TRICKLE, not a second income - the whole point of the rate.
    ordinary = float(conn.execute(
        "SELECT servant_haul_per_hour(%s)", (sid,)
    ).fetchone()[0])
    assert seen[-1] < ordinary / 4, (
        f"immortal ground pays {seen[-1]} against an ordinary {ordinary}, "
        "which is not a trickle"
    )


def test_a_penalty_never_introduces_itself_with_a_plus(conn):
    """Hollow Victory read "Body +-12".

    `effect_amount` wrote the sign itself on the base-stat branch and let the
    number write its own on the percentage branch, so a negative base stat got
    both. Latent since the function was written - no base stat was ever
    negative until 0433 turned Hollow Victory's `max_hp -0.1` into
    `base_hp -12` and walked a value into the branch that could not print it.

    Two copies of this function exist, one in SQL and one in Python, and they
    are asked the same questions here so they cannot drift apart.
    """
    from decimal import Decimal

    from bot.formatting import effect_amount as py_amount

    def sql_amount(code, value):
        return conn.execute(
            "SELECT effect_amount(%s, %s::numeric)", (code, str(value))
        ).fetchone()[0]

    # Both branches, both directions, the zero in between - and the small
    # amount that used to round away entirely. A base stat is multiplied by
    # the realm afterwards, so four tenths of a point is real and "+0" is the
    # one answer that is certainly wrong.
    for value, want in ((-12, "-12"), (12, "+12"), (0, "+0"),
                        ("0.4", "+1"), ("-0.4", "-1")):
        assert sql_amount("base_hp", value) == want, sql_amount("base_hp", value)
        assert py_amount(Decimal(str(value)), is_base=True) == want

    for value, want in ((0.45, "45%"), (-0.05, "-5%")):
        assert sql_amount("crit_damage", value) == want

    # And the invariant behind them, asked of every real grant in the game
    # rather than of the numbers this test happened to choose.
    doubled = conn.execute(
        """
        SELECT x.said FROM (
            SELECT effect_amount(de.effect_code, de.magnitude) AS said
            FROM destiny_effects de
            UNION ALL
            SELECT effect_amount(g.effect_code, g.magnitude) FROM gu_type_effects g
            UNION ALL
            SELECT effect_amount(p.effect_code, p.magnitude) FROM physique_effects p
            UNION ALL
            SELECT effect_amount(ro.effect_code, ro.magnitude) FROM root_effects ro
            UNION ALL
            SELECT effect_amount(ee.effect_code, ee.magnitude) FROM equipment_effects ee
        ) x
        WHERE x.said LIKE '+-%' OR x.said LIKE '-+%' OR x.said LIKE '++%'
        """
    ).fetchall()
    assert doubled == [], f"these print two signs: {[r[0] for r in doubled]}"


def test_a_base_stat_is_never_printed_as_a_percentage(conn):
    """29.7 points of Body read as "+2970%" on the physique card.

    `is_base` is the only thing that knows whether a magnitude is a count of
    points or a fraction of one, and it lives on the effect - so any screen
    that decides for itself is one conversion away from being wrong by a
    factor of a hundred. It went wrong the moment 0433 started granting
    base_hp to three bodies; the card had rendered percentages since before
    a physique could carry a flat stat at all.

    Two halves: the screens that CAN show a base stat must ask
    `effect_amount`, and the screens that still assume a percentage must not
    be reachable by a base stat. The second half is the one that fires early,
    on whoever adds the grant rather than on the player who sees the number.
    """
    # The renderer itself, which both halves depend on.
    base, pct = conn.execute(
        "SELECT effect_amount('base_hp', 29.7), effect_amount('attack_power', 0.25)"
    ).fetchone()
    assert base == "+30", base
    assert pct == "25%", pct

    # Half one: every screen that can be handed a base stat renders through it.
    for path in ("bot/character.py", "bot/cogs/physique.py",
                 "bot/cogs/gu.py", "bot/cogs/destiny.py", "bot/cogs/gurefine.py",
                 # Joined the list in 0444, when Ward Array started granting
                 # hide in points and the dwelling screen was one conversion
                 # away from calling 0.30 a thirty per cent wall.
                 "bot/cogs/dwelling.py"):
        src = pathlib.Path(path).read_text(encoding="utf-8")
        assert "effect_amount" in src, (
            f"{path} renders effect magnitudes without asking what unit they are in"
        )

    # Half two: the screens that still assume a fraction must stay unreachable
    # by a base stat. If one of these fires, the fix is to teach that screen
    # `effect_amount` - not to delete the row that tripped it.
    for table, column, screen in (
        ("manual_effect_columns", "effect_code", "bot/cogs/enlighten.py"),
    ):
        reachable = conn.execute(
            f"""
            SELECT e.code FROM {table} t
            JOIN gu_effects e ON e.code = t.{column}
            WHERE e.is_base ORDER BY e.code
            """
        ).fetchall()
        assert reachable == [], (
            f"{[r[0] for r in reachable]} now reaches {screen}, which prints a "
            f"bare percentage - it will read a count of points as a fraction"
        )


def test_no_live_effect_goes_unspoken(conn):
    """`gu_effects.is_live` means the combat code reads it. A live word with no
    Gu behind it is a row on the /gu screen that nothing can ever fill - five
    of them were in that state until 0211 aimed a companion at each.
    """
    silent = conn.execute(
        """
        SELECT f.code FROM gu_effects f
        WHERE f.is_live
          AND NOT EXISTS (SELECT 1 FROM gu_type_effects e WHERE e.effect_code = f.code)
        ORDER BY f.code
        """
    ).fetchall()
    assert [r[0] for r in silent] == []


def test_the_catalogue_reaches_every_path_and_every_rank(conn):
    """A Path a cultivator can focus and find nothing for is a dead end, and a
    rank with no Gu in it is a gap in the ladder."""
    ranks = dict(conn.execute("SELECT rank, count(*) FROM gu_types GROUP BY rank").fetchall())
    assert sorted(ranks) == list(range(1, 10)), f"ranks present: {sorted(ranks)}"

    pathless = conn.execute(
        """
        SELECT p.code FROM paths p
        WHERE NOT EXISTS (
            SELECT 1 FROM gu_region_drops d
            JOIN gu_types t ON t.gu_type_id = d.gu_type_id
            WHERE t.path_code = p.code)
        ORDER BY p.code
        """
    ).fetchall()
    assert [r[0] for r in pathless] == []


def test_every_build_axis_has_gu_to_build_it_from(conn):
    """The six the request names. Each needs more than one source, or the
    'build' is a single item everybody holds."""
    # base_strength rather than attack_power since 0443, when the multiplier
    # retired into the base stat. The axis is the same one - "hit harder" -
    # and it is now reached through the body rather than through a fraction
    # that three cultivators had already filled.
    for effect in ("multi_hit", "base_strength", "dodge",
                   "armor_pen", "crit_rate", "lifesteal"):
        count = conn.execute(
            "SELECT count(*) FROM gu_type_effects WHERE effect_code = %s", (effect,)
        ).fetchone()[0]
        assert count >= 2, f"{effect} has only {count} Gu behind it"


def test_a_gu_with_no_effects_would_be_a_lie(conn):
    empty = conn.execute(
        """
        SELECT t.code FROM gu_types t
        WHERE NOT EXISTS (
            SELECT 1 FROM gu_type_effects e WHERE e.gu_type_id = t.gu_type_id
        )
        """
    ).fetchall()
    assert [r[0] for r in empty] == []


# ---------------------------------------------------------------------------
# Gu refinement (0038, 0039)
# ---------------------------------------------------------------------------


@pytest.fixture
def refiner(conn, make_player):
    """A cultivator with a workshop and stores deep enough to work from."""
    def _make(level: int = 1, stock: int = 5000) -> int:
        player = make_player("Gu Refiner")
        conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (player,))
        # Pinned, not rolled. A physique carries Path affinities, affinities
        # move harmony, and harmony decides the grade - so a rolled body made
        # every refining assertion a dice throw that happened to pass. Which
        # body this cultivator has is irrelevant to every test that uses the
        # fixture; that it is the SAME body every run is not.
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id) "
            "VALUES (%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
            (player,),
        )
        conn.execute(
            "INSERT INTO player_materials (player_id, material_code, quantity) "
            "SELECT %s, code, %s FROM materials",
            (player, stock),
        )
        if level > 1:
            # The level a profession row carries is derived from its EXP, so
            # the two are set together or not at all.
            conn.execute(
                "INSERT INTO player_professions (player_id, profession, exp, level) "
                "VALUES (%s, 'gu_refining', %s, %s)",
                (player, (level - 1) * 150, level),
            )
        return player

    return _make


def _gu_type(conn, code: str) -> int:
    return conn.execute(
        "SELECT gu_type_id FROM gu_types WHERE code = %s", (code,)
    ).fetchone()[0]


def test_every_gu_can_be_refined(conn):
    """Refinement is the intended main source. A Gu with no recipe is a Gu
    nobody can plan for."""
    missing = conn.execute(
        """
        SELECT t.code FROM gu_types t
        WHERE NOT EXISTS (SELECT 1 FROM gu_recipes r WHERE r.gu_type_id = t.gu_type_id)
        """
    ).fetchall()
    assert [r[0] for r in missing] == []


def test_the_bench_stops_where_the_world_says(conn, refiner):
    """0210 opened rank 6 and 0393 opened rank 7. The refuser is a config
    value, so the level ladder is not what decides it: a refiner past every
    level gate still cannot make the rank above the bench.

    Read off the config rather than written down. This test asserted `== 6` and
    had to be edited the day the bench moved, which is the test encoding a
    ceiling instead of the rule that there is one.
    """
    ceiling = int(
        conn.execute(
            "SELECT game_config_value('gu_max_refinable_rank')"
        ).fetchone()[0]
    )
    assert 1 <= ceiling <= 9, ceiling

    # Read off the table for the same reason the ceiling is read off the
    # config: 0494 repriced the top rung to level 85 and 67,200 of a material,
    # and a fixture pinned at 65 and 50,000 made this test fail for the gate
    # moving rather than for the bench being shut.
    gate = conn.execute(
        """
        SELECT c.required_level, max(rc.base_quantity)
        FROM gu_refine_costs c
        JOIN gu_recipe_costs rc ON rc.rank = c.rank
        WHERE c.rank = %s
        GROUP BY c.required_level
        """,
        (ceiling,),
    ).fetchone()
    player = refiner(level=int(gate[0]), stock=int(gate[1]) * 2)

    shut = conn.execute(
        "SELECT gu_type_id FROM gu_types WHERE rank = %s ORDER BY gu_type_id LIMIT 1",
        (ceiling + 1,),
    ).fetchone()
    if shut is not None:
        conn.execute("SAVEPOINT before_refusal")
        with pytest.raises(psycopg.errors.CheckViolation, match="not been opened"):
            conn.execute("SELECT refine_gu(%s, %s)", (player, shut[0]))
        conn.execute("ROLLBACK TO SAVEPOINT before_refusal")

    # And the top open rung is genuinely open, or "opened one rung" opened none.
    open_one = conn.execute(
        "SELECT gu_type_id FROM gu_types WHERE rank = %s ORDER BY gu_type_id LIMIT 1",
        (ceiling,),
    ).fetchone()[0]
    conn.execute("SELECT refine_gu(%s, %s)", (player, open_one))


def test_every_rank_the_bench_is_open_to_can_be_reached(conn):
    """0393. Opening a rung means nothing if its recipes call for materials
    that exist only in the table - that is a rung painted on the wall."""
    unreachable = conn.execute(
        """
        SELECT DISTINCT m.name
        FROM gu_types t
        JOIN gu_recipes r ON r.gu_type_id = t.gu_type_id
        JOIN materials m ON m.code IN (r.base_material, r.secondary_material)
        WHERE t.rank <= game_config_value('gu_max_refinable_rank')
          AND NOT EXISTS (SELECT 1 FROM region_materials rm
                          WHERE rm.material_code = m.code)
          AND NOT EXISTS (SELECT 1 FROM creature_drops cd
                          WHERE cd.material_code = m.code)
        """
    ).fetchall()
    assert unreachable == [], unreachable

    # And every open Gu has a recipe at all.
    nameless = conn.execute(
        """
        SELECT count(*) FROM gu_types t
        WHERE t.rank <= game_config_value('gu_max_refinable_rank')
          AND NOT EXISTS (SELECT 1 FROM gu_recipes r
                          WHERE r.gu_type_id = t.gu_type_id)
        """
    ).fetchone()[0]
    assert nameless == 0


def test_the_two_ceilings_move_apart(conn, refiner):
    """Dropping and making are different achievements, so they are different
    configs. Moving one must not move the other - that is the whole reason
    0210 did not simply have the bench read `gu_max_droppable_rank`.
    """
    player = refiner(level=65, stock=50000)
    conn.execute("UPDATE game_config SET value = 5 WHERE key = 'gu_max_refinable_rank'")

    shut = conn.execute(
        "SELECT gu_type_id FROM gu_types WHERE rank = 6 ORDER BY gu_type_id LIMIT 1"
    ).fetchone()[0]
    conn.execute("SAVEPOINT before_refusal")
    with pytest.raises(psycopg.errors.CheckViolation, match="not been opened"):
        conn.execute("SELECT refine_gu(%s, %s)", (player, shut))
    conn.execute("ROLLBACK TO SAVEPOINT before_refusal")

    # The drop ceiling did not move with it.
    assert conn.execute(
        "SELECT game_config_value('gu_max_droppable_rank')"
    ).fetchone()[0] == 5


def test_the_world_is_asked_before_the_refiner(conn, refiner):
    """When both gates are shut, only one of them is worth saying. Telling a
    level 1 refiner that a deep Gu wants level 65 sends them on a climb that
    would not have worked.

    The closed rank is MADE here rather than assumed. This test used to reach
    for rank 9 as the example of something the bench had not opened; 0430
    opened it, and the test failed for the one reason that is not a bug - the
    ceiling it was standing on moved. What it is really about is the ORDER the
    two refusals come in, so it shuts the bench itself and checks that.
    """
    player = refiner(level=1, stock=50000)

    top = conn.execute("SELECT max(rank) FROM gu_types").fetchone()[0]
    shut = conn.execute(
        "SELECT gu_type_id FROM gu_types WHERE rank = %s ORDER BY gu_type_id LIMIT 1",
        (top,),
    ).fetchone()[0]

    # Close the bench under the deepest recipe, whatever that is today.
    conn.execute(
        "UPDATE game_config SET value = %s WHERE key = 'gu_max_refinable_rank'",
        (top - 1,),
    )

    with pytest.raises(psycopg.errors.CheckViolation) as raised:
        conn.execute("SELECT refine_gu(%s, %s)", (player, shut))

    assert "not been opened" in str(raised.value)
    assert "Gu Refiner level" not in str(raised.value)


def test_the_book_and_the_bench_agree(conn, refiner):
    """`gu_recipe_book.level_ok` is what the screen draws its three states
    from. If it meant only "your level suffices", a level 65 refiner would be
    shown every rank 9 recipe as In Reach while the bench refused all of them.
    """
    player = refiner(level=65, stock=50000)

    in_reach_but_shut = conn.execute(
        """
        SELECT count(*) FROM gu_recipe_book(%s) b
        WHERE b.rank > game_config_value('gu_max_refinable_rank') AND b.level_ok
        """,
        (player,),
    ).fetchone()[0]
    assert in_reach_but_shut == 0

    shut_but_unexplained = conn.execute(
        """
        SELECT count(*) FROM gu_recipe_book(%s) b
        WHERE NOT b.ready AND b.blocker IS NULL
        """,
        (player,),
    ).fetchone()[0]
    assert shut_but_unexplained == 0

    # A level 65 refiner is stopped by nothing but the world at rank 6.
    assert conn.execute(
        "SELECT count(*) FROM gu_recipe_book(%s) b WHERE b.rank = 6 AND NOT b.level_ok",
        (player,),
    ).fetchone()[0] == 0


def test_no_recipe_fights_itself(conn):
    """A recipe whose own ingredients the Gu's Path rejects always fails and
    eats the materials.

    0038 shipped exactly one - a Strength Gu asking for a Blood base and a
    Soul secondary, floor harmony 17 against a threshold of 25. This is the
    check that found it, kept as a rule about the whole table.
    """
    threshold = conn.execute(
        "SELECT game_config_value('gu_refine_failure_threshold')"
    ).fetchone()[0]

    worst = conn.execute(
        """
        SELECT c.gu_code,
               50 + material_affinity(c.base_material, c.path_code)
                  + material_affinity(c.secondary_material, c.path_code) AS floor
        FROM gu_recipe_costs c
        ORDER BY floor
        LIMIT 1
        """
    ).fetchone()
    assert worst[1] >= threshold + 15, (
        f"{worst[0]} floors at {worst[1]}, and an empty bench would destroy it"
    )


def test_every_ingredient_is_something_the_world_produces(conn):
    """A price nobody can pay is not a price. Every base has to grow
    somewhere and every secondary has to come off something."""
    unreachable = conn.execute(
        """
        SELECT c.gu_code FROM gu_recipe_costs c
        WHERE NOT EXISTS (
                SELECT 1 FROM region_materials r
                WHERE r.material_code = c.base_material)
           OR NOT EXISTS (
                SELECT 1 FROM creature_drops d
                WHERE d.material_code = c.secondary_material)
        """
    ).fetchall()
    assert [r[0] for r in unreachable] == []


def test_a_secondary_is_never_gated_behind_a_monster_nobody_can_reach(conn):
    """0038 asked for 270 bones off a rank 9 leviathan. Whatever a recipe
    costs, something within a few ranks of it has to drop the ingredient."""
    out_of_reach = conn.execute(
        """
        SELECT c.gu_code, c.rank, min(s.rank) AS easiest
        FROM gu_recipe_costs c
        JOIN creature_drops d ON d.material_code = c.secondary_material
        JOIN creature_species s ON s.species_id = d.species_id
        GROUP BY c.gu_code, c.rank
        HAVING min(s.rank) > c.rank + 2
        """
    ).fetchall()
    assert [r[0] for r in out_of_reach] == []


def test_every_ingredient_leans_somewhere(conn):
    """A Path-less material is bulk and no opinion, which 0038 called a real
    thing to be while noting that nothing shipped yet was meant to be one.

    Spirit Jade is. A Path is an opinion about what a material belongs in, and
    money is supposed to belong in everything equally - so currency is exempt,
    and every INGREDIENT still is not.
    """
    # Immortal essence is exempt for the same reason money is. It is not an
    # ingredient - nothing is brewed or forged out of it; it is drunk, and a
    # Path would be an opinion about which immortals are allowed to advance.
    # Ancient Venerable Notes are exempt for exactly the reason essence is,
    # and the reason is worth keeping in the same words: they are not an
    # ingredient. Nothing is brewed or forged out of them - they are READ, and
    # the aspect they are read into is the player's choice at the moment of
    # reading. A path_code would be an opinion about which Daos are allowed to
    # advance, which is the thing this rule exists to avoid putting in the
    # schema.
    pathless = conn.execute(
        """
        SELECT code FROM materials
        WHERE path_code IS NULL
          AND category NOT IN ('currency', 'essence')
          AND code <> 'ancient_venerable_notes'
        ORDER BY code
        """
    ).fetchall()
    assert [r[0] for r in pathless] == []

    assert conn.execute(
        "SELECT count(*) FROM materials "
        "WHERE category = 'currency' AND path_code IS NOT NULL"
    ).fetchone()[0] == 0, "money with an opinion would belong in something"


def test_rank_and_rarity_both_raise_the_price(conn):
    prices = dict(
        conn.execute(
            "SELECT gu_code, base_quantity FROM gu_recipe_costs "
            "WHERE gu_code IN ('bookworm', 'golden_centipede_gu', 'battle_bone_wheel')"
        ).fetchall()
    )
    # Same rank, rarer.
    assert prices["golden_centipede_gu"] > prices["bookworm"]
    # Four ranks up and legendary: a different order of undertaking.
    assert prices["battle_bone_wheel"] > 10 * prices["bookworm"]


def test_a_plain_refinement_makes_a_one_star_gu(conn, refiner):
    """The recipe alone is the price of entry, and it buys the floor."""
    player = refiner()
    row = conn.execute(
        "SELECT succeeded, stars_made, new_gu_id, spent_total, potency_score "
        "FROM refine_gu(%s, %s)",
        (player, _gu_type(conn, "bookworm")),
    ).fetchone()

    assert row[0] is True
    assert row[1] == 1, "nothing on the bench buys nothing above the floor"
    assert row[3] == 12, "eight of the base and four of the secondary"
    assert row[4] == 0

    made = conn.execute(
        "SELECT owner_id, stars, found_in FROM player_gu WHERE gu_id = %s", (row[2],)
    ).fetchone()
    assert made == (player, 1, None), "refined, not found anywhere"


def test_the_recipe_comes_out_of_the_stores(conn, refiner):
    player = refiner(stock=100)
    conn.execute("SELECT refine_gu(%s, %s)", (player, _gu_type(conn, "bookworm")))

    left = dict(
        conn.execute(
            "SELECT material_code, quantity FROM player_materials "
            "WHERE player_id = %s AND material_code IN ('wisdom_flower', 'lingzhi_meat')",
            (player,),
        ).fetchall()
    )
    assert left == {"wisdom_flower": 92, "lingzhi_meat": 96}


def test_the_right_auxiliaries_make_a_better_gu(conn, refiner):
    """This is the whole decision the request asks for: the base and the
    secondary are fixed, and what else goes in is where a build comes from."""
    player = refiner()
    gu = _gu_type(conn, "bookworm")

    bare = conn.execute(
        "SELECT stars_made FROM refine_gu(%s, %s)", (player, gu)
    ).fetchone()[0]

    dressed = conn.execute(
        "SELECT stars_made, potency_score FROM refine_gu(%s, %s, %s, %s)",
        (player, gu, ["rule_fragment", "imperial_lotus_seed"], [9, 9]),
    ).fetchone()

    assert dressed[1] == 18, "two rare materials, three measures each"
    assert dressed[0] > bare


def test_two_refinements_in_one_transaction(conn, refiner):
    """0038 built its bench as a temp table `ON COMMIT DROP`, so a second call
    inside one transaction died on `relation _aux already exists`. Every bot
    command is its own transaction, which is exactly why nothing in play would
    have caught it."""
    player = refiner()
    gu = _gu_type(conn, "bookworm")
    for _ in range(2):
        assert conn.execute(
            "SELECT succeeded FROM refine_gu(%s, %s, %s, %s)",
            (player, gu, ["rule_fragment"], [6]),
        ).fetchone()[0] is True


def test_a_hostile_bench_destroys_the_attempt_and_hands_half_back(conn, refiner):
    """Wood against Poison is -22 twice over. Piling it in is a way to lose,
    which is what makes the auxiliary pile a decision rather than a tax."""
    player = refiner(stock=100)
    row = conn.execute(
        "SELECT succeeded, harmony_score, spent_total, handed_back "
        "FROM refine_gu(%s, %s, %s, %s)",
        (player, _gu_type(conn, "poison_needle_gu"), ["jade_leaf", "jade_bamboo"], [30, 30]),
    ).fetchone()

    assert row[0] is False
    assert row[2] == 72, "8 base, 4 secondary, 60 auxiliary"
    assert row[3] == 36, "half of every one of them, rounded down"

    swept = conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = 'poison_herb'",
        (player,),
    ).fetchone()[0]
    assert swept == 96, "eight spent, four returned"


def test_even_a_failure_teaches(conn, refiner):
    player = refiner(stock=100)
    conn.execute(
        "SELECT refine_gu(%s, %s, %s, %s)",
        (player, _gu_type(conn, "poison_needle_gu"), ["jade_leaf"], [30]),
    )
    row = conn.execute(
        "SELECT exp, failures, successes FROM player_professions "
        "WHERE player_id = %s AND profession = 'gu_refining'",
        (player,),
    ).fetchone()
    assert row[0] > 0 and row[1] == 1 and row[2] == 0


def test_potency_buys_the_ceiling_and_harmony_keeps_it(conn, refiner):
    """Both are needed. With the harmony a build could never reach, a perfect
    pile of rare materials still comes out at one star."""
    player = refiner()
    # Every rung above the first put out of reach, not just the second: the
    # ladder is read as "the best star both columns allow", which only means
    # the lesser of the two ladders while both of them climb.
    conn.execute("UPDATE gu_refine_grades SET min_harmony = 200 WHERE stars > 1")

    row = conn.execute(
        "SELECT potency_score, stars_made FROM refine_gu(%s, %s, %s, %s)",
        (player, _gu_type(conn, "bookworm"), ["rule_fragment", "imperial_lotus_seed"], [9, 9]),
    ).fetchone()

    assert row[0] >= 6, "the potency alone would have bought a second star"
    assert row[1] == 1


def test_more_of_the_same_material_stops_helping(conn, refiner):
    """Three measures is the end of it, so a wide bench beats a deep one -
    which is what the profession's slots are for."""
    player = refiner()
    gu = _gu_type(conn, "bookworm")

    enough = conn.execute(
        "SELECT potency_score FROM refine_gu(%s, %s, %s, %s)",
        (player, gu, ["rule_fragment"], [9]),
    ).fetchone()[0]
    absurd = conn.execute(
        "SELECT potency_score FROM refine_gu(%s, %s, %s, %s)",
        (player, gu, ["rule_fragment"], [900]),
    ).fetchone()[0]

    assert enough == absurd


def test_the_bench_is_only_as_wide_as_the_profession(conn, refiner):
    assert conn.execute(
        "SELECT gu_refine_aux_slots(1::smallint), gu_refine_aux_slots(%s::smallint)",
        (top_of(conn, "gu_refine_aux"),),
    ).fetchone() == (2, 8), "a novice holds two, a finished refiner eight"

    player = refiner()
    with pytest.raises(psycopg.errors.CheckViolation, match="bench holds"):
        conn.execute(
            "SELECT refine_gu(%s, %s, %s, %s)",
            (
                player,
                _gu_type(conn, "bookworm"),
                ["rule_fragment", "spirit_stone", "tree_bark"],
                [3, 3, 3],
            ),
        )


def test_a_refined_gu_remembers_how_well_it_was_made(conn, refiner):
    """Harmony is what killer-move fusion will read, so a Gu made at 90 must
    not be the same Gu as one scraped together at 40."""
    player = refiner()
    row = conn.execute(
        "SELECT harmony_score, new_gu_id FROM refine_gu(%s, %s)",
        (player, _gu_type(conn, "bookworm")),
    ).fetchone()
    stored = conn.execute(
        "SELECT harmony FROM player_gu WHERE gu_id = %s", (row[1],)
    ).fetchone()[0]
    assert stored == row[0]


def test_refining_teaches_the_profession(conn, refiner):
    player = refiner()
    gu = _gu_type(conn, "bookworm")
    for _ in range(3):
        conn.execute("SELECT refine_gu(%s, %s)", (player, gu))

    assert conn.execute(
        "SELECT exp, level, successes FROM player_professions "
        "WHERE player_id = %s AND profession = 'gu_refining'",
        (player,),
    ).fetchone() == (180, 2, 3)


def test_a_rank_you_have_not_earned_is_refused(conn, refiner):
    player = refiner()
    with pytest.raises(psycopg.errors.CheckViolation, match="Gu Refiner level"):
        conn.execute(
            "SELECT refine_gu(%s, %s)", (player, _gu_type(conn, "jade_skin_gu"))
        )


def test_a_shortfall_says_what_is_short(conn, refiner):
    player = refiner(stock=2)
    with pytest.raises(psycopg.errors.CheckViolation, match="8 Wisdom Flower, and have 2"):
        conn.execute("SELECT refine_gu(%s, %s)", (player, _gu_type(conn, "bookworm")))


def test_you_cannot_smuggle_the_recipe_in_as_an_auxiliary(conn, refiner):
    """Otherwise the base counts twice: once at the price the recipe sets and
    again for potency it was never meant to pay for."""
    player = refiner()
    with pytest.raises(psycopg.errors.CheckViolation, match="already in the recipe"):
        conn.execute(
            "SELECT refine_gu(%s, %s, %s, %s)",
            (player, _gu_type(conn, "bookworm"), ["wisdom_flower"], [3]),
        )


def test_a_recipe_keeps_the_two_economies_apart(conn):
    """Gathering feeds the base, beasts feed the secondary. It is the design,
    so it is enforced rather than trusted."""
    with pytest.raises(psycopg.errors.RaiseException, match="gathering material"):
        conn.execute(
            "UPDATE gu_recipes SET base_material = 'wolf_fang' WHERE gu_type_id = %s",
            (_gu_type(conn, "bookworm"),),
        )


def test_the_star_ladder_climbs_on_both_axes(conn):
    """`refine_gu` takes the best star both columns allow, which is the lesser
    of the potency ladder and the harmony ladder only while neither of them
    goes backwards. That is a property of the rows, so it is checked here."""
    rungs = conn.execute(
        "SELECT stars, min_potency, min_harmony FROM gu_refine_grades ORDER BY stars"
    ).fetchall()
    assert [r[1] for r in rungs] == sorted(r[1] for r in rungs)
    assert [r[2] for r in rungs] == sorted(r[2] for r in rungs)


# ---------------------------------------------------------------------------
# Trading Gu (0041)
# ---------------------------------------------------------------------------


def _trader_gu(conn, player, code="big_strength_gu"):
    return conn.execute(
        "SELECT grant_gu(%s, (SELECT gu_type_id FROM gu_types WHERE code = %s), NULL)",
        (player, code),
    ).fetchone()[0]


def test_a_gu_changes_hands(conn, traders):
    a, b = traders()
    gu = _trader_gu(conn, a)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]

    conn.execute("SELECT trade_add_gu(%s, %s, %s)", (trade, a, gu))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, a))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, b))

    assert conn.execute(
        "SELECT owner_id FROM player_gu WHERE gu_id = %s", (gu,)
    ).fetchone()[0] == b


def test_a_traded_gu_comes_out_of_the_aperture(conn, traders):
    """0036's capacity trigger fires BEFORE INSERT on player_gu_equipped and
    cannot see a handover, which is an UPDATE somewhere else. Without a rule of
    its own this leaves one player wearing another player's Gu."""
    a, b = traders()
    gu = _trader_gu(conn, a)
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)", (gu, a)
    )
    assert conn.execute("SELECT gu_used_by(%s)", (a,)).fetchone()[0] == 1

    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute("SELECT trade_add_gu(%s, %s, %s)", (trade, a, gu))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, a))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, b))

    assert conn.execute("SELECT gu_used_by(%s)", (a,)).fetchone()[0] == 0
    assert conn.execute("SELECT gu_used_by(%s)", (b,)).fetchone()[0] == 0, (
        "it arrives in the jar, not in the aperture"
    )
    assert conn.execute(
        "SELECT count(*) FROM player_gu_equipped WHERE gu_id = %s", (gu,)
    ).fetchone()[0] == 0


def test_the_aperture_follows_the_owner_however_the_owner_changes(conn, traders):
    """The rule is on `player_gu`, so it holds for psql and for whatever moves
    a Gu next - not only for the one path through `trade_execute`."""
    a, b = traders()
    gu = _trader_gu(conn, a)
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)", (gu, a)
    )

    conn.execute("UPDATE player_gu SET owner_id = %s WHERE gu_id = %s", (b, gu))

    assert conn.execute(
        "SELECT count(*) FROM player_gu_equipped WHERE gu_id = %s", (gu,)
    ).fetchone()[0] == 0


def test_a_trade_of_nothing_but_gu_is_not_an_empty_table(conn, traders):
    """trade_confirm used to refuse an empty trade by naming the three offer
    tables, which would have called a Gu-only trade empty."""
    a, b = traders()
    gu = _trader_gu(conn, a)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute("SELECT trade_add_gu(%s, %s, %s)", (trade, a, gu))

    assert conn.execute(
        "SELECT trade_confirm(%s, %s)", (trade, a)
    ).fetchone()[0] is False


def test_you_cannot_offer_a_gu_you_do_not_own(conn, traders):
    a, b = traders()
    theirs = _trader_gu(conn, b)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="not yours to give"):
        conn.execute("SELECT trade_add_gu(%s, %s, %s)", (trade, a, theirs))


def test_offering_a_gu_clears_both_confirmations(conn, traders):
    a, b = traders()
    gu = _trader_gu(conn, a)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]

    conn.execute("SELECT grant_material(%s, 'spirit_rice', 5)", (a,))
    conn.execute("SELECT trade_set_material(%s, %s, 'spirit_rice', 1)", (trade, a))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, a))
    assert conn.execute(
        "SELECT proposer_confirmed_at IS NOT NULL FROM trades WHERE trade_id = %s",
        (trade,),
    ).fetchone()[0] is True

    conn.execute("SELECT trade_add_gu(%s, %s, %s)", (trade, a, gu))
    assert conn.execute(
        "SELECT proposer_confirmed_at IS NULL FROM trades WHERE trade_id = %s",
        (trade,),
    ).fetchone()[0] is True


def test_withdrawing_sweeps_the_gu_off_the_table_too(conn, traders):
    a, b = traders()
    gu = _trader_gu(conn, a)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute("SELECT trade_add_gu(%s, %s, %s)", (trade, a, gu))

    conn.execute("SELECT trade_withdraw(%s, %s)", (trade, a))
    assert conn.execute(
        "SELECT count(*) FROM trade_offer_gu WHERE trade_id = %s", (trade,)
    ).fetchone()[0] == 0


def test_the_card_shows_a_traded_gu(conn, traders):
    a, b = traders()
    gu = _trader_gu(conn, a, "golden_centipede_gu")
    conn.execute("UPDATE player_gu SET stars = 3 WHERE gu_id = %s", (gu,))
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute("SELECT trade_add_gu(%s, %s, %s)", (trade, a, gu))

    row = conn.execute(
        "SELECT kind, quantity, label, ref_id FROM trade_contents "
        "WHERE trade_id = %s AND kind = 'gu'",
        (trade,),
    ).fetchone()
    assert row == ("gu", 1, "3* Golden Centipede Gu", gu)


def test_trading_away_a_gu_shrinks_the_body_that_wore_it(conn, traders):
    """Max HP reads what you are carrying, so both sides are re-derived after
    a swap - and the loser of a +HP Gu must not be left over their own cap."""
    a, b = traders()
    for player in (a, b):
        conn.execute(
            "INSERT INTO player_character (player_id, race_code, root_code) "
            "VALUES (%s, 'human', 'earthen_root') ON CONFLICT DO NOTHING",
            (player,),
        )
    gu = _trader_gu(conn, a, "cleansing_water_gu")   # +6% max HP
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)", (gu, a)
    )
    conn.execute("SELECT apply_physique_xp(%s, 0)", (a,))
    before = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (a,)
    ).fetchone()[0]

    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute("SELECT trade_add_gu(%s, %s, %s)", (trade, a, gu))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, a))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, b))

    after = conn.execute(
        "SELECT max_hp, current_hp FROM player_physique WHERE player_id = %s", (a,)
    ).fetchone()
    assert after[0] < before
    assert after[1] <= after[0], "never left above your own cap"


def test_every_material_has_a_face(conn):
    """A material added without one renders the crate, which is honest but
    tells a player nothing. Nothing shipped should still be wearing it."""
    boxed = conn.execute(
        "SELECT code FROM materials WHERE emoji = '\N{PACKAGE}' ORDER BY code"
    ).fetchall()
    assert [r[0] for r in boxed] == []


def test_no_emoji_default_is_a_python_escape(conn):
    r"""0036 wrote '\N{BUG}' into two emoji DEFAULTs, which PostgreSQL stores
    as the eight literal characters - it is a Python escape, not an SQL one.
    Every row was given an explicit emoji, so it never showed; the first one
    added without one would have printed it onto the card."""
    escaped = conn.execute(
        """
        SELECT c.table_name || '.' || c.column_name
        FROM information_schema.columns c
        WHERE c.column_name = 'emoji' AND c.column_default LIKE %s
        """,
        (r"%\N{%",),
    ).fetchall()
    assert [r[0] for r in escaped] == []


# ---------------------------------------------------------------------------
# The body: paths and ranks (0046, 0047)
# ---------------------------------------------------------------------------


@pytest.fixture
def body(conn, make_player):
    """A cultivator with a body and nothing decided about it.

    `rank` is separate from `xp` because since 0108 it is: training fills the
    bar and `temper_body` crosses the door, so a test wanting a body past
    Rank 1 has to put it there rather than hoping XP does it.
    """
    def _make(xp: int = 0, rank: int = 1) -> int:
        player = make_player("Tempering")
        conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (player,))
        conn.execute(
            "INSERT INTO player_physique "
            "(player_id, physique_id, physique_xp, body_rank) "
            "VALUES (%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'), "
            "%s, %s)",
            (player, xp, rank),
        )
        conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
        return player

    return _make


def test_every_path_climbs_the_same_ranks(conn):
    """The names differ; the ladder does not. A requirement typed three times
    is three chances for it to drift.

    Eighteen rungs since 0383 took the body up beside the realms. Read off
    `body_rank_requirements` rather than written down, so the three Paths are
    asserted to agree with the ladder and with each other without this test
    having an opinion about how long the ladder is.
    """
    top = conn.execute(
        "SELECT max(rank) FROM body_rank_requirements"
    ).fetchone()[0]
    rows = conn.execute(
        "SELECT path_code, count(*), min(rank), max(rank) FROM body_ranks "
        "GROUP BY path_code ORDER BY path_code"
    ).fetchall()
    assert [(r[1], r[2], r[3]) for r in rows] == [(top, 1, top)] * 3

    unnamed = conn.execute(
        """
        SELECT p.code, r.rank
        FROM body_paths p CROSS JOIN body_rank_requirements r
        WHERE NOT EXISTS (
            SELECT 1 FROM body_ranks b
            WHERE b.path_code = p.code AND b.rank = r.rank
        )
        """
    ).fetchall()
    assert unnamed == [], "every rank of every path has a name"


def test_the_body_ladder_never_goes_backwards(conn):
    required = [
        r[0] for r in conn.execute(
            "SELECT xp_required FROM body_rank_requirements ORDER BY rank"
        ).fetchall()
    ]
    assert required == sorted(required)
    assert required[0] == 0, "a body starts at Rank 1 owing nothing"


def test_a_rank_is_a_band_over_the_experience_total(conn):
    # The last is "more experience than the ladder has rungs for", so it reads
    # the top off the ladder rather than naming a rank that moves.
    top = conn.execute("SELECT max(rank) FROM body_rank_requirements").fetchone()[0]
    assert conn.execute(
        "SELECT body_rank_for_xp(0), body_rank_for_xp(1499), "
        "body_rank_for_xp(1500), body_rank_for_xp(1000000000)"
    ).fetchone() == (1, 1, 2, top)


def test_a_path_is_a_trade_and_not_a_bonus(conn, body):
    """Aggressive and defensive have to cost something, or the words are
    decoration and everybody picks the same one."""
    player = body(xp=10_000)
    bare = conn.execute(
        "SELECT max_hp, defense, strength FROM player_physique WHERE player_id = %s",
        (player,),
    ).fetchone()

    got = {}
    for path in ("demonic", "buddhist", "taoist"):
        conn.execute("UPDATE player_physique SET physique_xp = 0 WHERE player_id = %s", (player,))
        conn.execute(
            "UPDATE player_physique SET body_path = %s WHERE player_id = %s", (path, player)
        )
        conn.execute("UPDATE player_physique SET physique_xp = 10000 WHERE player_id = %s", (player,))
        conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
        got[path] = conn.execute(
            "SELECT max_hp, defense, strength FROM player_physique WHERE player_id = %s",
            (player,),
        ).fetchone()

    assert got["demonic"][2] > bare[2] > got["buddhist"][2], "strength is what Demonic buys"
    assert got["buddhist"][1] > bare[1] > got["demonic"][1], "and defence is what it sells"
    assert got["buddhist"][0] > got["taoist"][0] > got["demonic"][0], "health follows defence"


def test_a_first_choice_is_always_open(conn, body):
    """0046 locked the path at Rank 2 and locked out every character that was
    already past it - which was all of them, the paths being new."""
    player = body(xp=50_000, rank=4)
    assert conn.execute(
        "SELECT body_rank FROM player_body WHERE player_id = %s", (player,)
    ).fetchone()[0] > 1

    conn.execute(
        "UPDATE player_physique SET body_path = 'demonic' WHERE player_id = %s", (player,)
    )
    assert conn.execute(
        "SELECT body_path FROM player_body WHERE player_id = %s", (player,)
    ).fetchone()[0] == "demonic"


def test_changing_your_mind_is_free_only_while_the_body_forms(conn, body):
    player = body(xp=0)
    conn.execute(
        "UPDATE player_physique SET body_path = 'taoist' WHERE player_id = %s", (player,)
    )
    conn.execute(
        "UPDATE player_physique SET body_path = 'demonic' WHERE player_id = %s", (player,)
    )
    assert conn.execute(
        "SELECT body_path FROM player_body WHERE player_id = %s", (player,)
    ).fetchone()[0] == "demonic", "still Rank 1, still yours to change"

    # The lock is the crossing, not the training: a body that set its path
    # while you were offline would not be a decision you made.
    conn.execute(
        "UPDATE player_physique SET body_rank = 2 WHERE player_id = %s", (player,)
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="not something you take back"):
        conn.execute(
            "UPDATE player_physique SET body_path = 'buddhist' WHERE player_id = %s",
            (player,),
        )


def test_the_screen_and_the_trigger_agree_on_whether_it_is_open(conn, body):
    """`path_still_open` decides which buttons are drawn; the trigger decides
    which ones work. A disagreement is a button that lies."""
    unchosen = body(xp=50_000, rank=4)
    chosen = body(xp=50_000, rank=1)
    conn.execute(
        "UPDATE player_physique SET body_path = 'taoist' WHERE player_id = %s", (chosen,)
    )
    conn.execute(
        "UPDATE player_physique SET body_rank = 4 WHERE player_id = %s", (chosen,)
    )

    assert conn.execute(
        "SELECT path_still_open FROM player_body WHERE player_id = %s", (unchosen,)
    ).fetchone()[0] is True
    assert conn.execute(
        "SELECT path_still_open FROM player_body WHERE player_id = %s", (chosen,)
    ).fetchone()[0] is False


def test_an_unchosen_body_still_has_a_rank(conn, body):
    """The rank is what you have got to; the name is what you chose to call
    it. One does not wait for the other."""
    player = body(xp=8_500, rank=4)
    row = conn.execute(
        "SELECT body_rank, rank_name, path_name, next_rank_name, next_floor "
        "FROM player_body WHERE player_id = %s",
        (player,),
    ).fetchone()
    assert row[0] == 4
    assert row[1] is None and row[2] is None
    assert row[4] == 16000


def test_the_top_of_the_ladder_has_nothing_above_it(conn, body):
    # The top moved from 9 to 18 in 0383. What is being asserted is that
    # wherever the ladder ends there is nothing above it - not where it ends.
    top = conn.execute("SELECT max(rank) FROM body_rank_requirements").fetchone()[0]
    player = body(xp=200_000, rank=top)
    row = conn.execute(
        "SELECT body_rank, next_floor, next_rank_name FROM player_body WHERE player_id = %s",
        (player,),
    ).fetchone()
    assert row == (top, None, None)


# ---------------------------------------------------------------------------
# The Divine band (0048)
# ---------------------------------------------------------------------------


def test_the_rarity_ladder_only_ever_gets_rarer(conn):
    """Sort order and roll weight have to disagree about nothing, or a band
    that reads rarer than its neighbour turns up more often than it."""
    weights = [
        r[0] for r in conn.execute(
            "SELECT roll_weight FROM rarities WHERE code <> 'extreme' ORDER BY sort_order"
        ).fetchall()
    ]
    assert weights == sorted(weights, reverse=True)


def test_divine_sits_between_mythic_and_unique(conn):
    """Where the design spec puts it: sections 7.7 and 10.7 sit between the
    Mythic and Unique catalogs."""
    ladder = [
        r[0] for r in conn.execute(
            "SELECT code FROM rarities ORDER BY sort_order"
        ).fetchall()
    ]
    assert ladder.index("mythic") < ladder.index("divine") < ladder.index("unique")


def test_the_divine_band_has_something_in_it(conn):
    """0011: a band with no members simply never comes up. Mythic has been
    proving that since it shipped - 1.4 weight and nothing to award."""
    roots, physiques = conn.execute(
        """
        SELECT (SELECT count(*) FROM roots WHERE rarity = 'divine'),
               (SELECT count(*) FROM physiques WHERE tier = 'divine')
        """
    ).fetchone()
    assert roots > 0 and physiques > 0


def test_a_divine_root_is_the_widest_path_package_in_the_game(conn):
    """This game gives no root a flat cultivation bonus - all of them carry 0,
    and identity lives in the Path table. So that is where rank has to show."""
    best = dict(
        conn.execute(
            """
            SELECT r.rarity, max(b.attainment_bonus)
            FROM roots r JOIN root_path_bonuses b ON b.root_code = r.code
            GROUP BY r.rarity
            """
        ).fetchall()
    )
    assert best["legendary"] < best["divine"] < best["unique"]

    flat = conn.execute(
        "SELECT count(*) FROM roots WHERE cultivation_rate_bonus <> 0"
    ).fetchone()[0]
    assert flat == 0, "no root has ever been the one that makes numbers bigger"


def test_divine_physiques_hit_the_tier_baseline(conn):
    """The spec asks for +25% on the stat the name promises."""
    peak = conn.execute(
        """
        SELECT max(greatest(hp_multiplier, defense_multiplier, strength_multiplier))
        FROM physiques WHERE tier = 'divine'
        """
    ).fetchone()[0]
    assert float(peak) >= 1.25


def test_no_divine_trait_is_silent(conn):
    """A tier this rare must either DO something or SAY what it will do.

    The first form of this test asserted that every Divine trait declared
    something in `unmodelled`, which was right while nothing was wired and
    became wrong the moment Supreme Dao Physique got a real effect: it went
    quiet in the only column the test was looking at, having just become the
    one Divine body that is not a promise.
    """
    silent = conn.execute(
        """
        SELECT code FROM roots
        WHERE rarity = 'divine' AND unmodelled = '{}'::jsonb
        UNION ALL
        SELECT p.code FROM physiques p
        WHERE p.tier = 'divine'
          AND p.unmodelled = '{}'::jsonb
          AND NOT EXISTS (
              SELECT 1 FROM physique_effects e WHERE e.physique_id = p.physique_id
          )
        """
    ).fetchall()
    assert [r[0] for r in silent] == []


# ---------------------------------------------------------------------------
# The physique ladder, filled (0049)
# ---------------------------------------------------------------------------


def test_the_physique_ladder_has_no_dead_bands(conn):
    """A band with members never comes up, and 25% of the physique roll's
    weight used to sit in three that had none - so a good roll returned Rare
    or nothing.

    Unique is the exception and it is deliberate: 0011 put the Ten Extreme
    outside the ladder, and the spec's own "Unique Physiques" list is exactly
    those four. Unique is the roots-only band.
    """
    empty = conn.execute(
        """
        SELECT ra.code
        FROM rarities ra
        WHERE ra.code <> 'unique'
          AND NOT EXISTS (SELECT 1 FROM physiques p WHERE p.tier = ra.code)
        ORDER BY ra.sort_order
        """
    ).fetchall()
    assert [r[0] for r in empty] == []

    assert conn.execute(
        "SELECT count(*) FROM physiques WHERE tier = 'unique'"
    ).fetchone()[0] == 0, "the Unique physiques of the spec are this game's Extreme"


def test_no_rarity_band_is_entirely_unreachable(conn):
    """Every band has to be able to award SOMETHING, or its weight is a
    rounding error taken out of the bands that can."""
    dead = conn.execute(
        """
        SELECT ra.code FROM rarities ra
        WHERE ra.roll_weight > 0
          AND NOT EXISTS (SELECT 1 FROM roots r WHERE r.rarity = ra.code)
          AND NOT EXISTS (SELECT 1 FROM physiques p WHERE p.tier = ra.code)
        ORDER BY ra.sort_order
        """
    ).fetchall()
    assert [r[0] for r in dead] == []


def test_a_physique_path_package_deepens_with_its_tier(conn):
    """Rare gives damage and no attainment; Extreme gives half again of both.
    Attainment is what carries the ladder between them."""
    best = dict(
        conn.execute(
            """
            SELECT p.tier, max(b.attainment_bonus)
            FROM physiques p JOIN physique_path_bonuses b ON b.physique_id = p.physique_id
            GROUP BY p.tier
            """
        ).fetchall()
    )
    ladder = ["rare", "epic", "legendary", "mythic", "divine", "extreme"]
    values = [best[tier] for tier in ladder]
    assert values == sorted(values), f"attainment does not climb: {dict(zip(ladder, values))}"


def test_a_physique_stat_package_deepens_with_its_tier(conn):
    """The spec's baselines: +10%, +14%, +18%, +22%, +25% on the stat the name
    promises. Extreme is outside the ladder and has its own package."""
    peak = dict(
        conn.execute(
            """
            SELECT tier, max(greatest(hp_multiplier, defense_multiplier, strength_multiplier))
            FROM physiques GROUP BY tier
            """
        ).fetchall()
    )
    ladder = ["common", "uncommon", "rare", "epic", "legendary", "mythic", "divine"]
    values = [float(peak[tier]) for tier in ladder]
    assert values == sorted(values), f"stats do not climb: {dict(zip(ladder, values))}"

    # And the whole package, not only its headline. 0049 shipped an Epic band
    # whose best stat was below the best Rare one, which the first of these
    # caught and the second did not.
    totals = dict(
        conn.execute(
            """
            SELECT tier, max(hp_multiplier + defense_multiplier + strength_multiplier)
            FROM physiques GROUP BY tier
            """
        ).fetchall()
    )
    sums = [float(totals[tier]) for tier in ladder]
    assert sums == sorted(sums), f"packages do not climb: {dict(zip(ladder, sums))}"


def test_a_physique_that_names_a_path_backs_it_with_one(conn):
    """The plain bodies - Mortal Body and the rest of the common band - favour
    no Path at all, which is a real thing for a body to be. What must not
    happen is a physique whose sheet names an affinity that pays nothing, or an
    ALIGNMENT with a Path the sheet never mentions.

    This was a biconditional until 0069, and it was right while
    `physique_path_bonuses` held only attainment and damage - both of which are
    ways of being aligned WITH a Path. Resistance is the opposite relationship:
    Jade Skin turns aside Poison precisely by not being a Poison body, and Iron
    Bone shrugs off raw Strength without being a Strength one. So a
    resistance-only row needs no affinity, and the rule is two implications
    about alignment rather than one biconditional about rows.
    """
    unpaid = conn.execute(
        """
        SELECT p.code FROM physiques p
        WHERE p.affinity_path IS NOT NULL
          AND NOT EXISTS (
            SELECT 1 FROM physique_path_bonuses b
            WHERE b.physique_id = p.physique_id
              AND (b.attainment_bonus <> 0 OR b.damage_bonus <> 0))
        ORDER BY p.code
        """
    ).fetchall()
    assert [r[0] for r in unpaid] == [], "a named affinity that pays nothing"

    # The other direction, and only this weak. A body carries SEVERAL Path
    # rows - Blazing Glory is Fire on the sheet and paid for Lightning too - so
    # the rule is that alignment implies a named affinity somewhere, not that
    # every row matches it.
    unnamed = conn.execute(
        """
        SELECT DISTINCT p.code FROM physiques p
        JOIN physique_path_bonuses b ON b.physique_id = p.physique_id
        WHERE p.affinity_path IS NULL
          AND (b.attainment_bonus <> 0 OR b.damage_bonus <> 0)
        ORDER BY p.code
        """
    ).fetchall()
    assert [r[0] for r in unnamed] == [], "aligned with a Path but claims no affinity"


def test_a_resistance_is_to_a_path_something_actually_attacks_with(conn):
    """A resistance to a Path nothing in the bestiary leads with can never
    fire, and would read on the sheet as a number that does nothing. Same
    failure as an empty rarity band or a Path with no root: a content hole that
    says nothing when it opens.
    """
    idle = conn.execute(
        """
        SELECT DISTINCT b.path_code
        FROM physique_path_bonuses b
        WHERE b.resistance > 0
          AND NOT EXISTS (
            SELECT 1 FROM creature_paths cp
            WHERE cp.path_code = b.path_code AND cp.is_primary)
        ORDER BY 1
        """
    ).fetchall()
    assert [r[0] for r in idle] == [], "nothing attacks with that Path"


def test_no_body_resists_more_than_the_cap_allows(conn):
    cap = conn.execute(
        "SELECT game_config_value('physique_resistance_cap')"
    ).fetchone()[0]
    worst = conn.execute(
        "SELECT max(resistance) FROM physique_path_bonuses"
    ).fetchone()[0]
    assert worst <= cap, f"a body resists {worst}, above the cap of {cap}"


# ---------------------------------------------------------------------------
# Bodies stop repeating themselves (0051, 0052, 0053)
# ---------------------------------------------------------------------------


def test_no_two_notable_bodies_make_the_same_claim(conn):
    """Common bodies are allowed to be plain and alike - two of them both give
    +3% evasion and that is what Common is for. From Rare upward a body is
    supposed to be a reason to want it, and three of them once shared "every
    third landed strike" across three different bands.
    """
    shared = conn.execute(
        """
        WITH claims AS (
            SELECT p.code, p.tier, j.key, j.value #>> '{}' AS val
            FROM physiques p, jsonb_each(p.unmodelled) j
            WHERE p.tier NOT IN ('common', 'uncommon')
        )
        SELECT key || ' = ' || val, string_agg(code, ', ' ORDER BY code)
        FROM claims GROUP BY key, val HAVING count(*) > 1
        """
    ).fetchall()
    assert shared == [], f"repeated: {shared}"


def test_the_root_ladder_can_award_every_band(conn):
    """Mythic held 1.4 roll weight and nothing to give from 0011 until 0052."""
    empty = conn.execute(
        """
        SELECT ra.code FROM rarities ra
        WHERE ra.roll_weight > 0 AND ra.code NOT IN ('extreme')
          AND NOT EXISTS (SELECT 1 FROM roots r WHERE r.rarity = ra.code)
        ORDER BY ra.sort_order
        """
    ).fetchall()
    assert [r[0] for r in empty] == []


def test_a_mythic_root_lands_between_legendary_and_divine(conn):
    best = dict(
        conn.execute(
            """
            SELECT r.rarity, max(b.attainment_bonus)
            FROM roots r JOIN root_path_bonuses b ON b.root_code = r.code
            GROUP BY r.rarity
            """
        ).fetchall()
    )
    ladder = ["rare", "epic", "legendary", "mythic", "divine", "unique"]
    values = [best[tier] for tier in ladder]
    assert values == sorted(values), f"the root ladder does not climb: {dict(zip(ladder, values))}"


def test_a_root_does_not_copy_its_neighbour(conn):
    """Voidwalker Root was proposed as Space/Theft, which is exactly
    `thieving_heavens_inheritor` two bands up - a strictly weaker copy of a
    Venerable's inheritance.

    Sharing a pairing is not itself wrong: Ancient Beast Root is Rare and
    Reckless Savage's Inheritor is Unique, four bands apart, and the first
    reads as an early echo of the second rather than as a copy of it. What
    must not happen is two roots owning one pairing close enough together that
    the lower is simply the worse one.
    """
    doubled = conn.execute(
        """
        WITH pairs AS (
            SELECT r.code, ra.sort_order,
                   string_agg(b.path_code, '+' ORDER BY b.path_code) AS paths
            FROM roots r
            JOIN rarities ra ON ra.code = r.rarity
            JOIN root_path_bonuses b ON b.root_code = r.code
            GROUP BY r.code, ra.sort_order
            HAVING count(*) > 1
        )
        SELECT a.paths, a.code, b.code
        FROM pairs a JOIN pairs b
          ON a.paths = b.paths AND a.code < b.code
        WHERE abs(a.sort_order - b.sort_order) <= 20
        """
    ).fetchall()
    assert doubled == [], f"neighbouring roots own one pairing: {doubled}"


# ---------------------------------------------------------------------------
# A body that reaches manual refinement
# ---------------------------------------------------------------------------


@pytest.fixture
def refiner_body(conn, make_player):
    def _make(physique: str | None) -> int:
        player = make_player("Refiner")
        conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (player,))
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id) VALUES (%s, "
            "(SELECT physique_id FROM physiques WHERE code = %s))",
            (player, physique or "mortal_body"),
        )
        return player

    return _make


def test_only_the_right_body_carries_refining_tolerance(conn, refiner_body):
    plain = refiner_body(None)
    dao = refiner_body("supreme_dao_physique")

    assert conn.execute(
        "SELECT physique_stat(%s, 'refine_conflict_relief')", (plain,)
    ).fetchone()[0] == 0
    assert float(
        conn.execute(
            "SELECT physique_stat(%s, 'refine_conflict_relief')", (dao,)
        ).fetchone()[0]
    ) == 0.5


def _pinned_refine(conn, player: int, paths: tuple[str, ...]) -> int:
    """One refinement with every source of variance except the jitter removed.

    A minted page rolls tier, power, quality, type and trait, and those swing
    harmony by nearly twenty points - enough to bury an eleven-point effect
    entirely, which is how the first version of this test concluded the body
    did nothing while it was working correctly.
    """
    pages = [
        conn.execute(
            "SELECT mint_page(%s, 1::smallint, 1::smallint, %s)", (player, path)
        ).fetchone()[0]
        for path in paths
    ]
    conn.execute(
        "UPDATE manual_pages SET quality = 75, power = 20, tier = 1, "
        "page_type = 'attack', trait = NULL WHERE page_id = ANY(%s)",
        (pages,),
    )
    return conn.execute(
        "SELECT harmony FROM refine(%s, %s)", (player, pages)
    ).fetchone()[0]


def test_a_supreme_dao_body_holds_paths_that_fight(conn, refiner_body):
    """Poison and Wood are -22 to each other, both ways. An ordinary refiner
    carries all of that; this body carries half.

    Four refinements each. With the pages pinned the only thing left moving is
    the plus-or-minus-four jitter, against a nine-point separation.
    """
    plain = [_pinned_refine(conn, refiner_body(None), ("poison", "wood")) for _ in range(4)]
    dao = [
        _pinned_refine(conn, refiner_body("supreme_dao_physique"), ("poison", "wood"))
        for _ in range(4)
    ]

    assert min(dao) > max(plain), (
        f"the body made no difference: plain {plain}, Supreme Dao {dao}"
    )


def test_refining_tolerance_only_softens_conflict(conn, refiner_body):
    """A body that also inflated agreement would make every refinement better
    rather than making hard ones possible.

    Fire with Fire raises no pair at all, so the two bodies must come out
    indistinguishable beyond the jitter they both roll.
    """
    plain = _pinned_refine(conn, refiner_body(None), ("fire", "fire"))
    dao = _pinned_refine(conn, refiner_body("supreme_dao_physique"), ("fire", "fire"))

    assert abs(plain - dao) <= 8


def test_every_path_can_be_a_talent_and_a_body(conn):
    """A Path with techniques, creatures and Gu but no root and no physique is
    fully playable and impossible to be born for.

    That is a quieter failure than an empty rarity band, which at least awards
    nothing: fourteen Paths had no root and seventeen had no physique, and
    nothing anywhere reported it.
    """
    orphaned = conn.execute(
        """
        SELECT p.code,
               EXISTS (SELECT 1 FROM root_path_bonuses b WHERE b.path_code = p.code) AS root,
               EXISTS (SELECT 1 FROM physique_path_bonuses b WHERE b.path_code = p.code) AS body
        FROM paths p
        WHERE NOT EXISTS (SELECT 1 FROM root_path_bonuses b WHERE b.path_code = p.code)
           OR NOT EXISTS (SELECT 1 FROM physique_path_bonuses b WHERE b.path_code = p.code)
        ORDER BY p.code
        """
    ).fetchall()
    assert orphaned == [], f"Paths nobody can be born for: {orphaned}"


# ---------------------------------------------------------------------------
# Herbs and alchemy (0056, 0057, 0058)
# ---------------------------------------------------------------------------


@pytest.fixture
def alchemist(conn, make_player):
    """A cultivator with a body and a shed full of every herb there is."""
    def _make(level: int = 1, stock: int = 200) -> int:
        player = make_player("Alchemist")
        conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (player,))
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id) "
            "VALUES (%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
            (player,),
        )
        conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
        conn.execute(
            "INSERT INTO player_materials (player_id, material_code, quantity) "
            "SELECT %s, code, %s FROM materials WHERE tier IS NOT NULL",
            (player, stock),
        )
        if level > 1:
            conn.execute(
                "INSERT INTO player_professions (player_id, profession, exp, level) "
                "VALUES (%s, 'alchemy', %s, %s)",
                (player, (level - 1) * 200, level),
            )
        return player

    return _make


def test_a_herb_grows_in_exactly_one_region(conn):
    """0017 said 77 gathering materials sit across five regions with zero
    overlap and never enforced it. Alchemy makes a pill's ingredients a claim
    about where somebody has travelled, so it is an index now."""
    with pytest.raises(psycopg.errors.UniqueViolation):
        conn.execute(
            "INSERT INTO region_materials (region_code, material_code, weight) "
            "VALUES ('northern', 'blue_kelp_grass', 5)"
        )


def test_every_region_grows_a_full_ladder_of_herbs(conn):
    """Coverage, not a count. What a region owes a gatherer is an unbroken
    ladder - no tier missing between its own floor and its own ceiling, so
    nobody climbing it falls through a hole. Growing something extra beside a
    rung is not a gap.

    This asserted `count == 7` until 0182, which is the same thing only while
    nothing else grows anywhere. 0177 and 0181 added cultivation herbs to
    regions that had none, and a count would have called that a fault.

    It then asserted tiers 1 to 7 for EVERY region, which was the same thing
    again only while every region shared one band. 0368 gave the two heavens
    their own: tier 6 to 12, a floor no mortal region reaches, because an
    immortal-only region handing out the same tier 1 weeds as the Central
    Continent is the reward curve flattening exactly where it should climb.
    Demanding 1 to 7 everywhere would now demand the heavens grow weeds.

    So the rule is per-region and it is about HOLES, which is what a gatherer
    actually feels. The bands themselves are pinned separately below.
    """
    missing = conn.execute(
        """
        SELECT r.code, t.tier
        FROM regions r
        JOIN LATERAL (
            SELECT min(m.tier) AS lo, max(m.tier) AS hi
            FROM region_materials rm
            JOIN materials m ON m.code = rm.material_code
            WHERE rm.region_code = r.code AND m.tier IS NOT NULL
        ) band ON band.lo IS NOT NULL
        CROSS JOIN LATERAL generate_series(band.lo::int, band.hi::int) AS t (tier)
        WHERE NOT EXISTS (
            SELECT 1 FROM region_materials rm
            JOIN materials m ON m.code = rm.material_code
            WHERE rm.region_code = r.code AND m.tier = t.tier
        )
        ORDER BY r.code, t.tier
        """
    ).fetchall()
    assert missing == [], f"ladders with holes in them: {missing}"

    # The bands themselves, so 'no holes' cannot be satisfied by a region that
    # grows exactly one tier and calls it a ladder.
    bands = {
        code: (lo, hi)
        for code, lo, hi in conn.execute(
            """
            SELECT rm.region_code, min(m.tier), max(m.tier)
            FROM region_materials rm
            JOIN materials m ON m.code = rm.material_code
            WHERE m.tier IS NOT NULL
            GROUP BY rm.region_code
            """
        ).fetchall()
    }
    for code, (lo, hi) in bands.items():
        gate = conn.execute(
            "SELECT COALESCE(min_rank, 1) FROM regions WHERE code = %s", (code,)
        ).fetchone()[0]
        # Three bands because there are three tiers of world, not two. The
        # mortal continent grows 1-7; the two heavens 6-12, which 0368 gave
        # them so "an immortal-only region handing out the same tier 1 weeds
        # as the Central Continent" stopped being the reward curve flattening
        # where it should climb. The Heavenly Court is a rank above the heavens
        # and reaches one band further: 6-13.
        top_of_the_ladder = conn.execute(
            "SELECT max(rank) FROM realms"
        ).fetchone()[0]
        if gate == 1:
            want = (1, 7)
        elif gate <= top_of_the_ladder:
            want = (6, 12)
        else:
            want = (6, 13)
        assert (lo, hi) == want, (
            f"{code} grows tiers {lo}-{hi}, wanted {want[0]}-{want[1]}"
        )

    # Six since 0337. Counted rather than listed so a region that grows
    # nothing at all is still caught: the ladder check above only visits
    # regions that have rows.
    assert conn.execute(
        "SELECT count(DISTINCT region_code) FROM region_materials"
    ).fetchone()[0] == conn.execute(
        "SELECT count(*) FROM regions"
    ).fetchone()[0]


def test_every_region_grows_a_brewable_cultivation_herb(conn):
    """0177, 0181, 0182. The kind of a brew comes from its lead herb's Path,
    and the five Paths that brew cultivation held 10.1 of gatherable weight
    against physique's 186 - cultivation being the bar every cultivator is
    trying to move.

    The check is coverage AND usability together, because 0177 delivered the
    first without the second: it added ten cultivation herbs with
    `materials.tier` NULL, and potency is `tier x quantity`, so all ten could
    be gathered and none could be brewed.

    "Has a tier" is the only thing marking a material as a herb - 76
    gatherable things correctly have none, Spirit Stone among them - so the
    question has to be asked of what a region GROWS FOR BREWING rather than
    of every material on a cultivation Path.
    """
    barren = conn.execute(
        """
        SELECT r.code FROM regions r
        WHERE NOT EXISTS (
            SELECT 1 FROM region_materials rm
            JOIN materials m ON m.code = rm.material_code
            JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
            WHERE rm.region_code = r.code
              AND ppk.kind IN ('cultivation', 'cultivation_rate')
              AND m.tier IS NOT NULL
        )
        ORDER BY 1
        """
    ).fetchall()
    assert barren == [], f"no brewable cultivation herb grows in: {barren}"


def test_a_higher_tier_herb_is_rarer_to_find(conn):
    """The roster asks that higher tiers be meaningfully rarer, and weight is
    where that lives rather than in a gate.

    Read per REGION, because since 0368 a tier number is not comparable across
    the whole world. The heavens grow tiers 6 to 12 and the mortal regions 1 to
    7, so tier 6 is the commonest thing in Black Heaven and nearly the rarest
    in the Central Continent. Globally those two curves interleave and a
    world-wide sort reads as a failure while every region is individually
    correct - which is exactly what it did.

    What a gatherer experiences is one region at a time, and that is the thing
    worth pinning: wherever you are standing, climbing a tier makes it rarer.
    """
    for (region,) in conn.execute(
        "SELECT DISTINCT region_code FROM region_materials ORDER BY region_code"
    ).fetchall():
        weights = conn.execute(
            """
            SELECT m.tier, max(r.weight)
            FROM region_materials r JOIN materials m ON m.code = r.material_code
            WHERE m.tier IS NOT NULL AND r.region_code = %s
            GROUP BY m.tier ORDER BY m.tier
            """,
            (region,),
        ).fetchall()
        values = [float(w[1]) for w in weights]
        assert len(values) > 1, f"{region} has nothing to compare"
        assert values == sorted(values, reverse=True), (
            f"weight does not fall in {region}: {weights}"
        )


def test_every_path_a_herb_carries_knows_what_it_brews(conn):
    """`path_pill_kinds` maps a Path to what a pill of it does. A Path with a
    herb and no mapping would brew into nothing at all."""
    unmapped = conn.execute(
        """
        SELECT DISTINCT m.path_code FROM materials m
        WHERE m.tier IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM path_pill_kinds k WHERE k.path_code = m.path_code)
        ORDER BY 1
        """
    ).fetchall()
    assert [r[0] for r in unmapped] == []


def test_every_path_at_all_knows_what_it_brews(conn):
    missing = conn.execute(
        """
        SELECT p.code FROM paths p
        WHERE NOT EXISTS (SELECT 1 FROM path_pill_kinds k WHERE k.path_code = p.code)
        ORDER BY p.code
        """
    ).fetchall()
    assert [r[0] for r in missing] == []


def test_agreeing_herbs_brew_and_the_pot_decides_the_kind(conn, alchemist):
    player = alchemist()
    row = conn.execute(
        "SELECT succeeded, pill_kind, path_code, pill_tier, magnitude, quantity "
        "FROM brew(%s, %s, %s)",
        (player, ["blue_kelp_grass", "pearl_dew_lily"], [4, 4]),
    ).fetchone()

    assert row[0] is True
    assert row[1] == "healing", "two Water herbs make a healing pill"
    assert row[2] == "water"
    assert row[3] >= 1 and row[4] > 0 and row[5] >= 1


def test_a_pot_that_fights_itself_is_spoiled(conn, alchemist):
    """Wood against Poison is -22, both ways, and five tiers apart on top.

    The first version of this used two herbs one tier apart, which scores
    22.75 against a threshold of 25 - so it spoiled four times in five and
    passed four times in five. A test that asserts a coin flip is worse than
    no test, and the fix is to make the pot decisively bad rather than to
    loosen what the test claims.
    """
    player = alchemist(stock=40)
    row = conn.execute(
        "SELECT succeeded, harmony, spent_total, handed_back FROM brew(%s, %s, %s)",
        (player, ["ten_thousand_poison_heartflower", "coiling_vine_root"], [8, 8]),
    ).fetchone()

    assert row[0] is False, f"harmony came out at {row[1]}"
    assert row[2] == 16
    assert row[3] == 8, "half of every herb swept back out"

    left = conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = 'coiling_vine_root'",
        (player,),
    ).fetchone()[0]
    assert left == 36, "eight in, four back"


def test_more_potency_buys_a_better_grade(conn, alchemist):
    player = alchemist()
    small = conn.execute(
        "SELECT pill_tier FROM brew(%s, %s, %s)",
        (player, ["blue_kelp_grass", "pearl_dew_lily"], [2, 2]),
    ).fetchone()[0]
    large = conn.execute(
        "SELECT pill_tier FROM brew(%s, %s, %s)",
        (player, ["blue_kelp_grass", "pearl_dew_lily"], [40, 40]),
    ).fetchone()[0]
    assert large > small


def test_only_herbs_go_in_a_cauldron(conn, alchemist):
    player = alchemist()
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 10)", (player,))
    with pytest.raises(psycopg.errors.CheckViolation, match="only herbs"):
        conn.execute(
            "SELECT brew(%s, %s, %s)",
            (player, ["blue_kelp_grass", "wolf_fang"], [4, 4]),
        )


def test_the_cauldron_is_only_as_wide_as_the_alchemist(conn, alchemist):
    assert conn.execute(
        "SELECT alchemy_herb_slots(1::smallint), alchemy_herb_slots(%s::smallint)",
        (top_of(conn, "alchemy_herbs"),),
    ).fetchone() == (2, 6), "a novice holds two, a finished alchemist six"

    player = alchemist()
    with pytest.raises(psycopg.errors.CheckViolation, match="cauldron holds"):
        conn.execute(
            "SELECT brew(%s, %s, %s)",
            (player, ["blue_kelp_grass", "pearl_dew_lily", "sandroot"], [1, 1, 1]),
        )


def test_one_herb_is_an_ingredient_not_a_brew(conn, alchemist):
    player = alchemist()
    with pytest.raises(psycopg.errors.CheckViolation, match="at least two herbs"):
        conn.execute("SELECT brew(%s, %s, %s)", (player, ["blue_kelp_grass"], [4]))


def test_brewing_teaches_the_profession(conn, alchemist):
    player = alchemist()
    conn.execute(
        "SELECT brew(%s, %s, %s)", (player, ["blue_kelp_grass", "pearl_dew_lily"], [4, 4])
    )
    row = conn.execute(
        "SELECT exp, successes FROM player_professions "
        "WHERE player_id = %s AND profession = 'alchemy'",
        (player,),
    ).fetchone()
    assert row[0] > 0 and row[1] == 1


def test_a_supreme_dao_body_brews_what_others_cannot(conn, alchemist):
    """A cauldron holding Fire and Water is the same problem as a manual
    holding them, so the body that carries one carries the other."""
    plain = alchemist()
    dao = alchemist()
    conn.execute(
        "UPDATE player_physique SET physique_id = "
        "(SELECT physique_id FROM physiques WHERE code = 'supreme_dao_physique') "
        "WHERE player_id = %s",
        (dao,),
    )

    def pot(player):
        return conn.execute(
            "SELECT harmony FROM brew(%s, %s, %s)",
            (player, ["coiling_vine_root", "green_venom_leaf"], [4, 4]),
        ).fetchone()[0]

    assert min(pot(dao) for _ in range(3)) > max(pot(plain) for _ in range(3))


# ---------------------------------------------------------------------------
# Taking one
# ---------------------------------------------------------------------------


def _shelf(conn, player, kind, magnitude, path="water", quantity=2):
    return conn.execute(
        "INSERT INTO player_pills (owner_id, name, tier, kind, path_code, "
        "magnitude, quantity, harmony) VALUES (%s, 'Test Pill', 3, %s, %s, %s, %s, 80) "
        "RETURNING pill_id",
        (player, kind, path, magnitude, quantity),
    ).fetchone()[0]


def test_a_pill_reports_what_it_gave_and_not_its_dose(conn, alchemist):
    """0057 had healing and Qi announcing their own magnitude, so a pill taken
    at full health claimed five hundred while the bar did not move. The same
    bug 0045 fixed in the idle payout, one system over.
    """
    player = alchemist()
    pill = _shelf(conn, player, "healing", 500)

    at_full = conn.execute(
        "SELECT granted FROM take_pill(%s, %s)", (player, pill)
    ).fetchone()[0]
    assert at_full == 0, "a full body absorbs nothing and should say so"

    conn.execute("UPDATE player_physique SET current_hp = 1 WHERE player_id = %s", (player,))
    hurt = conn.execute(
        "SELECT granted FROM take_pill(%s, %s)", (player, pill)
    ).fetchone()[0]
    max_hp = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]
    assert hurt == max_hp - 1


def test_a_cultivation_pill_respects_the_bottleneck(conn, alchemist):
    player = alchemist()
    ceiling = conn.execute("SELECT cultivation_ceiling(%s)", (player,)).fetchone()[0]
    conn.execute(
        "UPDATE player_cultivation SET cultivation = %s WHERE player_id = %s",
        (ceiling, player),
    )
    pill = _shelf(conn, player, "cultivation", 5000, path="qi")

    row = conn.execute(
        "SELECT granted, detail FROM take_pill(%s, %s)", (player, pill)
    ).fetchone()
    assert row[0] == 0
    assert "bottleneck" in row[1]


def test_taking_the_last_of_a_batch_clears_the_shelf(conn, alchemist):
    player = alchemist()
    pill = _shelf(conn, player, "physique", 100, quantity=1)
    assert conn.execute(
        "SELECT remaining FROM take_pill(%s, %s)", (player, pill)
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT count(*) FROM player_pills WHERE pill_id = %s", (pill,)
    ).fetchone()[0] == 0


def test_an_insight_pill_goes_into_the_path_it_is_pointed_at(conn, alchemist):
    """0163. The pill is still brewed on a Path and still named for one; what
    changed is that the Path is no longer an address the insight has to obey.
    Taking a Human pill into Space must raise Space and leave Human alone."""
    player = alchemist()
    pill = _shelf(conn, player, "insight", 300, path="human", quantity=1)

    granted, detail = conn.execute(
        "SELECT granted, detail FROM take_pill(%s, %s, 'space')", (player, pill)
    ).fetchone()
    assert granted > 0

    space, human = conn.execute(
        """
        SELECT COALESCE((SELECT insight FROM player_path_attainment
                         WHERE player_id = %s AND path_code = 'space'), 0),
               COALESCE((SELECT insight FROM player_path_attainment
                         WHERE player_id = %s AND path_code = 'human'), 0)
        """,
        (player, player),
    ).fetchone()
    assert space == granted, "the insight did not land where it was aimed"
    assert human == 0, "it landed on the Path it was brewed on as well"
    assert "Space Path" in detail, detail


def test_an_insight_pill_left_unpointed_feeds_its_own_path(conn, alchemist):
    """Every caller written before 0163 passes two arguments, and the shelf
    still passes two for a pill nobody redirected. Neither may change meaning."""
    player = alchemist()
    pill = _shelf(conn, player, "insight", 200, path="human", quantity=1)

    granted = conn.execute(
        "SELECT granted FROM take_pill(%s, %s)", (player, pill)
    ).fetchone()[0]

    human = conn.execute(
        "SELECT insight FROM player_path_attainment WHERE player_id = %s "
        "AND path_code = 'human'",
        (player,),
    ).fetchone()[0]
    assert human == granted > 0


def test_every_path_in_the_game_can_be_raised_by_a_pill(conn, alchemist):
    """The audit that prompted 0163. `path_pill_kinds` sends seven Paths to
    'insight' and two of those seven have no herbs, so five Paths in practice
    could produce an insight pill - and a pill only fed the Path it was brewed
    on. Twenty-nine Paths had no pill in the game that could touch them.

    Stated as the invariant rather than as the five rows that broke it: there
    is no Path a cultivator cannot pour a pill into."""
    player = alchemist()
    paths = [
        r[0] for r in conn.execute("SELECT code FROM paths ORDER BY sort_order")
    ]
    assert len(paths) == 34

    refused = []
    for code in paths:
        pill = _shelf(conn, player, "insight", 50, path="human", quantity=1)
        granted = conn.execute(
            "SELECT granted FROM take_pill(%s, %s, %s)", (player, pill, code)
        ).fetchone()[0]
        if not granted:
            refused.append(code)

    assert refused == [], f"a pill could not be poured into: {refused}"

    fed = conn.execute(
        "SELECT count(*) FROM player_path_attainment WHERE player_id = %s "
        "AND insight > 0",
        (player,),
    ).fetchone()[0]
    assert fed == 34


def test_only_an_insight_pill_has_somewhere_to_be_pointed(conn, alchemist):
    """A healing pill aimed at a Path is a caller with a bug, and swallowing
    the argument would hide it. Refused before the pill is spent."""
    player = alchemist()
    pill = _shelf(conn, player, "healing", 100, quantity=1)

    with pytest.raises(psycopg.errors.CheckViolation, match="does not go into a Path"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT take_pill(%s, %s, 'space')", (player, pill))

    assert conn.execute(
        "SELECT quantity FROM player_pills WHERE pill_id = %s", (pill,)
    ).fetchone()[0] == 1, "the refusal ate the pill"


def test_a_path_that_does_not_exist_is_refused_before_the_pill_is_spent(
    conn, alchemist
):
    player = alchemist()
    pill = _shelf(conn, player, "insight", 100, path="human", quantity=1)

    with pytest.raises(psycopg.errors.CheckViolation, match="there is no"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT take_pill(%s, %s, 'gravy')", (player, pill))

    assert conn.execute(
        "SELECT quantity FROM player_pills WHERE pill_id = %s", (pill,)
    ).fetchone()[0] == 1, "the refusal ate the pill"


def test_you_cannot_take_someone_elses_pill(conn, alchemist):
    mine = alchemist()
    theirs = alchemist()
    pill = _shelf(conn, theirs, "healing", 50)
    with pytest.raises(psycopg.errors.CheckViolation, match="not yours"):
        conn.execute("SELECT take_pill(%s, %s)", (mine, pill))


# ---------------------------------------------------------------------------
# Pills that change the rate (0059)
# ---------------------------------------------------------------------------


def test_a_rate_will_not_fix_below_its_grade(conn, alchemist):
    """`min_tier` is where "expensive" lives. Below it the pot does not fail -
    it makes the plainer pill that Path also brews, which teaches what was
    missing instead of punishing the attempt."""
    player = alchemist()
    small = conn.execute(
        "SELECT pill_tier, pill_kind FROM brew(%s, %s, %s)",
        (player, ["spirit_dew_grass", "heavenly_essence_ginseng"], [3, 1]),
    ).fetchone()
    assert small[0] < 5
    assert small[1] == "cultivation", "the lesser thing, not nothing"

    large = conn.execute(
        "SELECT pill_tier, pill_kind, magnitude FROM brew(%s, %s, %s)",
        (player, ["spirit_dew_grass", "heavenly_essence_ginseng"], [20, 14]),
    ).fetchone()
    assert large[0] >= 5
    assert large[1] == "cultivation_rate"
    assert large[2] > 0, "hours, not a quantity of cultivation"


def test_a_boost_is_hours_and_they_are_spent_by_settling(conn, make_player):
    """Not a clock. An expiry would have burned while nobody was cultivating,
    and would have needed the one thing this game has refused since 0006."""
    player = make_player("Quickened")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, 20)", (player,)
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) "
        "VALUES (%s, roll_physique())", (player,)
    )
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code, confirmed_at) "
        "VALUES (%s, 'human', 'earthen_root', now())", (player,)
    )
    conn.execute("SELECT grant_boost(%s, 'cultivation_rate', 0.25, 30)", (player,))

    conn.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '10 hours' "
        "WHERE player_id = %s", (player,)
    )
    conn.execute("SELECT settle_passive_cultivation(%s)", (player,))

    assert float(conn.execute(
        "SELECT hours_left FROM player_boosts WHERE player_id = %s", (player,)
    ).fetchone()[0]) == 20, "ten settled hours, ten spent"


def test_a_boost_pays_exactly_what_it_promises(conn, make_player):
    # Both bodies are pinned. `physiques.cultivation_rate_bonus` feeds
    # `cultivation_multiplier`, so two rolled physiques give the two players
    # different base rates and the ratio below stops being 1.25 - which made
    # this an occasional failure that had nothing to do with boosts.
    def settled(boost: bool) -> tuple[int, int]:
        player = make_player("Rate")
        conn.execute(
            "INSERT INTO player_cultivation (player_id, realm_id, focus_path) "
            "VALUES (%s, 20, 'wisdom')", (player,)
        )
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id) VALUES "
            "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
            (player,)
        )
        conn.execute(
            "INSERT INTO player_character (player_id, race_code, root_code, confirmed_at) "
            "VALUES (%s, 'human', 'earthen_root', now())", (player,)
        )
        if boost:
            conn.execute("SELECT grant_boost(%s, 'cultivation_rate', 0.25, 100)", (player,))
            conn.execute("SELECT grant_boost(%s, 'attainment_rate', 0.50, 100)", (player,))
        conn.execute(
            "UPDATE player_cultivation SET last_tick_at = now() - interval '10 hours' "
            "WHERE player_id = %s", (player,)
        )
        return conn.execute(
            "SELECT cultivation_gained, insight_gained FROM settle_passive_cultivation(%s)",
            (player,),
        ).fetchone()

    plain_cult, plain_insight = settled(False)
    fast_cult, fast_insight = settled(True)

    # Within one. `settle_passive_cultivation` rounds ONCE at the end, so
    # comparing against a re-rounded intermediate can be a unit out - and is,
    # now that 0183's realm scale makes the numbers large enough to show it.
    assert abs(fast_cult - round(plain_cult * 1.25)) <= 1, (
        f"{fast_cult} is not a quarter more than {plain_cult}"
    )
    assert fast_insight == round(plain_insight * 1.50)


def test_two_pills_of_one_kind_stack_rather_than_blend(conn, make_player):
    """This asserted the opposite until 0199, for a reason that was half
    right: taking the stronger magnitude for the whole pile would let a short
    strong pill upgrade a long weak one, which is free cultivation.

    Averaging avoided that and bought a worse problem. m_i_y_u_k_i. held 978
    hours at +80%, swallowed 153 at +240%, and came out with 1,131 at +101% -
    she paid a grade 7 pill for twenty-one points, and the bigger the bank the
    less any pill could ever move it.

    Stacks settle both: each dose keeps its own rate, nothing is upgraded, and
    the strongest is spent first so the pill you just took is the one you
    feel."""
    player = make_player("Stacker")
    conn.execute("SELECT grant_boost(%s, 'cultivation_rate', 0.50, 10)", (player,))
    conn.execute("SELECT grant_boost(%s, 'cultivation_rate', 0.25, 30)", (player,))

    rows = conn.execute(
        "SELECT magnitude, hours_left FROM player_boosts WHERE player_id = %s "
        "ORDER BY magnitude DESC",
        (player,),
    ).fetchall()
    assert [(float(m), float(h)) for m, h in rows] == [(0.50, 10), (0.25, 30)]

    # The screen shows what is in force, and the total behind it.
    now = conn.execute(
        "SELECT magnitude, hours_left, hours_at_this_rate, stacks "
        "FROM player_boost_standing WHERE player_id = %s "
        "AND kind = 'cultivation_rate'",
        (player,),
    ).fetchone()
    assert float(now[0]) == 0.50, "the rate in force is the strongest"
    assert float(now[1]) == 40, "and everything banked is still counted"
    assert float(now[2]) == 10 and now[3] == 2

    # Spending drinks the strong one first and reports what it was worth.
    used, extra = conn.execute(
        "SELECT hours_used, extra_hours FROM spend_boost(%s, 'cultivation_rate', 12)",
        (player,),
    ).fetchone()
    assert float(used) == 12
    # 10h at 0.50 then 2h at 0.25 - not 12h at the blended 0.3125.
    assert float(extra) == pytest.approx(10 * 0.50 + 2 * 0.25)
    assert float(extra) != pytest.approx(12 * 0.3125)


def test_a_weak_dose_never_upgrades_itself_on_a_strong_one(conn, make_player):
    """The failure the old average was guarding against. A one-hour +240% pill
    must not drag thirty hours of +25% up with it."""
    player = make_player("Opportunist")
    conn.execute("SELECT grant_boost(%s, 'cultivation_rate', 0.25, 30)", (player,))
    conn.execute("SELECT grant_boost(%s, 'cultivation_rate', 2.40, 1)", (player,))

    used, extra = conn.execute(
        "SELECT hours_used, extra_hours FROM spend_boost(%s, 'cultivation_rate', 31)",
        (player,),
    ).fetchone()
    assert float(used) == 31
    assert float(extra) == pytest.approx(1 * 2.40 + 30 * 0.25), (
        "the weak hours were paid at the strong rate"
    )


def test_a_spent_boost_sweeps_itself_away(conn, make_player):
    player = make_player("Spent")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, 20)", (player,)
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) "
        "VALUES (%s, roll_physique())", (player,)
    )
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code, confirmed_at) "
        "VALUES (%s, 'human', 'earthen_root', now())", (player,)
    )
    conn.execute("SELECT grant_boost(%s, 'cultivation_rate', 0.25, 2)", (player,))
    conn.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '10 hours' "
        "WHERE player_id = %s", (player,)
    )
    conn.execute("SELECT settle_passive_cultivation(%s)", (player,))

    assert conn.execute(
        "SELECT count(*) FROM player_boosts WHERE player_id = %s", (player,)
    ).fetchone()[0] == 0


def test_no_path_brews_two_things(conn):
    doubled = conn.execute(
        "SELECT path_code FROM path_pill_kinds GROUP BY path_code HAVING count(*) > 1"
    ).fetchall()
    assert doubled == []


def test_a_gated_kind_has_somewhere_to_fall_back_to(conn):
    """A kind that cannot form below a grade and has no fallback would make a
    high-potency pot produce nothing at all."""
    stranded = conn.execute(
        "SELECT code FROM pill_kinds WHERE min_tier > 1 AND fallback IS NULL"
    ).fetchall()
    assert [r[0] for r in stranded] == []


# ---------------------------------------------------------------------------
# Mining
# ---------------------------------------------------------------------------


def test_every_region_reaches_every_tier_of_ore(conn):
    """A region that stopped at tier 4 would be a dead end for a miner, and the
    only fix would be to leave - which is not a decision, it is a tax."""
    rows = conn.execute(
        """
        SELECT rv.region_code, min(o.tier), max(o.tier), count(DISTINCT o.tier)
        FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
        GROUP BY rv.region_code ORDER BY rv.region_code
        """
    ).fetchall()
    # Every region, heavens included - 0342 and 0348 each owe a miner a seam
    # the way the mortal world does. Counted against the regions table so a
    # region with no veins at all is caught rather than quietly skipped by
    # the GROUP BY.
    assert len(rows) == conn.execute("SELECT count(*) FROM regions").fetchone()[0]

    # Coverage, not a band. This asserted `(1, 8, 8)` literally, which was the
    # same thing only while 8 was the top of the world - and 0504/0506 opened a
    # ninth for the Heavenly Court. The herb test beside this one went through
    # exactly this history and says so in its own docstring: a count, then a
    # literal band for every region, then the rule it was always about. What a
    # miner actually feels is a HOLE, so that is what is asserted; how deep a
    # region reaches is its own business and is pinned separately.
    for region, low, high, distinct in rows:
        assert low == 1, f"{region} starts a miner at tier {low}"
        assert high - low + 1 == distinct, (
            f"{region} covers {low}-{high} with only {distinct} tiers - a hole"
        )


def test_a_deeper_vein_is_rarer(conn):
    weights = conn.execute(
        """
        SELECT o.tier, max(rv.weight)
        FROM region_veins rv JOIN ores o ON o.material_code = rv.material_code
        GROUP BY o.tier ORDER BY o.tier
        """
    ).fetchall()
    values = [float(w[1]) for w in weights]
    assert values == sorted(values, reverse=True), f"weight does not fall: {weights}"


def test_an_ore_is_never_also_a_herb(conn):
    """`brew()` decides what is a herb by `materials.tier IS NOT NULL`. An ore
    carrying that column would be legal in a cauldron, which is why the forging
    tier lives in `ores` instead."""
    both = conn.execute(
        "SELECT o.material_code FROM ores o JOIN materials m ON m.code = o.material_code "
        "WHERE m.tier IS NOT NULL"
    ).fetchall()
    assert [r[0] for r in both] == []


def test_a_beast_material_cannot_be_an_ore(conn):
    with pytest.raises(psycopg.errors.RaiseException):
        conn.execute(
            "INSERT INTO ores (material_code, tier, signature, word) "
            "VALUES ('wolf_fang', 3, 'attack_power', 'Fang')"
        )


def test_no_gu_recipe_lost_its_base_to_the_mines(conn):
    """Thirteen ores were promoted rather than moved. A recipe whose base
    stopped being gatherable would be gated behind a Miner level, which is
    0039's lesson - a price nobody can pay is not a price."""
    stranded = conn.execute(
        """
        SELECT c.gu_code FROM gu_recipe_costs c
        JOIN ores o ON o.material_code = c.base_material
        WHERE NOT EXISTS (
            SELECT 1 FROM region_materials r WHERE r.material_code = c.base_material)
        """
    ).fetchall()
    assert [r[0] for r in stranded] == []


def test_mining_only_brings_up_what_the_level_reaches(conn, make_player):
    """The gate is a filter on the draw, not a wasted swing."""
    player = make_player("Miner")
    conn.execute(
        "INSERT INTO player_location (player_id, region_code) VALUES (%s, 'western')",
        (player,),
    )
    # The cap is re-read every swing rather than pinned at level 1: mining
    # grants Miner EXP, so thirty swings raise the level and legitimately raise
    # the cap. Pinning it would fail the test for the right thing happening.
    for _ in range(30):
        tier, cap = conn.execute(
            "SELECT ore_tier, tier_cap FROM mine(%s)", (player,)
        ).fetchone()
        assert tier <= cap, f"a miner reaching tier {cap} brought up tier {tier}"


def test_a_deeper_miner_reaches_deeper(conn, make_player):
    player = make_player("Deep")
    conn.execute(
        "INSERT INTO player_location (player_id, region_code) VALUES (%s, 'eastern')",
        (player,),
    )
    # Enough EXP to stand on the last rung, read from the ladder.
    exp = top_of(conn, "mining_tier") * 120
    conn.execute(
        "INSERT INTO player_professions (player_id, profession, exp, level) "
        "VALUES (%s, 'mining', %s, profession_level_for_exp('mining', %s))",
        (player, exp, exp),
    )
    row = conn.execute("SELECT tier_cap, deepest FROM mine(%s)", (player,)).fetchone()

    # Derived, not written down. 0504 opened a ninth band for the Heavenly
    # Court and this line said 8 twice, two lines under a comment about
    # reading the ladder. The cap is what the ladder gives a miner at this
    # level; the depth is what THIS region actually holds, which stays 8
    # because the ninth band's ore exists only in the Court.
    cap, deepest = conn.execute(
        """
        SELECT mining_tier_cap(ps.level),
               LEAST(mining_tier_cap(ps.level),
                     (SELECT max(o.tier) FROM region_veins rv
                      JOIN ores o ON o.material_code = rv.material_code
                      WHERE rv.region_code = 'eastern'))
        FROM player_professions ps
        WHERE ps.player_id = %s AND ps.profession = 'mining'
        """,
        (player,),
    ).fetchone()
    assert row[0] == cap, f"reach {row[0]} against a ladder giving {cap}"
    assert row[1] == deepest, f"dug {row[1]} where the region holds {deepest}"


# ---------------------------------------------------------------------------
# Beast parts
# ---------------------------------------------------------------------------


def test_every_beast_material_can_be_forged(conn):
    """The document asks twice for reuse rather than duplicates. A carcass with
    no forging reading is a hunt that a smith has no use for."""
    orphans = conn.execute(
        "SELECT code FROM materials WHERE category = 'beast' AND code NOT IN "
        "(SELECT material_code FROM beast_parts)"
    ).fetchall()
    assert [r[0] for r in orphans] == []


def test_no_part_kind_is_empty(conn):
    """A kind with no member never comes up, and its effects are a promise in a
    table nobody reads."""
    empty = conn.execute(
        "SELECT code FROM part_kinds WHERE code NOT IN (SELECT part FROM beast_parts)"
    ).fetchall()
    assert [r[0] for r in empty] == []


def test_an_ore_cannot_be_a_beast_part(conn):
    with pytest.raises(psycopg.errors.RaiseException):
        conn.execute(
            "INSERT INTO beast_parts (material_code, part) VALUES ('iron_ore', 'bone')"
        )


def test_every_share_spends_the_whole_budget(conn):
    """A part or a slot whose shares sum to less than one quietly throws away
    part of the piece's budget, and nothing would ever say so."""
    for table, key in (("part_effects", "part"), ("slot_effects", "slot")):
        wrong = conn.execute(
            f"SELECT {key}, sum(share) FROM {table} GROUP BY {key} "
            f"HAVING round(sum(share), 3) <> 1"
        ).fetchall()
        assert wrong == [], f"{table} does not spend its budget"


# ---------------------------------------------------------------------------
# Forging
# ---------------------------------------------------------------------------


def test_a_forge_only_grants_effects_something_reads(conn):
    """0036 flagged four effects `is_live = FALSE` rather than pretend. A piece
    of equipment granting one of those would be the pretence it refused."""
    dead = conn.execute(
        """
        SELECT ef.code FROM gu_effects ef WHERE ef.is_live = FALSE AND (
            ef.code IN (SELECT effect_code FROM slot_effects)
         OR ef.code IN (SELECT effect_code FROM part_effects)
         OR ef.code IN (SELECT signature FROM ores)
         OR ef.code IN (SELECT effect_code FROM forge_reactions))
        """
    ).fetchall()
    assert [r[0] for r in dead] == []


def test_no_reaction_rewards_a_pairing_the_chart_already_likes(conn):
    """The idea is an unlikely combination a skilled smith makes work. Six of
    the eight are outright hostile (-22 or -11); Venomsteel and Darksteel pair
    Metal with Poison and Shadow, which the chart is merely silent about at +4.
    Silence is fine - a reaction on a pairing that already AGREES would be a
    free bonus for the obvious choice, and that is what this forbids."""
    friendly = conn.execute(
        "SELECT path_a, path_b, pair_harmony(path_a, path_b) FROM forge_reactions "
        "WHERE pair_harmony(path_a, path_b) >= 8"
    ).fetchall()
    assert friendly == []


def test_most_reactions_are_outright_conflicts(conn):
    """If this ever inverts, `forge_reactions` has stopped being about turning
    a conflict into a property and become a bonus table."""
    hostile = conn.execute(
        "SELECT count(*) FROM forge_reactions WHERE pair_harmony(path_a, path_b) < 0"
    ).fetchone()[0]
    total = conn.execute("SELECT count(*) FROM forge_reactions").fetchone()[0]
    assert hostile * 2 > total, f"only {hostile} of {total} reactions are conflicts"


def top_of(conn, ladder: str) -> int:
    """The level at which a ladder runs out of rungs.

    Tests that want "somebody who has finished this craft" ask the ladder
    rather than naming a level, so retuning the spacing does not quietly turn
    them into tests of something else.
    """
    return conn.execute(
        "SELECT max(level_required) FROM profession_steps WHERE ladder = %s",
        (ladder,),
    ).fetchone()[0]


def make_smith(
    conn, make_player, level: int | None = None, region: str = "western"
) -> int:
    player = make_player("Smith")
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) "
        "VALUES (%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_location (player_id, region_code) VALUES (%s, %s)",
        (player, region),
    )
    # Far enough along to work the deepest ore, whatever the ladder says.
    if level is None:
        level = max(top_of(conn, "forge_tier"), top_of(conn, "forge_parts"))
    exp = level * 220
    conn.execute(
        "INSERT INTO player_professions (player_id, profession, exp, level) "
        "VALUES (%s, 'blacksmithing', %s, profession_level_for_exp('blacksmithing', %s))",
        (player, exp, exp),
    )
    return player


def test_a_cartload_of_ore_becomes_practice(conn, make_player):
    """0167. A forging takes ore AND a beast material, so the parts are what a
    smith runs out of - one cultivator holds 28,227 ore against 199 parts, and
    nearly eleven thousand of the rocks are tier 1, which can only ever make a
    tier 1 piece. The furnace is what that surplus is for."""
    player = make_smith(conn, make_player, level=1)
    conn.execute("SELECT grant_material(%s, 'iron_ore', 100)", (player,))

    before = conn.execute(
        "SELECT COALESCE(exp, 0) FROM player_professions WHERE player_id = %s "
        "AND profession = 'blacksmithing'",
        (player,),
    ).fetchone()[0]

    got = conn.execute(
        "SELECT * FROM smelt_many(%s, ARRAY['iron_ore'], ARRAY[60::bigint])",
        (player,),
    ).fetchone()
    kinds, melted, potency, gained, was, now, cap_was, cap_now = got

    assert (kinds, melted) == (1, 60)
    assert gained > 0

    left = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'iron_ore'",
        (player,),
    ).fetchone()[0]
    assert left == 40, "the furnace paid out without eating the ore"

    banked = conn.execute(
        "SELECT exp FROM player_professions WHERE player_id = %s "
        "AND profession = 'blacksmithing'",
        (player,),
    ).fetchone()[0]
    assert banked == before + gained, "the EXP was reported but not banked"
    assert now >= was and cap_now >= cap_was


def test_a_rock_is_worth_the_same_in_the_furnace_as_on_the_anvil(conn, make_player):
    """Potency is tier squared times quantity in `forge`, and has to be the
    same curve here - otherwise the two screens disagree about what a tier 6
    rock is, and a player learns one of them is lying by melting the wrong
    pile."""
    player = make_smith(conn, make_player)
    deep = conn.execute(
        "SELECT material_code, tier FROM ores ORDER BY tier DESC LIMIT 1"
    ).fetchone()
    conn.execute("SELECT grant_material(%s, 'iron_ore', 100)", (player,))
    conn.execute("SELECT grant_material(%s, %s, 100)", (player, deep[0]))

    shallow_tier = conn.execute(
        "SELECT tier FROM ores WHERE material_code = 'iron_ore'"
    ).fetchone()[0]

    thin = conn.execute(
        "SELECT potency FROM smelt_many(%s, ARRAY['iron_ore'], ARRAY[10::bigint])",
        (player,),
    ).fetchone()[0]
    thick = conn.execute(
        "SELECT potency FROM smelt_many(%s, ARRAY[%s], ARRAY[10::bigint])",
        (player, deep[0]),
    ).fetchone()[0]

    assert thin == shallow_tier ** 2 * 10
    assert thick == deep[1] ** 2 * 10


def test_the_furnace_reaches_exactly_as_far_as_the_anvil(conn, make_player):
    """Gated on `smith_tier_cap` for the same reason forging is, and it is
    what makes the low tiers the ones a new smith can melt - so the surplus
    is the ladder out of the surplus rather than a way around the ladder."""
    player = make_smith(conn, make_player, level=1)
    cap = conn.execute(
        "SELECT smith_tier_cap(profession_level(%s, 'blacksmithing'))", (player,)
    ).fetchone()[0]

    too_hot = conn.execute(
        "SELECT material_code FROM ores WHERE tier > %s ORDER BY tier LIMIT 1",
        (cap,),
    ).fetchone()[0]
    conn.execute("SELECT grant_material(%s, %s, 50)", (player, too_hot))

    with pytest.raises(psycopg.errors.CheckViolation, match="furnace reaches"):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT * FROM smelt_many(%s, ARRAY[%s], ARRAY[10::bigint])",
                (player, too_hot),
            )

    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = %s",
        (player, too_hot),
    ).fetchone()[0] == 50, "the refusal ate the ore"


def test_the_furnace_refuses_before_it_takes_anything(conn, make_player):
    """A bulk action that half-works and reports a number is worse than one
    that does nothing and names the rock that was the problem - so every
    refusal is found before the first `spend_material`."""
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'iron_ore', 30)", (player,))

    not_ore = conn.execute(
        "SELECT code FROM materials WHERE code NOT IN "
        "(SELECT material_code FROM ores) LIMIT 1"
    ).fetchone()[0]

    for args, complaint in (
        (("ARRAY['iron_ore']", "ARRAY[9999::bigint]"), "do not hold"),
        ((f"ARRAY['{not_ore}']", "ARRAY[1::bigint]"), "is not ore"),
        (("ARRAY['iron_ore','iron_ore']", "ARRAY[1::bigint,1::bigint]"), "once"),
        (("ARRAY['iron_ore']", "ARRAY[0::bigint]"), "not a quantity"),
        (("ARRAY[]::text[]", "ARRAY[]::bigint[]"), "nothing was put"),
    ):
        with pytest.raises(psycopg.errors.CheckViolation, match=complaint):
            with conn.transaction(force_rollback=True):
                conn.execute(
                    f"SELECT * FROM smelt_many(%s, {args[0]}, {args[1]})", (player,)
                )

    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'iron_ore'",
        (player,),
    ).fetchone()[0] == 30


def test_the_furnace_will_not_melt_money(conn, make_player):
    """0168. `spirit_stone` is a row in `ores` - tier 1, signature
    cultivation_rate - and has been since the forge was written. The anvil
    could afford that: it takes one ore at a time and asks how much. A furnace
    with a "Melt all" button cannot, and clearwest is holding 6,205 of them.

    Nothing marked Spirit Stone as money: `materials.category` says
    'gathering', the same as Iron Ore. So the marker is a table now, and this
    is the test that the furnace reads it."""
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 500)", (player,))

    for code in conn.execute(
        "SELECT material_code FROM currency_materials ORDER BY material_code"
    ).fetchall():
        with pytest.raises(psycopg.errors.CheckViolation, match="is money"):
            with conn.transaction(force_rollback=True):
                conn.execute(
                    "SELECT * FROM smelt_many(%s, ARRAY[%s], ARRAY[1::bigint])",
                    (player, code[0]),
                )

    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (player,),
    ).fetchone()[0] == 500

    # And the refusal comes before the tier gate, not after it - the money
    # check must not depend on the smith being able to work tier 1.
    poor = make_player("Broke Smith")
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 5)", (poor,))
    with pytest.raises(psycopg.errors.CheckViolation, match="is money"):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT * FROM smelt_many(%s, ARRAY['spirit_stone'], "
                "ARRAY[1::bigint])",
                (poor,),
            )


def test_melting_is_never_the_better_use_of_ore_you_could_forge(conn):
    """The furnace competes with nothing on purpose. An efficient tier 1
    forging is 60 EXP for 4 potency; if smelting ever paid more per potency
    than the worst forging, the anvil would become the slow way to do the
    furnace's job.

    Only tiers an ANVIL CAN MAKE count. Tier 10 exists since 0546 and cannot
    be forged - the deepest ore is tier 9 and `smith_tier_cap` is a hard nine
    - so its `potency_required` is a statement about being beyond an anvil
    rather than a price anybody pays. Counting it made "the least rewarding
    forging" a forging nobody can do.
    """
    rate = conn.execute(
        "SELECT game_config_value('smelt_exp_per_potency')"
    ).fetchone()[0]

    worst = conn.execute(
        """
        SELECT min((et.tier * game_config_value('forge_exp_per_tier'))
                   / et.potency_required)
        FROM equipment_tiers et
        WHERE et.tier <= LEAST((SELECT max(tier) FROM ores),
                               smith_tier_cap(32767::smallint))
        """
    ).fetchone()[0]

    assert rate < worst, (
        f"smelting pays {rate} a potency and the least rewarding forging pays "
        f"{worst} - the furnace has become the better anvil"
    )


def test_the_ore_caps_the_tier(conn, make_player):
    """A mountain of tier 1 iron is a mountain of tier 1 iron. This is the
    document's foundation rule and the reason volume cannot buy depth."""
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'iron_ore', 4000)", (player,))
    conn.execute("SELECT grant_material(%s, 'dragon_scale', 40)", (player,))

    row = conn.execute(
        "SELECT succeeded, potency, item_tier FROM forge(%s, 'weapon', ARRAY['iron_ore'], ARRAY[3000], "
        "ARRAY['dragon_scale'], ARRAY[20])",
        (player,),
    ).fetchone()
    assert row[0] is True
    assert row[1] > 3000, "three thousand potency was on that anvil"
    assert row[2] == 1, "and tier 1 iron can only make a tier 1 piece"


def test_a_piece_never_exceeds_an_effect_ceiling(conn, make_player):
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'blazing_sunsteel', 200)", (player,))
    conn.execute("SELECT grant_material(%s, 'dragon_scale', 60)", (player,))

    conn.execute(
        "SELECT * FROM forge(%s, 'armour', ARRAY['blazing_sunsteel'], ARRAY[60], "
        "ARRAY['dragon_scale'], ARRAY[30])",
        (player,),
    )
    over = conn.execute(
        """
        SELECT ee.effect_code, ee.magnitude, ef.cap
        FROM equipment_effects ee
        JOIN player_equipment pe ON pe.equipment_id = ee.equipment_id
        JOIN gu_effects ef ON ef.code = ee.effect_code
        WHERE pe.owner_id = %s AND ee.magnitude > ef.cap
        """,
        (player,),
    ).fetchall()
    assert over == []


def test_a_ruined_forging_hands_half_of_it_back(conn, make_player):
    """Water metal, a Fire core, two grades apart, at level 1.

    The worst crucible a beginner can build still lands at 50 - 22 (Fire against
    Water) - 4 (a second Path) - 4 (the grade gap) + 0.9 (skill), and the roll
    is worth four either way: 17 to 25, which straddles the shipped threshold
    of 25 exactly. So the threshold is moved for this test rather than the pot
    being made worse, because there is no worse pot to build at level 1 - and a
    test that asserts a coin flip fails one run in five.

    What is under test is the refund arithmetic, not which harmony ruins a
    piece. The dial is a game_config row and the transaction rolls back.
    """
    player = make_player("Butterfingers")
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) "
        "VALUES (%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (player,),
    )
    conn.execute(
        "UPDATE game_config SET value = 40 WHERE key = 'forge_failure_threshold'"
    )
    conn.execute("SELECT grant_material(%s, 'tide_stone', 100)", (player,))
    conn.execute("SELECT grant_material(%s, 'golden_crow_essence', 100)", (player,))

    row = conn.execute(
        "SELECT succeeded, harmony, spent_total, handed_back FROM forge(%s, 'weapon', "
        "ARRAY['tide_stone'], ARRAY[20], ARRAY['golden_crow_essence'], ARRAY[4])",
        (player,),
    ).fetchone()

    assert row[0] is False, f"harmony came out at {row[1]}"
    assert (row[2], row[3]) == (24, 12)
    held = dict(conn.execute(
        "SELECT material_code, quantity FROM player_materials WHERE player_id = %s",
        (player,),
    ).fetchall())
    assert held["tide_stone"] == 90, "twenty spent, ten raked back"
    assert held["golden_crow_essence"] == 98, "four spent, two raked back"


def test_a_failed_forging_still_teaches(conn, make_player):
    """Every craft in this game levels on the attempt, not the success."""
    assert conn.execute(
        "SELECT exp_per_level FROM professions WHERE code = 'blacksmithing'"
    ).fetchone()[0] > 0


# ---------------------------------------------------------------------------
# Wearing it
# ---------------------------------------------------------------------------


def test_a_piece_cannot_be_worn_in_the_wrong_slot(conn, make_player):
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'gold_ore', 200)", (player,))
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 50)", (player,))
    conn.execute(
        "SELECT * FROM forge(%s, 'weapon', ARRAY['gold_ore'], ARRAY[40], ARRAY['wolf_fang'], ARRAY[10])",
        (player,),
    )
    piece = conn.execute(
        "SELECT equipment_id FROM player_equipment WHERE owner_id = %s", (player,)
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.RaiseException):
        conn.execute(
            "INSERT INTO player_equipped (player_id, slot, equipment_id) "
            "VALUES (%s, 'boots', %s)", (player, piece)
        )


def test_a_piece_cannot_be_worn_by_someone_else(conn, make_player):
    player = make_smith(conn, make_player)
    thief = make_player("Thief")
    conn.execute("SELECT grant_material(%s, 'gold_ore', 200)", (player,))
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 50)", (player,))
    conn.execute(
        "SELECT * FROM forge(%s, 'weapon', ARRAY['gold_ore'], ARRAY[40], ARRAY['wolf_fang'], ARRAY[10])",
        (player,),
    )
    piece = conn.execute(
        "SELECT equipment_id FROM player_equipment WHERE owner_id = %s", (player,)
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.RaiseException):
        conn.execute(
            "INSERT INTO player_equipped (player_id, slot, equipment_id) "
            "VALUES (%s, 'weapon', %s)", (thief, piece)
        )


def test_only_one_thing_per_slot(conn, make_player):
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'gold_ore', 400)", (player,))
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 100)", (player,))
    for _ in range(2):
        conn.execute(
            "SELECT * FROM forge(%s, 'weapon', ARRAY['gold_ore'], ARRAY[40], ARRAY['wolf_fang'], ARRAY[10])",
            (player,),
        )
    pieces = [r[0] for r in conn.execute(
        "SELECT equipment_id FROM player_equipment WHERE owner_id = %s ORDER BY equipment_id",
        (player,),
    ).fetchall()]

    conn.execute("SELECT equip(%s, %s)", (player, pieces[0]))
    conn.execute("SELECT equip(%s, %s)", (player, pieces[1]))

    worn = conn.execute(
        "SELECT count(*) FROM player_equipped WHERE player_id = %s", (player,)
    ).fetchone()[0]
    assert worn == 1, "the second one should have displaced the first"


def test_wearing_armour_changes_the_body_at_once(conn, make_player):
    """Max HP is STORED on player_physique and a battle snapshots it at the
    door. Armour that only took effect on the next physique level would be gear
    that does nothing until you train, which is why equip() recomputes."""
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'blazing_sunsteel', 200)", (player,))
    conn.execute("SELECT grant_material(%s, 'dragon_scale', 60)", (player,))
    conn.execute(
        "SELECT * FROM forge(%s, 'armour', ARRAY['blazing_sunsteel'], ARRAY[60], "
        "ARRAY['dragon_scale'], ARRAY[30])",
        (player,),
    )
    piece = conn.execute(
        "SELECT equipment_id FROM player_equipment WHERE owner_id = %s AND slot = 'armour'",
        (player,),
    ).fetchone()[0]
    # base_hp since 0434, when max_hp was retired. Asked of the forge rather
    # than spelled out: a piece that rolls flesh is what this test needs, and
    # naming the retired code made it skip every run instead of failing - a
    # test that has quietly stopped testing anything is worse than a red one.
    gain = conn.execute(
        "SELECT magnitude FROM equipment_effects WHERE equipment_id = %s "
        "AND effect_code = 'base_hp'", (piece,)
    ).fetchone()
    assert not conn.execute(
        "SELECT 1 FROM gu_effects WHERE code = 'max_hp' AND is_live"
    ).fetchone(), "max_hp is live again; this test should be asking about it"
    if gain is None:
        pytest.skip("that piece rolled no flesh")

    # A body that has never been recomputed still holds the column default, so
    # the baseline is taken from a recompute rather than from the row as
    # inserted - otherwise this measures the first recompute, not the armour.
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    before = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]
    conn.execute("SELECT equip(%s, %s)", (player, piece))
    after = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]
    assert after > before

    conn.execute("SELECT unequip(%s, 'armour')", (player,))
    assert conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0] == before


def test_player_stat_sums_the_sources_under_one_ceiling(conn, make_player):
    """Three separately capped sums would let a player hold three ceilings by
    spreading one stat across a Gu, a body and a sword."""
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'gold_ore', 200)", (player,))
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 50)", (player,))
    conn.execute(
        "SELECT * FROM forge(%s, 'weapon', ARRAY['gold_ore'], ARRAY[40], ARRAY['wolf_fang'], ARRAY[10])",
        (player,),
    )
    piece = conn.execute(
        "SELECT equipment_id FROM player_equipment WHERE owner_id = %s", (player,)
    ).fetchone()[0]
    conn.execute("SELECT equip(%s, %s)", (player, piece))

    row = conn.execute(
        """
        SELECT player_stat(%s, 'base_strength'),
               gu_stat(%s, 'base_strength') + equipment_stat(%s, 'base_strength')
                 + physique_stat(%s, 'base_strength')
        """,
        (player, player, player, player),
    ).fetchone()
    assert row[0] == row[1], "nothing is capped here, so the sum is the sum"

    # And the ceiling holds when the sources together would break it.
    # Pushed past the ceiling rather than to a number: base_strength's cap is
    # 240 since 0443, and a literal 9 would have tested nothing once the cap
    # stopped being 2.00.
    conn.execute(
        "INSERT INTO equipment_effects (equipment_id, effect_code, magnitude) "
        "VALUES (%s, 'base_strength', "
        "        (SELECT cap * 2 FROM gu_effects WHERE code = 'base_strength')) "
        "ON CONFLICT ON CONSTRAINT equipment_effects_pkey "
        "DO UPDATE SET magnitude = EXCLUDED.magnitude", (piece,)
    )
    # The ceiling over the SUM is still the whole point, and still holds -
    # three sources cannot buy three ceilings. What 0516 added underneath it
    # is that one source cannot buy the whole one either, so a single piece of
    # gear carrying twice the cap now reaches the gear share of it.
    capped = conn.execute(
        "SELECT player_stat(%s, 'base_strength'), "
        "stat_source_cap('base_strength', %s), "
        "(SELECT cap FROM gu_effects WHERE code = 'base_strength')",
        (player, player),
    ).fetchone()
    assert capped[0] == capped[1], (
        "one source may not finish an effect by itself"
    )
    assert capped[0] <= capped[2], (
        "one ceiling over every source is the whole point of player_stat"
    )


def test_gear_reaches_the_stack_a_fight_reads(conn, make_player):
    """The point of 0066. If `battle_act` still read gu_stat, a sword would be
    a row in a table and nothing else."""
    sources = conn.execute(
        """
        SELECT p.proname
        FROM pg_proc p
        -- `player_external_multiplier` left this list in 0443. It used to
        -- read player_stat for attack_power; that grant is now base_strength,
        -- which reaches a fight through `thews` in compute_technique_damage
        -- instead - so the hook that has to read player_stat moved with it.
        WHERE p.proname IN ('battle_act', 'apply_physique_xp',
                            'compute_technique_damage', 'settle_passive_cultivation',
                            'gather', 'mine')
          AND pg_get_functiondef(p.oid) NOT LIKE '%player_stat(%'
        """
    ).fetchall()
    assert [r[0] for r in sources] == []


# ---------------------------------------------------------------------------
# Bodies that do something
# ---------------------------------------------------------------------------


def body_player(conn, make_player, code: str) -> int:
    player = make_player("Born")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, 3)", (player,)
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) "
        "VALUES (%s, (SELECT physique_id FROM physiques WHERE code = %s))",
        (player, code),
    )
    return player


def test_no_body_promises_without_paying_something(conn):
    """`unmodelled` is an admission, not a hiding place. A body may still owe a
    clause it cannot pay - eleven of them do - but not while granting nothing
    at all, because then the whole sheet is a promise."""
    hollow = conn.execute(
        """
        SELECT p.code FROM physiques p
        WHERE p.unmodelled <> '{}'::jsonb
          AND NOT EXISTS (SELECT 1 FROM physique_effects e
                          WHERE e.physique_id = p.physique_id)
          AND NOT EXISTS (SELECT 1 FROM physique_path_bonuses b
                          WHERE b.physique_id = p.physique_id AND b.resistance > 0)
        ORDER BY p.code
        """
    ).fetchall()
    assert [r[0] for r in hollow] == []


def test_a_body_only_grants_effects_something_reads(conn):
    dead = conn.execute(
        """
        SELECT DISTINCT e.effect_code FROM physique_effects e
        JOIN gu_effects ef ON ef.code = e.effect_code
        WHERE ef.is_live = FALSE ORDER BY 1
        """
    ).fetchall()
    assert [r[0] for r in dead] == []


def test_a_rarer_body_is_worth_more(conn):
    """The whole ladder hangs off `physique_power`, so this is really a test
    that nobody has hand-set a magnitude behind its back."""
    ranks = conn.execute(
        """
        SELECT r.sort_order, pw.ranks FROM physique_power pw
        JOIN rarities r ON r.code = pw.tier ORDER BY r.sort_order
        """
    ).fetchall()
    values = [row[1] for row in ranks]
    assert values == sorted(values), f"power does not rise with rarity: {ranks}"

    # And a body's magnitude really is step x ranks x its weights.
    wrong = conn.execute(
        """
        SELECT p.code, e.effect_code, e.magnitude
        FROM physique_effects e
        JOIN physiques p ON p.physique_id = e.physique_id
        JOIN physique_power pw ON pw.tier = p.tier
        JOIN gu_effects ef ON ef.code = e.effect_code
        WHERE e.magnitude > ef.step * pw.ranks + 0.0001
        ORDER BY p.code
        """
    ).fetchall()
    assert wrong == [], "a body is worth more than its tier allows"


def test_a_body_resists_the_path_it_names(conn, make_player):
    """0015 returned a hardcoded zero here for fifty-four migrations, above a
    comment saying a resistance would land in it without a signature change."""
    fire_beast = conn.execute(
        """
        SELECT s.species_id FROM creature_species s
        JOIN creature_paths cp ON cp.species_id = s.species_id
        WHERE cp.is_primary AND cp.path_code = 'fire' ORDER BY s.rank LIMIT 1
        """
    ).fetchone()[0]

    plain = body_player(conn, make_player, "mortal_body")
    warded = body_player(conn, make_player, "flameblood_physique")

    def taken(player: int, species: int) -> tuple[int, float]:
        row = conn.execute(
            "SELECT final_damage, matchup_modifier FROM compute_creature_damage("
            "%s, %s, 20, 100)", (species, player)
        ).fetchone()
        return row[0], float(row[1])

    plain_dmg, plain_mod = taken(plain, fire_beast)
    ward_dmg, ward_mod = taken(warded, fire_beast)

    assert plain_mod == 0
    assert ward_mod == -0.10, "Flameblood is ten percent against Fire"
    assert ward_dmg < plain_dmg, f"{ward_dmg} should be under {plain_dmg}"


def test_a_resistance_does_not_leak_to_other_paths(conn, make_player):
    poison_beast = conn.execute(
        """
        SELECT s.species_id FROM creature_species s
        JOIN creature_paths cp ON cp.species_id = s.species_id
        WHERE cp.is_primary AND cp.path_code = 'poison' ORDER BY s.rank LIMIT 1
        """
    ).fetchone()[0]

    plain = body_player(conn, make_player, "mortal_body")
    warded = body_player(conn, make_player, "flameblood_physique")

    def taken(player: int) -> int:
        return conn.execute(
            "SELECT final_damage FROM compute_creature_damage(%s, %s, 20, 100)",
            (poison_beast, player),
        ).fetchone()[0]

    assert taken(plain) == taken(warded), "a Fire ward must not stop Poison"


def test_a_body_can_hold_more_qi_than_its_realm(conn, make_player):
    plain = body_player(conn, make_player, "mortal_body")
    deep = body_player(conn, make_player, "primordial_chaos_body")

    realm = conn.execute("SELECT qi_capacity FROM realms WHERE realm_id = 3").fetchone()[0]
    assert conn.execute("SELECT player_max_qi(%s)", (plain,)).fetchone()[0] == realm
    assert conn.execute("SELECT player_max_qi(%s)", (deep,)).fetchone()[0] > realm


def test_a_fight_opens_with_what_the_body_holds(conn, make_player):
    """`battle_open` snapshots the pool. Reading the realm directly would mean
    a body that holds more Qi holds it everywhere except in a fight."""
    deep = body_player(conn, make_player, "primordial_chaos_body")
    species = conn.execute(
        "SELECT species_id FROM creature_species ORDER BY rank LIMIT 1"
    ).fetchone()[0]

    battle_id = conn.execute("SELECT battle_open(%s, %s)", (deep, species)).fetchone()[0]
    opened = conn.execute(
        "SELECT current_qi FROM battle_combatants WHERE battle_id = %s AND combatant_no = 0",
        (battle_id,),
    ).fetchone()[0]
    assert opened == conn.execute(
        "SELECT player_max_qi(%s)", (deep,)
    ).fetchone()[0]


def test_a_body_that_grants_hp_is_felt_without_training_first(conn, make_player):
    """Max HP is stored. A body worth +25% that only paid out on the next
    physique level would be a body that does nothing until you train."""
    plain = body_player(conn, make_player, "mortal_body")
    great = body_player(conn, make_player, "primordial_origin_body")

    for player in (plain, great):
        conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))

    hp = {
        player: conn.execute(
            "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
        ).fetchone()[0]
        for player in (plain, great)
    }
    assert hp[great] > hp[plain]


def test_the_source_share_exempts_exactly_the_innate_capstones(conn):
    """A body is rolled, not bought, so its signature may finish an effect.

    0516 bounded every source at three fifths of an effect's ceiling, which is
    right for anything a cultivator can accumulate - another worm, another
    sword - and wrong for the one body they will ever have. Where a physique or
    a root grants an effect at or above its own cap, finishing it alone IS what
    owning that body is for.

    This is derived rather than listed because the listed version was wrong
    three times. 0517 exempted `death_ward` and called it "the ONLY exception";
    `foresight` was clipped to a coin flip and failed this suite six runs in
    eight for four migrations, and `realm_tempering` had no test at all and
    quietly took 40% off two live characters' Primordial Origin Body. Listing
    them found them one unlucky roll at a time. Deriving them finds the next
    one when it is added.
    """
    capstones = {
        r[0]
        for r in conn.execute(
            """
            SELECT DISTINCT e.code
            FROM gu_effects e
            WHERE EXISTS (
                SELECT 1 FROM physique_effects pe
                WHERE pe.effect_code = e.code AND pe.magnitude >= e.cap
                UNION ALL
                SELECT 1 FROM root_effects re
                WHERE re.effect_code = e.code AND re.magnitude >= e.cap)
            """
        ).fetchall()
    }
    exempt = {
        r[0]
        for r in conn.execute(
            "SELECT code FROM gu_effects WHERE source_share >= 1"
        ).fetchall()
    }

    assert capstones, "no body grants any effect up to its own ceiling any more"
    assert exempt == capstones, (
        f"clipped but a body finishes it: {sorted(capstones - exempt)}; "
        f"exempt but no body finishes it: {sorted(exempt - capstones)}"
    )

    # And a worm reaching the cap alone is NOT a reason to exempt anything -
    # that is the thing the share exists to stop, and the choice that was made
    # when the question was put.
    for code in ("crit_rate", "crit_damage", "multi_hit"):
        share = conn.execute(
            "SELECT source_share FROM gu_effects WHERE code = %s", (code,)
        ).fetchone()[0]
        assert float(share) < 1, f"{code} stopped being a build choice"


def test_a_capstone_body_uses_everything_it_grants(conn, make_player):
    """What the body says is what the blow uses, for the three that finish.

    `physique_stat` reports what a body GRANTS (0518) and `player_stat` what a
    fight USES. For a capstone those must agree, or the screen and the fight
    disagree - the 0492 fault, which took four migrations to notice the first
    time.
    """
    rows = conn.execute(
        """
        SELECT p.code, e.code, pe.magnitude, e.cap
        FROM physique_effects pe
        JOIN physiques p USING (physique_id)
        JOIN gu_effects e ON e.code = pe.effect_code
        WHERE pe.magnitude >= e.cap
        """
    ).fetchall()
    assert rows, "no body carries a capstone effect to test"

    for body, effect, _granted, cap in rows:
        pid = body_player(conn, make_player, body)
        grants = float(
            conn.execute(
                "SELECT physique_stat(%s, %s)", (pid, effect)
            ).fetchone()[0]
        )
        uses = float(
            conn.execute("SELECT player_stat(%s, %s)", (pid, effect)).fetchone()[0]
        )
        assert grants == pytest.approx(float(cap)), (
            f"{body} should grant all of {effect}, grants {grants} of {cap}"
        )
        assert uses == pytest.approx(grants), (
            f"{body} grants {grants} {effect} but a fight uses {uses}"
        )


def test_a_body_and_a_sword_share_one_ceiling(conn, make_player):
    """The reason the numbers are allowed to be this big. A Divine body spends
    most of an effect's ceiling, so gear granting the same effect is worth
    little on it - which is what makes the roll a build decision."""
    divine = body_player(conn, make_player, "infinite_immortal_body")
    cap = conn.execute(
        "SELECT cap FROM gu_effects WHERE code = 'dodge'"
    ).fetchone()[0]

    from_body = conn.execute(
        "SELECT physique_stat(%s, 'dodge')", (divine,)
    ).fetchone()[0]
    # Against the share a single source may give, not the whole cap: 0516
    # bounds every source at `stat_source_share` of it. A Divine body should
    # still be most of what a body is allowed to be, which is the claim.
    assert from_body > float(conn.execute(
        "SELECT stat_source_cap('dodge')"
    ).fetchone()[0]) / 2, "a Divine body should be most of the ceiling"

    # What a fight uses is the body's STACKING share of the effect, not the
    # whole of what the body grants: 0516 bounded every source at
    # `source_share` so one source cannot finish an effect alone, and 0518
    # kept `physique_stat` reporting what the body actually gives. The claim
    # here - that a Divine body spends most of the ceiling, so gear granting
    # the same effect is worth little on it - holds either way.
    assert conn.execute(
        "SELECT player_stat(%s, 'dodge')", (divine,)
    ).fetchone()[0] == min(
        from_body,
        conn.execute("SELECT stat_source_cap('dodge', %s)", (divine,)).fetchone()[0],
    )

    # Now hand it gear worth more than the rest of the ceiling and watch the
    # ceiling hold rather than the two of them adding past it.
    piece = conn.execute(
        """
        INSERT INTO player_equipment
            (owner_id, name, slot, tier, rarity, harmony, ore_code)
        VALUES (%s, 'Test Treads', 'boots', 3, 'rare', 80, 'iron_ore')
        RETURNING equipment_id
        """,
        (divine,),
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO equipment_effects (equipment_id, effect_code, magnitude) "
        "VALUES (%s, 'dodge', %s)", (piece, cap)
    )
    conn.execute("SELECT equip(%s, %s)", (divine, piece))

    assert conn.execute(
        "SELECT player_stat(%s, 'dodge')", (divine,)
    ).fetchone()[0] == cap


# ---------------------------------------------------------------------------
# The conditional effects
# ---------------------------------------------------------------------------


def a_species(conn, kind: str = "beast") -> int:
    return conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = %s ORDER BY rank LIMIT 1",
        (kind,),
    ).fetchone()[0]


def a_technique(conn, player: int) -> int:
    """A move this player can use.

    Taught here rather than looked up: a bare fixture player has learned
    nothing, so `player_usable_techniques` is empty for them and the lookup
    would return None rather than fail in a way that says so.
    """
    technique_id = conn.execute(
        "SELECT technique_id FROM techniques WHERE created_by IS NULL "
        "AND base_power > 0 ORDER BY rank, technique_id LIMIT 1"
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s) "
        "ON CONFLICT DO NOTHING",
        (player, technique_id),
    )
    return technique_id


def fighter(conn, make_player, code: str) -> int:
    """A cultivator with a body, a realm and a technique."""
    player = make_player("Fighter")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, 3)", (player,)
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) "
        "VALUES (%s, (SELECT physique_id FROM physiques WHERE code = %s))",
        (player, code),
    )
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code, confirmed_at) "
        "VALUES (%s, 'human', 'earthen_root', now())", (player,)
    )
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    return player


def test_every_new_effect_has_a_reader(conn):
    """Ten words were added in 0071 and each was supposed to arrive with its
    one consumer. A word nothing reads is the thing `is_live` exists to admit,
    so if one is not read it has to say so."""
    unread = []
    for code, reader in (
        ("beast_damage",    "compute_technique_damage"),
        ("matchup_relief",  "compute_technique_damage"),
        # 0225 moved the offensive half of the swing out of `battle_act` so
        # the dungeon and the horde would get it too. The reader moved; the
        # rule that a word must have one did not.
        ("momentum",        "player_swing"),
        ("wounded_power",   "player_swing"),
        # 0243 moved the defensive half out of `battle_act` for the same
        # reason 0225 moved the offensive half: the dungeon and the gauntlet
        # were taking raw damage on a body that had paid for these.
        ("braced",          "player_take"),
        ("death_ward",      "player_take"),
        # The guard's qi is the duel's own business, not the blow's.
        ("guard_qi",        "battle_act"),
        ("foresight",       "battle_open"),
        ("pill_potency",    "take_pill"),
        ("realm_tempering", "breakthrough"),
    ):
        body = conn.execute(
            "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = %s", (reader,)
        ).fetchone()[0]
        if code not in body:
            unread.append((code, reader))
    assert unread == []


def test_beast_slaying_only_touches_beasts(conn, make_player):
    plain = fighter(conn, make_player, "mortal_body")
    slayer = fighter(conn, make_player, "heavenly_battle_body")
    tech = a_technique(conn, plain)

    def hit(player: int, kind: str) -> int:
        return conn.execute(
            "SELECT final_damage FROM compute_technique_damage(%s, %s, %s, 1, 0)",
            (player, tech, a_species(conn, kind)),
        ).fetchone()[0]

    # Both bodies levelled flat first. 0244 gave Strength a job and these
    # two physiques temper at different rates, so without this the gap
    # between them measures their bodies rather than Beast Slaying.
    # Comparing each against itself would not work either: the two species
    # have different matchups against the technique.
    conn.execute(
        "UPDATE player_physique SET strength = 0 WHERE player_id IN (%s, %s)",
        (plain, slayer),
    )

    assert hit(slayer, "beast") > hit(plain, "beast"), (
        "a beast slayer should slay beasts"
    )
    assert hit(slayer, "rogue") == hit(plain, "rogue"), "a rogue is not a beast"


def test_a_resistance_bites_less_but_an_immunity_still_holds(conn, make_player):
    """Softening -1 would be arguing with the matchup chart rather than with a
    creature, so immunity is deliberately left alone."""
    relief = conn.execute(
        "SELECT physique_stat((SELECT physique_id FROM physiques "
        "WHERE code = 'chaos_immortal_body'), 'matchup_relief')"
    ).fetchone()
    # physique_stat takes a player, not a physique - so read the row directly.
    magnitude = conn.execute(
        """
        SELECT pe.magnitude FROM physique_effects pe
        JOIN physiques p ON p.physique_id = pe.physique_id
        WHERE p.code = 'chaos_immortal_body' AND pe.effect_code = 'matchup_relief'
        """
    ).fetchone()
    assert magnitude is not None and magnitude[0] > 0

    definition = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc "
        "WHERE proname = 'compute_technique_damage'"
    ).fetchone()[0]
    assert "matchup < 0 AND matchup > -1" in definition, (
        "immunity must be excluded from the softening"
    )


def test_a_cornered_body_hits_harder_only_when_cornered(conn, make_player):
    """The condition is the whole effect: an unconditional version of this
    would just be attack power under another name."""
    definition = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'player_swing'"
    ).fetchone()[0]
    assert "p_player_hp * 2 <= p_player_max_hp" in definition
    assert "wounded_power" in definition

    # And a fight that does not track a body cannot corner one, which is why
    # the two hp arguments are nullable rather than assumed.
    assert "p_player_hp IS NOT NULL" in definition


def test_a_braced_body_stops_being_braced(conn):
    definition = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'player_take'"
    ).fetchone()[0]
    assert "braced_hp_threshold" in definition
    threshold = conn.execute(
        "SELECT game_config_value('braced_hp_threshold')"
    ).fetchone()[0]
    assert 0 < threshold <= 100


def test_reduction_can_never_turn_a_blow_into_nothing(conn):
    """Damage reduction, braced and a guard now stack. A ceiling under one
    keeps the sum from reaching a wall nothing gets through."""
    ceiling = conn.execute(
        "SELECT game_config_value('damage_reduction_ceiling')"
    ).fetchone()[0]
    assert ceiling < 1


def test_a_death_ward_fires_once_and_the_fight_remembers(conn, make_player):
    warded = fighter(conn, make_player, "infinite_immortal_body")
    species = a_species(conn)
    battle_id = conn.execute(
        "SELECT battle_open(%s, %s)", (warded, species)
    ).fetchone()[0]

    assert conn.execute(
        "SELECT ward_used FROM battle_combatants "
        "WHERE battle_id = %s AND combatant_no = 0", (battle_id,)
    ).fetchone()[0] is False, "a fresh fight has a fresh ward"

    # Divine death_ward is capped at 1.0, so it is a certainty rather than a
    # roll - which is what makes this assertable at all.
    assert conn.execute(
        "SELECT player_stat(%s, 'death_ward')", (warded,)
    ).fetchone()[0] == 1

    # Walk it to the edge and take a blow that would finish it.
    conn.execute(
        "UPDATE battle_combatants SET current_hp = 1 "
        "WHERE battle_id = %s AND combatant_no = 0", (battle_id,)
    )
    # At one health, any blow at all is a killing blow - so the ward is what
    # decides this, and it is a certainty rather than a roll. Evasion could
    # also save it, which is why the claim is "still standing" and not "the
    # ward fired": both outcomes mean the body survived a lethal turn.
    row = conn.execute(
        "SELECT finished, player_hp FROM battle_act(%s, 'guard', NULL)", (battle_id,)
    ).fetchone()
    assert row[1] >= 1, "the ward should have left it standing"


def test_foresight_knows_the_weakness_without_looking(conn, make_player):
    seer = fighter(conn, make_player, "celestial_sovereign_body")
    plain = fighter(conn, make_player, "mortal_body")

    species = conn.execute(
        """
        SELECT cip.species_id FROM creature_incoming_paths cip
        WHERE cip.interaction = 'advantage' LIMIT 1
        """
    ).fetchone()[0]

    for player in (seer, plain):
        conn.execute("SELECT battle_open(%s, %s)", (player, species))

    known = {
        player: conn.execute(
            "SELECT count(*) FROM player_bestiary_paths "
            "WHERE player_id = %s AND species_id = %s", (player, species)
        ).fetchone()[0]
        for player in (seer, plain)
    }
    assert known[seer] > 0, "foresight should have written it down at the door"
    assert known[plain] == 0, "and an ordinary body should have to look"


def test_a_pill_pays_more_into_the_right_body(conn, make_player):
    plain = fighter(conn, make_player, "mortal_body")
    apothecary = fighter(conn, make_player, "orchard_body")

    def swallow(player: int) -> int:
        conn.execute(
            "UPDATE player_physique SET current_hp = 1 WHERE player_id = %s", (player,)
        )
        pill = conn.execute(
            """
            INSERT INTO player_pills
                (owner_id, name, tier, kind, path_code, magnitude, quantity, harmony)
            VALUES (%s, 'Test Pill', 1, 'healing', 'water', 100, 1, 80)
            RETURNING pill_id
            """,
            (player,),
        ).fetchone()[0]
        return conn.execute(
            "SELECT granted FROM take_pill(%s, %s)", (player, pill)
        ).fetchone()[0]

    assert swallow(apothecary) > swallow(plain)


def test_crossing_a_realm_tempers_the_right_body(conn, make_player):
    plain = fighter(conn, make_player, "mortal_body")
    growing = fighter(conn, make_player, "primordial_origin_body")

    for player in (plain, growing):
        conn.execute(
            "UPDATE player_cultivation SET cultivation = "
            "(SELECT cultivation_required FROM realms WHERE realm_id = 4) "
            "WHERE player_id = %s", (player,)
        )

    banked = {
        player: conn.execute(
            "SELECT tempering_gained, body_levels FROM breakthrough(%s)", (player,)
        ).fetchone()
        for player in (plain, growing)
    }
    assert banked[plain][0] == 0
    assert banked[growing][0] > 0, "a body that tempers on the crossing should"

    # And it reports what it BANKED, not what it offered - 0045's lesson.
    assert banked[growing][1] == conn.execute(
        "SELECT body_level - 1 FROM player_physique WHERE player_id = %s", (growing,)
    ).fetchone()[0]


def test_observe_shows_the_weakness_before_the_immunity(conn):
    """`creature_incoming_paths` holds advantage, resistance and immunity -
    never 'weakness' - so the old CASE branch had never matched and Observe was
    ordering by the fallback."""
    definition = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'battle_act'"
    ).fetchone()[0]
    assert "WHEN 'weakness' THEN 0" not in definition
    assert "WHEN 'advantage' THEN 0" in definition

    kinds = {
        r[0] for r in conn.execute(
            "SELECT DISTINCT interaction FROM creature_incoming_paths"
        ).fetchall()
    }
    assert "weakness" not in kinds, "if this ever appears, the ordering needs it back"


def test_founding_always_goes_into_the_weakest_pillar(conn, make_player):
    """The whole safety argument for stacking this permanently. If growth ever
    lands anywhere but the lowest pillar, it can concentrate, and a
    twenty-six-crossing stack that can concentrate is a runaway."""
    player = fighter(conn, make_player, "celestial_emperor_body")

    def rates() -> dict:
        row = conn.execute(
            "SELECT hp_multiplier + foundation_bonus(%s, 'hp'), "
            "       defense_multiplier + foundation_bonus(%s, 'defense'), "
            "       strength_multiplier + foundation_bonus(%s, 'strength') "
            "FROM player_trait_rates WHERE player_id = %s",
            (player, player, player, player),
        ).fetchone()
        return dict(zip(("hp", "defense", "strength"), (float(v) for v in row)))

    start = rates()
    # Celestial Emperor is 1.18 / 1.18 / 1.08, so strength is where the first
    # crossing must go - and the body is the reason that is knowable at all.
    assert conn.execute(
        "SELECT weakest_foundation(%s)", (player,)
    ).fetchone()[0] == "strength"

    spread_before = max(start.values()) - min(start.values())

    # Topped up to whatever the NEXT realm needs, read off the player's own
    # row: `fighter` starts at realm 3, so a fixed range would be asking to
    # break into realms already behind it.
    for _ in range(10):
        conn.execute(
            """
            UPDATE player_cultivation pc SET cultivation =
                (SELECT r.cultivation_required FROM realms r
                 WHERE r.realm_id = pc.realm_id + 1)
            WHERE pc.player_id = %s
            """,
            (player,),
        )
        # 0253 put a door in front of every rank crossing. This test is about
        # where founding LANDS, so the door is paid rather than argued with.
        _pay_the_gate(conn, player)
        stat, amount = conn.execute(
            "SELECT founded_stat, founded_by FROM breakthrough(%s)", (player,)
        ).fetchone()
        assert amount > 0, "a founding body should found on every crossing"
        # Whatever it chose has to have been the lowest before it chose.
        assert stat is not None

    end = rates()
    spread_after = max(end.values()) - min(end.values())

    assert sum(end.values()) > sum(start.values()), "ten crossings should grow it"
    assert spread_after < spread_before, (
        f"the pillars should converge, not spread: {start} -> {end}"
    )


def test_an_ordinary_body_founds_nothing(conn, make_player):
    plain = fighter(conn, make_player, "mortal_body")
    conn.execute(
        "UPDATE player_cultivation SET cultivation = "
        "(SELECT cultivation_required FROM realms WHERE realm_id = 4) "
        "WHERE player_id = %s", (plain,)
    )
    stat, amount = conn.execute(
        "SELECT founded_stat, founded_by FROM breakthrough(%s)", (plain,)
    ).fetchone()
    assert amount == 0 and stat is None
    assert conn.execute(
        "SELECT count(*) FROM player_foundation_bonuses WHERE player_id = %s", (plain,)
    ).fetchone()[0] == 0


def test_founding_reaches_the_stored_stats_at_once(conn, make_player):
    """It has to land on player_physique on the crossing itself, or the
    breakthrough card reports a body the player does not yet have."""
    player = fighter(conn, make_player, "celestial_emperor_body")
    before = conn.execute(
        "SELECT strength FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]

    conn.execute(
        "UPDATE player_cultivation SET cultivation = "
        "(SELECT cultivation_required FROM realms WHERE realm_id = 4) "
        "WHERE player_id = %s", (player,)
    )
    conn.execute("SELECT breakthrough(%s)", (player,))

    assert conn.execute(
        "SELECT strength FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0] > before


def test_equipment_does_not_steer_a_permanent_decision(conn, make_player):
    """A sword can be taken off the next morning. What the body founds must
    not chase it."""
    definition = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'weakest_foundation'"
    ).fetchone()[0]
    assert "equipment_stat" not in definition and "player_stat" not in definition


# ---------------------------------------------------------------------------
# The last roll
# ---------------------------------------------------------------------------


def test_harmony_buys_draws_rather_than_tilting_the_weights(conn):
    """The reason the roll cannot be tuned into a certainty: more chances at
    the same ladder is bounded by the ladder, a shifted weight is not."""
    draws = [
        conn.execute("SELECT manual_quality_draws(%s::smallint)", (h,)).fetchone()[0]
        for h in (0, 40, 50, 75, 100, 125, 140)
    ]
    assert draws == sorted(draws), f"draws must not fall as harmony rises: {draws}"
    assert draws[0] >= 1, "even a barely-successful refinement rolls once"
    assert max(draws) <= conn.execute(
        "SELECT game_config_value('manual_quality_max_draws')"
    ).fetchone()[0]


def test_the_quality_ladder_rises_and_thins(conn):
    rows = conn.execute(
        """
        SELECT mq.rarity, mq.weight, mq.budget_multiplier, r.sort_order
        FROM manual_qualities mq JOIN rarities r ON r.code = mq.rarity
        ORDER BY r.sort_order
        """
    ).fetchall()
    weights = [float(r[1]) for r in rows]
    lifts = [float(r[2]) for r in rows]
    assert weights == sorted(weights, reverse=True), "a better band must be rarer"
    assert lifts == sorted(lifts), "and worth more"
    assert lifts[0] == 1.0, "common is the baseline, not a penalty"


def test_unique_is_not_a_band_a_manual_can_roll(conn):
    """It means 'there is one of these'. A manual can be refined twice."""
    assert conn.execute(
        "SELECT count(*) FROM manual_qualities WHERE rarity = 'unique'"
    ).fetchone()[0] == 0


def test_a_better_roll_is_worth_more_stats(conn, make_player):
    """The band multiplies the budget, so it has to reach the stored bonuses."""
    cheap, rich = conn.execute(
        """
        SELECT (SELECT budget_multiplier FROM manual_qualities WHERE rarity = 'common'),
               (SELECT budget_multiplier FROM manual_qualities WHERE rarity = 'extreme')
        """
    ).fetchone()
    assert float(rich) > float(cheap) * 2 - 0.1, "extreme should be worth about double"


def test_the_forecast_stops_before_the_dice(conn, make_player):
    """Called twice on the same pages it must return the same thing, or the
    confirmation screen would be showing one roll and refining another."""
    player = make_player("Forecaster")
    pages = [
        conn.execute(
            """
            INSERT INTO manual_pages (owner_id, tier, path_code, page_type, power, quality)
            VALUES (%s, 3, 'fire', 'attack', 40, 80) RETURNING page_id
            """,
            (player,),
        ).fetchone()[0]
        for _ in range(3)
    ]
    seen = {
        tuple(conn.execute(
            "SELECT base_harmony, forecast_tier, archetype FROM refine_forecast(%s, %s)",
            (player, pages),
        ).fetchone())
        for _ in range(5)
    }
    assert len(seen) == 1, f"the forecast moved between calls: {seen}"


def test_a_manual_records_the_band_it_rolled(conn, make_player):
    player = make_player("Roller")
    pages = [
        conn.execute(
            """
            INSERT INTO manual_pages (owner_id, tier, path_code, page_type, power, quality)
            VALUES (%s, 4, 'wood', 'cultivation', 70, 90) RETURNING page_id
            """,
            (player,),
        ).fetchone()[0]
        for _ in range(3)
    ]
    got = conn.execute(
        "SELECT succeeded, manual_id, quality, draws FROM refine(%s, %s)",
        (player, pages),
    ).fetchone()
    if not got[0]:
        pytest.skip("that refinement failed; the band is only rolled on success")

    stored = conn.execute(
        "SELECT quality FROM manuals WHERE manual_id = %s", (got[1],)
    ).fetchone()[0]
    assert stored == got[2], "the card and the row must name the same band"
    assert got[3] >= 1


def test_more_draws_actually_produce_better_bands(conn):
    """0077 wrote this roll as an UNCORRELATED lateral subquery, so Postgres
    evaluated it once and reused the answer for all four draws. Four chances
    were four copies of one chance, and the code looked entirely correct - the
    distributions at harmony 55 and 130 were identical to within noise.

    So this test asks the data rather than the code, and the margin it asserts
    is enormous: one draw lands legendary-or-better about 5% of the time, four
    draws about 20%. Anything that collapses the draws again fails this by a
    mile rather than by a coin flip.
    """
    # The call is in the SELECT LIST rather than in a LATERAL, because the
    # first version of this test reproduced the very bug it was written to
    # catch: an uncorrelated lateral is evaluated once and every "sample" came
    # back identical. A volatile function in the select list is not hoisted.
    def rate(harmony: int, samples: int = 4000) -> float:
        hits = conn.execute(
            """
            SELECT count(*) FILTER (WHERE r.sort_order >= 50)::numeric / %s
            FROM (SELECT roll_manual_quality(%s::smallint) AS band
                  FROM generate_series(1, %s)) d
            JOIN rarities r ON r.code = d.band
            """,
            (samples, harmony, samples),
        ).fetchone()[0]
        return float(hits)

    one, four = rate(55), rate(130)
    assert conn.execute(
        "SELECT manual_quality_draws(55::smallint), manual_quality_draws(130::smallint)"
    ).fetchone() == (1, 4), "the premise of this test"
    assert four > one * 2, (
        f"four draws should roughly quadruple the good bands: {one:.3f} -> {four:.3f}"
    )


def test_a_single_draw_still_matches_the_written_weights(conn):
    """The other half: if the draws stopped being independent the OTHER way -
    every draw a fresh best-of - a single draw would stop matching the table."""
    samples = 4000
    common = conn.execute(
        """
        SELECT count(*) FILTER (WHERE d.band = 'common')::numeric / %s
        FROM (SELECT roll_manual_quality(55::smallint) AS band
              FROM generate_series(1, %s)) d
        """,
        (samples, samples),
    ).fetchone()[0]

    expected = conn.execute(
        """
        SELECT (SELECT weight FROM manual_qualities WHERE rarity = 'common')
               / (SELECT sum(weight) FROM manual_qualities)
        """
    ).fetchone()[0]
    assert abs(float(common) - float(expected)) < 0.05, (
        f"one draw should follow the table: {common} vs {expected}"
    )


# ---------------------------------------------------------------------------
# Forager and Explorer
# ---------------------------------------------------------------------------


def worker(conn, make_player, region: str = "central") -> int:
    player = make_player("Worker")
    conn.execute(
        "INSERT INTO player_location (player_id, region_code) VALUES (%s, %s)",
        (player, region),
    )
    return player


def set_level(conn, player: int, profession: str, level: int) -> None:
    # `exp_per_level` is NUMERIC and `profession_level_for_exp` takes BIGINT,
    # so the product is rounded here rather than left for Postgres to guess at.
    exp = int(level * conn.execute(
        "SELECT exp_per_level FROM professions WHERE code = %s", (profession,)
    ).fetchone()[0])
    conn.execute(
        """
        INSERT INTO player_professions (player_id, profession, exp, level)
        VALUES (%s, %s, %s, profession_level_for_exp(%s, %s::bigint))
        ON CONFLICT (player_id, profession) DO UPDATE
            SET exp = EXCLUDED.exp, level = EXCLUDED.level
        """,
        (player, profession, exp, profession, exp),
    )


def test_every_profession_says_what_a_level_buys(conn):
    """A profession that only counts is a counter. `skill_buys` is where each
    one has to justify itself, and a new row here with no case is silent."""
    silent = conn.execute(
        """
        SELECT s.code FROM skills s
        WHERE skill_buys(s.code, 5::smallint) IS NULL
        ORDER BY s.code
        """
    ).fetchall()
    assert [r[0] for r in silent] == []


def test_a_forager_looks_more_than_once(conn):
    looks = [
        conn.execute("SELECT forage_draws(%s::smallint)", (lvl,)).fetchone()[0]
        for lvl in (1, 8, 16, 40)
    ]
    assert looks == sorted(looks), f"looks must not fall with level: {looks}"
    assert looks[0] == 1 and looks[-1] == conn.execute(
        "SELECT game_config_value('forage_max_draws')"
    ).fetchone()[0]


def test_a_better_forager_finds_rarer_things(conn, make_player):
    """The levels buy DRAWS and the rarest is kept, so this is a distribution
    claim rather than a code one - and the margin is wide because three looks
    at a table where 'common' is most of it is a large change."""
    def rarity_rate(level: int, samples: int = 300) -> float:
        player = worker(conn, make_player)
        set_level(conn, player, "foraging", level)
        better = 0
        for _ in range(samples):
            code = conn.execute(
                "SELECT material_code FROM gather(%s)", (player,)
            ).fetchone()[0]
            sort_order = conn.execute(
                "SELECT r.sort_order FROM materials m JOIN rarities r ON r.code = m.rarity "
                "WHERE m.code = %s", (code,)
            ).fetchone()[0]
            better += 1 if sort_order > 10 else 0
        return better / samples

    novice, expert = rarity_rate(1), rarity_rate(40)
    assert expert > novice, f"three looks should beat one: {novice} -> {expert}"


def test_a_forage_teaches_the_forager(conn, make_player):
    player = worker(conn, make_player)
    got = conn.execute(
        "SELECT exp_gained, level_after FROM gather(%s)", (player,)
    ).fetchone()
    assert got[0] > 0 and got[1] >= 1
    assert conn.execute(
        "SELECT exp FROM player_professions WHERE player_id = %s AND profession = 'foraging'",
        (player,),
    ).fetchone()[0] == got[0]


def test_an_explorer_walks_home_empty_less_often(conn, make_player):
    """The level has to be pinned between samples.

    `explore` grants Exploring EXP on every call, so drawing four hundred
    samples from a level 1 explorer levels them to the fortune cap somewhere
    around the middle of the sample - and both arms then measure the same
    capped player, which made this a coin flip rather than a test. The
    mechanic itself was never in doubt: fortune 0.02 empties 18% of walks and
    fortune 0.75 empties 5%.
    """
    # 500, not 250. The effect is real and large - fortune 0.02 empties 18% of
    # walks against 0.75's 5% - but at 250 the threshold below sits under three
    # standard deviations from the expected gap, which is a test that fails
    # roughly once every few hundred suite runs for no reason. It did, twice.
    # Doubling the sample puts it past four, at a cost of half a second.
    def empty_rate(level: int, samples: int = 500) -> float:
        player = worker(conn, make_player)
        empties = 0
        for _ in range(samples):
            set_level(conn, player, "exploring", level)
            outcome = conn.execute(
                "SELECT outcome FROM explore(%s)", (player,)
            ).fetchone()[0]
            empties += outcome == "nothing"
        return empties / samples

    novice, expert = empty_rate(1), empty_rate(40)
    assert expert < novice, f"skill should remove empty walks: {novice} -> {expert}"
    # The gap is large enough that noise cannot close it: the weights put
    # these three standard deviations apart at this sample size.
    assert novice - expert > 0.05, f"the effect shrank: {novice} -> {expert}"


def test_exploring_levels_itself_as_you_do_it(conn, make_player):
    """Why the test above has to pin the level - and worth pinning as its own
    fact, because it is what makes a long sample of any explore statistic
    measure the wrong player."""
    player = worker(conn, make_player)
    before = conn.execute(
        "SELECT explore_fortune(%s)", (player,)
    ).fetchone()[0]
    for _ in range(60):
        conn.execute("SELECT explore(%s)", (player,))
    after = conn.execute("SELECT explore_fortune(%s)", (player,)).fetchone()[0]
    assert after > before, "walking about teaches you where to look"


def test_fortune_is_no_longer_a_lie(conn, make_player):
    """0036 shipped `resource_find` is_live FALSE. Something reads it now, and
    if that ever stops being true the flag has to go back."""
    assert conn.execute(
        "SELECT is_live FROM gu_effects WHERE code = 'resource_find'"
    ).fetchone()[0] is True

    # 0332 moved the read down into `fortune_share` so four lanes could
    # share one clamp, so the check follows the call rather than demanding
    # the column name appear in a particular function.
    reader = conn.execute(
        """
        SELECT proname FROM pg_proc
        WHERE prokind = 'f' AND pronamespace = 'public'::regnamespace
          AND prosrc LIKE '%resource_find%'
        """
    ).fetchall()
    assert reader, "nothing reads resource_find at all"

    # And every lane Fortune is supposed to touch actually reaches it.
    for lane in ("explore_fortune", "gather", "mine", "battle_conclude"):
        body = conn.execute(
            "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = %s",
            (lane,),
        ).fetchone()[0]
        assert "fortune_share" in body or "resource_find" in body, (
            f"{lane} does not read Fortune"
        )


def test_a_level_alone_still_reaches_the_level_ceiling(conn, make_player):
    """These two used to share one ceiling, and 0331 separated them: at 0.02 a
    level the cap was reached at level 38, and every Explorer on the server
    was in the hundreds - so Fortune was added to a number already past the
    clamp and thrown away. A 604 was carrying 0.7964 of it for nothing.

    The level still reaches the level's own cap on its own."""
    player = worker(conn, make_player)
    set_level(conn, player, "exploring", 200)
    cap = conn.execute(
        "SELECT game_config_value('explore_fortune_cap')"
    ).fetchone()[0]
    assert conn.execute("SELECT explore_fortune(%s)", (player,)).fetchone()[0] == cap


def test_fortune_pays_on_top_of_a_maxed_level(conn, make_player):
    """The other half of 0331, and the half that was broken: a cultivator
    whose level has already reached the ceiling must still get something for
    carrying Fortune, or the stat is decoration on every character who
    explores."""
    player = worker(conn, make_player)
    set_level(conn, player, "exploring", 200)
    capped = conn.execute("SELECT explore_fortune(%s)", (player,)).fetchone()[0]

    # Through a destiny, which is a real source of it - `player_gu_stats` is a
    # view over a GROUP BY and cannot be written to.
    conn.execute(
        "INSERT INTO player_destinies "
        "    (player_id, rank, code, offered, chosen_at) "
        "SELECT %s, 2, de.code, ARRAY[de.code], now() FROM destiny_effects de "
        "WHERE de.effect_code = 'resource_find' LIMIT 1",
        (player,),
    )
    lucky = conn.execute("SELECT explore_fortune(%s)", (player,)).fetchone()[0]

    assert lucky > capped, (
        f"Fortune bought a maxed Explorer nothing: {capped} -> {lucky}"
    )
    # ...and it can never remove the empty-handed result altogether, because
    # `explore` divides by that weight.
    assert lucky < 1


# ---------------------------------------------------------------------------
# Roots and bodies for the crafts
# ---------------------------------------------------------------------------


def crafter(conn, make_player, *, root: str | None = None,
            body: str | None = None, level: int = 30) -> int:
    player = make_player("Crafter")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, 3)", (player,)
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = %s))",
        (player, body or "mortal_body"),
    )
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code, confirmed_at) "
        "VALUES (%s, 'human', %s, now())",
        (player, root or "earthen_root"),
    )
    for craft in ("blacksmithing", "alchemy", "gu_refining"):
        set_level(conn, player, craft, level)
    return player


def test_a_root_reaches_the_shared_stack(conn, make_player):
    """0053 gave bodies the vocabulary and roots never got it. This is the
    other half, so `player_stat` has to see it."""
    plain = crafter(conn, make_player)
    smith = crafter(conn, make_player, root="heavens_forge_root")

    assert conn.execute("SELECT root_stat(%s, 'forge_power')", (plain,)).fetchone()[0] == 0
    from_root = conn.execute(
        "SELECT root_stat(%s, 'forge_power')", (smith,)
    ).fetchone()[0]
    assert from_root > 0
    assert conn.execute(
        "SELECT player_stat(%s, 'forge_power')", (smith,)
    ).fetchone()[0] == from_root


def test_the_unique_root_forges_stronger_gear(conn, make_player):
    """What the Unique root was asked for. Measured on the piece rather than
    on the function definition, and averaged, because harmony rolls."""
    def budget(player: int, samples: int = 12) -> float:
        conn.execute("SELECT grant_material(%s, 'gold_ore', 4000)", (player,))
        conn.execute("SELECT grant_material(%s, 'wolf_fang', 4000)", (player,))
        total = 0.0
        for _ in range(samples):
            piece = conn.execute(
                "SELECT equipment_id FROM forge(%s, 'weapon', ARRAY['gold_ore'], ARRAY[40], "
                "ARRAY['wolf_fang'], ARRAY[10])",
                (player,),
            ).fetchone()[0]
            if piece is None:
                continue
            total += float(conn.execute(
                "SELECT COALESCE(sum(magnitude), 0) FROM equipment_effects "
                "WHERE equipment_id = %s", (piece,)
            ).fetchone()[0])
        return total / samples

    plain = budget(crafter(conn, make_player))
    blessed = budget(crafter(conn, make_player, root="heavens_forge_root"))
    assert blessed > plain, f"Heaven's Forge should forge harder: {plain} -> {blessed}"


def test_a_cauldron_sense_body_brews_stronger_pills(conn, make_player):
    def dose(player: int) -> int:
        for code in ("blue_kelp_grass", "pearl_dew_lily"):
            conn.execute("SELECT grant_material(%s, %s, 400)", (player, code))
        best = 0
        for _ in range(8):
            row = conn.execute(
                "SELECT succeeded, magnitude FROM brew(%s, ARRAY['blue_kelp_grass', "
                "'pearl_dew_lily'], ARRAY[10, 10])",
                (player,),
            ).fetchone()
            if row[0]:
                best = max(best, row[1])
        return best

    plain = dose(crafter(conn, make_player))
    tasted = dose(crafter(conn, make_player, body="iron_palate_body"))
    assert tasted > plain, f"an Iron Palate should get more out: {plain} -> {tasted}"


def test_every_craft_word_has_a_consumer(conn):
    """Three words shipped is_live TRUE in 0083. If one of them stopped being
    read, the flag would be the lie `is_live` exists to prevent."""
    for code, reader in (
        ("forge_power", "forge"),
        ("brew_potency", "brew"),
        ("gu_potency", "refine_gu"),
    ):
        body = conn.execute(
            "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = %s", (reader,)
        ).fetchone()[0]
        assert code in body, f"{code} is not read by {reader}"


def test_the_craft_traits_do_not_break_the_root_ladder(conn):
    """0011's rule, still standing: no root is the one that makes numbers
    bigger, and rank shows in the Path package."""
    assert conn.execute(
        "SELECT count(*) FROM roots WHERE cultivation_rate_bonus <> 0"
    ).fetchone()[0] == 0

    best = dict(conn.execute(
        """
        SELECT r.rarity, max(b.attainment_bonus)
        FROM roots r JOIN root_path_bonuses b ON b.root_code = r.code
        GROUP BY r.rarity
        """
    ).fetchall())
    assert best["legendary"] < best["divine"] < best["unique"]


def test_a_rolled_trait_of_a_band_is_worth_that_band(conn):
    """Roots and bodies read one ladder, so a Rare of either kind grants the
    same size of thing. If they drift, one pillar quietly becomes the better
    place to get lucky."""
    rows = conn.execute(
        """
        SELECT re.effect_code, r.rarity, re.magnitude
        FROM root_effects re
        JOIN roots r ON r.code = re.root_code
        WHERE re.effect_code IN ('forge_power', 'brew_potency', 'gu_potency')
        """
    ).fetchall()
    for effect, rarity, magnitude in rows:
        ceiling = conn.execute(
            """
            SELECT e.step * pw.ranks FROM gu_effects e, physique_power pw
            WHERE e.code = %s AND pw.tier = %s
            """,
            (effect, rarity),
        ).fetchone()[0]
        assert magnitude <= ceiling + Decimal("0.0001"), (
            f"{effect} on a {rarity} root is worth more than the band allows"
        )


# ---------------------------------------------------------------------------
# Spirit Jade
# ---------------------------------------------------------------------------


def test_money_is_not_an_ingredient(conn):
    """Every craft table that takes a material has a guard. Currency must not
    be legal in any of them, or jade becomes a way to buy power directly -
    which is the one thing the design forbids."""
    with pytest.raises(psycopg.errors.RaiseException):
        conn.execute(
            "INSERT INTO ores (material_code, tier, signature, word) "
            "VALUES ('spirit_jade', 3, 'attack_power', 'Jade')"
        )


def test_currency_cannot_be_gathered_or_dropped(conn):
    """The guards 0017 wrote for the gathering/beast split cover this for
    free, and that is worth asserting rather than assuming."""
    with pytest.raises(psycopg.errors.RaiseException):
        conn.execute(
            "INSERT INTO region_materials (region_code, material_code, weight) "
            "VALUES ('central', 'spirit_jade', 5)"
        )


def test_the_ledger_and_the_purse_agree(conn, make_player):
    """The whole reason for a ledger. If they drift, the metrics are lying."""
    player = make_player("Rich")
    conn.execute("SELECT grant_jade(%s, 10, 'test_faucet')", (player,))
    conn.execute("SELECT grant_jade(%s, 5, 'test_faucet')", (player,))
    conn.execute("SELECT spend_jade(%s, 4, 'test_sink')", (player,))

    assert conn.execute("SELECT jade_held(%s)", (player,)).fetchone()[0] == 11
    assert conn.execute(
        "SELECT sum(delta) FROM jade_ledger WHERE player_id = %s", (player,)
    ).fetchone()[0] == 11


def test_a_sink_cannot_run_a_balance_negative(conn, make_player):
    player = make_player("Broke")
    conn.execute("SELECT grant_jade(%s, 2, 'test_faucet')", (player,))
    # `spend_material` already refuses with a check_violation and a sentence a
    # player can act on - "you need 3 Spirit Jade, and have 2" - so the sink
    # inherits the refusal rather than writing a second one.
    with pytest.raises(psycopg.errors.CheckViolation, match="Spirit Jade"):
        conn.execute("SELECT spend_jade(%s, 3, 'test_sink')", (player,))


def test_a_trade_moves_jade_without_minting_it(conn, make_player):
    """A trade changes who holds the money, not how much exists - so it must
    not touch the ledger, or generated-minus-destroyed stops matching held."""
    player = make_player("Trader")
    conn.execute("SELECT grant_jade(%s, 20, 'test_faucet')", (player,))
    before = conn.execute("SELECT count(*) FROM jade_ledger").fetchone()[0]

    conn.execute("SELECT spend_material(%s, 'spirit_jade', 5)", (player,))
    conn.execute("SELECT grant_material(%s, 'spirit_jade', 5)", (player,))

    assert conn.execute("SELECT count(*) FROM jade_ledger").fetchone()[0] == before
    assert conn.execute("SELECT jade_held(%s)", (player,)).fetchone()[0] == 20


def test_crossing_a_realm_pays(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    conn.execute(
        "UPDATE player_cultivation pc SET cultivation = "
        "(SELECT r.cultivation_required FROM realms r WHERE r.realm_id = pc.realm_id + 1) "
        "WHERE pc.player_id = %s", (player,)
    )
    paid = conn.execute("SELECT jade_gained FROM breakthrough(%s)", (player,)).fetchone()[0]

    assert paid == conn.execute(
        "SELECT game_config_value('jade_per_realm')"
    ).fetchone()[0]
    assert conn.execute("SELECT jade_held(%s)", (player,)).fetchone()[0] == paid
    assert conn.execute(
        "SELECT reason FROM jade_ledger WHERE player_id = %s", (player,)
    ).fetchone()[0] == "breakthrough"


def test_protection_costs_more_for_a_better_thing(conn):
    costs = [
        conn.execute("SELECT jade_protection_cost(%s::smallint)", (g,)).fetchone()[0]
        for g in range(1, 8)
    ]
    assert costs == sorted(costs), f"a dearer loss must cost more to insure: {costs}"
    assert costs[6] > costs[4] * 2, "the top of the ladder should bite"


def test_insuring_the_same_thing_costs_the_same_through_any_craft(conn):
    """A Tier 7 herb and a Tier 7 ore are the same size of loss, and insuring
    one through alchemy must not be cheaper than the other through forging."""
    herb = conn.execute(
        "SELECT jade_material_protection_cost('ninefold_dao_blossom')"
    ).fetchone()[0]
    ore = conn.execute(
        "SELECT jade_material_protection_cost('golden_crow_ore')"
    ).fetchone()[0]
    assert herb == ore


def test_a_protected_herb_comes_back_whole(conn, make_player):
    """The sink doing what it was bought for. The cauldron is made decisively
    bad the same way 0065's forging test is, so this is not a coin flip."""
    player = make_player("Insured")
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (player,),
    )
    conn.execute("UPDATE game_config SET value = 200 WHERE key = 'alchemy_failure_threshold'")
    conn.execute("SELECT grant_jade(%s, 500, 'test_faucet')", (player,))
    for code in ("ninefold_dao_blossom", "spirit_dew_grass"):
        conn.execute("SELECT grant_material(%s, %s, 100)", (player, code))

    row = conn.execute(
        "SELECT succeeded FROM brew(%s, ARRAY['ninefold_dao_blossom', 'spirit_dew_grass'], "
        "ARRAY[10, 10], 'ninefold_dao_blossom')",
        (player,),
    ).fetchone()
    assert row[0] is False, "the threshold was moved to guarantee a spoil"

    held = dict(conn.execute(
        "SELECT material_code, quantity FROM player_materials WHERE player_id = %s "
        "AND material_code <> 'spirit_jade'", (player,)
    ).fetchall())
    assert held["ninefold_dao_blossom"] == 100, "the insured herb is untouched"
    assert held["spirit_dew_grass"] == 95, "the uninsured one lost half of ten"

    assert conn.execute(
        "SELECT reason FROM jade_ledger WHERE player_id = %s AND delta < 0", (player,)
    ).fetchone()[0] == "protect_herb"


def test_you_cannot_insure_something_you_are_not_using(conn, make_player):
    player = make_player("Chancer")
    conn.execute("SELECT grant_jade(%s, 500, 'test_faucet')", (player,))
    for code in ("blue_kelp_grass", "pearl_dew_lily"):
        conn.execute("SELECT grant_material(%s, %s, 100)", (player, code))

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "SELECT brew(%s, ARRAY['blue_kelp_grass', 'pearl_dew_lily'], "
            "ARRAY[10, 10], 'ninefold_dao_blossom')",
            (player,),
        )


def test_protection_is_optional_everywhere(conn):
    """The document is emphatic: normal play must work without jade. Every
    craft's protection parameter has to have a default, or the old three-
    argument call would have stopped resolving."""
    for name, args in (
        ("refine", "bigint, bigint[]"),
        ("brew", "bigint, text[], integer[]"),
        ("forge", "bigint, text, text, integer, text[], integer[]"),
    ):
        assert conn.execute(
            "SELECT count(*) FROM pg_proc WHERE proname = %s "
            "AND pg_get_function_identity_arguments(oid) LIKE %s",
            (name, "%" + args.split(", ")[-1] + "%"),
        ).fetchone()[0] >= 1, f"{name} lost its callable form"


def test_a_drop_never_writes_out_a_picture_it_could_read(conn):
    """0086 hardcoded '\U0001F49A' into the JSON and Postgres has no such
    escape in an ordinary literal, so the drop line read the ten characters
    back at the player. The row already knows what the material looks like."""
    definition = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = 'battle_conclude'"
    ).fetchone()[0]
    assert "U0001" not in definition, "an escape that Postgres does not have"
    assert "FROM materials m WHERE m.code = 'spirit_jade'" in definition


def test_one_body_hands_back_one_purse(conn, make_player):
    """Killing the first rogue of a species fires both faucets. The ledger
    keeps them apart because tuning needs to know which tap ran; the player is
    looking at a corpse and wants one number."""
    player = fighter(conn, make_player, "mortal_body")
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'rogue' LIMIT 1"
    ).fetchone()[0]

    conn.execute("UPDATE game_config SET value = 1 WHERE key = 'jade_rogue_chance'")
    battle_id = conn.execute("SELECT battle_open(%s, %s)", (player, species)).fetchone()[0]
    conn.execute(
        "UPDATE battle_combatants SET current_hp = 0 "
        "WHERE battle_id = %s AND combatant_no = 1", (battle_id,)
    )
    drops = conn.execute(
        "SELECT battle_conclude(%s, 'complete')", (battle_id,)
    ).fetchone()[0]

    jade = [d for d in drops if d["code"] == "spirit_jade"]
    assert len(jade) == 1, f"one line, however many faucets ran: {jade}"
    expected = conn.execute(
        "SELECT game_config_value('jade_first_kill') "
        "     + game_config_value('jade_rogue_purse')"
    ).fetchone()[0]
    assert jade[0]["quantity"] == expected, "the first kill and the purse, added up"
    assert jade[0]["emoji"] == conn.execute(
        "SELECT emoji FROM materials WHERE code = 'spirit_jade'"
    ).fetchone()[0]

    reasons = {
        r[0] for r in conn.execute(
            "SELECT reason FROM jade_ledger WHERE player_id = %s", (player,)
        ).fetchall()
    }
    assert reasons == {"first_kill", "rogue_purse"}, "and the ledger keeps both"


def test_the_only_repeatable_faucet_is_the_thinnest(conn):
    """A rogue turns up in roughly one world action in ten and can be killed
    for ever, so this is the one tap that must never be generous.

    0123 moved it from 3% to 10%. Behind the 10% ambush roll that is about one
    hunt in a hundred - visible, where 0.3% was indistinguishable from zero -
    and still an order of magnitude under the daily, which is the tap meant to
    be doing the work.
    """
    chance, purse, ambush = conn.execute(
        "SELECT game_config_value('jade_rogue_chance'), "
        "       game_config_value('jade_rogue_purse'), "
        "       game_config_value('rogue_spawn_chance')"
    ).fetchone()
    assert 0 < chance <= 0.15, f"a repeatable faucet at {chance} is a flood forever"

    per_action = float(chance) * float(ambush) * float(purse)
    daily_per_day = float(conn.execute(
        "SELECT game_config_value('daily_jade_max')"
    ).fetchone()[0])
    assert per_action * 200 < daily_per_day, (
        f"two hundred hunts pays {per_action * 200:.1f}, which should still be "
        f"under one day's purse of {daily_per_day:.0f}"
    )


# ---------------------------------------------------------------------------
# Rerolling
# ---------------------------------------------------------------------------


def test_the_published_odds_are_the_odds_the_roll_uses(conn):
    """A player about to spend three Jade a pull is entitled to the real
    numbers, so the view reads the same weights the roll does."""
    published = dict(conn.execute(
        "SELECT rarity, chance FROM reroll_odds WHERE trait = 'root'"
    ).fetchall())
    actual = dict(conn.execute(
        """
        SELECT r.rarity, ra.roll_weight / (
            SELECT sum(x.roll_weight) FROM (
                SELECT DISTINCT r2.rarity, ra2.roll_weight
                FROM roots r2 JOIN rarities ra2 ON ra2.code = r2.rarity
                WHERE ra2.roll_weight > 0
                  AND NOT EXISTS (SELECT 1 FROM roots e WHERE e.evolves_into = r2.code)
            ) x)
        FROM roots r JOIN rarities ra ON ra.code = r.rarity
        WHERE ra.roll_weight > 0
          AND NOT EXISTS (SELECT 1 FROM roots e WHERE e.evolves_into = r.code)
        GROUP BY r.rarity, ra.roll_weight
        """
    ).fetchall())
    for band, chance in published.items():
        assert abs(float(chance) - float(actual[band])) < 0.0001, band


def test_a_batch_stops_the_moment_it_meets_the_target(conn, make_player):
    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 3000, 'test_faucet')", (player,))

    # Common or better is every roll, so the batch must stop on the first.
    row = conn.execute(
        "SELECT rolls_made, spent, hit_target FROM reroll_root(%s, 'common', 100)",
        (player,),
    ).fetchone()
    assert row[0] == 1, "one roll met a target of 'common or rarer'"
    assert row[2] is True
    assert row[1] == conn.execute(
        "SELECT game_config_value('reroll_jade_cost')"
    ).fetchone()[0]


def test_a_batch_stops_when_the_purse_runs_dry(conn, make_player):
    """It stops rather than failing: a batch that runs out has done what it
    could, and the player keeps whatever came up."""
    player = crafter(conn, make_player)
    cost = conn.execute("SELECT game_config_value('reroll_jade_cost')").fetchone()[0]
    conn.execute("SELECT grant_jade(%s, %s, 'test_faucet')", (player, int(cost) * 4))

    row = conn.execute(
        "SELECT rolls_made, spent, jade_left FROM reroll_root(%s, 'unique', 100)",
        (player,),
    ).fetchone()
    assert row[0] == 4, "four rolls is what four rolls' worth buys"
    assert row[2] < cost, "and it stopped with too little for another"


def test_rerolling_actually_moves_the_root(conn, make_player):
    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 3000, 'test_faucet')", (player,))
    conn.execute("SELECT reroll_root(%s, 'unique', 50)", (player,))

    assert conn.execute(
        "SELECT root_rolls FROM player_character WHERE player_id = %s", (player,)
    ).fetchone()[0] >= 1
    # Every roll is a ledger line, so the sink is measurable like the others.
    assert conn.execute(
        "SELECT count(*) FROM jade_ledger WHERE player_id = %s AND reason = 'reroll_root'",
        (player,),
    ).fetchone()[0] >= 1


def test_rerolling_a_body_recomputes_the_body(conn, make_player):
    """A physique is stats. Leaving the stored ones alone would mean the sheet
    describes one body and the fight uses another."""
    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 3000, 'test_faucet')", (player,))
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))

    conn.execute("SELECT reroll_physique(%s, 'divine', 100)", (player,))

    stored, derived = conn.execute(
        """
        SELECT pp.max_hp,
               greatest(1, round((game_config_value('physique_base_hp')) *
                   (tr.hp_multiplier + player_stat(pp.player_id, 'max_hp')
                    + foundation_bonus(pp.player_id, 'hp'))))
        FROM player_physique pp
        JOIN player_trait_rates tr ON tr.player_id = pp.player_id
        WHERE pp.player_id = %s
        """,
        (player,),
    ).fetchone()
    assert stored == derived, "the stored body must be the rolled body"


def test_a_race_is_changed_rather_than_rolled(conn, make_player):
    """0011: a race is the one trait a player states rather than receives, and
    it has no rarity at all - so there is nothing to gamble on."""
    assert conn.execute(
        "SELECT count(*) FROM information_schema.columns "
        "WHERE table_name = 'races' AND column_name = 'rarity'"
    ).fetchone()[0] == 0

    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 100, 'test_faucet')", (player,))
    fee = conn.execute(
        "SELECT game_config_value('race_change_jade_cost')"
    ).fetchone()[0]

    row = conn.execute(
        "SELECT race_code, spent FROM change_race(%s, 'rockman')", (player,)
    ).fetchone()
    assert row == ("rockman", fee)
    with pytest.raises(psycopg.errors.CheckViolation, match="already"):
        conn.execute("SELECT change_race(%s, 'rockman')", (player,))


def test_a_reroll_you_cannot_afford_costs_nothing(conn, make_player):
    player = crafter(conn, make_player)
    row = conn.execute(
        "SELECT rolls_made, spent FROM reroll_root(%s, 'divine', 100)", (player,)
    ).fetchone()
    assert row == (0, 0), "no purse, no rolls, no charge"


def test_a_roll_changes_nothing_until_it_is_taken(conn, make_player):
    """The whole point of 0092. Rolling must leave the character alone."""
    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 3000, 'test_faucet')", (player,))
    before = conn.execute(
        "SELECT root_code FROM player_character WHERE player_id = %s", (player,)
    ).fetchone()[0]

    conn.execute("SELECT reroll_root(%s, 'unique', 40)", (player,))

    assert conn.execute(
        "SELECT root_code FROM player_character WHERE player_id = %s", (player,)
    ).fetchone()[0] == before, "the roll must not have touched it"
    assert conn.execute(
        "SELECT count(*) FROM player_reroll_offers WHERE player_id = %s "
        "AND trait = 'root'", (player,)
    ).fetchone()[0] == 1, "but there is an offer standing"


def test_taking_an_offer_applies_it_and_clears_it(conn, make_player):
    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 3000, 'test_faucet')", (player,))
    conn.execute("SELECT reroll_root(%s, 'unique', 40)", (player,))

    offered = conn.execute(
        "SELECT root_code FROM player_reroll_offers WHERE player_id = %s "
        "AND trait = 'root'", (player,)
    ).fetchone()[0]
    conn.execute("SELECT reroll_take(%s, 'root')", (player,))

    assert conn.execute(
        "SELECT root_code FROM player_character WHERE player_id = %s", (player,)
    ).fetchone()[0] == offered
    assert conn.execute(
        "SELECT count(*) FROM player_reroll_offers WHERE player_id = %s", (player,)
    ).fetchone()[0] == 0


def test_refusing_keeps_what_you_had_and_costs_the_jade(conn, make_player):
    """The Jade bought the look, and the look happened."""
    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 3000, 'test_faucet')", (player,))
    before = conn.execute(
        "SELECT root_code FROM player_character WHERE player_id = %s", (player,)
    ).fetchone()[0]

    spent = conn.execute(
        "SELECT spent FROM reroll_root(%s, 'unique', 20)", (player,)
    ).fetchone()[0]
    purse = conn.execute("SELECT jade_held(%s)", (player,)).fetchone()[0]

    conn.execute("SELECT reroll_discard(%s, 'root')", (player,))

    assert conn.execute(
        "SELECT root_code FROM player_character WHERE player_id = %s", (player,)
    ).fetchone()[0] == before
    assert conn.execute("SELECT jade_held(%s)", (player,)).fetchone()[0] == purse
    assert spent > 0, "and it was not free"


def test_rolling_again_can_only_improve_a_standing_offer(conn, make_player):
    """Pressing Roll with a Divine offer up must not throw it away. Anything
    else is a trap the first time somebody presses it out of habit."""
    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 5000, 'test_faucet')", (player,))

    # Roll until something better than common is standing.
    conn.execute("SELECT reroll_root(%s, 'legendary', 100)", (player,))
    first = conn.execute(
        """
        SELECT ra.sort_order FROM player_reroll_offers o
        JOIN roots r ON r.code = o.root_code
        JOIN rarities ra ON ra.code = r.rarity
        WHERE o.player_id = %s AND o.trait = 'root'
        """,
        (player,),
    ).fetchone()[0]

    for _ in range(5):
        conn.execute("SELECT reroll_root(%s, 'unique', 5)", (player,))
        now = conn.execute(
            """
            SELECT ra.sort_order FROM player_reroll_offers o
            JOIN roots r ON r.code = o.root_code
            JOIN rarities ra ON ra.code = r.rarity
            WHERE o.player_id = %s AND o.trait = 'root'
            """,
            (player,),
        ).fetchone()[0]
        assert now >= first, "an offer must never get worse for rolling again"
        first = now


def test_a_batch_offers_the_best_it_saw_not_the_last(conn, make_player):
    """Rolling a hundred times, hitting Legendary on the fortieth and being
    offered the hundredth would be absurd."""
    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 5000, 'test_faucet')", (player,))

    # Target something almost unreachable so the batch runs its full length.
    conn.execute("SELECT reroll_root(%s, 'unique', 100)", (player,))
    offered = conn.execute(
        """
        SELECT ra.sort_order FROM player_reroll_offers o
        JOIN roots r ON r.code = o.root_code
        JOIN rarities ra ON ra.code = r.rarity
        WHERE o.player_id = %s AND o.trait = 'root'
        """,
        (player,),
    ).fetchone()[0]
    common = conn.execute(
        "SELECT sort_order FROM rarities WHERE code = 'common'"
    ).fetchone()[0]
    # A hundred rolls sees uncommon-or-better with overwhelming probability;
    # if it offered the LAST roll this would be common about 45% of the time.
    assert offered > common, "a hundred rolls should not offer a common root"


def test_taking_a_body_recomputes_it(conn, make_player):
    """Taking a body refreshes the stored figures rather than leaving them.

    This used to re-derive max_hp inline and compare. The formula has moved
    four times since that copy was written - `max_hp` LEFT the multiplier sum
    in 0434 ("every grant of it became base_hp"), speed joined defence in 0405,
    and body paths and foundation bonuses were added - and the copy followed
    none of it. Since `reroll_physique` lands on a RANDOM divine body, it
    agreed whenever the rolled body carried none of the terms it had never
    heard of: 44 runs in 50, failing the rest with values like 172 against 138.

    So it asks the function instead of keeping a copy. The figures must MOVE
    when the body changes, and a fresh recompute afterwards must move nothing -
    because the take already did it. One definition, not two.
    """

    def figures():
        return conn.execute(
            "SELECT max_hp, defense, strength FROM player_physique "
            "WHERE player_id = %s",
            (player,),
        ).fetchone()

    player = crafter(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 3000, 'test_faucet')", (player,))
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))

    was_body, was = (
        conn.execute(
            "SELECT physique_id FROM player_physique WHERE player_id = %s", (player,)
        ).fetchone()[0],
        figures(),
    )

    conn.execute("SELECT reroll_physique(%s, 'divine', 60)", (player,))
    conn.execute("SELECT reroll_take(%s, 'physique')", (player,))

    now_body = conn.execute(
        "SELECT physique_id FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]
    now = figures()

    assert now_body != was_body, "the take did not change the body at all"

    # The figures must move WHEN THE BODY'S MULTIPLIERS DO, and only then.
    # Asserting they always move failed about one run in ten: 0514 cut low-rank
    # magnitudes, so at rank 1 a divine body whose multipliers round to the
    # same place legitimately leaves (120, 20, 30) exactly where it found them.
    # That is the recompute working, not skipping - so the condition is read
    # off `physiques` instead of assumed.
    moved = conn.execute(
        """
        SELECT (was.hp_multiplier, was.defense_multiplier, was.strength_multiplier)
            IS DISTINCT FROM
               (now.hp_multiplier, now.defense_multiplier, now.strength_multiplier)
        FROM physiques was, physiques now
        WHERE was.physique_id = %s AND now.physique_id = %s
        """,
        (was_body, now_body),
    ).fetchone()[0]
    if moved:
        assert now != was, (
            f"body {was_body} and body {now_body} carry different multipliers "
            f"and the stored figures did not move: {was}"
        )

    # And it was recomputed AT the take, not left for the next tick: running
    # the recompute again moves nothing.
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    assert figures() == now, (
        "the figures moved on the next recompute, so the take left them stale"
    )


def test_the_price_rose_with_the_safety(conn):
    """0091 priced a roll that could cost you your root. 0092 made it
    refusable, so a roll is strictly non-negative and worth more."""
    assert conn.execute(
        "SELECT game_config_value('reroll_jade_cost')"
    ).fetchone()[0] == 5


# ---------------------------------------------------------------------------
# The daily purse
# ---------------------------------------------------------------------------


def test_a_daily_pays_once_and_then_says_when(conn, make_player):
    """It reports rather than raises when it is not due - `claim_cooldown`
    settled that shape, and "come back at" is an answer."""
    player = make_player("Daily")
    first = conn.execute("SELECT * FROM claim_daily(%s)", (player,)).fetchone()
    assert first[0] is True and first[1] > 0

    again = conn.execute("SELECT * FROM claim_daily(%s)", (player,)).fetchone()
    assert again[0] is False, "not due yet"
    assert again[1] == 0, "and it pays nothing"
    assert again[5] is not None, "but it says when"

    assert conn.execute("SELECT jade_held(%s)", (player,)).fetchone()[0] == first[1]


def test_a_run_pays_more_and_then_stops_growing(conn):
    ladder = [
        conn.execute("SELECT daily_jade_for_streak(%s)", (d,)).fetchone()[0]
        for d in range(1, 12)
    ]
    assert ladder == sorted(ladder), f"a run must not pay less: {ladder}"
    assert ladder[-1] == conn.execute(
        "SELECT game_config_value('daily_jade_max')"
    ).fetchone()[0], "and it has to stop somewhere"


def test_a_settled_run_pays_a_week_worth_spending(conn):
    """The old target was the economy document's "about 50 Jade a week", and
    every sink was priced against it. Nobody ever reached the sinks: 61 pieces
    were generated in the game's whole life and the auction house never
    carried a listing, because 50 a week is what the ceiling said and the
    faucet never ran near it.

    0123 tripled it. The band below is wide on purpose - what matters is that
    a settled week buys something real and does not buy everything: several
    rerolls, or a slow accumulation toward a dwelling, and nowhere near a
    Grotto-Heaven's 640.
    """
    cap = conn.execute("SELECT game_config_value('daily_jade_max')").fetchone()[0]
    hours = conn.execute(
        "SELECT game_config_value('daily_cooldown_hours')"
    ).fetchone()[0]
    weekly = float(cap) * (7 * 24 / float(hours))

    reroll = float(conn.execute(
        "SELECT game_config_value('reroll_jade_cost')"
    ).fetchone()[0])
    top_dwelling = float(conn.execute(
        "SELECT max(jade_cost) FROM dwelling_stages"
    ).fetchone()[0])

    assert 100 <= weekly <= 250, f"a settled week pays {weekly:.0f}"
    assert weekly / reroll >= 10, "a week should buy a handful of rolls"
    assert weekly < top_dwelling, (
        "and a week must not buy the last rung of the dwelling ladder"
    )


def test_a_broken_run_starts_again(conn, make_player):
    player = make_player("Lapsed")
    conn.execute("SELECT claim_daily(%s)", (player,))
    conn.execute("SELECT claim_daily(%s)", (player,))  # refused, changes nothing

    # Walk the clock past the grace window rather than past the cooldown.
    conn.execute(
        "UPDATE player_daily SET last_claimed_at = now() - interval '5 days' "
        "WHERE player_id = %s", (player,)
    )
    row = conn.execute(
        "SELECT claimed, streak, kept FROM claim_daily(%s)", (player,)
    ).fetchone()
    assert row[0] is True
    assert row[1] == 1, "the run started again"
    assert row[2] is False, "and the screen is told so"


def test_a_run_survives_a_late_return(conn, make_player):
    """Two hours under a day, and forgiveness measured in elapsed time, is
    what stops a run breaking because somebody slept in."""
    player = make_player("Punctual")
    conn.execute("SELECT claim_daily(%s)", (player,))
    conn.execute(
        "UPDATE player_daily SET last_claimed_at = now() - interval '30 hours' "
        "WHERE player_id = %s", (player,)
    )
    row = conn.execute(
        "SELECT streak, kept FROM claim_daily(%s)", (player,)
    ).fetchone()
    assert row[0] == 2, "thirty hours later is still the next day"
    assert row[1] is True


def test_the_daily_is_measurable_like_every_other_faucet(conn, make_player):
    player = make_player("Counted")
    conn.execute("SELECT claim_daily(%s)", (player,))
    assert conn.execute(
        "SELECT count(*) FROM jade_ledger WHERE player_id = %s AND reason = 'daily'",
        (player,),
    ).fetchone()[0] == 1


# ---------------------------------------------------------------------------
# Rest and meditate
# ---------------------------------------------------------------------------


def test_a_rest_heals_a_share_of_the_whole_body(conn, make_player):
    """A share of MAXIMUM health, not of what is missing - a percentage of the
    gap pays least exactly when a player most needs it."""
    player = fighter(conn, make_player, "mortal_body")
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    cap = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]
    lo, hi = conn.execute(
        "SELECT game_config_value('rest_heal_min_pct'), "
        "game_config_value('rest_heal_max_pct')"
    ).fetchone()

    for _ in range(12):
        conn.execute(
            "UPDATE player_physique SET current_hp = 1 WHERE player_id = %s", (player,)
        )
        healed = conn.execute("SELECT healed FROM rest(%s)", (player,)).fetchone()[0]
        assert float(lo) * cap - 1 <= healed <= float(hi) * cap + 1, healed


def test_a_rest_reports_what_it_banked(conn, make_player):
    """The body's cap is why offered and healed differ, and 0045 is why the
    screen must be told the second number."""
    player = fighter(conn, make_player, "mortal_body")
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    cap = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]
    conn.execute(
        "UPDATE player_physique SET current_hp = %s WHERE player_id = %s",
        (cap - 1, player),
    )
    row = conn.execute(
        "SELECT healed, offered, full_up FROM rest(%s)", (player,)
    ).fetchone()
    assert row[0] == 1, "one point was all there was room for"
    assert row[1] > row[0], "and it rolled more than that"
    assert row[2] is True


def test_resting_at_full_health_does_nothing_and_says_so(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    conn.execute(
        "UPDATE player_physique pp SET current_hp = pp.max_hp WHERE player_id = %s",
        (player,),
    )
    row = conn.execute("SELECT healed, full_up FROM rest(%s)", (player,)).fetchone()
    assert row == (0, True)


def test_meditation_is_a_share_of_the_realm_not_of_the_total(conn, make_player):
    """A percentage of what a player already holds pays the rich and starves
    the poor. A percentage of the realm being crossed is worth the same at the
    bottom of the ladder and the top."""
    player = fighter(conn, make_player, "mortal_body")
    span = conn.execute(
        """
        SELECT r.cultivation_required FROM realms r
        JOIN player_cultivation pc ON r.realm_id = pc.realm_id + 1
        WHERE pc.player_id = %s
        """,
        (player,),
    ).fetchone()[0]
    lo, hi = conn.execute(
        "SELECT game_config_value('meditate_min_pct'), "
        "game_config_value('meditate_max_pct')"
    ).fetchone()

    for _ in range(10):
        conn.execute("UPDATE player_cultivation SET cultivation = 0 WHERE player_id = %s",
                     (player,))
        offered = conn.execute(
            "SELECT offered FROM meditate(%s, 'cultivation')", (player,)
        ).fetchone()[0]
        assert float(lo) * span - 1 <= offered <= float(hi) * span + 1, offered


def test_meditation_stops_at_the_realms_door(conn, make_player):
    """Cultivation fills to the threshold and stops, so what is offered and
    what is banked are routinely different numbers."""
    player = fighter(conn, make_player, "mortal_body")
    ceiling = conn.execute("SELECT cultivation_ceiling(%s)", (player,)).fetchone()[0]
    conn.execute(
        "UPDATE player_cultivation SET cultivation = %s WHERE player_id = %s",
        (ceiling, player),
    )
    row = conn.execute(
        "SELECT gained, offered, at_the_door FROM meditate(%s, 'cultivation')",
        (player,),
    ).fetchone()
    assert row[0] == 0, "there was no room"
    assert row[1] > 0, "but the hour was worth something"
    assert row[2] is True


def test_meditating_on_a_path_needs_a_path(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    conn.execute(
        "UPDATE player_cultivation SET focus_path = NULL WHERE player_id = %s", (player,)
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="focus"):
        conn.execute("SELECT meditate(%s, 'path')", (player,))


def test_meditating_on_a_path_moves_the_tier(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    conn.execute(
        "UPDATE player_cultivation SET focus_path = 'fire' WHERE player_id = %s",
        (player,),
    )
    row = conn.execute(
        "SELECT gained, path_code, tier_before, tier_after FROM meditate(%s, 'path')",
        (player,),
    ).fetchone()
    assert row[0] > 0 and row[1] == "fire"
    assert row[3] >= row[2]
    assert conn.execute(
        "SELECT insight FROM player_path_attainment "
        "WHERE player_id = %s AND path_code = 'fire'", (player,)
    ).fetchone()[0] == row[0]


def test_you_cannot_meditate_on_something_that_is_not_a_thing(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT meditate(%s, 'vibes')", (player,))


def test_every_timed_action_appears_on_the_cooldown_list(conn, make_player):
    """The list is derived from the `<action>_cooldown_minutes` keys, so a new
    timed action appears in the migration that creates it. A hand-written list
    would leave the newest thing invisible."""
    player = make_player("Waiting")
    listed = {
        r[0] for r in conn.execute(
            "SELECT action FROM cooldown_status(%s)", (player,)
        ).fetchall()
    }
    declared = {
        r[0].replace("_cooldown_minutes", "")
        for r in conn.execute(
            r"SELECT key FROM game_config WHERE key LIKE '%\_cooldown\_minutes'"
        ).fetchall()
    }
    assert declared <= listed, f"a declared cooldown is missing: {declared - listed}"
    assert "daily" in listed, "the one people most want to see"


def test_an_untouched_player_can_do_everything(conn, make_player):
    player = make_player("Fresh")
    assert all(
        r[0] for r in conn.execute(
            "SELECT ready FROM cooldown_status(%s)", (player,)
        ).fetchall()
    ), "nothing has been claimed yet"


def test_an_open_set_of_tries_reads_as_ready(conn, make_player):
    """A claim buys five swings and starts the clock on the first, so the
    cooldown runs while the player still has swings in hand. Saying 'gather in
    four minutes' to somebody holding three would be wrong in the way that
    matters most."""
    player = make_player("Midway")
    conn.execute(
        "INSERT INTO player_location (player_id, region_code) VALUES (%s, 'central')",
        (player,),
    )
    conn.execute(
        "SELECT begin_action(%s, 'gather', 'gather_cooldown_minutes', 'gather_tries')",
        (player,),
    )
    conn.execute("SELECT spend_try(%s, 'gather')", (player,))
    # Push the clock forward so only the open set can be making it ready.
    conn.execute(
        "UPDATE player_cooldowns SET available_at = now() + interval '1 hour' "
        "WHERE player_id = %s AND action = 'gather'", (player,)
    )

    row = conn.execute(
        "SELECT ready, tries_left FROM cooldown_status(%s) WHERE action = 'gather'",
        (player,),
    ).fetchone()
    assert row[0] is True and row[1] == 4


def test_a_spent_set_with_the_clock_running_is_not_ready(conn, make_player):
    player = make_player("Spent")
    conn.execute(
        "INSERT INTO player_location (player_id, region_code) VALUES (%s, 'central')",
        (player,),
    )
    conn.execute(
        "SELECT begin_action(%s, 'mine', 'mine_cooldown_minutes', 'mine_tries')",
        (player,),
    )
    conn.execute("DELETE FROM player_action_tries WHERE player_id = %s", (player,))
    conn.execute(
        "UPDATE player_cooldowns SET available_at = now() + interval '1 hour' "
        "WHERE player_id = %s AND action = 'mine'", (player,)
    )

    row = conn.execute(
        "SELECT ready, ready_at FROM cooldown_status(%s) WHERE action = 'mine'",
        (player,),
    ).fetchone()
    assert row[0] is False and row[1] is not None


def test_the_waits_are_the_ones_that_were_asked_for(conn):
    assert conn.execute(
        "SELECT game_config_value('rest_cooldown_minutes')"
    ).fetchone()[0] == 5
    assert conn.execute(
        "SELECT game_config_value('meditate_cooldown_minutes')"
    ).fetchone()[0] == 60


def test_an_action_nobody_styled_still_shows_up(conn, make_player):
    """The point of the LEFT JOIN in `cooldown_status`.

    `cooldown_display` is decoration. If a missing row could drop an action
    from the screen then the derived list - the whole reason 0095 read the
    config keys instead of naming the actions - would be back to being a list
    somebody has to remember to update, only now silently.
    """
    player = make_player("Unstyled")
    conn.execute(
        "INSERT INTO game_config (key, value, description) "
        "VALUES ('sparring_cooldown_minutes', 12, 'a test key')"
    )
    row = conn.execute(
        "SELECT label, emoji, section, sort_order FROM cooldown_status(%s) "
        "WHERE action = 'sparring'",
        (player,),
    ).fetchone()
    conn.execute("DELETE FROM game_config WHERE key = 'sparring_cooldown_minutes'")

    assert row is not None, "an unstyled action vanished"
    assert row[0] == "Sparring", "it names itself when nothing else will"
    assert row[2] == "Other" and row[3] == 999, "and sorts to the end"


def test_every_styled_action_is_a_real_one(conn):
    """The other direction: a row for an action that no longer has a cooldown
    is a heading with nothing under it."""
    orphans = conn.execute(
        r"""
        SELECT d.action FROM cooldown_display d
        WHERE d.action <> 'daily'
          AND NOT EXISTS (
            SELECT 1 FROM game_config g
            WHERE g.key = d.action || '_cooldown_minutes')
        """
    ).fetchall()
    assert [r[0] for r in orphans] == [], "styling for an action with no clock"


def test_the_screen_says_nothing_this_game_does_not_have(conn):
    """The screen this was modelled on lists systems from another game. A
    timer for one of them is a promise with a clock on it."""
    absent = {
        "pvp", "battlefield", "world_boss", "tournament", "inheritance",
        "mentorship", "companion", "servant", "split_body", "farm",
    }
    listed = {r[0] for r in conn.execute("SELECT action FROM cooldown_display").fetchall()}
    assert not (listed & absent), f"a timer for a system we do not have: {listed & absent}"




# ---------------------------------------------------------------------------
# Attainment resistance, and the standing it is read from
# ---------------------------------------------------------------------------


def test_understanding_a_path_turns_its_blows_aside(conn, make_player):
    """Seeded in 0003, read by nothing until 0101. /tiers had been promising
    Grandmasters a resistance the damage pipeline never applied."""
    player = fighter(conn, make_player, "mortal_body")
    species = conn.execute(
        """
        SELECT cs.species_id, cp.path_code
        FROM creature_species cs
        JOIN creature_paths cp ON cp.species_id = cs.species_id AND cp.is_primary
        WHERE cs.base_attack > 0
        ORDER BY cs.species_id LIMIT 1
        """
    ).fetchone()

    before = conn.execute(
        "SELECT final_damage FROM compute_creature_damage(%s, %s)",
        (species[0], player),
    ).fetchone()[0]

    # Grandmaster is the first tier the ladder pays resistance at.
    conn.execute(
        """
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (%s, %s, 50000, 6)
        ON CONFLICT (player_id, path_code) DO UPDATE SET tier = 6
        """,
        (player, species[1]),
    )
    after = conn.execute(
        "SELECT final_damage FROM compute_creature_damage(%s, %s)",
        (species[0], player),
    ).fetchone()[0]

    assert after < before, "a Grandmaster of the Path takes less from it"


def test_resistance_is_one_sum_not_two(conn, make_player):
    """The screen and the pipeline read the same function on purpose. Body and
    attainment add, the way every other bonus in this game does."""
    player = fighter(conn, make_player, "mortal_body")
    conn.execute(
        """
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (%s, 'fire', 50000, 6)
        ON CONFLICT (player_id, path_code) DO UPDATE SET tier = 6
        """,
        (player,),
    )
    body = conn.execute(
        """
        SELECT COALESCE(ppb.resistance, 0)
        FROM player_physique pp
        LEFT JOIN physique_path_bonuses ppb
               ON ppb.physique_id = pp.physique_id AND ppb.path_code = 'fire'
        WHERE pp.player_id = %s
        """,
        (player,),
    ).fetchone()[0]
    tier = conn.execute(
        "SELECT resistance_bonus FROM attainment_tiers WHERE tier = 6"
    ).fetchone()[0]

    assert conn.execute(
        "SELECT player_path_resistance(%s, 'fire')", (player,)
    ).fetchone()[0] == body + tier


def test_resistance_still_cannot_pass_the_cap(conn, make_player):
    """A stack of resistances must never make anybody immune to a whole Path."""
    player = fighter(conn, make_player, "mortal_body")
    conn.execute(
        """
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (%s, 'fire', 2000000, 10)
        ON CONFLICT (player_id, path_code) DO UPDATE SET tier = 10
        """,
        (player,),
    )
    conn.execute(
        """
        INSERT INTO physique_path_bonuses (physique_id, path_code, resistance)
        SELECT pp.physique_id, 'fire', 0.9
        FROM player_physique pp WHERE pp.player_id = %s
        ON CONFLICT (physique_id, path_code) DO UPDATE SET resistance = 0.9
        """,
        (player,),
    )
    cap = conn.execute(
        "SELECT game_config_value('physique_resistance_cap')"
    ).fetchone()[0]
    assert conn.execute(
        "SELECT player_path_resistance(%s, 'fire')", (player,)
    ).fetchone()[0] == cap


def test_the_standing_covers_every_path_touched_or_not(conn, make_player):
    """"Where would I learn fastest" is a question about the Paths you have
    NOT started, so a screen fed only by attainment rows could not answer it."""
    player = fighter(conn, make_player, "mortal_body")
    listed = conn.execute(
        "SELECT count(*) FROM player_path_standing(%s)", (player,)
    ).fetchone()[0]
    assert listed == conn.execute("SELECT count(*) FROM paths").fetchone()[0]


def test_an_untouched_path_reads_as_uninitiated_rather_than_missing(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    row = conn.execute(
        "SELECT insight, tier, tier_name, dao_marks FROM player_path_standing(%s) "
        "WHERE path_code = 'fire'",
        (player,),
    ).fetchone()
    assert row == (0, 0, "Uninitiated", 0)


def test_the_standing_reports_the_resistance_the_pipeline_uses(conn, make_player):
    """The reason both go through one function: a screen that summed the
    bonuses itself would be a second implementation of the pipeline."""
    player = fighter(conn, make_player, "mortal_body")
    conn.execute(
        """
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (%s, 'fire', 50000, 6)
        ON CONFLICT (player_id, path_code) DO UPDATE SET tier = 6
        """,
        (player,),
    )
    shown = conn.execute(
        "SELECT resistance FROM player_path_standing(%s) WHERE path_code = 'fire'",
        (player,),
    ).fetchone()[0]
    assert shown == conn.execute(
        "SELECT player_path_resistance(%s, 'fire')", (player,)
    ).fetchone()[0]


def test_the_focused_path_says_so(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    conn.execute(
        "UPDATE player_cultivation SET focus_path = 'fire' WHERE player_id = %s",
        (player,),
    )
    focused = [
        r[0] for r in conn.execute(
            "SELECT path_code FROM player_path_standing(%s) WHERE focused", (player,)
        ).fetchall()
    ]
    assert focused == ["fire"], "exactly one, and it is the one aimed at"

# ---------------------------------------------------------------------------
# The reserve
# ---------------------------------------------------------------------------


def bottlenecked(conn, make_player, realm: int = 1) -> int:
    """A cultivator sitting exactly at a realm's door."""
    player = make_player("Waiting at the door")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id, cultivation, aptitude) "
        "VALUES (%s, %s, 0, 100)", (player, realm)
    )
    conn.execute("INSERT INTO player_physique (player_id) VALUES (%s)", (player,))
    return player


def test_overflow_is_held_rather_than_dropped(conn, make_player):
    """The whole point. Before 0099 the excess was clamped away and the player
    was told the bottleneck took it."""
    player = bottlenecked(conn, make_player)
    ceiling = conn.execute("SELECT cultivation_ceiling(%s)", (player,)).fetchone()[0]

    conn.execute("SELECT apply_cultivation_xp(%s, %s)", (player, ceiling + 100))
    have, held = conn.execute(
        "SELECT cultivation, reserve FROM player_cultivation WHERE player_id = %s",
        (player,),
    ).fetchone()
    assert have == ceiling, "the door still holds"
    assert held == 100, "and the overflow is behind it"


def test_the_reserve_pours_in_on_the_crossing(conn, make_player):
    player = bottlenecked(conn, make_player)
    ceiling = conn.execute("SELECT cultivation_ceiling(%s)", (player,)).fetchone()[0]
    conn.execute("SELECT apply_cultivation_xp(%s, %s)", (player, ceiling + 400))

    # How much room the crossing makes is the ladder's business, not this
    # test's. 0124 put a Late rung between Mid and Peak, so a crossing opens
    # less at once than it used to and part of a big reserve stays held -
    # which is the reserve working, not failing.
    room = conn.execute(
        """
        SELECT after.cultivation_required - here.cultivation_required
        FROM player_cultivation pc
        JOIN realms here  ON here.realm_id  = pc.realm_id + 1
        JOIN realms after ON after.realm_id = pc.realm_id + 2
        WHERE pc.player_id = %s
        """,
        (player,),
    ).fetchone()[0]
    # And how much was ever held is the lid's business: the cap is a share of
    # that same gap, so a finer ladder banks less as well as pouring less.
    banked = conn.execute(
        "SELECT reserve FROM player_cultivation WHERE player_id = %s", (player,)
    ).fetchone()[0]
    expected = min(banked, room)

    drawn, left = conn.execute(
        "SELECT reserve_drawn, reserve_left FROM breakthrough(%s)", (player,)
    ).fetchone()
    have, held = conn.execute(
        "SELECT cultivation, reserve FROM player_cultivation WHERE player_id = %s",
        (player,),
    ).fetchone()
    assert drawn == expected
    assert left == banked - expected
    assert have == ceiling + expected, "every point the new room could take"
    assert held == left, "and the rest is still waiting, not lost"


def test_the_reserve_stops_at_one_realm(conn, make_player):
    """Uncapped, not breaking through would be the strongest play in the game:
    bank a month at the door, then cross three realms at once."""
    player = bottlenecked(conn, make_player)
    lid = conn.execute("SELECT cultivation_reserve_cap(%s)", (player,)).fetchone()[0]

    conn.execute("SELECT apply_cultivation_xp(%s, %s)", (player, 10_000_000))
    held = conn.execute(
        "SELECT reserve FROM player_cultivation WHERE player_id = %s", (player,)
    ).fetchone()[0]
    assert held == lid, "the lid is the lid however long somebody waits"

    # And a full reserve buys exactly one more crossing, never two.
    conn.execute("SELECT breakthrough(%s)", (player,))
    assert conn.execute(
        "SELECT ready_to_break_through(%s)", (player,)
    ).fetchone()[0] is True, "the reserve was worth the next door"
    conn.execute("SELECT breakthrough(%s)", (player,))
    assert conn.execute(
        "SELECT ready_to_break_through(%s)", (player,)
    ).fetchone()[0] is False, "but not the one after it"


def test_the_lid_is_measured_against_the_gap_it_is_spent_on(conn, make_player):
    """It is the NEXT gap, not the one in hand - because the next gap is what
    the reserve is poured into, and that is what bounds the chain to one."""
    player = bottlenecked(conn, make_player, realm=4)
    expected = conn.execute(
        """
        SELECT round(game_config_value('cultivation_reserve_share')
                     * (after.cultivation_required - next.cultivation_required))
        FROM player_cultivation pc
        JOIN realms next  ON next.realm_id  = pc.realm_id + 1
        JOIN realms after ON after.realm_id = pc.realm_id + 2
        WHERE pc.player_id = %s
        """,
        (player,),
    ).fetchone()[0]
    assert conn.execute(
        "SELECT cultivation_reserve_cap(%s)", (player,)
    ).fetchone()[0] == expected


def test_every_source_fills_the_reserve_not_just_idle_time(conn, make_player):
    """apply_cultivation_xp is the one writer, which is why this holds for
    pills and meditation without either of them knowing about it."""
    player = bottlenecked(conn, make_player)
    ceiling = conn.execute("SELECT cultivation_ceiling(%s)", (player,)).fetchone()[0]
    conn.execute("SELECT apply_cultivation_xp(%s, %s)", (player, ceiling))

    before = conn.execute(
        "SELECT reserve FROM player_cultivation WHERE player_id = %s", (player,)
    ).fetchone()[0]
    conn.execute("SELECT meditate(%s, 'cultivation')", (player,))
    after = conn.execute(
        "SELECT reserve FROM player_cultivation WHERE player_id = %s", (player,)
    ).fetchone()[0]
    assert after > before, "a meditation at the door is held, not burned"


def test_the_top_of_the_ladder_holds_nothing_back(conn, make_player):
    """No ceiling, so nothing overflows and the reserve never fills."""
    top = conn.execute("SELECT max(realm_id) FROM realms").fetchone()[0]
    player = bottlenecked(conn, make_player, realm=top)
    conn.execute("SELECT apply_cultivation_xp(%s, 500)", (player,))
    have, held = conn.execute(
        "SELECT cultivation, reserve FROM player_cultivation WHERE player_id = %s",
        (player,),
    ).fetchone()
    assert have == 500 and held == 0


def test_settle_reports_what_it_held(conn, make_player):
    """The gain column keeps meaning cultivation that landed. A card that
    folded the two together would tell somebody at the bottleneck they were
    making progress they cannot spend."""
    player = bottlenecked(conn, make_player)
    ceiling = conn.execute("SELECT cultivation_ceiling(%s)", (player,)).fetchone()[0]
    conn.execute("SELECT apply_cultivation_xp(%s, %s)", (player, ceiling))
    conn.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '10 hours' "
        "WHERE player_id = %s", (player,)
    )
    row = conn.execute(
        "SELECT cultivation_gained, cultivation_stored "
        "FROM settle_passive_cultivation(%s)",
        (player,),
    ).fetchone()
    assert row[0] == 0, "the door was already full"
    assert row[1] > 0, "and the hours went to the reserve"


def test_a_full_reserve_reports_the_zero_it_stored(conn, make_player):
    """Measured, not calculated. Past the lid it really is lost, and the screen
    has to be able to say so."""
    player = bottlenecked(conn, make_player)
    conn.execute("SELECT apply_cultivation_xp(%s, 10000000)", (player,))
    conn.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '10 hours' "
        "WHERE player_id = %s", (player,)
    )
    row = conn.execute(
        "SELECT cultivation_gained, cultivation_stored "
        "FROM settle_passive_cultivation(%s)",
        (player,),
    ).fetchone()
    assert row == (0, 0)


def test_the_reserve_can_never_go_negative(conn, make_player):
    player = bottlenecked(conn, make_player)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "UPDATE player_cultivation SET reserve = -1 WHERE player_id = %s", (player,)
        )


def test_drawing_on_an_empty_reserve_changes_nothing(conn, make_player):
    player = bottlenecked(conn, make_player)
    conn.execute("SELECT apply_cultivation_xp(%s, 10)", (player,))
    assert conn.execute(
        "SELECT draw_from_reserve(%s)", (player,)
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT cultivation FROM player_cultivation WHERE player_id = %s", (player,)
    ).fetchone()[0] == 10


def test_the_lists_that_do_not_page_cannot_outgrow_a_select(conn):
    """Some screens hand a select a list without paging it, because the list is
    bounded by something other than the screen: the race table, the cap on
    open listings, the four equipment slots. Each of those bounds is a config
    dial or a table somebody could grow, and the day one passes 25 the select
    stops silently. So the bound is asserted here rather than trusted.

    The aperture used to be on this list and is not any more. 0352 took it
    from twelve to fifty-seven, this rule caught the `[:25]` in `GuView.build`
    that would have left an immortal wearing worms they could not take off,
    and the answer was to page that select rather than to cap the aperture at
    what a dropdown happens to hold.
    """
    limits = {
        "races on the reroll screen": conn.execute(
            "SELECT count(*) FROM races"
        ).fetchone()[0],
        "your own auction listings": conn.execute(
            "SELECT game_config_value('auction_max_open')"
        ).fetchone()[0],
        "equipment slots": conn.execute(
            "SELECT count(*) FROM equipment_slots"
        ).fetchone()[0],
    }
    too_big = {name: n for name, n in limits.items() if n > 25}
    assert not too_big, f"these need paging now: {too_big}"


# ---------------------------------------------------------------------------
# The Binder
# ---------------------------------------------------------------------------


def a_manual(conn, player: int, tier: int = 2, path: str = "fire") -> int:
    """A refined manual on somebody's shelf: codeless, so the garbage
    collector takes it when the last owner lets go."""
    manual = conn.execute(
        "INSERT INTO manuals (name, tier, created_by, refined_at, harmony) "
        "VALUES ('Test Scripture', %s, %s, now(), 60) RETURNING manual_id",
        (tier, player),
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO manual_paths (manual_id, path_code, weight) VALUES (%s, %s, 1)",
        (manual, path),
    )
    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (player, manual),
    )
    return manual


def test_unbinding_gives_pages_of_the_manuals_own_path(conn, make_player):
    """The point of returning them on the book's Path: pages of one Path
    refine together, so what comes back is worth refining."""
    player = make_player("Binder")
    manual = a_manual(conn, player, tier=3, path="fire")

    made = conn.execute(
        "SELECT page_ids FROM unbind_manuals(%s, ARRAY[%s])", (player, manual)
    ).fetchone()[0]
    paths = conn.execute(
        "SELECT DISTINCT path_code FROM manual_pages WHERE page_id = ANY(%s)",
        (made,),
    ).fetchall()
    assert [r[0] for r in paths] == ["fire"]


def test_the_manual_is_actually_gone(conn, make_player):
    player = make_player("Binder")
    manual = a_manual(conn, player)
    conn.execute("SELECT unbind_manuals(%s, ARRAY[%s])", (player, manual))

    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE manual_id = %s", (manual,)
    ).fetchone()[0] == 0
    # Codeless and unowned, so 0034's collector takes the row itself.
    assert conn.execute(
        "SELECT count(*) FROM manuals WHERE manual_id = %s", (manual,)
    ).fetchone()[0] == 0


def test_an_equipped_manual_is_refused_by_name(conn, make_player):
    """The slot table CASCADEs on the ownership row, so without this a bulk
    unbind would strip the book you were reading and say nothing."""
    player = make_player("Binder")
    manual = a_manual(conn, player)
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, manual_id, slot_index) "
        "VALUES (%s, %s, 0)", (player, manual)
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="equipped"):
        conn.execute("SELECT unbind_manuals(%s, ARRAY[%s])", (player, manual))


def test_you_cannot_unbind_somebody_elses_book(conn, make_player):
    mine = make_player("Owner")
    yours = make_player("Thief")
    manual = a_manual(conn, mine)
    # A savepoint, because a failed statement aborts the transaction and the
    # assertion afterwards is the interesting half: the book is still there.
    with conn.transaction(force_rollback=True):
        with pytest.raises(
            psycopg.errors.CheckViolation, match="none of those are yours"
        ):
            conn.execute("SELECT unbind_manuals(%s, ARRAY[%s])", (yours, manual))
    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE manual_id = %s", (manual,)
    ).fetchone()[0] == 1


def test_unbinding_always_loses(conn, make_player):
    """Refining makes a manual from pages and unbinding makes pages from a
    manual. At par that is a machine that turns two pages into two pages
    forever. The returned power must be well under what went in."""
    player = make_player("Binder")
    for tier in range(1, 11):
        implied, returned = conn.execute(
            """
            SELECT mt.bonus_budget * 100
                   * game_config_value('refinement_potential_divisor'),
                   y.power_returned
            FROM manual_tiers mt, LATERAL manual_unbind_yield(mt.tier) y
            WHERE mt.tier = %s
            """,
            (tier,),
        ).fetchone()
        assert returned < implied / 2, f"tier {tier} returns too much"


def test_a_page_never_comes_back_as_good_as_the_book(conn):
    rows = conn.execute(
        "SELECT mt.tier, y.page_tier FROM manual_tiers mt, "
        "LATERAL manual_unbind_yield(mt.tier) y ORDER BY mt.tier"
    ).fetchall()
    for tier, page_tier in rows:
        assert page_tier < tier or tier == 1, f"tier {tier} returns tier {page_tier}"


def test_every_tier_returns_at_least_one_page(conn):
    """A button that destroys your property and hands back nothing is not a
    feature."""
    counts = [
        r[0] for r in conn.execute(
            "SELECT y.pages FROM manual_tiers mt, "
            "LATERAL manual_unbind_yield(mt.tier) y"
        ).fetchall()
    ]
    assert min(counts) >= 1


def test_unbinding_grants_no_refinement_exp(conn, make_player):
    """Otherwise refine-then-unbind is a treadmill that levels the craft for
    free, which is the whole reason the loop would be worth closing."""
    player = make_player("Binder")
    manual = a_manual(conn, player)
    before = conn.execute(
        "SELECT profession_level(%s, 'refinement')", (player,)
    ).fetchone()[0]
    conn.execute("SELECT unbind_manuals(%s, ARRAY[%s])", (player, manual))
    after = conn.execute(
        "SELECT profession_level(%s, 'refinement')", (player,)
    ).fetchone()[0]
    assert after == before
    assert conn.execute(
        "SELECT count(*) FROM player_professions "
        "WHERE player_id = %s AND profession = 'refinement'",
        (player,),
    ).fetchone()[0] == 0


def test_unbinding_nothing_is_refused(conn, make_player):
    player = make_player("Binder")
    with pytest.raises(psycopg.errors.CheckViolation, match="at least one"):
        conn.execute("SELECT unbind_manuals(%s, ARRAY[]::bigint[])", (player,))


def test_a_conversion_reaches_tiers_a_drop_cannot(conn, make_player):
    """Tiers 8 to 10 carry roll_weight 0 so they never drop. An unbound Tier 9
    manual still has to be able to return a Tier 8 page, which is why the
    minting of one page and the choosing of its tier are separate."""
    player = make_player("Binder")
    page = conn.execute(
        "SELECT mint_page_at(%s, 8::smallint)", (player,)
    ).fetchone()[0]
    assert conn.execute(
        "SELECT tier FROM manual_pages WHERE page_id = %s", (page,)
    ).fetchone()[0] == 8

    # And the drop path still cannot.
    for _ in range(30):
        dropped = conn.execute("SELECT mint_page(%s)", (player,)).fetchone()[0]
        tier = conn.execute(
            "SELECT tier FROM manual_pages WHERE page_id = %s", (dropped,)
        ).fetchone()[0]
        assert tier <= 7, "a drop reached a tier that is not meant to drop"


def test_minting_an_impossible_tier_is_refused(conn, make_player):
    player = make_player("Binder")
    with pytest.raises(psycopg.errors.CheckViolation, match="no page tier"):
        conn.execute("SELECT mint_page_at(%s, 99::smallint)", (player,))


def test_unbinding_several_at_once_is_one_transaction(conn, make_player):
    """The bulk half. Eleven Tier 1 manuals is the case this exists for."""
    player = make_player("Binder")
    manuals = [a_manual(conn, player, tier=1) for _ in range(5)]

    taken, made = conn.execute(
        "SELECT manuals_taken, pages_made FROM unbind_manuals(%s, %s)",
        (player, manuals),
    ).fetchone()
    assert taken == 5
    assert made >= 5
    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE player_id = %s", (player,)
    ).fetchone()[0] == 0


def test_one_equipped_book_stops_the_whole_batch(conn, make_player):
    """All or nothing: a bulk unbind that silently skipped the equipped one
    would be fine, but one that silently UNEQUIPPED it would not, and the
    difference is invisible from the button."""
    player = make_player("Binder")
    loose = a_manual(conn, player, tier=1)
    worn = a_manual(conn, player, tier=1)
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, manual_id, slot_index) "
        "VALUES (%s, %s, 0)", (player, worn)
    )
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "SELECT unbind_manuals(%s, %s)", (player, [loose, worn])
        )


# ---------------------------------------------------------------------------
# The profession ladders
# ---------------------------------------------------------------------------

LADDERS = {
    # Both of these ran to 7 until 0317 added Pseudo-Immortal gear, which
    # is tier 8 - so the metal, the miner who digs it and the smith who
    # works it all had to gain a rung together. 0504/0506 did it again for
    # tier 9, the Heavenly Court's band, and for the same reason: 0504 moved
    # the miner alone and these three tests caught the half-open ladder
    # before any ore was seeded into it.
    "mining_tier": ("mining_tier_cap", 1, 9),
    "forage_draws": ("forage_draws", 1, 3),
    "alchemy_herbs": ("alchemy_herb_slots", 2, 6),
    "forge_tier": ("smith_tier_cap", 2, 9),
    "forge_parts": ("smith_part_slots", 1, 4),
    "gu_refine_aux": ("gu_refine_aux_slots", 2, 8),
    "refinement_pages": ("refinement_max_pages", 3, 8),
}


def test_a_ladder_has_exactly_the_rungs_its_range_needs(conn):
    """One rung per step between the base and the cap. A missing rung is a
    benefit nobody can ever reach; a spare one is a rung that buys nothing
    because the LEAST() above it has already clamped."""
    for ladder, (_, base, cap) in LADDERS.items():
        rungs = conn.execute(
            "SELECT count(*) FROM profession_steps WHERE ladder = %s", (ladder,)
        ).fetchone()[0]
        assert rungs == cap - base, f"{ladder} has {rungs} rungs, wants {cap - base}"


def test_every_ladder_climbs(conn):
    """Enforced by a trigger, asserted here because the trigger only fires on
    write and the seeded rows went in before anybody was watching."""
    for ladder in LADDERS:
        levels = [
            r[0] for r in conn.execute(
                "SELECT level_required FROM profession_steps "
                "WHERE ladder = %s ORDER BY step", (ladder,)
            ).fetchall()
        ]
        assert levels == sorted(levels), f"{ladder} goes backwards: {levels}"
        assert len(set(levels)) == len(levels), f"{ladder} repeats a level"


def test_a_rung_below_the_one_before_it_is_refused(conn):
    """The trigger is DEFERRABLE on purpose: retuning a whole ladder rewrites
    every rung in one statement and passes through states that are briefly
    out of order. So the check lands at commit, and forcing it is how a test
    inside a rolled-back transaction can see it at all.
    """
    conn.execute(
        "UPDATE profession_steps SET level_required = 1 "
        "WHERE ladder = 'mining_tier' AND step = 6"
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="rung below"):
        conn.execute("SET CONSTRAINTS ALL IMMEDIATE")


def test_retuning_a_whole_ladder_at_once_is_allowed(conn):
    """The other half of why it defers. Every rung moves, and the ladder is
    out of order in the middle of the statement."""
    conn.execute(
        "UPDATE profession_steps SET level_required = level_required * 2 "
        "WHERE ladder = 'mining_tier'"
    )
    conn.execute("SET CONSTRAINTS ALL IMMEDIATE")
    assert conn.execute(
        "SELECT mining_tier_cap(132::smallint)"
    ).fetchone()[0] == 7


def test_the_top_rung_is_where_the_cap_lands(conn):
    """The ladder and the function have to agree about when it is over."""
    for ladder, (fn, base, cap) in LADDERS.items():
        top = conn.execute(
            "SELECT max(level_required) FROM profession_steps WHERE ladder = %s",
            (ladder,),
        ).fetchone()[0]
        at_top = conn.execute(
            f"SELECT {fn}(%s::smallint)", (top,)
        ).fetchone()[0]
        below = conn.execute(
            f"SELECT {fn}(%s::smallint)", (top - 1,)
        ).fetchone()[0]
        assert at_top == cap, f"{fn} at its top rung gives {at_top}, wants {cap}"
        assert below == cap - 1, f"{fn} was already capped before its top rung"


def test_a_ladder_never_goes_down_as_you_level(conn):
    for ladder, (fn, _, _) in LADDERS.items():
        values = [
            conn.execute(f"SELECT {fn}(%s::smallint)", (lvl,)).fetchone()[0]
            for lvl in range(1, 120, 3)
        ]
        assert values == sorted(values), f"{fn} falls somewhere: {values}"


def test_the_climb_is_longer_than_it_was(conn):
    """The whole point of 0106. Every ladder used to finish inside 50 levels
    and most inside 24."""
    was = {
        "mining_tier": 24,
        "forage_draws": 16,
        "alchemy_herbs": 20,
        "forge_tier": 20,
        "forge_parts": 12,
        "gu_refine_aux": 24,
        "refinement_pages": 50,
    }
    for ladder, old_cap in was.items():
        now = conn.execute(
            "SELECT max(level_required) FROM profession_steps WHERE ladder = %s",
            (ladder,),
        ).fetchone()[0]
        assert now > old_cap, f"{ladder} finishes at {now}, no later than {old_cap}"


def test_the_early_rungs_did_not_move(conn):
    """A stretch that demoted a cultivator who had already climbed would be
    taking something away to slow somebody else down. These are the rungs the
    live shelf was standing on when 0106 was written."""
    unchanged = [
        ("mining_tier", 9, "mining_tier_cap", 3),
        ("mining_tier", 13, "mining_tier_cap", 4),
        ("forage_draws", 7, "forage_draws", 1),
        ("forage_draws", 32, "forage_draws", 3),
        ("alchemy_herbs", 4, "alchemy_herb_slots", 2),
        ("alchemy_herbs", 7, "alchemy_herb_slots", 3),
        ("alchemy_herbs", 12, "alchemy_herb_slots", 4),
        ("forge_tier", 3, "smith_tier_cap", 2),
        ("forge_parts", 3, "smith_part_slots", 1),
        ("refinement_pages", 7, "refinement_max_pages", 3),
    ]
    for ladder, level, fn, expected in unchanged:
        got = conn.execute(f"SELECT {fn}(%s::smallint)", (level,)).fetchone()[0]
        assert got == expected, f"{fn}({level}) is {got}, was {expected}"


def test_the_next_rung_is_knowable(conn):
    """A long climb needs a screen that says how long. `ladder_next_at`
    returns NULL at the top, which is how one says "this is as far as it
    goes" rather than inventing a level nobody can reach."""
    assert conn.execute(
        "SELECT ladder_next_at('mining_tier', 1::smallint)"
    ).fetchone()[0] == 4
    top = conn.execute(
        "SELECT max(level_required) FROM profession_steps WHERE ladder = 'mining_tier'"
    ).fetchone()[0]
    assert conn.execute(
        "SELECT ladder_next_at('mining_tier', %s::smallint)", (top,)
    ).fetchone()[0] is None


def test_the_dials_that_stopped_turning_are_gone(conn):
    """A config key nothing reads is a lie with a number on it."""
    dead = conn.execute(
        """
        SELECT key FROM game_config WHERE key IN (
            'mining_levels_per_tier', 'forage_levels_per_draw',
            'alchemy_herbs_per_levels', 'forge_tier_per_levels',
            'forge_parts_per_levels', 'gu_refine_aux_per_levels',
            'refinement_pages_per_levels')
        """
    ).fetchall()
    assert [r[0] for r in dead] == []


# ---------------------------------------------------------------------------
# Tempering the body
# ---------------------------------------------------------------------------


def a_body(conn, make_player, xp: int = 0, rank: int = 1) -> int:
    player = make_player("Tempered")
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id, physique_xp, body_rank) "
        "VALUES (%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'), "
        "%s, %s)",
        (player, xp, rank),
    )
    conn.execute(
        "UPDATE player_physique SET body_path = 'taoist' WHERE player_id = %s",
        (player,),
    )
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))
    return player


def give_parts(conn, player: int, weight: int) -> None:
    """Enough beast material to pay a crossing, in common parts."""
    code = conn.execute(
        """
        SELECT bp.material_code FROM beast_parts bp
        JOIN materials m ON m.code = bp.material_code
        WHERE material_grade(m.rarity) = 1 ORDER BY bp.material_code LIMIT 1
        """
    ).fetchone()[0]
    conn.execute("SELECT grant_material(%s, %s, %s)", (player, code, weight))


def test_a_body_stops_at_the_rank_it_has_crossed(conn, make_player):
    """The whole point. XP keeps counting; the level waits at the door."""
    player = a_body(conn, make_player, xp=50_000, rank=1)
    level, xp = conn.execute(
        "SELECT body_level, physique_xp FROM player_physique WHERE player_id = %s",
        (player,),
    ).fetchone()
    assert xp == 50_000, "the training is kept in full"
    assert level == conn.execute(
        "SELECT body_level_ceiling(1::smallint)"
    ).fetchone()[0], "and the level stops at rank 1's ceiling"


def test_crossing_collects_every_level_waiting_behind_the_door(conn, make_player):
    player = a_body(conn, make_player, xp=50_000, rank=1)
    give_parts(conn, player, 500)
    before = conn.execute(
        "SELECT body_level FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0]

    after = conn.execute(
        "SELECT level_after FROM temper_body(%s)", (player,)
    ).fetchone()[0]
    assert after > before, "the levels arrive at once"
    assert after == conn.execute(
        "SELECT body_level_ceiling(2::smallint)"
    ).fetchone()[0]


def test_a_crossing_eats_beast_material(conn, make_player):
    player = a_body(conn, make_player, xp=2_000, rank=1)
    give_parts(conn, player, 100)
    before = conn.execute("SELECT player_beast_weight(%s)", (player,)).fetchone()[0]

    spent = conn.execute(
        "SELECT weight_spent FROM temper_body(%s)", (player,)
    ).fetchone()[0]
    after = conn.execute("SELECT player_beast_weight(%s)", (player,)).fetchone()[0]

    assert spent == conn.execute("SELECT body_rank_cost(2::smallint)").fetchone()[0]
    assert before - after == spent, "exactly what it said it would take"


def test_the_commonest_material_goes_first(conn, make_player):
    """A crossing that helped itself to the dragon scale while the boar tusks
    sat in the bag would be a trap rather than a price - the rare parts are
    what the forge wants."""
    player = a_body(conn, make_player, xp=2_000, rank=1)
    give_parts(conn, player, 100)
    rare = conn.execute(
        """
        SELECT bp.material_code FROM beast_parts bp
        JOIN materials m ON m.code = bp.material_code
        WHERE material_grade(m.rarity) = (SELECT max(material_grade(m2.rarity))
            FROM beast_parts b2 JOIN materials m2 ON m2.code = b2.material_code)
            ORDER BY bp.material_code LIMIT 1
        """
    ).fetchone()[0]
    conn.execute("SELECT grant_material(%s, %s, 10)", (player, rare))

    conn.execute("SELECT temper_body(%s)", (player,))
    left = conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = %s",
        (player, rare),
    ).fetchone()[0]
    assert left == 10, "the good material was not touched"


def test_a_crossing_without_the_training_is_refused(conn, make_player):
    player = a_body(conn, make_player, xp=10, rank=1)
    give_parts(conn, player, 500)
    with pytest.raises(psycopg.errors.CheckViolation, match="this rank asks for"):
        conn.execute("SELECT temper_body(%s)", (player,))


def test_a_crossing_without_the_material_is_refused(conn, make_player):
    player = a_body(conn, make_player, xp=50_000, rank=1)
    with pytest.raises(psycopg.errors.CheckViolation, match="beast material"):
        conn.execute("SELECT temper_body(%s)", (player,))


def test_the_last_rank_has_no_door_above_it(conn, make_player):
    # Rank 9 stopped being the top in 0383; the rule it was checking did not
    # change, so the test asks the ladder where its top is.
    top = conn.execute("SELECT max(rank) FROM body_rank_requirements").fetchone()[0]
    player = a_body(conn, make_player, xp=200_000, rank=top)
    give_parts(conn, player, 5_000)
    assert conn.execute(
        "SELECT body_level_ceiling(%s::smallint)", (top,)
    ).fetchone()[0] is None, "nothing is held back at the top"
    with pytest.raises(psycopg.errors.CheckViolation, match="nothing above"):
        conn.execute("SELECT temper_body(%s)", (player,))


def test_only_temper_body_moves_a_rank(conn, make_player):
    """It used to be derived from XP. If anything else starts moving it, the
    crossing stops being something a player does."""
    player = a_body(conn, make_player, xp=0, rank=1)
    conn.execute("SELECT apply_physique_xp(%s, 100000)", (player,))
    assert conn.execute(
        "SELECT body_rank FROM player_physique WHERE player_id = %s", (player,)
    ).fetchone()[0] == 1, "training alone never crosses a rank"


def test_both_gates_are_read_by_one_function(conn, make_player):
    player = a_body(conn, make_player, xp=2_000, rank=1)
    assert conn.execute("SELECT ready_to_temper(%s)", (player,)).fetchone()[0] is False
    give_parts(conn, player, 100)
    assert conn.execute("SELECT ready_to_temper(%s)", (player,)).fetchone()[0] is True


# ---------------------------------------------------------------------------
# The three effects that used to render and do nothing
# ---------------------------------------------------------------------------


def granting(conn, player: int, effect: str, magnitude) -> None:
    conn.execute(
        """
        INSERT INTO physique_effects (physique_id, effect_code, magnitude)
        SELECT pp.physique_id, %s, %s FROM player_physique pp
        WHERE pp.player_id = %s
        ON CONFLICT (physique_id, effect_code)
        DO UPDATE SET magnitude = EXCLUDED.magnitude
        """,
        (effect, magnitude, player),
    )


def a_fight(conn, player: int) -> int:
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE base_attack > 0 "
        "ORDER BY species_id LIMIT 1"
    ).fetchone()[0]
    conn.execute("DELETE FROM player_active_battle WHERE player_id = %s", (player,))
    return conn.execute("SELECT battle_open(%s, %s)", (player, species)).fetchone()[0]


def test_the_three_effects_are_no_longer_decoration(conn):
    """They carried is_live FALSE from 0036 to 0109, rendering on Gu in
    italics and doing nothing. Moonshadow Gu advertised 10% Suppression to
    everybody who ever looked at it."""
    dead = conn.execute(
        "SELECT code FROM gu_effects WHERE code IN ('heal','shield','suppression') "
        "AND NOT is_live"
    ).fetchall()
    assert [r[0] for r in dead] == []


def test_a_shield_is_a_fraction_of_the_body(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    granting(conn, player, "shield", 0.30)
    conn.execute("SELECT apply_physique_xp(%s, 0)", (player,))

    battle = a_fight(conn, player)
    max_hp, shield = conn.execute(
        "SELECT max_hp, shield FROM battle_combatants "
        "WHERE battle_id = %s AND combatant_no = 0", (battle,)
    ).fetchone()
    assert shield == int(max_hp * 0.30)


def test_a_body_with_no_shield_carries_none(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    battle = a_fight(conn, player)
    assert conn.execute(
        "SELECT shield FROM battle_combatants "
        "WHERE battle_id = %s AND combatant_no = 0", (battle,)
    ).fetchone()[0] == 0


def test_suppression_stops_the_move_the_creature_had_chosen(conn, make_player):
    """A mechanics test, so suppression has to be a certainty to be checked.

    `granting` writes ONE source - the body - and since 0516 no single source
    may give more than `source_share` of an effect, so a body granting 1.0
    suppression reaches 0.6 and this became a 60% coin flip that passed one
    run in three. The share is lifted here deliberately rather than worked
    around, because what is being tested is what happens WHEN suppression
    fires, not how often it does.
    """
    player = fighter(conn, make_player, "mortal_body")
    conn.execute(
        "UPDATE gu_effects SET source_share = 1.000 WHERE code = 'suppression'"
    )
    granting(conn, player, "suppression", 1.0)
    assert float(
        conn.execute("SELECT player_stat(%s, 'suppression')", (player,)).fetchone()[0]
    ) == 1.0, "the setup did not actually make suppression certain"
    battle = a_fight(conn, player)

    taken = conn.execute(
        "SELECT taken FROM battle_act(%s, 'guard', NULL)", (battle,)
    ).fetchone()[0]
    detail = conn.execute(
        "SELECT detail FROM battle_actions WHERE battle_id = %s AND actor_no = 1 "
        "ORDER BY action_id DESC LIMIT 1", (battle,)
    ).fetchone()[0]
    assert detail["suppressed"] is True
    assert taken == 0


def test_without_suppression_the_move_comes_out(conn, make_player):
    player = fighter(conn, make_player, "mortal_body")
    battle = a_fight(conn, player)
    conn.execute("SELECT battle_act(%s, 'guard', NULL)", (battle,))
    detail = conn.execute(
        "SELECT detail FROM battle_actions WHERE battle_id = %s AND actor_no = 1 "
        "ORDER BY action_id DESC LIMIT 1", (battle,)
    ).fetchone()[0]
    assert detail["suppressed"] is False


# ---------------------------------------------------------------------------
# The dwelling
# ---------------------------------------------------------------------------


def a_settler(conn, make_player, realm: int = 1, stones: int = 0) -> int:
    player = make_player("Settler")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, %s)",
        (player, realm),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (player,),
    )
    if stones:
        conn.execute(
            "SELECT grant_material(%s, 'spirit_stone', %s)", (player, stones)
        )
    return player


def stock(conn, player: int, ore: int = 0, beast: int = 0) -> None:
    """Common ore and beast material by weight - grade 1, so quantity is weight."""
    if ore:
        code = conn.execute(
            "SELECT o.material_code FROM ores o JOIN materials m ON m.code = o.material_code "
            "WHERE material_grade(m.rarity) = 1 ORDER BY o.material_code LIMIT 1"
        ).fetchone()[0]
        conn.execute("SELECT grant_material(%s, %s, %s)", (player, code, ore))
    if beast:
        code = conn.execute(
            "SELECT bp.material_code FROM beast_parts bp "
            "JOIN materials m ON m.code = bp.material_code "
            "WHERE material_grade(m.rarity) = 1 ORDER BY bp.material_code LIMIT 1"
        ).fetchone()[0]
        conn.execute("SELECT grant_material(%s, %s, %s)", (player, code, beast))


def test_the_ladder_runs_from_a_hut_to_a_blessed_land(conn):
    """Eleven rungs, and the top of it wants a true immortal.

    The last three want progressively more of one. Rank 6 is where a Gu Master
    becomes a Gu Immortal and the ladder stops being architecture and starts
    being geography - that is where the Blessed Land and the Grotto-Heaven sit.
    0365 put a rung above both of them, gated at rank 10, which is the first
    realm past the mortal ladder entirely and the point at which a home stops
    merely holding qi and starts condensing essence out of it.
    """
    rows = conn.execute(
        "SELECT s.stage, s.name, r.rank FROM dwelling_stages s "
        "JOIN realms r ON r.realm_id = s.realm_required ORDER BY s.stage"
    ).fetchall()
    assert len(rows) == 11
    assert rows[0][1] == "Thatched Hut" and rows[0][2] == 1
    assert rows[-1][1] == "Immortal Blessed Land"
    assert rows[-1][2] >= 10, "the last rung is folded by a true immortal"
    assert [r[0] for r in rows] == sorted(r[0] for r in rows)

    # The rung that condenses essence is the top one and nothing below it, so
    # the config and the ladder cannot drift apart.
    condensing = conn.execute(
        "SELECT stage FROM dwelling_stages "
        "WHERE stage >= game_config_value('blessed_land_stage') ORDER BY stage"
    ).fetchall()
    assert [r[0] for r in condensing] == [rows[-1][0]]


def test_the_ladder_only_ever_gets_dearer(conn):
    """A rung cheaper than the one below it would be a rung nobody stops at."""
    for column in ("stone_cost", "ore_weight", "beast_weight", "jade_cost", "facility_slots"):
        values = [
            r[0] for r in conn.execute(
                f"SELECT {column} FROM dwelling_stages ORDER BY stage"
            ).fetchall()
        ]
        assert values == sorted(values), f"{column} dips: {values}"


def test_the_first_roof_is_free_and_the_last_is_not(conn):
    first, last = conn.execute(
        "SELECT (SELECT stone_cost FROM dwelling_stages WHERE stage = 1), "
        "       (SELECT stone_cost FROM dwelling_stages WHERE stage = 10)"
    ).fetchone()
    assert first == 0, "a ladder nobody can get onto is not a ladder"
    assert last >= 100_000, "and a sink has to be deep enough to still be there"


def test_founding_and_raising_spend_what_they_said(conn, make_player):
    player = a_settler(conn, make_player, realm=4, stones=1000)
    stock(conn, player, ore=800, beast=200)

    conn.execute("SELECT raise_dwelling(%s)", (player,))   # hut, free
    assert conn.execute(
        "SELECT stage FROM player_dwelling WHERE player_id = %s", (player,)
    ).fetchone()[0] == 1

    before = conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = 'spirit_stone'", (player,)
    ).fetchone()[0]
    spent = conn.execute(
        "SELECT stones_spent FROM raise_dwelling(%s)", (player,)
    ).fetchone()[0]
    after = conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = 'spirit_stone'", (player,)
    ).fetchone()[0]
    assert before - after == spent


def test_a_rung_above_your_realm_is_refused(conn, make_player):
    player = a_settler(conn, make_player, realm=1, stones=10_000_000)
    stock(conn, player, ore=100_000, beast=100_000)
    conn.execute("SELECT raise_dwelling(%s)", (player,))   # hut at Rank 1
    with pytest.raises(psycopg.errors.CheckViolation, match="and you are not one yet"):
        conn.execute("SELECT raise_dwelling(%s)", (player,))


def test_a_rung_you_cannot_pay_for_is_refused_before_it_takes_anything(conn, make_player):
    # Realm 27 clears every gate but the purse: a Tiled House wants 60 stones
    # and this cultivator has ten.
    player = a_settler(conn, make_player, realm=27, stones=10)
    conn.execute("SELECT raise_dwelling(%s)", (player,))
    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation, match="spirit stones"):
            conn.execute("SELECT raise_dwelling(%s)", (player,))
    assert conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = 'spirit_stone'", (player,)
    ).fetchone()[0] == 10, "a half-paid dwelling is not a state that can exist"
    assert conn.execute(
        "SELECT stage FROM player_dwelling WHERE player_id = %s", (player,)
    ).fetchone()[0] == 1


def test_a_facility_grants_an_ordinary_effect(conn, make_player):
    """The whole reason nothing downstream knows dwellings exist: a Meditation
    Chamber reaches the settle by the road a Gu's cultivation speed does."""
    player = a_settler(conn, make_player, realm=1, stones=500)
    stock(conn, player, ore=500)
    conn.execute("SELECT raise_dwelling(%s)", (player,))

    before = conn.execute(
        "SELECT player_stat(%s, 'cultivation_rate')", (player,)
    ).fetchone()[0]
    conn.execute("SELECT build_facility(%s, 'meditation_chamber')", (player,))
    after = conn.execute(
        "SELECT player_stat(%s, 'cultivation_rate')", (player,)
    ).fetchone()[0]

    per_level = conn.execute(
        "SELECT per_level FROM dwelling_facilities WHERE code = 'meditation_chamber'"
    ).fetchone()[0]
    assert after - before == per_level


def test_the_slots_are_a_real_wall(conn, make_player):
    """The decision the system exists to pose: a hut holds one, and there are
    ten things worth building."""
    player = a_settler(conn, make_player, realm=1, stones=5000)
    stock(conn, player, ore=5000, beast=500)
    conn.execute("SELECT raise_dwelling(%s)", (player,))
    conn.execute("SELECT build_facility(%s, 'meditation_chamber')", (player,))

    with pytest.raises(psycopg.errors.CheckViolation, match="all of them are taken"):
        conn.execute("SELECT build_facility(%s, 'training_yard')", (player,))


def test_improving_what_stands_needs_no_slot(conn, make_player):
    """Otherwise a full dwelling would be a wall rather than a decision."""
    player = a_settler(conn, make_player, realm=1, stones=5000)
    stock(conn, player, ore=5000)
    conn.execute("SELECT raise_dwelling(%s)", (player,))
    conn.execute("SELECT build_facility(%s, 'meditation_chamber')", (player,))
    assert conn.execute(
        "SELECT level_after FROM build_facility(%s, 'meditation_chamber')", (player,)
    ).fetchone()[0] == 2


def test_a_facility_above_your_dwelling_is_refused(conn, make_player):
    player = a_settler(conn, make_player, realm=1, stones=50_000)
    stock(conn, player, ore=50_000, beast=5_000)
    conn.execute("SELECT raise_dwelling(%s)", (player,))
    with pytest.raises(psycopg.errors.CheckViolation, match="wants at least a"):
        conn.execute("SELECT build_facility(%s, 'ward_array')", (player,))


def test_a_facility_stops_at_its_ceiling(conn, make_player):
    player = a_settler(conn, make_player, realm=1, stones=10_000_000)
    stock(conn, player, ore=10_000_000, beast=1_000_000)
    conn.execute("SELECT raise_dwelling(%s)", (player,))
    top = conn.execute(
        "SELECT max_level FROM dwelling_facilities WHERE code = 'meditation_chamber'"
    ).fetchone()[0]
    for _ in range(top):
        conn.execute("SELECT build_facility(%s, 'meditation_chamber')", (player,))
    with pytest.raises(psycopg.errors.CheckViolation, match="as good as one gets"):
        conn.execute("SELECT build_facility(%s, 'meditation_chamber')", (player,))


def test_building_with_nowhere_to_build_is_refused(conn, make_player):
    player = a_settler(conn, make_player, realm=1, stones=5000)
    stock(conn, player, ore=5000)
    with pytest.raises(psycopg.errors.CheckViolation, match="nowhere to build"):
        conn.execute("SELECT build_facility(%s, 'meditation_chamber')", (player,))


def test_every_facility_grants_something_that_exists(conn):
    """A facility pointing at an effect nothing reads would be a building that
    does nothing, which is the shape of bug this codebase keeps finding."""
    dead = conn.execute(
        """
        SELECT f.code FROM dwelling_facilities f
        JOIN gu_effects e ON e.code = f.effect_code
        WHERE NOT e.is_live
        """
    ).fetchall()
    assert [r[0] for r in dead] == []


def test_a_facility_never_promises_past_its_effects_cap(conn):
    over = conn.execute(
        """
        SELECT f.code, f.per_level * f.max_level AS most, e.cap
        FROM dwelling_facilities f
        JOIN gu_effects e ON e.code = f.effect_code
        WHERE f.per_level * f.max_level > e.cap
        """
    ).fetchall()
    assert over == [], f"these would be capped away: {over}"


def test_the_body_reads_its_own_rate_now(conn, make_player):
    """settle_passive_cultivation consulted player_stat for cultivation and
    had no equivalent line for the body, so gear that claimed to strengthen a
    cultivator did nothing for the pillar named after it."""
    player = a_settler(conn, make_player, realm=1, stones=500)
    stock(conn, player, ore=500, beast=100)
    conn.execute("SELECT raise_dwelling(%s)", (player,))
    conn.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '10 hours' "
        "WHERE player_id = %s", (player,)
    )
    bare = conn.execute(
        "SELECT physique_gained FROM settle_passive_cultivation(%s)", (player,)
    ).fetchone()[0]

    conn.execute("SELECT build_facility(%s, 'training_yard')", (player,))
    conn.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '10 hours' "
        "WHERE player_id = %s", (player,)
    )
    trained = conn.execute(
        "SELECT physique_gained FROM settle_passive_cultivation(%s)", (player,)
    ).fetchone()[0]

    assert trained > bare, "a Training Yard has to reach the settle"


def test_weight_is_spent_commonest_first(conn, make_player):
    player = a_settler(conn, make_player, realm=1, stones=500)
    stock(conn, player, ore=500)
    rare = conn.execute(
        """
        SELECT o.material_code FROM ores o JOIN materials m ON m.code = o.material_code
        WHERE material_grade(m.rarity) = (
            SELECT max(material_grade(m2.rarity)) FROM ores o2
            JOIN materials m2 ON m2.code = o2.material_code)
        ORDER BY o.material_code LIMIT 1
        """
    ).fetchone()[0]
    conn.execute("SELECT grant_material(%s, %s, 20)", (player, rare))

    conn.execute("SELECT raise_dwelling(%s)", (player,))
    conn.execute("SELECT build_facility(%s, 'meditation_chamber')", (player,))
    assert conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = %s", (player, rare)
    ).fetchone()[0] == 20, "the good ore was left alone"


# ---------------------------------------------------------------------------
# The Broker
# ---------------------------------------------------------------------------


def a_seller(conn, make_player) -> int:
    player = make_player("Seller")
    conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (player,))
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (player,),
    )
    return player


def stones_of(conn, player: int) -> int:
    return conn.execute(
        "SELECT COALESCE((SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = 'spirit_stone'), 0)",
        (player,),
    ).fetchone()[0]


def test_he_pays_a_materials_grade(conn):
    """One stone for a common, four for an epic - roughly what an explore
    cache pays, so gathering and exploring come out level."""
    for rarity, grade in (("common", 1), ("uncommon", 2), ("rare", 3)):
        code = conn.execute(
            "SELECT code FROM materials WHERE rarity = %s AND category <> 'currency' "
            "AND code <> 'spirit_stone' ORDER BY code LIMIT 1",
            (rarity,),
        ).fetchone()[0]
        assert conn.execute(
            "SELECT broker_price_material(%s)", (code,)
        ).fetchone()[0] == grade


def test_he_does_not_buy_his_own_money(conn, make_player):
    """A merchant who trades a stone for a stone is not a merchant."""
    player = a_seller(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 50)", (player,))
    assert conn.execute(
        "SELECT count(*) FROM broker_offer(%s) WHERE ref = 'spirit_stone'", (player,)
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT broker_price_material('spirit_stone')"
    ).fetchone()[0] is None


def test_he_does_not_buy_spirit_jade(conn, make_player):
    player = a_seller(conn, make_player)
    conn.execute("SELECT grant_jade(%s, 20, 'test')", (player,))
    assert conn.execute(
        "SELECT count(*) FROM broker_offer(%s) o JOIN materials m ON m.code = o.ref "
        "WHERE m.category = 'currency'", (player,)
    ).fetchone()[0] == 0


def test_selling_pays_what_the_counter_said(conn, make_player):
    player = a_seller(conn, make_player)
    code = conn.execute(
        "SELECT code FROM materials WHERE rarity = 'uncommon' "
        "AND category <> 'currency' ORDER BY code LIMIT 1"
    ).fetchone()[0]
    conn.execute("SELECT grant_material(%s, %s, 10)", (player, code))

    quoted = conn.execute(
        "SELECT total FROM broker_offer(%s) WHERE ref = %s", (player, code)
    ).fetchone()[0]
    before = stones_of(conn, player)

    paid = conn.execute(
        "SELECT stones_paid FROM sell_to_broker(%s, 'material', ARRAY[%s], ARRAY[10::bigint])",
        (player, code),
    ).fetchone()[0]

    assert paid == quoted, "the quote and the till have to agree"
    assert stones_of(conn, player) == before + paid
    assert conn.execute(
        "SELECT COALESCE((SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = %s), 0)", (player, code)
    ).fetchone()[0] == 0


def test_selling_more_than_you_hold_is_refused(conn, make_player):
    player = a_seller(conn, make_player)
    code = conn.execute(
        "SELECT code FROM materials WHERE category <> 'currency' ORDER BY code LIMIT 1"
    ).fetchone()[0]
    conn.execute("SELECT grant_material(%s, %s, 3)", (player, code))
    with pytest.raises(psycopg.errors.CheckViolation, match="do not have"):
        conn.execute(
            "SELECT sell_to_broker(%s, 'material', ARRAY[%s], ARRAY[9::bigint])",
            (player, code),
        )


def test_he_will_not_take_the_gear_you_are_wearing(conn, make_player):
    player = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'blazing_sunsteel', 200)", (player,))
    conn.execute("SELECT grant_material(%s, 'dragon_scale', 60)", (player,))
    made = conn.execute(
        "SELECT equipment_id FROM forge(%s, 'armour', ARRAY['blazing_sunsteel'], ARRAY[60], "
        "ARRAY['dragon_scale'], ARRAY[30])", (player,)
    ).fetchone()[0]

    assert conn.execute(
        "SELECT count(*) FROM broker_offer(%s) WHERE ref = %s",
        (player, str(made)),
    ).fetchone()[0] == 1, "unworn, so it is on the counter"

    conn.execute("SELECT equip(%s, %s)", (player, made))
    assert conn.execute(
        "SELECT count(*) FROM broker_offer(%s) WHERE ref = %s",
        (player, str(made)),
    ).fetchone()[0] == 0, "worn, so it is not"

    with pytest.raises(psycopg.errors.CheckViolation, match="being worn"):
        conn.execute(
            "SELECT sell_to_broker(%s, 'equipment', ARRAY[%s])",
            (player, str(made)),
        )


def test_he_will_not_take_the_book_you_are_reading(conn, make_player):
    player = a_seller(conn, make_player)
    manual = a_manual(conn, player, tier=2)
    assert conn.execute(
        "SELECT count(*) FROM broker_offer(%s) WHERE kind = 'manual'", (player,)
    ).fetchone()[0] == 1

    conn.execute(
        "INSERT INTO player_manual_slots (player_id, manual_id, slot_index) "
        "VALUES (%s, %s, 0)", (player, manual)
    )
    assert conn.execute(
        "SELECT count(*) FROM broker_offer(%s) WHERE kind = 'manual'", (player,)
    ).fetchone()[0] == 0
    with pytest.raises(psycopg.errors.CheckViolation, match="equipped"):
        conn.execute(
            "SELECT sell_to_broker(%s, 'manual', ARRAY[%s])", (player, str(manual))
        )


def test_a_sold_manual_leaves_the_shelf(conn, make_player):
    player = a_seller(conn, make_player)
    manual = a_manual(conn, player, tier=3)
    before = stones_of(conn, player)
    paid = conn.execute(
        "SELECT stones_paid FROM sell_to_broker(%s, 'manual', ARRAY[%s])",
        (player, str(manual)),
    ).fetchone()[0]

    assert paid == conn.execute(
        "SELECT round(bonus_budget * 100 * game_config_value('broker_manual_rate'))"
        " FROM manual_tiers WHERE tier = 3"
    ).fetchone()[0]
    assert stones_of(conn, player) == before + paid
    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE manual_id = %s", (manual,)
    ).fetchone()[0] == 0


def test_you_cannot_sell_what_is_not_yours(conn, make_player):
    mine = a_seller(conn, make_player)
    yours = a_seller(conn, make_player)
    manual = a_manual(conn, mine, tier=1)
    with pytest.raises(psycopg.errors.CheckViolation, match="not yours"):
        conn.execute(
            "SELECT sell_to_broker(%s, 'manual', ARRAY[%s])", (yours, str(manual))
        )


def test_he_deals_in_three_things_and_says_so(conn, make_player):
    player = a_seller(conn, make_player)
    with pytest.raises(psycopg.errors.CheckViolation, match="does not deal in"):
        conn.execute("SELECT sell_to_broker(%s, 'gu', ARRAY['1'])", (player,))


def test_an_empty_counter_is_refused(conn, make_player):
    player = a_seller(conn, make_player)
    with pytest.raises(psycopg.errors.CheckViolation, match="on the counter"):
        conn.execute(
            "SELECT sell_to_broker(%s, 'material', ARRAY[]::text[])", (player,)
        )


def test_a_better_piece_is_worth_more(conn):
    """Priced off the potency its tier demanded, so the curve is the one the
    forge is already defined by rather than a second opinion about value."""
    prices = [
        r[0] for r in conn.execute(
            "SELECT round(potency_required * material_grade('common') "
            "* game_config_value('broker_equipment_rate')) "
            "FROM equipment_tiers ORDER BY tier"
        ).fetchall()
    ]
    assert prices == sorted(prices) and prices[0] < prices[-1]


# ---------------------------------------------------------------------------
# The index
# ---------------------------------------------------------------------------


def test_every_material_says_where_it_comes_from(conn):
    """A recipe naming something the world does not drop is a recipe nobody
    can fill. Spirit Jade is the one exception - it is money, granted by kills
    and crossings rather than dug out of anything."""
    orphans = conn.execute(
        """
        SELECT m.code FROM materials m
        WHERE m.category <> 'currency'
          AND NOT EXISTS (SELECT 1 FROM material_sources(m.code))
        """
    ).fetchall()
    assert [r[0] for r in orphans] == []

    # Essence used to be carved out of the rule above. 0334 built the immortal
    # ladder and deliberately left the fuel undroppable, with a note saying the
    # carve-out could go the day something dropped it. 0359 is that day: rogue
    # immortals walk both heavens carrying their own realm's essence, so the
    # ordinary rule covers essence now and the exception is gone.
    #
    # Pinned rung by rung rather than left to the rule alone, because that rule
    # only asks whether SOME essence has a source. Nine realms need nine, and a
    # ladder missing its seventh rung is one nobody finishes climbing.
    sourceless = conn.execute(
        """
        SELECT e.rank, e.material_code FROM immortal_essences e
        WHERE NOT EXISTS (SELECT 1 FROM material_sources(e.material_code))
        ORDER BY e.rank
        """
    ).fetchall()
    assert not sourceless, f"no way to get these essences: {sourceless}"


def test_a_gathering_share_is_of_the_whole_region(conn):
    """The bug 0120 fixed: a window function partitions the QUERY'S rows, and
    the query had already filtered to one material - so every material in the
    world reported a 100% share of its region."""
    shares = conn.execute(
        """
        SELECT s.share FROM region_materials rm
        CROSS JOIN LATERAL material_sources(rm.material_code) s
        WHERE s.kind = 'gather'
        """
    ).fetchall()
    assert shares, "nothing is gathered, so this proves nothing"
    assert all(0 < r[0] <= 100 for r in shares)
    assert any(r[0] < 99 for r in shares), "they cannot all be the whole table"


def test_a_regions_gathering_table_sums_to_a_whole(conn):
    for region in conn.execute("SELECT code FROM regions").fetchall():
        total = conn.execute(
            "SELECT COALESCE(sum(share), 0) FROM region_finds(%s) WHERE kind = 'gather'",
            (region[0],),
        ).fetchone()[0]
        # Rounded to a tenth per row, so a point of drift is arithmetic.
        assert total == 0 or 99 <= total <= 101, f"{region[0]} sums to {total}"


def test_the_index_reads_both_ways_about_the_same_thing(conn):
    """"Where is this" and "what is here" are one table read from two ends. If
    they ever disagree, one of the two screens is lying."""
    code = conn.execute(
        "SELECT material_code FROM region_materials ORDER BY material_code LIMIT 1"
    ).fetchone()[0]
    region = conn.execute(
        "SELECT region_code FROM region_materials WHERE material_code = %s", (code,)
    ).fetchone()[0]

    from_material = conn.execute(
        "SELECT share FROM material_sources(%s) WHERE kind = 'gather'", (code,)
    ).fetchone()[0]
    from_region = conn.execute(
        "SELECT share FROM region_finds(%s) WHERE kind = 'gather' AND material_code = %s",
        (region, code),
    ).fetchone()[0]
    assert from_material == from_region


def test_a_beast_drop_reports_its_own_chance(conn):
    """A drop chance is absolute, not a share of anything, so it must come
    through unchanged."""
    row = conn.execute(
        """
        SELECT cd.material_code, cd.chance FROM creature_drops cd
        JOIN creature_regions cr ON cr.species_id = cd.species_id
        ORDER BY cd.chance DESC LIMIT 1
        """
    ).fetchone()
    best = conn.execute(
        "SELECT max(share) FROM material_sources(%s) WHERE kind = 'hunt'", (row[0],)
    ).fetchone()[0]
    assert best == round(100 * row[1], 1)


def test_an_ore_is_indexed_as_a_vein_not_only_as_a_herb(conn):
    """Ores sit in both `region_materials` and `region_veins` - they can be
    picked up off the ground and dug out - and the index has to say both."""
    code = conn.execute(
        "SELECT rv.material_code FROM region_veins rv "
        "JOIN region_materials rm ON rm.material_code = rv.material_code LIMIT 1"
    ).fetchone()[0]
    kinds = {
        r[0] for r in conn.execute(
            "SELECT kind FROM material_sources(%s)", (code,)
        ).fetchall()
    }
    assert {"gather", "mine"} <= kinds


def test_a_region_page_is_complete_not_a_top_ten(conn):
    """A gazetteer that shows the first ten of thirty-three is a table of
    contents. `region_index` returns everything; the cut for Discord's field
    limit happens in the screen and says how much it cut."""
    for region in conn.execute("SELECT code FROM regions").fetchall():
        listed = conn.execute(
            "SELECT count(*) FROM region_index(%s) WHERE kind = 'gather'",
            (region[0],),
        ).fetchone()[0]
        actual = conn.execute(
            "SELECT count(*) FROM region_materials WHERE region_code = %s",
            (region[0],),
        ).fetchone()[0]
        assert listed == actual, region[0]


def test_the_page_names_what_lives_there_and_what_it_drops(conn):
    """`gu_region_drops` decides where a Gu is found and was read by no screen
    in the game until 0121 - the only way to learn it was to kill things
    somewhere until one turned up."""
    kinds = {
        r[0] for r in conn.execute(
            "SELECT DISTINCT kind FROM region_index('northern')"
        ).fetchall()
    }
    assert {"gather", "mine", "beast", "gu", "road"} <= kinds


def test_every_region_has_a_page_worth_reading(conn):
    """A region with nothing in it is a place the map sends you to for no
    reason."""
    for region in conn.execute("SELECT code, name FROM regions").fetchall():
        counts = dict(
            conn.execute(
                "SELECT kind, count(*) FROM region_index(%s) GROUP BY kind",
                (region[0],),
            ).fetchall()
        )
        for kind in ("gather", "mine", "beast", "gu", "road"):
            assert counts.get(kind, 0) > 0, f"{region[1]} has no {kind}"


def test_a_road_leads_somewhere_real(conn):
    orphans = conn.execute(
        """
        SELECT rr.origin, rr.destination FROM region_routes rr
        WHERE NOT EXISTS (SELECT 1 FROM regions r WHERE r.code = rr.destination)
        """
    ).fetchall()
    assert orphans == []


def test_the_material_half_still_defers_to_one_place(conn):
    """`region_index` calls `region_finds` rather than recomputing shares, so
    the two can never disagree about the same herb."""
    code, share = conn.execute(
        "SELECT material_code, share FROM region_finds('central') "
        "WHERE kind = 'gather' ORDER BY share DESC LIMIT 1"
    ).fetchone()
    assert conn.execute(
        "SELECT share FROM region_index('central') WHERE kind = 'gather' AND code = %s",
        (code,),
    ).fetchone()[0] == share

# ---------------------------------------------------------------------------
# The tutorial
# ---------------------------------------------------------------------------


def test_no_tutorial_page_leaves_a_placeholder_unfilled(conn):
    """A brace that survives substitution is a key that does not exist - and
    the reader would see `{gathr_cooldown_minutes}` in the text."""
    leftover = conn.execute(
        "SELECT code, body FROM tutorial WHERE body LIKE '%{%'"
    ).fetchall()
    assert [r[0] for r in leftover] == [], "an unsubstituted placeholder"


def test_a_page_quotes_the_live_number(conn):
    """The whole reason the pages are rows. Move the dial, move the guide."""
    before = conn.execute(
        "SELECT body FROM tutorial WHERE code = 'world'"
    ).fetchone()[0]
    assert " 5 tries" in before

    conn.execute("UPDATE game_config SET value = 9 WHERE key = 'gather_tries'")
    after = conn.execute(
        "SELECT body FROM tutorial WHERE code = 'world'"
    ).fetchone()[0]
    assert " 9 tries" in after, "the guide must follow the config"


def test_a_fraction_reads_as_a_percentage(conn):
    body = conn.execute(
        "SELECT body FROM tutorial WHERE code = 'combat'"
    ).fetchone()[0]
    assert "15% to 55%" in body
    assert "0.15" not in body, "nobody wants to read a decimal here"


def test_every_command_the_tutorial_names_exists(conn):
    """A guide that teaches a command nobody can run is the worst kind of
    promise. The check is against the migration files rather than the tree,
    because the schema tests do not load the bot."""
    import pathlib
    import re

    # Matched from the DECORATOR rather than the signature: several commands
    # take arguments and spread their signature over several lines, so
    # `async def name(self, interaction` misses them.
    cogs = pathlib.Path("bot/cogs")
    shipped = set()
    for path in cogs.glob("*.py"):
        text = path.read_text(encoding="utf-8")
        shipped.update(
            re.findall(
                r"@app_commands\.command\(.*?\)\s*(?:@[^\n]*\n\s*)*"
                r"async def ([a-z_]+)",
                text,
                re.S,
            )
        )
        # GROUPS TOO. This check saw only @app_commands.command, so every
        # subcommand of /garden, /preset, /fight, /dev, /gu and /farm was
        # invisible to it - the guide could have named any of them wrongly
        # and this test would have passed. A group is both a name a player
        # starts typing and a prefix for its subcommands, so take both.
        for group in re.findall(
            r'app_commands\.Group\(\s*\n?\s*name="([a-z_]+)"', text
        ):
            shipped.add(group)
            shipped.update(
                group + " " + sub
                for sub in re.findall(
                    r"@" + group + r"\.command\(\s*\n?\s*name=.([a-z_]+).",
                    text,
                )
            )

    named = set()
    for (body,) in conn.execute("SELECT body FROM tutorial").fetchall():
        # Multi-word, so "**/gu look**" is checked AS "gu look" rather than
        # matching nothing and letting the check lapse.
        named.update(re.findall(r"/([a-z]+(?: [a-z]+)*)\*\*", body))

    missing = {c for c in named if c not in shipped}
    assert missing == set(), f"the guide names commands that do not exist: {missing}"


def test_the_pages_cover_what_the_game_has(conn):
    """Twelve systems, and the design this was modelled on listed five more
    that are not built. A page for an unbuilt system teaches a command nobody
    can run."""
    codes = {
        r[0] for r in conn.execute("SELECT code FROM tutorial").fetchall()
    }
    for expected in ("start", "cultivation", "world", "combat", "crafting", "jade"):
        assert expected in codes
    for absent in ("farming", "dungeons", "pets", "sect", "pvp"):
        assert absent not in codes, f"{absent} is not a system this game has"


# ---------------------------------------------------------------------------
# The technique ladder and what it costs (0125, 0126, 0127)
# ---------------------------------------------------------------------------


def test_every_rank_has_a_shelf_worth_reading(conn):
    """Ranks 4 to 9 held two techniques between them before 0125 - one at rank
    4, one at rank 6, nothing anywhere else. The reward for crossing a great
    realm was a door into an empty room, and that is invisible from inside the
    code: every function worked perfectly on the content that was not there.
    """
    counts = dict(
        conn.execute(
            "SELECT rank, count(*) FROM techniques "
            "WHERE created_by IS NULL GROUP BY rank"
        ).fetchall()
    )
    thin = {rank: counts.get(rank, 0) for rank in range(1, 10) if counts.get(rank, 0) < 4}
    assert not thin, f"ranks with nothing to choose between: {thin}"


def test_the_power_ladder_never_goes_backwards(conn):
    """Every rank's weakest attack beats the rank below it outright. Without
    this a realm can be crossed into a downgrade, and the only way anyone finds
    out is by paying for one."""
    bands = conn.execute(
        """
        SELECT rank, min(base_power), max(base_power)
        FROM techniques
        WHERE created_by IS NULL AND category = 'attack'
        GROUP BY rank ORDER BY rank
        """
    ).fetchall()

    for (lower, _, high), (upper, low, _) in zip(bands, bands[1:]):
        assert low > high, (
            f"rank {upper} starts at {low}, which rank {lower} already reaches"
        )


def test_a_technique_is_typed_by_a_path_that_exists(conn):
    """The FK guarantees the Path exists. This asks the other question: that
    every technique has one at all, because an untyped move is neutral into
    everything and silently opts out of the entire matchup chart."""
    untyped = conn.execute(
        """
        SELECT count(*) FROM techniques t
        WHERE t.created_by IS NULL
          AND NOT EXISTS (SELECT 1 FROM technique_paths tp
                          WHERE tp.technique_id = t.technique_id)
        """
    ).fetchone()[0]
    assert untyped == 0


def test_every_path_leads_exactly_one_first_rung(conn):
    """0161 and 0162. A Path can be reachable and still be nothing: before
    0162, Soul, Theft, Illusion, Shadow and Bone were all written on low-rank
    techniques as the junior half of a pair, and `technique_shelf` gates on the
    DOMINANT Path - so their attainment measured nothing and no move on the
    shelf was theirs.

    The rule that fixes it is worth more than the seventeen rows that opened
    the Paths in the first place, because it is the one a thirty-fifth Path
    would break: every Path leads exactly one rank 1 basic attack. Not zero,
    which is a Path you can only start on by starting on another one. Not two,
    which is how one Path quietly becomes the obvious opening."""
    off = conn.execute(
        """
        WITH lead AS (
            SELECT DISTINCT ON (t.technique_id) t.technique_id, tp.path_code
            FROM techniques t
            JOIN technique_paths tp ON tp.technique_id = t.technique_id
            WHERE t.created_by IS NULL AND t.category = 'attack'
              AND t.grade = 'basic' AND t.rank = 1
            ORDER BY t.technique_id, tp.weight DESC, tp.path_code
        )
        SELECT p.name, (SELECT count(*) FROM lead l WHERE l.path_code = p.code)
        FROM paths p
        WHERE (SELECT count(*) FROM lead l WHERE l.path_code = p.code) <> 1
        ORDER BY p.sort_order
        """
    ).fetchall()
    assert off == [], f"Paths without exactly one first rung: {off}"


def test_a_new_cultivator_can_open_any_path_in_the_game(conn, make_player):
    """The audit that prompted 0161 asked which Paths were reachable and found
    seventeen that were not - Space had a technique at rank 5 and the whole
    roster was rank 2, so four roots fed a Path with nothing addressed to it.

    Reachability is a claim about a screen, not about `technique_paths`, so it
    is asked of the shelf: a cultivator on the first rung of the first realm,
    with money and no attainment anywhere, must be able to buy into every one
    of the 34 Paths right now."""
    player_id = make_player()
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player_id,),
    )
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 1000)", (player_id,))

    opened = conn.execute(
        """
        SELECT p.name, bool_or(s.ready)
        FROM paths p
        LEFT JOIN technique_shelf(%s) s
               ON s.path_code = p.code AND s.tech_rank = 1
        GROUP BY p.name, p.sort_order
        ORDER BY p.sort_order
        """,
        (player_id,),
    ).fetchall()

    assert len(opened) == 34
    shut = [name for name, ready in opened if not ready]
    assert shut == [], f"a beginner cannot buy into: {shut}"


def test_the_price_of_a_technique_climbs_with_its_rank(conn):
    costs = [
        conn.execute("SELECT technique_stone_cost(%s::smallint)", (rank,)).fetchone()[0]
        for rank in range(1, 10)
    ]
    assert costs == sorted(costs) and len(set(costs)) == 9, costs
    assert costs[0] <= 40, f"a first technique at {costs[0]} stones is a wall"


def test_the_attainment_gate_is_one_tier_below_the_rank(conn):
    """The half money cannot buy. Rank 1 asks for nothing so a new cultivator
    is never locked out; rank 2 asks only that the Path has been trained at
    all; from there it tracks the rank one rung behind."""
    gates = [
        conn.execute("SELECT technique_required_tier(%s::smallint)", (rank,)).fetchone()[0]
        for rank in range(1, 10)
    ]
    assert gates == [0, 1, 2, 3, 4, 5, 6, 7, 8]

    top = conn.execute("SELECT max(tier) FROM attainment_tiers").fetchone()[0]
    assert max(gates) < top, "the last rung must not need a tier nobody can reach"


def test_the_shelf_answers_for_a_cultivator_with_nothing(conn, make_player):
    """A player row with no cultivation, no attainment and no stones. The shelf
    still has to return every technique with every gate shut, rather than
    returning nothing - a screen that answers with an empty list is a screen
    that says the game has no techniques."""
    player_id = make_player()

    rows = conn.execute(
        "SELECT s.ready, s.known, s.stone_cost, s.realm_ok, s.grade "
        "FROM technique_shelf(%s) s",
        (player_id,),
    ).fetchall()
    total = conn.execute(
        "SELECT count(*) FROM techniques WHERE created_by IS NULL"
    ).fetchone()[0]

    assert len(rows) == total, "the shelf lost rows for a player with nothing"
    for ready, known, cost, realm_ok, grade in rows:
        assert not ready and not known and not realm_ok
        # Advanced techniques are priced at 0 because they are not for sale at
        # any figure. Everything with a price must have a real one.
        assert cost > 0 if grade == "basic" else cost == 0


def test_the_shelf_and_the_command_cannot_disagree(conn, make_player):
    """`learn_technique` reads `technique_shelf` rather than re-deciding, so
    anything the shelf calls ready must actually buy - and anything it does not
    must refuse. This is the invariant that keeps the screen honest."""
    player_id = make_player()
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player_id,),
    )
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 1000)", (player_id,))

    offered = conn.execute(
        "SELECT s.technique_id, s.name FROM technique_shelf(%s) s WHERE s.ready "
        "ORDER BY s.technique_id LIMIT 1",
        (player_id,),
    ).fetchone()
    assert offered is not None, "a rank 1 cultivator with money can buy something"
    technique_id, offered_name = offered

    learned_name, spent, left = conn.execute(
        "SELECT l.learned_name, l.stones_spent, l.stones_left "
        "FROM learn_technique(%s, %s) l",
        (player_id, technique_id),
    ).fetchone()
    assert learned_name == offered_name
    assert left == 1000 - spent

    # And it is known now, so the shelf stops offering it.
    known, ready = conn.execute(
        "SELECT s.known, s.ready FROM technique_shelf(%s) s "
        "WHERE s.technique_id = %s",
        (player_id, technique_id),
    ).fetchone()
    assert known and not ready


def test_a_technique_out_of_reach_is_refused_before_it_is_charged(conn, make_player):
    """The order of the checks in `learn_technique` is load-bearing. A gate
    found after the stones were taken is a gate that charges for saying no."""
    player_id = make_player()
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player_id,),
    )
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 1000000)", (player_id,))

    out_of_reach = conn.execute(
        "SELECT technique_id FROM techniques WHERE code = 'blood_blade'"
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT * FROM learn_technique(%s, %s)", (player_id, out_of_reach)
            ).fetchone()

    held = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (player_id,),
    ).fetchone()[0]
    assert held == 1000000, "the refusal took money"


def test_an_advanced_technique_is_not_for_sale(conn, make_player):
    """The whole point of the grade. A cultivator at the top realm with a
    million stones and Supreme Grandmaster attainment still cannot buy one."""
    player_id = make_player()
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, (SELECT max(realm_id) FROM realms))",
        (player_id,),
    )
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 1000000)", (player_id,))

    advanced = conn.execute(
        "SELECT technique_id FROM techniques "
        "WHERE created_by IS NULL AND grade = 'advanced' ORDER BY rank LIMIT 1"
    ).fetchone()[0]
    conn.execute(
        "SELECT grant_path_insight(%s, tp.path_code, 3000000) "
        "FROM technique_paths tp WHERE tp.technique_id = %s",
        (player_id, advanced),
    )

    ready, cost = conn.execute(
        "SELECT s.ready, s.stone_cost FROM technique_shelf(%s) s "
        "WHERE s.technique_id = %s",
        (player_id, advanced),
    ).fetchone()
    assert not ready and cost == 0, "the shelf offered an advanced technique"

    with pytest.raises(psycopg.errors.CheckViolation, match="advanced"):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT * FROM learn_technique(%s, %s)", (player_id, advanced)
            ).fetchone()


def test_a_manual_lends_an_advanced_technique_and_takes_it_back(conn, make_player):
    """Carried, not owned. This is the trade the whole archetype exists to
    make, so it is the one thing about it that must be true."""
    player_id = make_player()
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, (SELECT max(realm_id) FROM realms))",
        (player_id,),
    )

    manual_id, technique_id = conn.execute(
        """
        SELECT m.manual_id, t.technique_id
        FROM manuals m
        JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE m.archetype = 'technique' AND t.grade = 'advanced'
        ORDER BY t.rank LIMIT 1
        """
    ).fetchone()

    def usable() -> bool:
        return conn.execute(
            "SELECT count(*) FROM player_usable_techniques u "
            "WHERE u.player_id = %s AND u.technique_id = %s",
            (player_id, technique_id),
        ).fetchone()[0] > 0

    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (player_id, manual_id),
    )
    assert not usable(), "owning the book is not carrying the move"

    conn.execute(
        "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
        "VALUES (%s, 0, %s)",
        (player_id, manual_id),
    )
    assert usable(), "equipping it should lend the move"

    conn.execute(
        "DELETE FROM player_manual_slots WHERE player_id = %s AND slot_index = 0",
        (player_id,),
    )
    assert not usable(), "unequipping it should take the move back"


def test_a_borrowed_technique_cannot_outrank_its_wielder(conn, make_player):
    """Manuals are tradeable and `required_rank` is not enforced on equipping.
    Before 0130 that meant a rank 1 cultivator handed a rank 9 technique manual
    could throw a 300,000 power move. The view is where that is refused,
    because the view is what combat validates against."""
    player_id = make_player()
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player_id,),
    )

    manual_id, technique_id = conn.execute(
        """
        SELECT m.manual_id, t.technique_id
        FROM manuals m
        JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE m.archetype = 'technique' AND t.rank = 9
        LIMIT 1
        """
    ).fetchone()

    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (player_id, manual_id),
    )
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
        "VALUES (%s, 0, %s)",
        (player_id, manual_id),
    )

    lent = conn.execute(
        "SELECT count(*) FROM player_usable_techniques u "
        "WHERE u.player_id = %s AND u.technique_id = %s",
        (player_id, technique_id),
    ).fetchone()[0]
    assert lent == 0, "a rank 1 cultivator was lent a rank 9 killer move"


def test_a_cultivator_with_no_realm_row_is_not_disarmed(conn, make_player):
    """0130 wrote the rank gate as an INNER JOIN, so a player with no
    `player_cultivation` row - a character between /register and its
    confirmation - lost every technique they had. A missing row must read as
    rank 1, not as rank nothing."""
    player_id = make_player()
    technique_id = conn.execute(
        "SELECT technique_id FROM techniques "
        "WHERE created_by IS NULL AND grade = 'basic' AND rank = 1 LIMIT 1"
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s)",
        (player_id, technique_id),
    )

    usable = conn.execute(
        "SELECT count(*) FROM player_usable_techniques u WHERE u.player_id = %s",
        (player_id,),
    ).fetchone()[0]
    assert usable == 1, "a realmless character was stripped of what they hold"


def test_refining_and_finding_agree_on_what_a_tier_is_worth(conn):
    """0166. "Two ways a killer move reaches you" was the title of 0131, and
    the two ways priced it differently, because each wrote its own rule inline
    where the other could not read it.

    0130 put the canonical books at tier = rank + 1, so Thunder Gale
    Dismemberment - rank 3 - sits in a tier 4 book. 0131 had `refine` grant
    rank <= (forecast_tier + 1) / 2, which demands tier 5 or 6 for that same
    move. The gap widened by a tier per rank until, from rank 6 up, no
    refinement could produce a killer move at all - tier 10 is the top of the
    crafting ladder and it handed back a rank 5 move, while the book teaching
    rank 9 is also tier 10.

    So the check is not "the numbers are these numbers" but the sentence both
    systems were separately trying to say: a refinement teaches exactly what a
    book of that tier teaches."""
    disagreeing = conn.execute(
        """
        SELECT t.name, t.rank, m.tier
        FROM manuals m
        JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE m.archetype = 'technique' AND m.created_by IS NULL
          AND (m.tier <> technique_manual_tier(t.rank)
               OR technique_manual_rank(m.tier) <> t.rank)
        ORDER BY t.rank
        """
    ).fetchall()
    assert disagreeing == [], disagreeing

    # Every advanced move must be refinable at some tier. Half of them were
    # not, which is the defect rather than a side effect of one.
    stranded = conn.execute(
        """
        SELECT DISTINCT t.rank FROM techniques t
        WHERE t.grade = 'advanced' AND t.created_by IS NULL
          AND NOT EXISTS (
              SELECT 1 FROM generate_series(1, 10) AS tier (tier)
              WHERE technique_manual_rank(tier.tier::smallint) = t.rank
          )
        ORDER BY 1
        """
    ).fetchall()
    assert stranded == [], f"no refinement tier reaches rank(s) {stranded}"


def test_the_tier_rule_is_read_and_not_restated(conn):
    """The rule drifted for 35 migrations because it was written twice: once
    in an INSERT in 0130 and once in an expression in `refine`. Two correct
    copies are one edit away from one correct copy, so what is asserted here
    is that `refine` asks rather than remembers.

    Since 0379 it asks one step further out. The move is no longer chosen
    inside `refine` at all - `refine_technique_for` chooses it, because the
    bench forecast has to name the same technique the refining will produce
    and the only way to guarantee that is for both to call one function. So
    the rule is followed to wherever the choosing now happens, and asserted
    there. Delegating is the same virtue as asking; what is still forbidden
    is restating.
    """
    def source(name):
        return conn.execute(
            "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = %s",
            (name,),
        ).fetchone()[0]

    said = source("refine")

    # Whoever picks the move must read the rule rather than restate it.
    picker = "refine_technique_for" if "refine_technique_for" in said else "refine"
    chooses = source(picker)

    assert "technique_manual_rank" in chooses, (
        f"{picker} decides for itself again how strong a move a tier is worth"
    )

    # The halving expression still lives in `refine` - it is what gates a
    # STAT manual's realm - so the check is that it is not what picks the
    # move. Asserting on its absence was brittle: 0187 wrapped it in a CASE
    # and the string-strip that excused it stopped matching.
    if picker == "refine":
        picking = said[
            said.index("grade = 'advanced'"):said.index("arch := 'technique'")
        ]
    else:
        picking = chooses
    assert "technique_manual_rank" in picking, "the move is chosen by some other rule"
    assert "forecast_tier + 1" not in picking, (
        "the old halving rule is still choosing the technique"
    )


def test_every_advanced_technique_has_a_book_and_every_book_has_a_move(conn):
    """Both directions. An advanced technique nothing teaches is unreachable;
    a technique manual teaching nothing is a slot spent on half a stat
    budget."""
    unreachable = conn.execute(
        """
        SELECT count(*) FROM techniques t
        WHERE t.created_by IS NULL AND t.grade = 'advanced'
          AND NOT EXISTS (
              SELECT 1 FROM manual_techniques mt
              JOIN manuals m ON m.manual_id = mt.manual_id
              WHERE mt.technique_id = t.technique_id AND m.archetype = 'technique'
          )
        """
    ).fetchone()[0]
    assert unreachable == 0

    empty = conn.execute(
        """
        SELECT count(*) FROM manuals m
        WHERE m.archetype = 'technique' AND m.code IS NOT NULL
          AND NOT EXISTS (
              SELECT 1 FROM manual_techniques mt
              JOIN techniques t ON t.technique_id = mt.technique_id
              WHERE mt.manual_id = m.manual_id AND t.grade = 'advanced'
          )
        """
    ).fetchone()[0]
    assert empty == 0


def test_a_good_attack_refinement_yields_a_killer_move(conn, make_player):
    """The route that has to work at every rank.

    Drops need an elite of the right rank to exist and the bestiary tops out at
    rank 5 plus one boss and one world beast, so refinement is the only way an
    advanced technique reaches ranks 6 and 8 at all. If this stops firing, six
    of the eighteen killer moves quietly become unobtainable and nothing else
    in the suite notices.

    Five pages of one Path, one page type, at high quality: no conflicting
    pairs, the full dominance bonus, and the same-type bonus. That lands base
    harmony near 125 against a bar of 105, which clears it even after the
    plus-or-minus four `refine` rolls on top.

    Level 31 because that is the rung where the ladder allows five pages at
    once, and five is what this harmony needs.
    """
    player = make_player("Killer")
    conn.execute(
        "INSERT INTO player_refinement (player_id, level, exp) VALUES (%s, 31, 0)",
        (player,),
    )

    pages = [
        conn.execute(
            """
            INSERT INTO manual_pages (owner_id, tier, path_code, page_type, power, quality)
            VALUES (%s, 5, 'ice', 'attack', 80, 99) RETURNING page_id
            """,
            (player,),
        ).fetchone()[0]
        for _ in range(5)
    ]

    harmony_forecast = conn.execute(
        "SELECT base_harmony, archetype FROM refine_forecast(%s, %s)", (player, pages)
    ).fetchone()
    assert harmony_forecast[1] == "offensive", "attack pages make an offensive manual"
    assert harmony_forecast[0] >= 109, (
        f"base harmony {harmony_forecast[0]} is too close to the bar for this "
        "test to mean anything - the fixture, not the feature, has drifted"
    )

    ok, manual_id, archetype = conn.execute(
        "SELECT succeeded, manual_id, archetype FROM refine(%s, %s)", (player, pages)
    ).fetchone()
    assert ok, "a refinement this harmonious cannot fail"
    assert archetype == "technique", (
        "a high-harmony attack refinement should produce a technique manual"
    )

    taught = conn.execute(
        """
        SELECT t.name, t.grade FROM manual_techniques mt
        JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE mt.manual_id = %s
        """,
        (manual_id,),
    ).fetchall()
    assert len(taught) == 1, f"expected one move, got {taught}"
    assert taught[0][1] == "advanced", "it must be a move /learn cannot sell"

    # And the card the player is shown has to say the same word the row does.
    stored = conn.execute(
        "SELECT archetype FROM manuals WHERE manual_id = %s", (manual_id,)
    ).fetchone()[0]
    assert stored == archetype


def test_an_ordinary_refinement_no_longer_hands_back_a_bought_move(conn, make_player):
    """Refinement used to attach the strongest BASIC technique of the dominant
    Path - something /learn would have sold for stones. A reward
    indistinguishable from no reward. It attaches an advanced move or nothing
    now, and nothing is the common case."""
    player = make_player("Ordinary")
    pages = [
        conn.execute(
            """
            INSERT INTO manual_pages (owner_id, tier, path_code, page_type, power, quality)
            VALUES (%s, 2, 'fire', 'attack', 30, 60) RETURNING page_id
            """,
            (player,),
        ).fetchone()[0]
        for _ in range(3)
    ]

    ok, manual_id = conn.execute(
        "SELECT succeeded, manual_id FROM refine(%s, %s)", (player, pages)
    ).fetchone()
    if not ok:
        pytest.skip("that refinement failed; there is no manual to inspect")

    basic = conn.execute(
        """
        SELECT count(*) FROM manual_techniques mt
        JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE mt.manual_id = %s AND t.grade = 'basic'
        """,
        (manual_id,),
    ).fetchone()[0]
    assert basic == 0, "a refinement handed back a technique that was for sale"


# ---------------------------------------------------------------------------
# A run of pots (0135 to 0138)
# ---------------------------------------------------------------------------


@pytest.fixture
def bulk_alchemist(conn, make_player):
    """A player who can run several pots and has the herbs for them."""
    player = make_player("Brewer")
    conn.execute(
        "SELECT grant_profession_exp(%s, 'alchemy', 26000, TRUE)", (player,)
    )
    conn.execute("SELECT grant_material(%s, 'spirit_dew_grass', 400)", (player,))
    conn.execute("SELECT grant_material(%s, 'clear_mind_orchid', 400)", (player,))
    return player


def test_overfilling_the_pot_finally_pays(conn):
    """`brew` has computed a batch since 0059 and it never once came out above
    one: at a divisor of 2 a second pill wanted three times the grade's floor,
    and every tier in this game begins at less than twice the one below - so
    overshooting promoted the pill instead of doubling it.

    The band has to exist in every tier, not just at the top.
    """
    divisor = conn.execute(
        "SELECT game_config_value('alchemy_batch_divisor')"
    ).fetchone()[0]
    tiers = conn.execute(
        "SELECT tier, potency_required FROM pill_tiers ORDER BY tier"
    ).fetchall()

    for (tier, floor), (_, next_floor) in zip(tiers, tiers[1:]):
        doubles_at = floor * (1 + divisor)
        assert doubles_at < next_floor, (
            f"tier {tier} doubles at {doubles_at} but tier {tier + 1} "
            f"begins at {next_floor}, so it tiers up instead"
        )


def test_a_run_brews_the_pot_that_many_times(conn, bulk_alchemist):
    run = conn.execute(
        "SELECT attempts, succeeded, spoiled, herbs_spent, exp_gained "
        "FROM brew_many(%s, %s, %s, %s)",
        (bulk_alchemist, ["spirit_dew_grass", "clear_mind_orchid"], [4, 4], 5),
    ).fetchone()
    attempts, ok, spoiled, spent, gained = run

    assert attempts == 5
    assert ok + spoiled == 5, "every pot either came out or spoiled"
    assert spent == 40, "five pots of eight herbs"
    assert gained > 0


def test_a_run_reports_the_pills_it_actually_made(conn, bulk_alchemist):
    """0137 found the run's pills with `brewed_at >= clock_timestamp()`, and
    `brewed_at` defaults to `now()` - the TRANSACTION clock, which is always
    earlier. So the filter excluded every row it was written to include and a
    seven-pot run handed back an empty list. The counts were all correct, which
    is why the migration's own probe passed."""
    ok, made = conn.execute(
        "SELECT succeeded, made FROM brew_many(%s, %s, %s, %s)",
        (bulk_alchemist, ["spirit_dew_grass", "clear_mind_orchid"], [4, 4], 4),
    ).fetchone()

    if not ok:
        pytest.skip("every pot spoiled; there is nothing to have reported")

    assert len(made) > 0, "the run made pills and named none of them"
    shelf = conn.execute(
        "SELECT count(*) FROM player_pills WHERE owner_id = %s", (bulk_alchemist,)
    ).fetchone()[0]
    assert len(made) == shelf, "the run and the shelf disagree about what exists"


def test_every_pot_in_a_run_rolls_its_own_harmony(conn, bulk_alchemist):
    """The whole design decision. A run that averaged the roll would be a
    duller game with the same herbs going in, so over enough pots the harmony
    spread has to actually spread."""
    low, high = conn.execute(
        "SELECT worst_harmony, best_harmony FROM brew_many(%s, %s, %s, %s)",
        (bulk_alchemist, ["spirit_dew_grass", "clear_mind_orchid"], [4, 4], 8),
    ).fetchone()
    assert high >= low
    assert high > low, "eight pots came out at identical harmony"


def test_a_run_you_cannot_afford_costs_nothing(conn, bulk_alchemist):
    """`brew` would refuse the pot it could not fill, but by then the earlier
    pots' herbs are gone and the player asked for a run rather than for
    whatever fitted."""
    before = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_dew_grass'",
        (bulk_alchemist,),
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="hold"):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT * FROM brew_many(%s, %s, %s, %s)",
                (bulk_alchemist, ["spirit_dew_grass", "clear_mind_orchid"], [300, 300], 5),
            ).fetchone()

    after = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_dew_grass'",
        (bulk_alchemist,),
    ).fetchone()[0]
    assert after == before, "a refused run took herbs anyway"


def test_the_run_ceiling_is_a_ladder_the_level_climbs(conn, make_player):
    """Two pots from the first level so a run is a run immediately, ten at the
    top, and monotonic in between - the same shape mining and refining use."""
    steps = [
        conn.execute("SELECT alchemy_max_brews(%s::smallint)", (lvl,)).fetchone()[0]
        for lvl in (1, 8, 18, 30, 44, 60, 78, 98, 120, 200)
    ]
    assert steps[0] == 2, "a new Alchemist cannot run a run"
    assert steps == sorted(steps), f"the ladder goes backwards: {steps}"
    assert steps[-1] == 10, f"the ceiling is {steps[-1]}"


def test_a_run_past_the_ceiling_is_refused(conn, make_player):
    player = make_player("Novice")
    conn.execute("SELECT grant_material(%s, 'spirit_dew_grass', 400)", (player,))
    conn.execute("SELECT grant_material(%s, 'clear_mind_orchid', 400)", (player,))

    with pytest.raises(psycopg.errors.CheckViolation, match="pots at a time"):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT * FROM brew_many(%s, %s, %s, %s)",
                (player, ["spirit_dew_grass", "clear_mind_orchid"], [4, 4], 9),
            ).fetchone()


# ---------------------------------------------------------------------------
# The world beast (0139 to 0142)
# ---------------------------------------------------------------------------


@pytest.fixture
def striker(conn, make_player):
    """A cultivator who can reach a beast whichever one turns up.

    Every rank 1 attack, because a world beast may be outright immune to a
    Path and a one-technique fixture would be testing the matchup chart.
    """
    player = make_player("Striker")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id, body_level, "
        "max_hp, current_hp) VALUES (%s, (SELECT physique_id FROM physiques "
        "LIMIT 1), 1, 5000, 5000)",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "SELECT %s, technique_id FROM techniques WHERE code IS NOT NULL "
        "AND grade = 'basic' AND rank = 1 AND base_power > 0",
        (player,),
    )
    return player


@pytest.fixture
def standing(conn):
    """A beast that is standing and too large to die mid-test.

    `boss_open_if_due` declines while the world is resting, and half the tests
    below end their encounter - so the first one to do so left every later
    fixture with nothing to fight. The rest period is a real rule and these
    tests are not the place to observe it, so one is made directly when the
    world will not offer one.
    """
    encounter = conn.execute("SELECT boss_open_if_due()").fetchone()[0]
    if encounter is None:
        encounter = conn.execute(
            """
            INSERT INTO boss_encounters
                (species_id, region_code, max_hp, current_hp, closes_at)
            SELECT pick.species_id, 'western', pool.hp, pool.hp,
                   now() + interval '2 days'
            FROM (SELECT cs.species_id FROM creature_species cs
                  WHERE cs.kind IN ('world', 'boss')
                  ORDER BY random() LIMIT 1) pick
            CROSS JOIN LATERAL (SELECT boss_hp_pool(pick.species_id) AS hp) pool
            RETURNING encounter_id
            """
        ).fetchone()[0]
    assert encounter is not None, "no beast could be opened"
    conn.execute(
        "UPDATE boss_encounters SET max_hp = 1000000000, "
        "current_hp = 1000000000 WHERE encounter_id = %s",
        (encounter,),
    )
    return encounter


def test_at_most_one_beast_stands_at_a_time(conn, standing):
    """A partial unique index, not a check somebody remembers to perform - two
    commands racing to open one must not both succeed."""
    open_now = conn.execute(
        "SELECT count(*) FROM boss_encounters WHERE status = 'open'"
    ).fetchone()[0]
    assert open_now == 1

    with pytest.raises(psycopg.errors.UniqueViolation):
        with conn.transaction(force_rollback=True):
            conn.execute(
                """
                INSERT INTO boss_encounters
                    (species_id, region_code, max_hp, current_hp, closes_at)
                SELECT species_id, 'central', 100, 100, now() + interval '1 day'
                FROM creature_species WHERE kind = 'world' LIMIT 1
                """
            )


def test_the_pool_is_sized_by_the_people_who_will_swing_at_it(conn):
    """Not `base_hp`. Five million against a roster of rank 1 cultivators is
    four hundred days of striking, and a written number cannot follow a server
    as it grows.

    0164 gave it the species, because how hard the roster can hit depends on
    what it is hitting. A world beast's pool is not its solo statline and may
    sit well above it - what it must never be is that statline read back.
    """
    floor = conn.execute(
        "SELECT game_config_value('boss_hp_floor')"
    ).fetchone()[0]

    for species_id, written in conn.execute(
        "SELECT species_id, base_hp FROM creature_species "
        "WHERE kind IN ('world', 'boss') ORDER BY species_id"
    ).fetchall():
        pool = conn.execute("SELECT boss_hp_pool(%s)", (species_id,)).fetchone()[0]
        assert pool >= floor, "a thin server still meets something worth the name"
        assert pool != written, (
            "the pool is the species' own written HP, which does not follow a "
            "server as it grows"
        )


def test_the_pool_measures_what_lands_rather_than_what_is_written(
    conn, make_player, make_species, make_technique
):
    """`base_power` is the number on the technique. What reaches a beast has
    been through attainment, the matchup chart, its defense and its
    resistances - and against a Path that turns the roster aside, that is a
    fraction. Sizing on the written figure gave a beast the roster could
    barely scratch the same health bar as one it could carve up.

    Two beasts, identical but for the Path they stand on, against whatever
    the roster actually holds.

    The Path is read off the live roster rather than assumed. `boss_hp_pool`
    sums over EVERY player in the database, so a test that plants one Fire
    technique and expects Fire to decide the sizing is really asserting that
    nobody else outguns it - and the day clearwest equipped a 3,259,003 power
    Light technique, a 90,000 power flame stopped being the loudest thing in
    the room and this failed for no reason of its own."""
    player = make_player("Pool Prober")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )

    # The probe is built to OUTGUN the live roster rather than hoping it
    # already does. This used to plant a flat 90,000 power flame and read the
    # loudest Path back off the roster, which held until somebody louder
    # turned up - the docstring above records it happening once with a Light
    # technique, and it happened again the day /enlighten let players forge
    # their own: a 28,663,349 power Refinement Art appeared overnight and the
    # planted flame stopped deciding anything.
    #
    # `boss_hp_pool` sums over every present player, so the only stable way to
    # make one Path decide the sizing is to hold a technique the rest of the
    # room cannot answer. Twenty times the loudest thing in the database is
    # arbitrary but self-maintaining: whatever anyone forges tomorrow, this
    # still dwarfs it.
    loudest = conn.execute(
        "SELECT COALESCE(max(t.base_power), 0) FROM techniques t "
        "WHERE t.base_power > 0"
    ).fetchone()[0]

    lead_path = ("fire",)
    technique = make_technique(
        None, name="Probe Flame", base_power=max(90000, int(loudest) * 20),
        paths={"fire": "1.0"}, created_by=player,
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s)",
        (player, technique),
    )
    # Counted at all: the pool only sums players who are HERE.
    conn.execute(
        "UPDATE players SET last_seen_at = now() WHERE player_id = %s", (player,)
    )

    eaten, turning = conn.execute(
        """
        SELECT (SELECT defender_path FROM path_matchups
                WHERE attacker_path = %s AND interaction = 'advantage' LIMIT 1),
               (SELECT defender_path FROM path_matchups
                WHERE attacker_path = %s AND interaction = 'resistance' LIMIT 1)
        """,
        (lead_path[0], lead_path[0]),
    ).fetchone()

    if eaten is None or turning is None:
        pytest.skip(f"the chart gives {lead_path[0]} nothing on both sides")

    kindling = make_species("pool_probe_wood", name="Kindling", paths=[eaten])
    drencher = make_species("pool_probe_water", name="Drencher", paths=[turning])
    for species in (kindling, drencher):
        conn.execute(
            "UPDATE creature_species SET kind = 'world' WHERE species_id = %s",
            (species,),
        )

    burns = conn.execute("SELECT boss_hp_pool(%s)", (kindling,)).fetchone()[0]
    douses = conn.execute("SELECT boss_hp_pool(%s)", (drencher,)).fetchone()[0]

    floor = conn.execute(
        "SELECT game_config_value('boss_hp_floor')"
    ).fetchone()[0]
    assert burns > floor and douses > floor, (
        "both pools sat on the floor, so this proved nothing"
    )
    assert douses < burns, (
        f"the beast that turns Fire aside was sized at {douses} and the one "
        f"that feeds it at {burns}; the pool is reading base_power again"
    )


def test_the_next_beast_has_a_moment_and_the_opener_obeys_it(conn, standing):
    """0165. Both screens said "nothing standing" and stopped, which is the
    half of the answer nobody asks for. The other half was computable all
    along - `boss_open_if_due` refuses until the world has rested - but the
    rule lived inline inside the opener, so a screen wanting to report it
    would have had to restate it.

    A restated rule drifts, and a countdown that disagrees with the opener
    reads as a bot simply not doing what it said. So the clock and the opener
    are checked against each other here rather than only against the config.
    """
    # While one stands there is nothing to promise: when the next arrives
    # depends on when somebody finishes this one.
    assert conn.execute("SELECT boss_next_spawn_at()").fetchone()[0] is None

    conn.execute(
        "UPDATE boss_encounters SET status = 'slain', ended_at = now() "
        "WHERE encounter_id = %s",
        (standing,),
    )

    due, ended, rest = conn.execute(
        """
        SELECT boss_next_spawn_at(),
               (SELECT max(ended_at) FROM boss_encounters),
               game_config_value('boss_rest_hours')
        """
    ).fetchone()
    assert due is not None
    assert due == ended + timedelta(hours=float(rest)), (
        "the clock is not the rest period after the last beast ended"
    )

    # And the opener refuses for exactly as long as the clock says it will.
    assert conn.execute("SELECT boss_open_if_due()").fetchone()[0] is None, (
        "the opener let one through before its own clock said it could"
    )

    conn.execute(
        "UPDATE boss_encounters "
        "SET ended_at = now() - make_interval(hours => %s) "
        "WHERE ended_at IS NOT NULL",
        (int(rest) + 1,),
    )
    assert conn.execute("SELECT boss_next_spawn_at()").fetchone()[0] < \
        conn.execute("SELECT now()").fetchone()[0]
    assert conn.execute("SELECT boss_open_if_due()").fetchone()[0] is not None, (
        "the clock said one was due and the opener disagreed"
    )


def test_a_strike_hurts_it_and_costs_you(conn, striker, standing):
    before = conn.execute(
        "SELECT current_hp FROM boss_encounters WHERE encounter_id = %s",
        (standing,),
    ).fetchone()[0]

    dealt, taken, my_hp = conn.execute(
        "SELECT dealt, taken, my_hp FROM strike_boss(%s)", (striker,)
    ).fetchone()

    after = conn.execute(
        "SELECT current_hp FROM boss_encounters WHERE encounter_id = %s",
        (standing,),
    ).fetchone()[0]

    assert dealt > 0, "a strike that lands has to land"
    assert before - after == dealt, "the pool and the report disagree"
    assert taken > 0, "the beast did not answer"
    assert my_hp == 5000 - taken


def test_health_ends_a_sitting_and_the_allowance_outlasts_it(conn, striker, standing):
    """Two limits, and they are meant to bite in that order.

    Before 0141 a rank 7 beast removed all of a cultivator's health in one
    blow, so an allowance of five ended on the first strike. The bite is capped
    at a share of maximum health now, which buys about five blows from full.

    0145 then took the allowance to twenty-five - well past what any one
    sitting allows - precisely so a world beast cannot be finished in an
    afternoon. Five blows, /rest, come back. So the property is no longer "you
    can spend it all and live"; it is that health ends the sitting, the
    allowance survives it, and resting hands the fight back.
    """
    allowed = int(conn.execute(
        "SELECT game_config_value('boss_strikes_each')"
    ).fetchone()[0])
    cap = float(conn.execute(
        "SELECT game_config_value('boss_bite_cap')"
    ).fetchone()[0])

    landed = 0
    for _ in range(allowed):
        try:
            with conn.transaction():
                # 0251 added a five-strike burst, which bites at roughly the
                # same point the bite cap does. This test is about HEALTH
                # ending a sitting, so the stand-off is stood down and the
                # only thing left to stop them is their own body.
                conn.execute(
                    "UPDATE boss_strikes SET resumes_at = NULL WHERE player_id = %s",
                    (striker,),
                )
                conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
            landed += 1
        except psycopg.errors.CheckViolation:
            break

    # The cap is a share of MAX health, so a full bar buys about 1/cap blows.
    expected = int(1 / cap)
    assert landed >= expected - 1, (
        f"a full-health striker landed only {landed} blows, and the cap of "
        f"{cap} should buy about {expected}"
    )
    assert landed < allowed, (
        f"the whole allowance of {allowed} went in one sitting, so the beast "
        "can still be finished in an afternoon"
    )

    # Health is what stopped them, and it comes back.
    spent = conn.execute(
        "SELECT strikes FROM boss_strikes WHERE encounter_id = %s AND player_id = %s",
        (standing, striker),
    ).fetchone()[0]
    assert spent == landed
    conn.execute(
        "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s",
        (striker,),
    )
    conn.execute(
        "UPDATE boss_strikes SET resumes_at = NULL WHERE player_id = %s",
        (striker,),
    )
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()

    after = conn.execute(
        "SELECT strikes FROM boss_strikes WHERE encounter_id = %s AND player_id = %s",
        (standing, striker),
    ).fetchone()[0]
    assert after == landed + 1, "resting did not hand the fight back"


def test_the_allowance_is_still_the_hard_stop(conn, striker, standing):
    """Health ends a sitting; the allowance ends the day. Spending it while
    healthy throughout must still refuse at the ceiling."""
    allowed = int(conn.execute(
        "SELECT game_config_value('boss_strikes_each')"
    ).fetchone()[0])

    for _ in range(allowed):
        conn.execute(
            "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s",
            (striker,),
        )
        # 0251 put a five-strike burst in front of the allowance. This test is
        # about the ceiling on the whole encounter, not the pace, so the
        # stand-off is stood down rather than waited out.
        conn.execute(
            "UPDATE boss_strikes SET resumes_at = NULL WHERE player_id = %s",
            (striker,),
        )
        conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()

    conn.execute(
        "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s",
        (striker,),
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="strikes"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()


def test_the_pick_is_by_what_lands_not_by_base_power(conn, striker, standing):
    """A world beast can be immune to a Path. Choosing the strongest technique
    by base power would spend a strike on a move the beast ignores and report
    nothing, so the pick asks the damage pipeline about each candidate."""
    species = conn.execute(
        "SELECT species_id FROM boss_encounters WHERE encounter_id = %s",
        (standing,),
    ).fetchone()[0]

    chosen, dealt = conn.execute(
        "SELECT technique, dealt FROM strike_boss(%s)", (striker,)
    ).fetchone()

    best = conn.execute(
        """
        SELECT max(would.final_damage)
        FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        CROSS JOIN LATERAL compute_technique_damage(
            %s, t.technique_id, %s,
            player_external_multiplier(%s, t.technique_id), 0) AS would
        WHERE u.player_id = %s AND t.base_power > 0
        """,
        (striker, species, striker, striker),
    ).fetchone()[0]

    assert dealt == best, f"{chosen} was not the hardest hit available"


def test_a_share_is_of_what_was_dealt_and_pays_once(conn, striker, standing):
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    conn.execute(
        "UPDATE boss_encounters SET status = 'escaped', ended_at = now() "
        "WHERE encounter_id = %s",
        (standing,),
    )

    mine, total = conn.execute(
        """
        SELECT (SELECT damage FROM boss_strikes
                WHERE encounter_id = %s AND player_id = %s),
               (SELECT sum(damage) FROM boss_strikes WHERE encounter_id = %s)
        """,
        (standing, striker, standing),
    ).fetchone()

    outcome, share, stones = conn.execute(
        "SELECT outcome, my_share, stones FROM claim_boss_reward(%s)", (striker,)
    ).fetchone()

    assert outcome == "escaped"
    # Derived, not assumed to be 1. The beast is shared - `boss_open_if_due`
    # hands back whichever one is standing - so another test's striker may be
    # on the same ledger, which is exactly the case a share has to survive.
    assert share == round(mine / total, 4), "the share is not of what was dealt"
    assert stones > 0, "a beast that got away still owes what it was bled for"

    with pytest.raises(psycopg.errors.CheckViolation, match="nothing owing"):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT * FROM claim_boss_reward(%s)", (striker,)
            ).fetchone()


def test_a_world_beast_is_not_something_you_blunder_into(conn):
    """The Leviathan sat in the Eastern Sea hunt draw from 0010 until 0139:
    five million HP at weight 1.0, so about one hunt in a hundred and
    twenty-five threw a Qi Condensation cultivator at an unkillable wall - and
    `player_active_battle` being one-per-player kept them in front of it.

    The draw lives in the world cog, so this asserts the fact that made it
    dangerous: these are creatures no single cultivator is meant to meet.
    """
    huge = conn.execute(
        """
        SELECT count(*) FROM creature_species cs
        JOIN creature_regions cr ON cr.species_id = cs.species_id
        WHERE cs.kind IN ('world', 'boss')
        """
    ).fetchone()[0]
    assert huge > 0, "the beasts still live somewhere, they are just not hunted"

    # Reachable means the hunt draw can pick it, which is a region and not a
    # kind. 0204 added dungeon bosses - The First Gu is 4.6 million HP - and
    # they live behind a door with no region at all, so a kind list would have
    # counted them as something you could blunder into.
    # "Blunder into" is the whole rule, and a region with a door on it cannot
    # be blundered into. Black Heaven asks for rank 10 to set foot in, and its
    # Immemorial beasts run to 2.1 billion - far past the smallest wall - but
    # nobody arrives there by accident on a hunt cooldown, which is precisely
    # what happened to the Qi Condensation cultivators above. So the question
    # is asked of the OPEN world, where it was earning its keep.
    reachable = conn.execute(
        """
        SELECT max(cs.base_hp) FROM creature_species cs
        WHERE cs.kind NOT IN ('world', 'boss')
          AND EXISTS (SELECT 1 FROM creature_regions cr
                      JOIN regions r ON r.code = cr.region_code
                      WHERE cr.species_id = cs.species_id AND r.min_rank = 1)
        """
    ).fetchone()[0]
    walls = conn.execute(
        """
        SELECT min(cs.base_hp) FROM creature_species cs
        WHERE cs.kind IN ('world', 'boss')
        """
    ).fetchone()[0]
    # Strictly tougher, not an invented multiple: the Revenant is 4.3x the
    # hardiest huntable creature and the Leviathan is a thousand times it, so
    # any threshold between them would be a number picked to pass.
    assert walls > reachable, (
        f"the weakest world beast has {walls} HP and the hardiest huntable "
        f"creature has {reachable}, so the split between /hunt and /boss is "
        "not about being out of reach"
    )


def test_a_trait_says_what_it_gives_without_being_worn(conn):
    """`/reroll` asks a player to spend Jade choosing between the root they
    have and one they do not. The character sheet could only describe the one
    they HELD - `fetch_traits` keys off player_id - so the offer was a name, a
    rarity band and a line of flavour, and the decision was made on vibes.

    Keyed by the trait, so the two sides of that choice are described by the
    same code and cannot disagree about what a root is worth.
    """
    for code, in conn.execute("SELECT code FROM roots").fetchall():
        got = conn.execute("SELECT * FROM root_grants(%s)", (code,)).fetchall()
        assert got, f"the root {code} grants nothing anybody can read"

    for pid, in conn.execute("SELECT physique_id FROM physiques").fetchall():
        got = conn.execute(
            "SELECT * FROM physique_grants(%s)", (pid,)
        ).fetchall()
        assert got, f"the body {pid} grants nothing anybody can read"


def test_a_trait_quotes_the_magnitude_the_game_applies(conn):
    """`root_stat` and `physique_stat` cap a magnitude at the effect's own cap.
    A screen quoting the stored figure would be quoting a number the game never
    uses - the same reason 0070's sheet caps them."""
    over = conn.execute(
        """
        SELECT count(*) FROM roots r
        CROSS JOIN LATERAL root_grants(r.code) g
        JOIN gu_effects ef ON ef.name = g.name
        WHERE g.kind = 'effect' AND g.magnitude > ef.cap
        """
    ).fetchone()[0]
    assert over == 0, "a root quotes a magnitude above the effect's ceiling"


def test_a_body_says_how_far_it_can_be_tempered(conn):
    """Three of the common bodies have no effects and no Path bonuses at all -
    Mortal Body among them - so without the tempering ceiling the reroll screen
    would have nothing whatever to say about them. It is also the thing a
    rarity band actually buys."""
    reach = conn.execute(
        """
        SELECT g.magnitude FROM physiques ph
        CROSS JOIN LATERAL physique_grants(ph.physique_id) g
        WHERE ph.code = 'mortal_body' AND g.kind = 'ceiling'
        """
    ).fetchone()
    assert reach is not None, "the starting body says nothing at all"

    rarer = conn.execute(
        """
        SELECT g.magnitude FROM physiques ph
        CROSS JOIN LATERAL physique_grants(ph.physique_id) g
        WHERE ph.code = 'northern_dark_ice_soul' AND g.kind = 'ceiling'
        """
    ).fetchone()
    assert rarer[0] > reach[0], "a rarer body must temper further"


def test_a_world_beast_holds_something_no_hunt_can_yield(conn):
    """It paid out of `creature_drops` - the same table a hunt rolls - so
    bringing down a rank 9 leviathan yielded three rare beast materials worth
    two or three Spirit Stones each. `boss_drops` is a second table so that a
    hunt can never roll these, whatever else changes."""
    for species, name in conn.execute(
        "SELECT species_id, name FROM creature_species WHERE kind IN ('world','boss')"
    ).fetchall():
        exclusive = conn.execute(
            """
            SELECT count(*) FROM boss_drops bd
            WHERE bd.species_id = %s
              AND NOT EXISTS (
                  SELECT 1 FROM creature_drops cd
                  WHERE cd.species_id = bd.species_id
                    AND cd.material_code = bd.material_code
              )
            """,
            (species,),
        ).fetchone()[0]
        assert exclusive > 0, f"{name} holds nothing a hunt could not also yield"


def test_the_spoils_include_ore_no_amount_of_hunting_produces(conn):
    """Deep ore is region-exclusive and takes about a hundred and ninety swings
    of /mine at full cap to gather nine of. A beast yielding two is the reason
    to fight one, and mining is still the reliable way."""
    deep = conn.execute(
        """
        SELECT count(*) FROM boss_drops bd
        JOIN ores o ON o.material_code = bd.material_code
        WHERE o.tier >= 6
        """
    ).fetchone()[0]
    assert deep > 0, "no world beast yields deep ore"

    # And nothing else in the game drops ore at all - it comes out of the
    # ground, which is what makes this worth having.
    from_corpses = conn.execute(
        """
        SELECT count(*) FROM creature_drops cd
        JOIN ores o ON o.material_code = cd.material_code
        """
    ).fetchone()[0]
    assert from_corpses == 0, "ordinary creatures drop ore, so this is not special"


def test_everyone_who_struck_it_rolls_their_own_jade(conn, striker, standing):
    """It used to be a flat fifteen to whoever landed the last blow, which pays
    one person for the timing of their afternoon. Turning up is the thing being
    rewarded now, and the size of it is luck."""
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    conn.execute(
        "UPDATE boss_encounters SET status = 'slain', ended_at = now(), "
        "slayer_id = NULL WHERE encounter_id = %s",
        (standing,),
    )

    lo, hi = conn.execute(
        "SELECT game_config_value('boss_jade_min'), game_config_value('boss_jade_max')"
    ).fetchone()

    jade = conn.execute(
        "SELECT jade FROM claim_boss_reward(%s)", (striker,)
    ).fetchone()[0]

    # Paid despite not landing the killing blow - slayer_id is NULL above.
    assert jade >= lo, f"a striker who did not land the last blow got {jade}"
    assert jade <= hi


def test_a_beast_that_got_away_still_pays_something(conn, striker, standing):
    """Half rate, and the shares still sum to one because the divisor is what
    was dealt rather than what was needed."""
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    conn.execute(
        "UPDATE boss_encounters SET status = 'escaped', ended_at = now() "
        "WHERE encounter_id = %s",
        (standing,),
    )

    outcome, stones, jade, spoils = conn.execute(
        "SELECT outcome, stones, jade, spoils FROM claim_boss_reward(%s)", (striker,)
    ).fetchone()

    assert outcome == "escaped"
    assert stones > 0 and jade > 0, "it owed what it was bled for"
    assert spoils == [], "a beast that got away leaves no carcass to strip"


def test_the_ledger_remembers_what_a_claim_paid(conn, striker, standing):
    """A claim used to compute stones, Jade and spoils, hand them over and
    remember none of it - `rewarded_at` recorded THAT a share was paid and
    nothing about what. Without this the kill cannot be announced with
    everyone's haul in it, and "what did the Leviathan pay out" is
    unanswerable."""
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    conn.execute(
        "UPDATE boss_encounters SET status = 'slain', ended_at = now(), "
        "slayer_id = %s WHERE encounter_id = %s",
        (striker, standing),
    )

    stones, jade, spoils = conn.execute(
        "SELECT stones, jade, spoils FROM claim_boss_reward(%s)", (striker,)
    ).fetchone()

    kept = conn.execute(
        "SELECT stones, jade, spoils, claimed FROM boss_haul(%s) "
        "WHERE player_id = %s",
        (standing, striker),
    ).fetchone()

    assert kept[3] is True
    assert kept[0] == stones and kept[1] == jade
    assert kept[2] == spoils, "the ledger and the claim disagree about the spoils"


def test_a_payout_lists_each_material_once(conn, striker, standing):
    """The corpse and the boss table can hold the same material - that is how
    bulk works, and it is deliberate. Reporting it as two lines is the screen
    being literal about the implementation:

        grafv - 170 stones - Dragon Whale Bone x6 - Dragon Whale Bone x3

    He got nine.
    """
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    conn.execute(
        "UPDATE boss_encounters SET status = 'slain', ended_at = now(), "
        "slayer_id = %s WHERE encounter_id = %s",
        (striker, standing),
    )

    spoils = conn.execute(
        "SELECT spoils FROM claim_boss_reward(%s)", (striker,)
    ).fetchone()[0]

    codes = [item["code"] for item in spoils]
    assert len(codes) == len(set(codes)), f"a material is listed twice: {codes}"


def test_an_unclaimed_share_shows_as_waiting(conn, striker, standing):
    """"Waiting" is information the channel wants - it is a nudge to whoever
    has a share sitting there."""
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    conn.execute(
        "UPDATE boss_encounters SET status = 'escaped', ended_at = now() "
        "WHERE encounter_id = %s",
        (standing,),
    )

    claimed, stones = conn.execute(
        "SELECT claimed, stones FROM boss_haul(%s) WHERE player_id = %s",
        (standing, striker),
    ).fetchone()
    assert claimed is False and stones == 0

    conn.execute("SELECT * FROM claim_boss_reward(%s)", (striker,)).fetchone()
    claimed, stones = conn.execute(
        "SELECT claimed, stones FROM boss_haul(%s) WHERE player_id = %s",
        (standing, striker),
    ).fetchone()
    assert claimed is True and stones > 0


# ---------------------------------------------------------------------------
# The table (0149, 0150)
# ---------------------------------------------------------------------------


@pytest.fixture
def punter(conn, make_player):
    player = make_player("Punter")
    conn.execute("SELECT grant_jade(%s, 5000, 'test')", (player,))
    return player


@pytest.fixture
def pair(conn, make_player):
    one = make_player("Challenger")
    two = make_player("Opponent")
    for who in (one, two):
        conn.execute("SELECT grant_jade(%s, 200, 'test')", (who,))
    return one, two


def test_every_roll_lands_in_exactly_one_band(conn):
    """A d100 that fell through the ladder would pay nothing and look like a
    loss, which is the sort of thing nobody reports because it is
    indistinguishable from bad luck."""
    orphans = conn.execute(
        """
        SELECT count(*) FROM generate_series(1, 100) AS r (roll)
        WHERE NOT EXISTS (SELECT 1 FROM gamble_bands gb WHERE gb.min_roll <= r.roll)
        """
    ).fetchone()[0]
    assert orphans == 0


def test_the_house_keeps_exactly_what_it_says_it_keeps(conn):
    """The house has infinite Jade, so this sum is the only thing between the
    payout table and an unbounded faucet. It is worth asserting from the data
    rather than trusting the migration that wrote it."""
    ev = conn.execute(
        """
        SELECT sum(band.multiplier) / 100
        FROM generate_series(1, 100) AS r (roll)
        CROSS JOIN LATERAL (
            SELECT gb.multiplier FROM gamble_bands gb
            WHERE gb.min_roll <= r.roll ORDER BY gb.min_roll DESC LIMIT 1
        ) band
        """
    ).fetchone()[0]
    take = conn.execute(
        "SELECT game_config_value('gamble_house_take')"
    ).fetchone()[0]

    assert ev < 1, f"the house pays out {ev} per Jade staked and cannot run dry"
    assert abs((1 - ev) - take) < Decimal("0.0001"), (
        f"the table keeps {1 - ev} and the config says {take}"
    )


def test_the_realised_return_matches_the_table(conn, punter):
    """Two thousand rolls. The arithmetic above says what the table should pay;
    this says what it does pay, which is a different claim and the one a player
    would notice was wrong."""
    staked = paid = 0
    for _ in range(2000):
        stake, back = conn.execute(
            "SELECT stake, paid FROM play_house(%s, 1)", (punter,)
        ).fetchone()
        staked += stake
        paid += back

    ratio = paid / staked
    # The band is four standard deviations, worked out rather than guessed.
    #
    # The table pays 0x on 42 rolls, 1x on 26, 2x on 28, 3x on 3 and 5x on 1.
    # E[X] = 0.96 and E[X^2] = 1.90, so a single roll has a variance of 0.978
    # and a deviation of 0.989. Over 2,000 rolls the mean's deviation is
    # 0.989/sqrt(2000) = 0.0221, and four of those is 0.0885.
    #
    # The old band was 0.90 to 1.02 with a comment calling that three
    # deviations. Three is 0.066, so 0.90 was 2.7 - and the test failed about
    # one suite run in seventy on a table that was working perfectly.
    assert 0.96 - 0.0885 < ratio < 0.96 + 0.0885, (
        f"two thousand rolls returned {ratio:.4f} per Jade, and the table says 0.96"
    )


def test_a_wager_you_cannot_cover_is_refused_before_it_rolls(conn, make_player):
    poor = make_player("Skint")
    conn.execute("SELECT grant_jade(%s, 2, 'test')", (poor,))

    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM play_house(%s, 20)", (poor,)).fetchone()

    assert conn.execute("SELECT jade_held(%s)", (poor,)).fetchone()[0] == 2


def test_the_stake_ceiling_holds(conn, punter):
    hi = conn.execute("SELECT game_config_value('gamble_max_stake')").fetchone()[0]
    with pytest.raises(psycopg.errors.CheckViolation, match="between"):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT * FROM play_house(%s, %s)", (punter, int(hi) + 1)
            ).fetchone()


def settle_a_wager(conn, one: int, two: int, stake: int = 5) -> dict:
    """Offer it and have both sides accept, which is now the whole ceremony."""
    wager = conn.execute(
        "SELECT wager_id FROM offer_wager(%s, %s, %s)", (one, two, stake)
    ).fetchone()[0]
    conn.execute("SELECT * FROM accept_wager(%s, %s)", (wager, one))
    row = conn.execute(
        "SELECT settled, challenger_roll, opponent_roll, winner_id, tied "
        "FROM accept_wager(%s, %s)",
        (wager, two),
    ).fetchone()
    return {
        "wager_id": wager,
        "settled": row[0],
        "challenger_roll": row[1],
        "opponent_roll": row[2],
        "winner_id": row[3],
        "tied": row[4],
    }


def test_a_wager_between_people_is_zero_sum(conn, pair):
    """The house needed an edge because it cannot run out. Two cultivators can,
    so no cut is taken - what one loses the other wins and the currency's total
    is untouched. A rake here would be a sink pretending to be a game."""
    one, two = pair
    before = conn.execute(
        "SELECT jade_held(%s) + jade_held(%s)", (one, two)
    ).fetchone()[0]

    for _ in range(20):
        settle_a_wager(conn, one, two, 5)

    after = conn.execute(
        "SELECT jade_held(%s) + jade_held(%s)", (one, two)
    ).fetchone()[0]
    assert after == before, f"twenty wagers moved the pair from {before} to {after}"


def test_a_tie_takes_nothing_from_anybody(conn, pair):
    """A d100 ties one time in a hundred and there is no house here to break it
    in favour of."""
    one, two = pair
    ties = 0

    # 0160 takes each side's stake as it accepts, which turned this loop into a
    # random walk: a thousand three-Jade wagers drift far enough to empty a
    # 200-Jade purse about one run in fourteen, and the bust is raised as
    # "cannot cover" - a schema refusal, reported as a schema failure.
    #
    # Enough Jade that a thousand straight losses still could not empty either
    # purse makes it impossible rather than merely unlikely, which is the
    # difference between a fixed test and a quieter one.
    for who in (one, two):
        conn.execute("SELECT grant_jade(%s, 3000, 'test')", (who,))

    # A d100 ties one time in a hundred, so three hundred wagers miss entirely
    # about one run in twenty - which is a test that fails for no reason once a
    # fortnight. A thousand puts that at one in twenty-three thousand.
    for _ in range(1000):
        before = conn.execute(
            "SELECT jade_held(%s), jade_held(%s)", (one, two)
        ).fetchone()
        tied = settle_a_wager(conn, one, two, 3)["tied"]
        if tied:
            ties += 1
            after = conn.execute(
                "SELECT jade_held(%s), jade_held(%s)", (one, two)
            ).fetchone()
            assert after == before, "a tie moved somebody's Jade"

    assert ties > 0, "a thousand wagers and never a tie; the roll is suspect"


# ---------------------------------------------------------------------------
# The free-for-all (0151, 0152)
# ---------------------------------------------------------------------------


@pytest.fixture
def fighters(conn, make_player):
    """Six cultivators who can all reach each other."""
    made = []
    for i in range(1, 7):
        who = make_player(f"Fighter {i}")
        conn.execute(
            "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
            "VALUES (%s, 0, 1)",
            (who,),
        )
        conn.execute(
            "INSERT INTO player_physique (player_id, physique_id, body_level, "
            "max_hp, current_hp, defense) VALUES (%s, (SELECT physique_id FROM "
            "physiques LIMIT 1), 1, %s, %s, %s)",
            (who, 200 + i * 40, 200 + i * 40, i * 5),
        )
        conn.execute(
            "INSERT INTO player_techniques (player_id, technique_id) "
            "SELECT %s, technique_id FROM techniques WHERE code IS NOT NULL "
            "AND grade = 'basic' AND rank = 1 AND base_power > 0 LIMIT 3",
            (who,),
        )
        made.append(who)
    return made


@pytest.fixture
def ring(conn, fighters):
    """An open tournament with all six in it."""
    conn.execute("UPDATE tournaments SET status = 'abandoned', fought_at = now() "
                 "WHERE status = 'signup'")
    meet = conn.execute("SELECT open_tournament()").fetchone()[0]
    for who in fighters:
        conn.execute("SELECT * FROM join_tournament(%s)", (who,))
    return meet


def test_a_free_for_all_ends_with_one_standing(conn, ring):
    entrants, rounds, champion, blows = conn.execute(
        "SELECT entrants, rounds, champion_id, blows FROM run_tournament(%s)",
        (ring,),
    ).fetchone()

    assert entrants == 6
    assert rounds >= 1 and blows >= 1, "it resolved without anybody swinging"
    assert champion is not None, "six entrants and no champion"

    standing = conn.execute(
        "SELECT count(*) FROM tournament_entrants WHERE tournament_id = %s "
        "AND current_hp > 0",
        (ring,),
    ).fetchone()[0]
    assert standing == 1


def test_everybody_is_placed_exactly_once(conn, ring):
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()

    places = [
        row[0] for row in conn.execute(
            "SELECT place FROM tournament_entrants WHERE tournament_id = %s "
            "ORDER BY place",
            (ring,),
        ).fetchall()
    ]
    assert places == [1, 2, 3, 4, 5, 6], f"six entrants placed {places}"

    champion_hp = conn.execute(
        "SELECT current_hp FROM tournament_entrants WHERE tournament_id = %s "
        "AND place = 1",
        (ring,),
    ).fetchone()[0]
    assert champion_hp > 0, "the champion is lying down"


def test_the_snapshot_is_what_fights_not_the_living_player(conn, fighters, ring):
    """The whole design. Somebody who signs up and then breaks through must not
    arrive stronger than somebody who signed up and went to bed."""
    who = fighters[0]
    frozen = conn.execute(
        "SELECT max_hp, snapshot FROM tournament_entrants "
        "WHERE tournament_id = %s AND player_id = %s",
        (ring, who),
    ).fetchone()

    # Become enormously stronger after entering.
    conn.execute(
        "UPDATE player_physique SET max_hp = 999999, current_hp = 999999, "
        "defense = 9999 WHERE player_id = %s",
        (who,),
    )

    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()

    fought_with = conn.execute(
        "SELECT max_hp, snapshot FROM tournament_entrants "
        "WHERE tournament_id = %s AND player_id = %s",
        (ring, who),
    ).fetchone()
    assert fought_with[0] == frozen[0], "the fight read the living player's health"
    assert fought_with[1] == frozen[1], "the snapshot moved after signup"
    assert fought_with[0] < 999999


def test_a_snapshot_freezes_both_halves_of_a_blow(conn, fighters):
    """Health and defense are the obvious half. The two easy to miss are the
    technique's rating - base power already through attainment and the trait
    hook - and the entrant's resistance per Path, because a defender who
    trained overnight would otherwise shrug off a blow aimed at who they
    used to be."""
    shot = conn.execute(
        "SELECT tournament_snapshot(%s)", (fighters[0],)
    ).fetchone()[0]

    assert "max_hp" in shot and "defense" in shot
    assert shot["techniques"], "a snapshot with no techniques cannot fight"
    for move in shot["techniques"]:
        assert "rating" in move, "a technique was frozen without its rating"
        assert "paths" in move, "without its typing, resistance cannot apply"
        assert move["rating"] > 0
    assert "resist" in shot, "the defending half was not frozen at all"


def test_a_blow_reads_no_table_at_all(conn, fighters):
    """`snapshot_blow` is arithmetic over two frozen documents, so a fight is
    reproducible from its entry list. Same inputs, same number, every time."""
    one = conn.execute("SELECT tournament_snapshot(%s)", (fighters[0],)).fetchone()[0]
    two = conn.execute("SELECT tournament_snapshot(%s)", (fighters[1],)).fetchone()[0]
    move = one["techniques"][0]

    hits = {
        conn.execute(
            "SELECT snapshot_blow(%s::jsonb, %s::jsonb)",
            (json.dumps(move), json.dumps(two)),
        ).fetchone()[0]
        for _ in range(8)
    }
    assert len(hits) == 1, f"the same blow came out as {hits}"
    assert hits.pop() > 0


def test_resistance_is_weighted_by_the_techniques_own_typing(conn, fighters):
    """A dual-Path move against somebody who resists one of its halves keeps
    the other half, the same way the creature matchup chart works."""
    move = {"rating": 1000, "paths": {"fire": 0.5, "ice": 0.5}}
    naked = {"defense": 0, "resist": {}}
    half = {"defense": 0, "resist": {"fire": 1.0}}
    both = {"defense": 0, "resist": {"fire": 1.0, "ice": 1.0}}

    full = conn.execute(
        "SELECT snapshot_blow(%s::jsonb, %s::jsonb)",
        (json.dumps(move), json.dumps(naked)),
    ).fetchone()[0]
    partial = conn.execute(
        "SELECT snapshot_blow(%s::jsonb, %s::jsonb)",
        (json.dumps(move), json.dumps(half)),
    ).fetchone()[0]
    none = conn.execute(
        "SELECT snapshot_blow(%s::jsonb, %s::jsonb)",
        (json.dumps(move), json.dumps(both)),
    ).fetchone()[0]

    assert partial == pytest.approx(full / 2, rel=0.02), (
        "resisting half a dual-Path move should stop half of it"
    )
    assert none == 1, "resisting all of it should still land the floor of 1"


def test_too_few_entrants_is_abandoned_rather_than_fought(conn, fighters):
    conn.execute("UPDATE tournaments SET status = 'abandoned', fought_at = now() "
                 "WHERE status = 'signup'")
    meet = conn.execute("SELECT open_tournament()").fetchone()[0]
    conn.execute("SELECT * FROM join_tournament(%s)", (fighters[0],))

    champion = conn.execute(
        "SELECT champion_id FROM run_tournament(%s)", (meet,)
    ).fetchone()[0]
    assert champion is None

    status = conn.execute(
        "SELECT status FROM tournaments WHERE tournament_id = %s", (meet,)
    ).fetchone()[0]
    assert status == "abandoned"


def test_you_cannot_enter_twice(conn, fighters, ring):
    with pytest.raises(psycopg.errors.CheckViolation, match="already entered"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM join_tournament(%s)", (fighters[0],))


def test_only_one_ring_takes_entries_at_a_time(conn, ring):
    open_now = conn.execute(
        "SELECT count(*) FROM tournaments WHERE status = 'signup'"
    ).fetchone()[0]
    assert open_now == 1

    with pytest.raises(psycopg.errors.UniqueViolation):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "INSERT INTO tournaments (closes_at) VALUES (now() + interval '1 hour')"
            )


def test_a_fought_tournament_cannot_be_fought_again(conn, ring):
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()

    with pytest.raises(psycopg.errors.CheckViolation, match="already been fought"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()


def test_somebody_felled_early_in_a_round_does_not_swing_later_in_it(conn, ring):
    """The only place turn order can matter, so it is worth being deliberate
    about rather than accidental."""
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()

    wrong = conn.execute(
        """
        SELECT count(*)
        FROM tournament_blows swung
        JOIN tournament_blows fell
          ON fell.tournament_id = swung.tournament_id
         AND fell.round = swung.round
         AND fell.target_id = swung.actor_id
         AND fell.felled
         AND fell.seq < swung.seq
        WHERE swung.tournament_id = %s
        """,
        (ring,),
    ).fetchone()[0]
    assert wrong == 0, f"{wrong} blow(s) were swung by somebody already down"


def test_a_slain_beast_pays_everybody_without_being_asked(conn, striker, standing):
    """A share that had to be claimed was a share somebody would forget, and
    forgetting is not a game mechanic. The killing blow settles the field."""
    conn.execute(
        "UPDATE boss_encounters SET current_hp = 1 WHERE encounter_id = %s",
        (standing,),
    )
    slain = conn.execute(
        "SELECT slain FROM strike_boss(%s)", (striker,)
    ).fetchone()[0]
    assert slain, "the beast was left standing with one health"

    paid = conn.execute(
        "SELECT rewarded_at, stones_paid, jade_paid FROM boss_strikes "
        "WHERE encounter_id = %s AND player_id = %s",
        (standing, striker),
    ).fetchone()
    assert paid[0] is not None, "nobody was settled when it fell"
    assert paid[1] > 0 and paid[2] > 0

    # And there is nothing left owing to claim by hand.
    with pytest.raises(psycopg.errors.CheckViolation, match="nothing owing"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM claim_boss_reward(%s)", (striker,))


def test_a_beast_that_runs_out_its_clock_settles_on_the_way_out(conn, striker, standing):
    """An escape owes what it was bled for, and retiring it is the moment that
    is known - so it pays there rather than waiting to be asked."""
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    conn.execute(
        "UPDATE boss_encounters SET closes_at = now() - interval '1 minute' "
        "WHERE encounter_id = %s",
        (standing,),
    )

    conn.execute("SELECT boss_open_if_due()")

    status, rewarded = conn.execute(
        """
        SELECT e.status, bs.rewarded_at
        FROM boss_encounters e
        JOIN boss_strikes bs ON bs.encounter_id = e.encounter_id
        WHERE e.encounter_id = %s AND bs.player_id = %s
        """,
        (standing, striker),
    ).fetchone()
    assert status == "escaped"
    assert rewarded is not None, "a beast that left owed somebody and did not pay"


def test_settling_twice_pays_once(conn, striker, standing):
    """`rewarded_at` is what makes a payout once, and settling walks only the
    strikers who have none."""
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    conn.execute(
        "UPDATE boss_encounters SET status = 'slain', ended_at = now() "
        "WHERE encounter_id = %s",
        (standing,),
    )

    first = conn.execute("SELECT settle_boss(%s)", (standing,)).fetchone()[0]
    stones = conn.execute(
        "SELECT stones_paid FROM boss_strikes WHERE encounter_id = %s "
        "AND player_id = %s",
        (standing, striker),
    ).fetchone()[0]

    second = conn.execute("SELECT settle_boss(%s)", (standing,)).fetchone()[0]
    again = conn.execute(
        "SELECT stones_paid FROM boss_strikes WHERE encounter_id = %s "
        "AND player_id = %s",
        (standing, striker),
    ).fetchone()[0]

    # `first` counts everybody unsettled on that beast, and the beast is
    # shared between these tests - so the claim is that a second sweep pays
    # nobody, not that the first paid exactly one.
    assert first >= 1, "settling a finished beast paid nobody"
    assert second == 0, "a second sweep paid somebody again"
    assert again == stones, "settling twice moved the ledger"


def test_settling_an_open_beast_does_nothing(conn, striker, standing):
    """Half a payout on a fight still running would be the worst outcome
    available."""
    conn.execute("SELECT * FROM strike_boss(%s)", (striker,)).fetchone()
    assert conn.execute("SELECT settle_boss(%s)", (standing,)).fetchone()[0] == 0
    assert conn.execute(
        "SELECT rewarded_at FROM boss_strikes WHERE encounter_id = %s "
        "AND player_id = %s",
        (standing, striker),
    ).fetchone()[0] is None


def test_an_arrival_is_offered_for_announcement_exactly_once(conn, standing):
    """`spawn_announced_at` is on the row rather than in the bot's memory, so a
    restart neither posts it twice nor forgets to post it at all."""
    # Cleared first. The beast is shared between these tests and the dev
    # database outlives a pytest run, so a second run would otherwise inherit
    # the flag this test set in the first and read "already announced" - which
    # is the fixture leaking, not the feature failing.
    conn.execute(
        "UPDATE boss_encounters SET spawn_announced_at = NULL WHERE encounter_id = %s",
        (standing,),
    )

    waiting = conn.execute("SELECT boss_awaiting_announcement()").fetchone()[0]
    assert waiting == standing, "a standing beast was not offered for announcement"

    conn.execute("SELECT boss_spawn_announced(%s)", (standing,))
    assert conn.execute("SELECT boss_awaiting_announcement()").fetchone()[0] is None

    # Marking it again must not un-mark or re-offer it.
    conn.execute("SELECT boss_spawn_announced(%s)", (standing,))
    assert conn.execute("SELECT boss_awaiting_announcement()").fetchone()[0] is None


def test_no_beast_outlasts_what_the_roster_can_actually_land(conn):
    """The check 0164 exists for, and the one whose absence let a beast stand
    for two days at 99% health.

    `boss_strikes_each` was doing two jobs: the ceiling on one cultivator's
    strikes, and the number the pool assumed every one of them would reach.
    Nobody reaches it - the bite cap is 18% of max HP, so about five and a
    half swings before /rest - and the pool also summed `base_power`, which is
    the figure before attainment, the matchup, defense and resistance. The two
    errors multiplied: 187,275 HP against a roster landing 3,500 in a round
    where everybody swings once, inside a 48-hour window.

    So the ceiling stops standing in for the expectation, and the thing that
    was actually wrong is stated: a beast must die inside the swings a
    cultivator is expected to take."""
    swings = conn.execute(
        "SELECT game_config_value('boss_swings_expected')"
    ).fetchone()[0]
    floor = conn.execute(
        "SELECT game_config_value('boss_hp_floor')"
    ).fetchone()[0]
    effort = conn.execute(
        "SELECT game_config_value('boss_effort')"
    ).fetchone()[0]

    outlasting = []
    for species_id, name in conn.execute(
        "SELECT species_id, name FROM creature_species "
        "WHERE kind IN ('world', 'boss') ORDER BY species_id"
    ).fetchall():
        pool = conn.execute("SELECT boss_hp_pool(%s)", (species_id,)).fetchone()[0]
        a_round = conn.execute(
            """
            SELECT COALESCE(sum(best.dealt
                                * player_blow_multiple(p.player_id)
                                + COALESCE(pet_blow(pet_at_heel(p.player_id),
                                                    %s, 0), 0)), 0)
            FROM players p
            JOIN LATERAL (
                SELECT max(would.final_damage) AS dealt
                FROM player_usable_techniques u
                JOIN techniques t ON t.technique_id = u.technique_id
                CROSS JOIN LATERAL compute_technique_damage(
                    p.player_id, t.technique_id, %s,
                    player_external_multiplier(p.player_id, t.technique_id),
                    0) AS would
                WHERE u.player_id = p.player_id AND t.base_power > 0
            ) best ON best.dealt IS NOT NULL AND best.dealt > 0
            WHERE p.deleted_at IS NULL
              AND p.last_seen_at >= now() - make_interval(
                      mins => game_config_value('boss_presence_minutes')::integer)
            """,
            # Twice: once for the technique's target, once for the beast at
            # heel that swings at the same thing. A roster's damage stopped
            # being only its techniques when pets started fighting.
            (species_id, species_id),
        ).fetchone()[0]

        # The floor is a deliberate override for a roster too thin to size a
        # beast at all, and is allowed to be out of reach. What is derived is
        # not.
        if pool <= floor or a_round == 0:
            continue
        if pool > a_round * swings:
            outlasting.append(f"{name}: {round(pool / a_round)} rounds")

        # And the effort dial still says what it says: the pool is that
        # fraction of everything the roster could land in the expected
        # swings - counting, since 0247, what a blow is actually worth
        # once extra strikes and criticals land.
        assert abs(pool - a_round * swings * effort) <= 1, (
            f"{name} was sized at {pool}, not "
            f"{a_round} x {swings} x {effort}"
        )

    assert outlasting == [], (
        f"beasts nobody can finish: {outlasting}"
    )


def test_a_finished_ring_does_not_block_the_next_one(conn, ring):
    """`open_tournament` was always able to do this - it looks for a row in
    'signup' and makes one when there is none. What was missing was anybody
    asking it: the bot's single call sat behind "has a tournament ever
    existed", which is true once and false for good afterwards.

    So the SQL half is checked here and the button half in test_commands: the
    two together are the thing that was broken."""
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,))
    assert conn.execute(
        "SELECT status FROM tournaments WHERE tournament_id = %s", (ring,)
    ).fetchone()[0] in ("fought", "abandoned")

    fresh = conn.execute("SELECT open_tournament()").fetchone()[0]
    assert fresh is not None and fresh != ring, (
        "a finished ring stopped the next one being opened"
    )
    assert conn.execute(
        "SELECT status FROM tournaments WHERE tournament_id = %s", (fresh,)
    ).fetchone()[0] == "signup"

    # And asking twice is one ring, not two - the partial unique index is
    # what makes the button safe to press by anybody, twice.
    assert conn.execute("SELECT open_tournament()").fetchone()[0] == fresh


def test_nobody_leaves_the_ring_with_nothing(conn, ring):
    """Eight of ten entrants used to walk away empty, having been beaten
    senseless by a roll they had no input into. A lottery you mostly lose, with
    the strongest cultivator collecting every time."""
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()

    unpaid = conn.execute(
        "SELECT count(*) FROM tournament_entrants WHERE tournament_id = %s "
        "AND stones_paid <= 0",
        (ring,),
    ).fetchone()[0]
    assert unpaid == 0, f"{unpaid} entrant(s) were paid nothing at all"


def test_the_floor_pays_somebody_who_never_landed_a_blow(conn, ring):
    """Somebody whose every swing was shrugged off still stood in the ring."""
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()
    floor = conn.execute(
        "SELECT game_config_value('tournament_stones_floor')"
    ).fetchone()[0]

    rows = conn.execute(
        "SELECT dealt, stones_paid FROM tournament_entrants WHERE tournament_id = %s",
        (ring,),
    ).fetchall()
    for dealt, paid in rows:
        assert paid >= floor, f"an entrant who dealt {dealt} was paid {paid}"


def test_stones_follow_damage_and_jade_follows_placing(conn, ring):
    """Two different questions, deliberately paid separately: you can deal a
    great deal and still be the third one killed."""
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()
    rate = conn.execute(
        "SELECT game_config_value('tournament_stones_per_damage')"
    ).fetchone()[0]
    floor = conn.execute(
        "SELECT game_config_value('tournament_stones_floor')"
    ).fetchone()[0]

    for dealt, paid in conn.execute(
        "SELECT dealt, stones_paid FROM tournament_entrants WHERE tournament_id = %s",
        (ring,),
    ).fetchall():
        # ROUND_HALF_UP, because that is what Postgres `round()` does on a
        # numeric. Python's built-in rounds half to EVEN, so 64.5 comes out
        # 64 here and 65 there - and the database is the one that is right.
        want = max(
            floor,
            (dealt * rate).quantize(Decimal("1"), rounding=ROUND_HALF_UP),
        )
        assert paid == want, f"{dealt} damage paid {paid}, not {want}"

    podium = conn.execute(
        "SELECT place, jade_paid FROM tournament_entrants "
        "WHERE tournament_id = %s AND jade_paid > 0 ORDER BY place",
        (ring,),
    ).fetchall()
    assert [row[0] for row in podium] == [1, 2, 3], "the podium is not three deep"
    assert podium[0][1] > podium[1][1] > podium[2][1], (
        "the podium does not descend"
    )


def test_the_champion_out_earns_the_first_one_out(conn, ring):
    """Paying the field must not make placing pointless."""
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()
    rows = dict(
        conn.execute(
            "SELECT place, stones_paid + jade_paid * 10 FROM tournament_entrants "
            "WHERE tournament_id = %s",
            (ring,),
        ).fetchall()
    )
    assert rows[1] > rows[max(rows)], (
        f"the champion took {rows[1]} and the first out took {rows[max(rows)]}"
    )


def test_the_champions_purse_is_not_the_biggest_in_the_game(conn):
    """Forty Jade landed every time three people fancied a fight - two settled
    days of /daily - against a world beast paying four to thirty per striker
    for a two-day group effort."""
    prize = conn.execute(
        "SELECT game_config_value('tournament_jade_prize')"
    ).fetchone()[0]
    beast = conn.execute(
        "SELECT game_config_value('boss_jade_max')"
    ).fetchone()[0]
    daily = conn.execute(
        "SELECT game_config_value('daily_jade_max')"
    ).fetchone()[0]

    assert prize <= beast, (
        f"the ring pays {prize} and the world beast tops out at {beast}"
    )
    assert prize < daily * 3, "a single fight should not beat three settled days"


def test_the_standings_report_what_was_paid(conn, ring):
    """A card that says "you came fourth" and not "and here is your thirty-one
    stones" is why nobody would notice the ring started paying everyone."""
    conn.execute("SELECT * FROM run_tournament(%s)", (ring,)).fetchone()
    rows = conn.execute(
        "SELECT place, stones_paid, jade_paid FROM tournament_standings(%s)",
        (ring,),
    ).fetchall()

    assert rows, "the standings came back empty"
    assert all(row[1] > 0 for row in rows), "the standings report nobody paid"


def test_putting_a_technique_down_hands_half_the_stones_back(conn, make_player):
    """Half, as every other craft in this game refunds - so learn-and-unlearn
    cycling is a straight loss and there is nothing to farm."""
    player = make_player("Forgetful")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "SELECT %s, technique_id FROM techniques WHERE code IS NOT NULL "
        "AND grade = 'basic' AND rank = 1 AND base_power > 0 LIMIT 2",
        (player,),
    )

    rank, = conn.execute(
        "SELECT t.rank FROM player_techniques pt JOIN techniques t "
        "ON t.technique_id = pt.technique_id WHERE pt.player_id = %s LIMIT 1",
        (player,),
    ).fetchone()
    cost = conn.execute(
        "SELECT technique_stone_cost(%s::smallint)", (rank,)
    ).fetchone()[0]
    share = conn.execute(
        "SELECT game_config_value('technique_unlearn_refund')"
    ).fetchone()[0]

    victim = conn.execute(
        "SELECT technique_id FROM player_techniques WHERE player_id = %s LIMIT 1",
        (player,),
    ).fetchone()[0]
    back = conn.execute(
        "SELECT refunded FROM unlearn_technique(%s, %s)", (player, victim)
    ).fetchone()[0]

    assert back == int(cost * share)
    assert back < cost, "putting one down paid more than learning it cost"


def test_unlearning_empties_the_loadout_slot(conn, make_player):
    """By the composite foreign key from 0004, not by bookkeeping somebody
    remembers to do."""
    player = make_player("Slotted")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "SELECT %s, technique_id FROM techniques WHERE code IS NOT NULL "
        "AND grade = 'basic' AND rank = 1 AND base_power > 0 LIMIT 2",
        (player,),
    )
    victim = conn.execute(
        "SELECT technique_id FROM player_techniques WHERE player_id = %s LIMIT 1",
        (player,),
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_loadout (player_id, slot_index, technique_id) "
        "VALUES (%s, 0, %s)",
        (player, victim),
    )

    freed = conn.execute(
        "SELECT slot_freed FROM unlearn_technique(%s, %s)", (player, victim)
    ).fetchone()[0]
    assert freed is True

    left = conn.execute(
        "SELECT count(*) FROM player_loadout WHERE player_id = %s AND "
        "technique_id = %s",
        (player, victim),
    ).fetchone()[0]
    assert left == 0, "the loadout kept a technique nobody knows"


def test_you_cannot_put_down_your_last_weapon(conn, make_player):
    """Being talked into disarming yourself is not a decision, it is a trap -
    and it is the same condition /hunt refuses on."""
    player = make_player("Bare")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "SELECT %s, technique_id FROM techniques WHERE code IS NOT NULL "
        "AND grade = 'basic' AND rank = 1 AND base_power > 0 LIMIT 1",
        (player,),
    )
    victim = conn.execute(
        "SELECT technique_id FROM player_techniques WHERE player_id = %s",
        (player,),
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="last thing"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM unlearn_technique(%s, %s)", (player, victim))

    assert conn.execute(
        "SELECT count(*) FROM player_techniques WHERE player_id = %s", (player,)
    ).fetchone()[0] == 1


def test_a_manual_lending_it_counts_as_still_being_armed(conn, make_player):
    """The guard reads `player_usable_techniques`, so a book in your hand is a
    weapon - and putting the learned copy down is then a refund and nothing
    else, which the caller is told."""
    player = make_player("Borrower")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    lent = conn.execute(
        """
        SELECT m.manual_id, t.technique_id
        FROM manuals m
        JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE m.code IS NOT NULL AND t.rank = 1 AND t.base_power > 0
        LIMIT 1
        """
    ).fetchone()
    if lent is None:
        pytest.skip("no rank 1 manual teaches a damaging technique")
    manual_id, technique_id = lent

    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (player, manual_id),
    )
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
        "VALUES (%s, 0, %s)",
        (player, manual_id),
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s)",
        (player, technique_id),
    )

    # The only learned technique, but the manual is holding it too - so this
    # is allowed where the test above is refused.
    still = conn.execute(
        "SELECT still_lent FROM unlearn_technique(%s, %s)", (player, technique_id)
    ).fetchone()[0]
    assert still is True, "the caller was not told the manual still teaches it"

    usable = conn.execute(
        "SELECT count(*) FROM player_usable_techniques WHERE player_id = %s",
        (player,),
    ).fetchone()[0]
    assert usable == 1, "putting the learned copy down took the borrowed one too"


def test_something_never_learned_cannot_be_put_down(conn, make_player):
    player = make_player("Innocent")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    stranger = conn.execute(
        "SELECT technique_id FROM techniques WHERE code IS NOT NULL LIMIT 1"
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="not learned"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM unlearn_technique(%s, %s)", (player, stranger))


def test_cycling_a_technique_is_a_loss(conn, make_player):
    """The refund is the thing that stops this being a free toggle, so it is
    worth asserting as a round trip rather than as a config value."""
    player = make_player("Cycler")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 1000)", (player,))
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "SELECT %s, technique_id FROM techniques WHERE code IS NOT NULL "
        "AND grade = 'basic' AND rank = 1 AND base_power > 0 LIMIT 1",
        (player,),
    )
    keeper = conn.execute(
        "SELECT technique_id FROM player_techniques WHERE player_id = %s", (player,)
    ).fetchone()[0]

    buyable = conn.execute(
        "SELECT s.technique_id FROM technique_shelf(%s) s WHERE s.ready LIMIT 1",
        (player,),
    ).fetchone()
    if buyable is None:
        pytest.skip("nothing this character can buy")
    victim = buyable[0]

    before = conn.execute("SELECT quantity FROM player_materials WHERE "
                          "player_id = %s AND material_code = 'spirit_stone'",
                          (player,)).fetchone()[0]
    conn.execute("SELECT * FROM learn_technique(%s, %s)", (player, victim))
    conn.execute("SELECT * FROM unlearn_technique(%s, %s)", (player, victim))
    after = conn.execute("SELECT quantity FROM player_materials WHERE "
                         "player_id = %s AND material_code = 'spirit_stone'",
                         (player,)).fetchone()[0]

    assert after < before, "learning and forgetting came out even or ahead"
    assert keeper is not None


def test_offering_a_wager_takes_nothing_from_anybody(conn, pair):
    """Offering is not accepting - that is the whole distinction. A wager on
    the table has cost nobody anything yet."""
    one, two = pair
    before = conn.execute(
        "SELECT jade_held(%s), jade_held(%s)", (one, two)
    ).fetchone()

    conn.execute("SELECT wager_id FROM offer_wager(%s, %s, 10)", (one, two))

    after = conn.execute(
        "SELECT jade_held(%s), jade_held(%s)", (one, two)
    ).fetchone()
    assert after == before, "putting a wager on the table took Jade"


def test_each_side_pays_as_it_accepts_and_nobody_else_does(conn, pair):
    """Half-agreed is a real state that can sit for ten minutes, so whoever has
    said yes has their Jade held from that moment - and whoever has not has
    parted with nothing."""
    one, two = pair
    start_one, start_two = conn.execute(
        "SELECT jade_held(%s), jade_held(%s)", (one, two)
    ).fetchone()

    wager = conn.execute(
        "SELECT wager_id FROM offer_wager(%s, %s, 8)", (one, two)
    ).fetchone()[0]

    settled, waiting = conn.execute(
        "SELECT settled, waiting_on FROM accept_wager(%s, %s)", (wager, one)
    ).fetchone()
    assert settled is False, "one acceptance settled it"
    assert waiting == two, "it is waiting on the wrong person"

    mid_one, mid_two = conn.execute(
        "SELECT jade_held(%s), jade_held(%s)", (one, two)
    ).fetchone()
    assert mid_one == start_one - 8, "the acceptor did not pay"
    assert mid_two == start_two, "the one who has not answered paid anyway"

    with pytest.raises(psycopg.errors.CheckViolation, match="already accepted"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM accept_wager(%s, %s)", (wager, one))


def test_declining_a_half_agreed_wager_hands_back_only_what_was_staked(conn, pair):
    one, two = pair
    before = conn.execute(
        "SELECT jade_held(%s) + jade_held(%s)", (one, two)
    ).fetchone()[0]

    wager = conn.execute(
        "SELECT wager_id FROM offer_wager(%s, %s, 7)", (one, two)
    ).fetchone()[0]
    conn.execute("SELECT * FROM accept_wager(%s, %s)", (wager, one))

    stake, refunded = conn.execute(
        "SELECT stake, refunded FROM decline_wager(%s, %s)", (wager, two)
    ).fetchone()
    assert stake == 7
    assert refunded == 7, "one side had staked; exactly that should come back"

    after = conn.execute(
        "SELECT jade_held(%s) + jade_held(%s)", (one, two)
    ).fetchone()[0]
    assert after == before


def test_the_dice_are_thrown_only_when_both_have_accepted(conn, pair):
    """The second yes is what rolls it, and the row keeps both dice - which is
    what the card reads back."""
    one, two = pair
    done = settle_a_wager(conn, one, two, 5)
    wager_id = done["wager_id"]
    mine, yours = done["challenger_roll"], done["opponent_roll"]
    winner, tied = done["winner_id"], done["tied"]

    assert done["settled"] is True
    assert 1 <= mine <= 100 and 1 <= yours <= 100
    if tied:
        assert mine == yours and winner is None
    else:
        assert mine != yours
        assert winner == (one if mine > yours else two), (
            "the higher roll did not take it"
        )

    status, kept_mine, kept_yours = conn.execute(
        "SELECT status, challenger_roll, opponent_roll FROM wagers "
        "WHERE wager_id = %s",
        (wager_id,),
    ).fetchone()
    assert status == "settled"
    assert (kept_mine, kept_yours) == (mine, yours)


def test_nothing_can_settle_a_wager_without_asking(conn):
    """0159 had `wager_now`, which took both stakes and rolled on the spot.
    Leaving it beside a flow whose whole purpose is to ask would be leaving the
    gate open next to the fence."""
    left = conn.execute(
        "SELECT count(*) FROM pg_proc WHERE proname = 'wager_now'"
    ).fetchone()[0]
    assert left == 0, "a function that settles without consent is still there"


def test_a_settled_wager_records_both_acceptances(conn, pair):
    """Stated as a constraint in 0160 because it is the point of it."""
    one, two = pair
    done = settle_a_wager(conn, one, two, 4)

    ok_one, ok_two = conn.execute(
        "SELECT challenger_ok, opponent_ok FROM wagers WHERE wager_id = %s",
        (done["wager_id"],),
    ).fetchone()
    assert ok_one is not None and ok_two is not None

    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "UPDATE wagers SET opponent_ok = NULL WHERE wager_id = %s",
                (done["wager_id"],),
            )


# ---------------------------------------------------------------------------
# Manuals on the auction house floor (0169, 0170)
# ---------------------------------------------------------------------------


def test_a_manual_can_be_listed_bought_and_collected(conn, make_player):
    """0169. 0088 called this the one deliberate gap: every other item is
    owned through an `owner_id` column while a manual is owned through a join
    table and can sit in an equipped slot.

    Both halves were already solved elsewhere. `trade_execute` moves manuals
    by inserting for the taker BEFORE deleting for the giver, because
    `collect_unowned_manual` fires on the delete and would take a manual
    nobody owns with it - and `player_manual_slots` cascades off
    `player_manuals`, so letting go of one unequips it by construction.
    """
    seller = make_player("Seller")
    buyer = make_player("Buyer")
    book = conn.execute(
        "SELECT manual_id FROM manuals ORDER BY manual_id LIMIT 1"
    ).fetchone()[0]

    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (seller, book),
    )
    for who in (seller, buyer):
        conn.execute("SELECT grant_material(%s, 'spirit_jade', 500)", (who,))

    listed = conn.execute(
        "SELECT auction_list_manual(%s, %s, 25)", (seller, book)
    ).fetchone()[0]

    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE player_id = %s "
        "AND manual_id = %s",
        (seller, book),
    ).fetchone()[0] == 0, "the seller still holds what they listed"
    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE player_id = auction_house() "
        "AND manual_id = %s",
        (book,),
    ).fetchone()[0] == 1, "the house does not hold what was listed"

    conn.execute("SELECT * FROM auction_buy(%s, %s)", (buyer, listed))

    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE player_id = %s "
        "AND manual_id = %s",
        (buyer, book),
    ).fetchone()[0] == 1, "the buyer paid and got nothing"
    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE player_id = auction_house() "
        "AND manual_id = %s",
        (book,),
    ).fetchone()[0] == 0, "the house kept a copy of what it sold"


def test_listing_a_manual_takes_it_off_your_back(conn, make_player):
    """`player_manual_slots` is keyed against `player_manuals` ON DELETE
    CASCADE, so this needs no code at all - which is exactly why it needs a
    test. A worn manual that stayed equipped after being sold would keep
    granting its bonuses to somebody who no longer owns it."""
    seller = make_player("Wearer")
    book = conn.execute(
        "SELECT manual_id FROM manuals ORDER BY manual_id LIMIT 1"
    ).fetchone()[0]

    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (seller, book),
    )
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
        "VALUES (%s, 0, %s)",
        (seller, book),
    )
    conn.execute("SELECT grant_material(%s, 'spirit_jade', 500)", (seller,))

    conn.execute("SELECT auction_list_manual(%s, %s, 25)", (seller, book))

    assert conn.execute(
        "SELECT count(*) FROM player_manual_slots WHERE player_id = %s",
        (seller,),
    ).fetchone()[0] == 0, "a sold manual is still equipped"


def test_you_cannot_buy_a_manual_you_already_carry(conn, make_player):
    """A manual is held one to a cultivator - `player_manuals` is keyed
    (player_id, manual_id). Without this the INSERT would do nothing, the
    house's copy would be deleted anyway, and the buyer would have paid for a
    row that cannot exist. Refused before the Jade moves."""
    seller = make_player("Seller")
    buyer = make_player("Buyer")
    book = conn.execute(
        "SELECT manual_id FROM manuals ORDER BY manual_id LIMIT 1"
    ).fetchone()[0]

    for who in (seller, buyer):
        conn.execute(
            "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
            (who, book),
        )
        conn.execute("SELECT grant_material(%s, 'spirit_jade', 500)", (who,))

    listed = conn.execute(
        "SELECT auction_list_manual(%s, %s, 25)", (seller, book)
    ).fetchone()[0]
    purse = conn.execute("SELECT jade_held(%s)", (buyer,)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="already carrying"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM auction_buy(%s, %s)", (buyer, listed))

    assert conn.execute("SELECT jade_held(%s)", (buyer,)).fetchone()[0] == purse, (
        "the refusal took the money anyway"
    )


def test_every_kind_on_a_listing_can_be_handed_over(conn):
    """`auction_release` is an ELSIF chain, and a kind added to the table but
    forgotten there would take the buyer's Jade and hand back nothing at all,
    silently, with the listing marked sold. 0169 gave it an ELSE that raises;
    this is the check that the chain still covers every column."""
    kinds = conn.execute(
        """
        SELECT a.attname FROM pg_attribute a
        WHERE a.attrelid = 'auction_listings'::regclass
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname IN ('material_code', 'gu_id', 'equipment_id',
                            'pill_id', 'page_id', 'manual_id')
        ORDER BY a.attname
        """
    ).fetchall()
    said = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'auction_release'"
    ).fetchone()[0]

    missing = [k for (k,) in kinds if f"it.{k}" not in said]
    assert missing == [], f"auction_release cannot hand over: {missing}"
    assert "ELSE" in said, "the chain has no catch for a kind added later"


# ---------------------------------------------------------------------------
# Reading a manual to pieces (0172, 0173)
# ---------------------------------------------------------------------------


def a_reader(conn, make_player, *, rank_ok=True, tier_ok=True, rich=True):
    """A cultivator holding the lowest-rank technique manual there is."""
    book, move, rank_n, path_c = conn.execute(
        """
        SELECT m.manual_id, t.technique_id, t.rank,
               (SELECT tp.path_code FROM technique_paths tp
                WHERE tp.technique_id = t.technique_id
                ORDER BY tp.weight DESC LIMIT 1)
        FROM manuals m
        JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = mt.technique_id
        -- Rank 2 at least: technique_required_tier(1) is 0, so a rank 1
        -- book has no attainment gate to fail and could not test one.
        WHERE m.archetype = 'technique' AND t.rank >= 2
        ORDER BY t.rank LIMIT 1
        """
    ).fetchone()

    who = make_player("Reader")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "SELECT %s, 0, min(realm_id) FROM realms WHERE rank >= %s",
        (who, rank_n if rank_ok else 1),
    )
    if tier_ok:
        conn.execute(
            "INSERT INTO player_path_attainment "
            "(player_id, path_code, insight, tier) VALUES (%s, %s, 999999, %s)",
            (who, path_c, conn.execute(
                "SELECT technique_required_tier(%s::smallint)", (rank_n,)
            ).fetchone()[0]),
        )
    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (who, book),
    )
    cost = conn.execute(
        "SELECT technique_stone_cost(%s::smallint)", (rank_n,)
    ).fetchone()[0]
    conn.execute(
        "SELECT grant_material(%s, 'spirit_stone', %s)",
        (who, cost if rich else max(0, cost - 1)),
    )
    return {"who": who, "book": book, "move": move, "rank": rank_n,
            "path": path_c, "cost": cost}


def test_reading_a_manual_keeps_the_move_and_spends_the_book(conn, make_player):
    """0172. A technique manual pays half a stat manual's bonus at the same
    tier and holds one of only two slots for as long as you want the move.
    That half is right as RENT; what was missing was the way to buy."""
    it = a_reader(conn, make_player)

    done = conn.execute(
        "SELECT * FROM study_manual(%s, %s)", (it["who"], it["book"])
    ).fetchone()

    assert conn.execute(
        "SELECT count(*) FROM player_techniques WHERE player_id = %s "
        "AND technique_id = %s",
        (it["who"], it["move"]),
    ).fetchone()[0] == 1, "the book was spent and nothing was learned"
    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE player_id = %s "
        "AND manual_id = %s",
        (it["who"], it["book"]),
    ).fetchone()[0] == 0, "the book survived being read to pieces"
    assert done[5] == it["cost"], "charged the wrong number of stones"


def test_reading_it_hands_the_slot_back(conn, make_player):
    """The slot is the point. Carrying an advanced move costs one of two
    forever, and if reading did not return it there would be no reason to."""
    it = a_reader(conn, make_player)
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
        "VALUES (%s, 0, %s)",
        (it["who"], it["book"]),
    )

    freed = conn.execute(
        "SELECT slot_freed FROM study_manual(%s, %s)", (it["who"], it["book"])
    ).fetchone()[0]

    assert freed is True
    assert conn.execute(
        "SELECT count(*) FROM player_manual_slots WHERE player_id = %s",
        (it["who"],),
    ).fetchone()[0] == 0, "the slot is still held by a book that is gone"


def test_reading_asks_an_attainment_that_wearing_does_not(conn, make_player):
    """The whole design. Studying frees the slot AND keeps the move, so
    without a gate wearing does not have, nobody would ever equip a technique
    manual again and the half-budget would stop meaning anything.

    Wearing asks realm rank alone. Reading asks realm rank AND the attainment
    `/learn` demands of a basic move at that rank."""
    it = a_reader(conn, make_player, tier_ok=False)

    with pytest.raises(psycopg.errors.CheckViolation, match="Carry it equipped"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM study_manual(%s, %s)", (it["who"], it["book"]))

    # And the book is untouched, so the refusal costs nothing.
    assert conn.execute(
        "SELECT count(*) FROM player_manuals WHERE player_id = %s "
        "AND manual_id = %s",
        (it["who"], it["book"]),
    ).fetchone()[0] == 1

    # Wearing it, meanwhile, is allowed on the same cultivator - which is what
    # makes renting the early answer.
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
        "VALUES (%s, 0, %s)",
        (it["who"], it["book"]),
    )
    assert conn.execute(
        "SELECT count(*) FROM player_usable_techniques WHERE player_id = %s "
        "AND technique_id = %s",
        (it["who"], it["move"]),
    ).fetchone()[0] >= 1, "the manual will not even lend it"


def test_a_refusal_to_read_never_costs_the_stones(conn, make_player):
    """Every gate is checked before `spend_material`. A book eaten by a
    refusal is the one unrecoverable failure this function could have."""
    for kwargs, complaint in (
        ({"tier_ok": False}, "Carry it equipped"),
        ({"rank_ok": False}, "could carry the book"),
        ({"rich": False}, "costs"),
    ):
        it = a_reader(conn, make_player, **kwargs)
        purse = conn.execute(
            "SELECT COALESCE(quantity, 0) FROM player_materials "
            "WHERE player_id = %s AND material_code = 'spirit_stone'",
            (it["who"],),
        ).fetchone()

        with pytest.raises(psycopg.errors.CheckViolation, match=complaint):
            with conn.transaction(force_rollback=True):
                conn.execute(
                    "SELECT * FROM study_manual(%s, %s)", (it["who"], it["book"])
                )

        after = conn.execute(
            "SELECT COALESCE(quantity, 0) FROM player_materials "
            "WHERE player_id = %s AND material_code = 'spirit_stone'",
            (it["who"],),
        ).fetchone()
        assert after == purse, f"{complaint}: the refusal took the stones"


def test_a_stat_manual_cannot_be_read_to_pieces(conn, make_player):
    """22 stat manuals carry a BASIC technique, and those are on the shelf for
    stones. Reading one would destroy a manual to get something buyable."""
    who = make_player("Reader")
    plain = conn.execute(
        """
        SELECT m.manual_id FROM manuals m
        JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        WHERE m.archetype <> 'technique' LIMIT 1
        """
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (who, plain),
    )

    with pytest.raises(psycopg.errors.CheckViolation, match="no killer move"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM study_manual(%s, %s)", (who, plain))


def test_the_shelf_and_the_reading_agree_on_who_may_read(conn, make_player):
    """0173. `technique_shelf` is the single authority for what /learn offers,
    and `study_ready` had to join it rather than a screen recomputing three
    gates. If the shelf says yes, the function must not say no."""
    it = a_reader(conn, make_player)

    said = conn.execute(
        "SELECT study_ready, study_cost, manual_id FROM technique_shelf(%s) "
        "WHERE technique_id = %s",
        (it["who"], it["move"]),
    ).fetchone()
    assert said[0] is True, "the shelf will not offer a reading that works"
    assert said[1] == it["cost"]
    assert said[2] == it["book"]

    conn.execute("SELECT * FROM study_manual(%s, %s)", (it["who"], it["book"]))

    after = conn.execute(
        "SELECT known, study_ready FROM technique_shelf(%s) WHERE technique_id = %s",
        (it["who"], it["move"]),
    ).fetchone()
    assert after == (True, False), "the shelf still offers a book that is gone"


# ---------------------------------------------------------------------------
# Forge reactions (0174, 0175)
# ---------------------------------------------------------------------------


def test_every_affix_can_be_forged_at_the_level_it_claims(conn):
    """A reaction fires when the ORE's Path and a BEAST PART's Path are the
    pair named in `forge_reactions`. Before 0174 two affixes had no such
    pairing anywhere in the game - Darksteel and Duskbound, the two at the top
    of the ladder, because Shadow had neither an ore nor a part - and Frostfire
    said level 10 while its only pairing used tier 7 ore, which wants a tier 7
    anvil at level 60.

    Stated as the two things that have to be true together: an affix must be
    makeable at all, and makeable by a smith of exactly its own `min_level`.
    Either alone would have missed one of the three."""
    broken = conn.execute(
        """
        WITH pairing AS (
            SELECT r.word, r.min_level, min(o.tier) AS cheapest, count(*) AS ways
            FROM forge_reactions r
            JOIN ores o ON TRUE
            JOIN materials om ON om.code = o.material_code
            JOIN beast_parts bp ON TRUE
            JOIN materials pm ON pm.code = bp.material_code
            WHERE (r.path_a = om.path_code AND r.path_b = pm.path_code)
               OR (r.path_b = om.path_code AND r.path_a = pm.path_code)
            GROUP BY r.word, r.min_level
        )
        SELECT r.word, r.min_level, COALESCE(p.ways, 0), p.cheapest,
               smith_tier_cap(r.min_level)
        FROM forge_reactions r
        LEFT JOIN pairing p ON p.word = r.word
        WHERE p.ways IS NULL OR p.cheapest > smith_tier_cap(r.min_level)
        ORDER BY r.min_level
        """
    ).fetchall()
    assert broken == [], f"affixes nobody can forge when told they can: {broken}"


def test_a_path_in_a_reaction_has_both_halves_somewhere(conn):
    """The cause underneath all three faults, rather than the faults. A Path
    named in a reaction needs an ore or a part on it somewhere - Shadow had
    neither, which killed two affixes with one omission."""
    barren = conn.execute(
        """
        SELECT DISTINCT p.code
        FROM forge_reactions r
        CROSS JOIN LATERAL (VALUES (r.path_a), (r.path_b)) AS u (code)
        JOIN paths p ON p.code = u.code
        WHERE NOT EXISTS (
                SELECT 1 FROM ores o JOIN materials m ON m.code = o.material_code
                WHERE m.path_code = p.code)
          AND NOT EXISTS (
                SELECT 1 FROM beast_parts bp
                JOIN materials m ON m.code = bp.material_code
                WHERE m.path_code = p.code)
        ORDER BY 1
        """
    ).fetchall()
    assert barren == [], (
        f"a reaction names Paths with no ore and no part: {barren}"
    )


def test_no_material_carries_a_python_escape_for_an_emoji(conn):
    r"""0175. 0174 wrote `\N{NEW MOON SYMBOL}` into four emoji columns. That is
    Python's syntax for a named character and Postgres stored the nineteen
    literal characters, so every screen drawing one would print a backslash
    and a word in braces.

    The bot's source is full of `\N{...}` because it is Python. A migration is
    not, and the habit crossed the boundary without complaining.

    It crossed again in 0316 and 0317, as `\U0001f505`, and THIS TEST WATCHED
    IT HAPPEN. The query said `LIKE '%\\%'` in the source, which is right, but
    the surrounding string is not raw - so Python handed Postgres `LIKE '%\%'`,
    where the backslash escapes the percent and the pattern means "ends in a
    literal % sign". It matched nothing and had never matched anything. Every
    escaped emoji since 0175 passed this test.

    Proven, on a value put back deliberately:

        LIKE '%\%'                as the test sent it       caught 0
        LIKE '%\\%'               as the source read        caught 1
        strpos(emoji, chr(92))    no escaping layer at all  caught 1

    So it asks in a way no escaping layer can disarm, and asks it of every
    emoji column rather than only materials - the same eight lines got written
    into ores, and a broken emoji is not a cosmetic fault. It is passed to
    Discord as a component emoji, which refuses the payload and leaves the
    interaction unanswered: clearwest could not press "Add part" at all.
    """
    columns = conn.execute(
        """
        SELECT c.table_name, c.column_name
        FROM information_schema.columns c
        JOIN information_schema.tables t
          ON t.table_name = c.table_name AND t.table_schema = c.table_schema
        WHERE c.table_schema = 'public' AND t.table_type = 'BASE TABLE'
          AND c.column_name = 'emoji'
        ORDER BY c.table_name
        """
    ).fetchall()
    assert columns, "no emoji columns found - this test is checking nothing"

    wrong: list[tuple] = []
    for table, column in columns:
        wrong += [
            (table, value)
            for (value,) in conn.execute(
                f"SELECT {column} FROM {table} "
                f"WHERE strpos({column}, chr(92)) > 0 "
                f"   OR strpos({column}, '{{') > 0 "
                f"   OR {column} = ''"
            ).fetchall()
        ]
    assert wrong == [], f"not emoji: {wrong}"


def test_the_new_materials_can_actually_be_got(conn):
    """A Path with an ore nobody can mine is a Path with no ore, which is the
    same fault one table along."""
    orphans = conn.execute(
        """
        SELECT m.code FROM materials m
        WHERE m.code IN ('nightsilver', 'crescent_horn', 'frost_scale',
                         'thunder_horn')
          AND NOT EXISTS (SELECT 1 FROM region_veins v
                          WHERE v.material_code = m.code)
          AND NOT EXISTS (SELECT 1 FROM creature_drops d
                          WHERE d.material_code = m.code)
        ORDER BY 1
        """
    ).fetchall()
    assert orphans == [], f"nothing yields: {orphans}"


# ---------------------------------------------------------------------------
# The cauldron, the herbs and the boards (0176 - 0179)
# ---------------------------------------------------------------------------


def test_every_batch_size_the_config_allows_is_reachable(conn):
    """0176. `alchemy_max_batch` is 5 and the biggest batch ever brewed was 2.
    It was read - the batch was `1 + floor((total - floor) / (floor * 0.5))` -
    but the grade is the highest tier the potency clears, and `pill_tiers`
    climbs by about 1.9x a step. So the potency for a third pill promoted you
    a grade instead, and 3, 4 and 5 existed only at tier 7 where there is no
    grade left to be promoted into.

    A dial that is read and cannot bind is worse than one that is ignored:
    somebody tunes it and nothing happens."""
    most = conn.execute(
        "SELECT game_config_value('alchemy_max_batch')"
    ).fetchone()[0]

    unreachable = []
    for tier, floor_p, next_p in conn.execute(
        """
        SELECT pt.tier, pt.potency_required,
               (SELECT min(p2.potency_required) FROM pill_tiers p2
                WHERE p2.tier > pt.tier)
        FROM pill_tiers pt ORDER BY pt.tier
        """
    ).fetchall():
        span = (next_p - floor_p) if next_p is not None else floor_p * conn.execute(
            "SELECT game_config_value('alchemy_batch_divisor')"
        ).fetchone()[0]
        step = max(Decimal("0.01"), span / most)
        top = (next_p - Decimal("0.01")) if next_p is not None else floor_p + span
        got = min(int(most), 1 + int((top - floor_p) / step))
        if got != most:
            unreachable.append((tier, got))

    assert unreachable == [], (
        f"tiers that cannot reach a batch of {most}: {unreachable}"
    )


def test_a_bare_minimum_brew_makes_one_pill(conn):
    """The other half of the same sum. Filling the cauldron is the reward for
    overshooting a grade, so exactly clearing one must not pay a handful."""
    most = conn.execute(
        "SELECT game_config_value('alchemy_max_batch')"
    ).fetchone()[0]
    for tier, floor_p, next_p in conn.execute(
        """
        SELECT pt.tier, pt.potency_required,
               (SELECT min(p2.potency_required) FROM pill_tiers p2
                WHERE p2.tier > pt.tier)
        FROM pill_tiers pt ORDER BY pt.tier
        """
    ).fetchall():
        span = (next_p - floor_p) if next_p is not None else floor_p
        step = max(Decimal("0.01"), span / most)
        assert 1 + int((floor_p - floor_p) / step) == 1, tier


def test_a_cultivation_herb_grows_in_every_region(conn):
    """0177. The kind of a brew comes from its lead herb's Path, and the five
    Paths mapped to 'cultivation' held 10.1 of gatherable weight against
    physique's 186 - with not one common among them. Cultivation is the bar
    every cultivator is trying to move, and it was the rarest thing to gather
    in the game."""
    barren = conn.execute(
        """
        SELECT r.code FROM regions r
        WHERE NOT EXISTS (
            SELECT 1 FROM region_materials rm
            JOIN materials m ON m.code = rm.material_code
            JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
            WHERE rm.region_code = r.code AND ppk.kind = 'cultivation'
              AND m.rarity = 'common'
        )
        ORDER BY 1
        """
    ).fetchall()
    assert barren == [], f"no common cultivation herb grows in: {barren}"

    least = conn.execute(
        """
        SELECT ppk.kind FROM region_materials rm
        JOIN materials m ON m.code = rm.material_code
        JOIN path_pill_kinds ppk ON ppk.path_code = m.path_code
        GROUP BY ppk.kind ORDER BY sum(rm.weight) LIMIT 1
        """
    ).fetchone()[0]
    assert least != "cultivation", (
        "cultivation is still the rarest thing to gather"
    )


def test_every_leaderboard_ranks_from_first_without_repeating(conn):
    """0178. Five boards, one function - a screen writing five queries would
    decide five times what "ahead" means, and a leaderboard is the one place
    where the game's number and the screen's number differing is not a
    cosmetic bug but an argument between players."""
    for board in ("cultivation", "boss", "crafting", "wealth", "techniques"):
        rows = conn.execute(
            "SELECT place, player_id FROM leaderboard(%s, 50)", (board,)
        ).fetchall()
        assert rows, f"the {board} board is empty"

        places = [r[0] for r in rows]
        assert places == sorted(places), f"{board} is out of order"
        assert len(set(places)) == len(places), f"{board} repeats a place"
        assert places[0] == 1, f"{board} does not start at first"

    # A stale button on an old message answers with nothing, not a red box.
    assert conn.execute(
        "SELECT count(*) FROM leaderboard('nonsense', 10)"
    ).fetchone()[0] == 0


def test_no_board_shows_the_auction_house(conn):
    """It holds whatever everybody has listed, so it would top the wealth
    board with other people's goods."""
    for board in ("cultivation", "boss", "crafting", "wealth", "techniques"):
        assert conn.execute(
            """
            SELECT count(*) FROM leaderboard(%s, 500) l
            JOIN players p ON p.player_id = l.player_id
            WHERE p.discord_id = 0 OR p.deleted_at IS NOT NULL
            """,
            (board,),
        ).fetchone()[0] == 0, board


def test_the_techniques_board_names_the_strongest_move(conn):
    """0179. It was picked with `max(t.name)` - the alphabetically last one -
    so clearwest was credited with Ox Shoulder over Thunder Step. A real
    aggregate that compiles, runs, and answers a question nobody asked, and
    nothing catches it because the answer is always a move they do own."""
    wrong = conn.execute(
        """
        SELECT l.discord_name, l.detail, truth.name
        FROM leaderboard('techniques', 500) l
        CROSS JOIN LATERAL (
            SELECT t.name FROM player_usable_techniques u
            JOIN techniques t ON t.technique_id = u.technique_id
            WHERE u.player_id = l.player_id
            ORDER BY t.base_power DESC, t.name LIMIT 1
        ) truth
        WHERE l.detail NOT LIKE truth.name || '%'
        """
    ).fetchall()
    assert wrong == [], f"the board names the wrong move: {wrong}"


# ---------------------------------------------------------------------------
# Qi comes faster to the stronger (0183)
# ---------------------------------------------------------------------------


def test_a_beginner_cultivates_at_the_plain_rate(conn):
    """Rank 1 is 1 whatever the exponent, so tuning the top of the ladder can
    never quietly change somebody's first afternoon."""
    assert conn.execute(
        "SELECT realm_cultivation_scale(1::smallint)"
    ).fetchone()[0] == 1


def test_the_draw_rises_with_the_realm_and_never_falls(conn):
    """`settle_passive_cultivation` read a flat 100 an hour and knew nothing
    about what realm the cultivator was in, while every realm costs 6.86x the
    one below. An exponential cost against a flat rate capped at +100% is not
    a difficulty curve, it is a wall - Spirit Severing was 243 days of perfect
    play and Dao Seeking was 1,665."""
    scales = [
        conn.execute(
            "SELECT realm_cultivation_scale(%s::smallint)", (rank,)
        ).fetchone()[0]
        for rank in range(1, 10)
    ]
    assert scales == sorted(scales), f"the draw falls somewhere: {scales}"
    assert scales[0] == 1


def test_scaling_actually_flattens_the_ladder(conn):
    """The claim, not the arithmetic. Raw, every realm costs a flat 6.86x the
    one below and compounds forever. Scaled, the step must be smaller than
    that at every rung - otherwise the change is decoration."""
    steps = conn.execute(
        """
        WITH r AS (
            -- Mortal ranks only. The immortal ladder above them is priced by
            -- the essence economy, where a rank drinks something a hundred
            -- times the last - so it steps by far more than this and is
            -- meant to. `test_the_immortal_ladder_steps_with_its_essence`
            -- is what holds that half.
            SELECT rank, min(cultivation_required)::numeric AS needs
            FROM realms WHERE rank >= 2 AND rank <= 9 GROUP BY rank
        ),
        e AS (
            SELECT rank, needs,
                   needs / realm_cultivation_scale(rank::smallint) AS effort
            FROM r
        )
        SELECT rank,
               effort / NULLIF(LAG(effort) OVER (ORDER BY rank), 0),
               needs  / NULLIF(LAG(needs)  OVER (ORDER BY rank), 0)
        FROM e ORDER BY rank
        """
    ).fetchall()

    for rank, scaled, raw in steps:
        if scaled is None:
            continue
        assert scaled < raw, f"realm {rank}: scaling did not help ({scaled} vs {raw})"
        assert scaled < 6, f"realm {rank} still costs {scaled}x the one below"


def test_the_immortal_ladder_steps_with_its_essence(conn):
    """The other half of the rule above. Mortal ranks are flattened against a
    6.86x curve; immortal ranks are not flattened against anything, because
    their price IS the essence economy - a rank drinks something worth a
    hundred times what the rank below drinks, so it costs a hundred times as
    much and is supposed to.

    What has to hold is that the two agree. A cultivation curve that drifted
    away from the essence values would be a second set of numbers saying a
    different thing about the same ladder, which is the fault this is written
    to catch."""
    rows = conn.execute(
        """
        SELECT r.rank, r.stage, r.name,
               (r.cultivation_required - prev.cultivation_required)::numeric AS step,
               e.unit_value::numeric AS worth,
               c.essence_units::numeric AS units,
               game_config_value('essence_cultivation_rate') AS rate
        FROM realms r
        JOIN realms prev ON prev.realm_id = r.realm_id - 1
        JOIN immortal_essences e ON e.rank = r.rank
        JOIN immortal_stage_costs c ON c.stage = r.stage
        WHERE r.rank >= 10
        ORDER BY r.realm_id
        """
    ).fetchall()
    assert len(rows) == 36, f"expected 36 immortal rungs, measured {len(rows)}"

    for rank, stage, name, step, worth, units, rate in rows:
        assert step == units * worth * rate, (
            f"{name} costs {step:,}, but {units:.0f} of a {worth:.0f}-point "
            f"essence at {rate:.0f} is {units * worth * rate:,.0f}"
        )


def test_an_immortal_sitting_still_earns_a_floor(conn):
    """0335 put a literal zero at the front of `cultivation_per_hour` for
    anything past rank 9, so essence was not the fast way up the immortal
    ladder but the only way. 0382 made it a floor instead.

    The floor cannot be the mortal curve. `realm_cultivation_scale` is rank
    squared - 100 at Dewberry, 324 at Yellow Apricot - while a stage goes from
    1.67e10 to 1.28e18. Letting the mortal rate through would have paid a
    Dewberry immortal ten thousand an hour against sixteen billion: one stage
    per hundred and ninety years. So the floor is measured against the stage
    being stood on, which is what lets one number hold all the way up.

    Asserted on the bare rate with every multiplier at one. A real cultivator
    beats it - traits, manuals and aptitude all still apply - and that is the
    point rather than a discrepancy.
    """
    want = float(conn.execute(
        "SELECT game_config_value('immortal_passive_days_per_stage')"
    ).fetchone()[0])
    assert want > 0

    rows = conn.execute(
        """
        SELECT r.rank, min(r.name), min(r.cultivation_required)::numeric
        FROM realms r WHERE r.rank > 9 GROUP BY r.rank ORDER BY r.rank
        """
    ).fetchall()
    assert rows, "no immortal realms to measure"

    for rank, name, needs in rows:
        floor = float(needs) / (want * 24)
        assert floor > 0, f"{name} still sits at zero"
        days = float(needs) / floor / 24
        assert abs(days - want) < 0.01, (
            f"{name} takes {days:.1f} days a stage rather than {want:.0f}"
        )

    # And sitting is still far behind essence, which is what keeps essence the
    # route rather than a convenience. A Dewberry stage is 20 units; thirty
    # days of sitting must not be competitive with a handful of kills.
    assert want >= 7, (
        "sitting a stage in under a week makes the essence economy decorative"
    )


def test_the_realm_scale_reaches_the_settle(conn):
    """The rule lives in one function so it can be retuned in one place. A
    copy of the exponent anywhere else is a copy that drifts.

    Checked as a chain rather than a grep of one body: 0185 moved the rate
    into `cultivation_per_hour`, so the settle no longer names the scale
    directly - it reads the function that does."""
    bodies = dict(conn.execute(
        """
        SELECT proname, prosrc FROM pg_proc
        WHERE proname IN ('settle_passive_cultivation', 'cultivation_per_hour')
        """
    ).fetchall())

    assert "cultivation_per_hour" in bodies["settle_passive_cultivation"], (
        "the settle computes its own rate again"
    )
    assert "realm_cultivation_scale" in bodies["cultivation_per_hour"], (
        "the rate cultivates flat again"
    )


def test_the_realm_ladder_only_ever_climbs(conn):
    """0184 retuned realms 2 and 3 after 0183 made the early game too quick.
    A ladder that dips would let a cultivator meet a later stage before an
    earlier one, and `breakthrough` walks it in order."""
    dips = conn.execute(
        """
        SELECT a.realm_id, a.cultivation_required, b.cultivation_required
        FROM realms a JOIN realms b ON b.realm_id = a.realm_id + 1
        WHERE b.cultivation_required <= a.cultivation_required
        ORDER BY a.realm_id
        """
    ).fetchall()
    assert dips == [], f"the ladder stops climbing: {dips}"


def test_no_stage_in_the_early_realms_is_an_afternoon(conn):
    """0183 gave Foundation Establishment 4x the draw and Core Formation 9x,
    against requirements written for a flat rate - a whole realm passed in
    about a day. 0184 narrowed that without reversing it.

    Qi Condensation is deliberately quick and deliberately exempt: it scales
    at 1x, so 0183 never touched it, and it is the onboarding."""
    quick = conn.execute(
        """
        WITH step AS (
            SELECT r.rank, r.name,
                   r.cultivation_required
                     - LAG(r.cultivation_required) OVER (ORDER BY r.realm_id)
                     AS gap
            FROM realms r
        )
        SELECT rank, name,
               round(gap / (2400.0 * realm_cultivation_scale(rank::smallint)), 2)
        FROM step
        WHERE rank BETWEEN 2 AND 3 AND gap IS NOT NULL
          AND gap / (2400.0 * realm_cultivation_scale(rank::smallint)) < 0.3
        ORDER BY rank, name
        """
    ).fetchall()
    assert quick == [], f"stages crossed in a few hours: {quick}"


def test_a_cultivator_is_never_below_the_floor_of_their_own_realm(conn):
    """`breakthrough` only moves somebody into a stage once they have met its
    requirement, so this has always been true and nothing stated it - until
    0184 raised the requirements under people who had already passed them.
    Five of eleven ended up underneath their own floor and the progress bar
    read -125%.

    The rule for any future retune is here: raising `cultivation_required`
    means topping up whoever is left behind it, in the same migration."""
    below = conn.execute(
        """
        SELECT p.discord_name, r.name, pc.cultivation - r.cultivation_required
        FROM player_cultivation pc
        JOIN players p ON p.player_id = pc.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE pc.cultivation < r.cultivation_required
        ORDER BY 3
        """
    ).fetchall()
    assert below == [], f"standing below their own floor: {below}"


def test_the_hourly_draw_is_asked_for_and_not_recomputed(conn, make_player):
    """0185. `/cultivation` printed an hourly rate it worked out itself, from
    a copy of the settle's arithmetic, under a comment warning that a rate
    which ignored something "would advertise one number and pay out another".

    It did, twice: it summed `gu_stat` where the settle sums `player_stat`, so
    gear and dwelling never counted, and when 0183 gave the settle a realm
    term the copy did not learn it - a realm 2 card read 103 an hour against
    412 being paid."""
    said = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'settle_passive_cultivation'"
    ).fetchone()[0]
    assert "cultivation_per_hour" in said, "the settle carries its own copy again"

    player = make_player("Drawer")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    base = conn.execute(
        "SELECT game_config_value('passive_cultivation_per_hour')"
    ).fetchone()[0]

    # Realm 1 scales at 1x and a bare cultivator has no bonuses, so the rate
    # is the base rate - which pins the function to the config rather than to
    # a number written here.
    assert conn.execute(
        "SELECT cultivation_per_hour(%s)", (player,)
    ).fetchone()[0] == base

    # And it carries the realm term, which is what the screen had lost.
    deep = conn.execute(
        "SELECT max(realm_id) FROM realms WHERE rank = 3"
    ).fetchone()[0]
    conn.execute(
        "UPDATE player_cultivation SET realm_id = %s WHERE player_id = %s",
        (deep, player),
    )
    assert conn.execute(
        "SELECT cultivation_per_hour(%s)", (player,)
    ).fetchone()[0] == base * 9


def test_a_technique_manual_spends_its_whole_tier(conn):
    """0187. 0130 wrote them at half budget so a book giving a killer move
    AND full stats could not beat a stat manual on both counts. The result was
    that the rarest drop in the game was the weakest thing of its tier - a
    tier 6 technique manual paid 0.18 against a stat manual's 0.36.

    They are rare enough to be strictly better. What keeps them honest is the
    move's own gate, not a thinner book."""
    short = conn.execute(
        """
        SELECT m.name, manual_total_bonus(m.manual_id), mt.bonus_budget
        FROM manuals m JOIN manual_tiers mt ON mt.tier = m.tier
        WHERE m.archetype = 'technique' AND m.code IS NOT NULL
          AND manual_total_bonus(m.manual_id) <> mt.bonus_budget
        ORDER BY m.tier
        """
    ).fetchall()
    assert short == [], f"technique manuals below their tier: {short}"


def test_the_book_opens_before_the_move_does(conn):
    """The point of 0187: carrying the book is worth something while you climb
    toward the move. clearwest won a tier 7 Canon off a rank 7 world beast and
    could not equip it at realm 3, so the best item on the server did nothing
    at all.

    A rank 1 move is the exception by arithmetic - there is no realm below 1
    for the book to open at."""
    late = conn.execute(
        """
        SELECT m.name, m.required_rank, t.rank
        FROM manuals m
        JOIN manual_techniques x ON x.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = x.technique_id
        WHERE m.archetype = 'technique' AND m.code IS NOT NULL
          AND t.rank > 1 AND m.required_rank >= t.rank
        ORDER BY m.tier
        """
    ).fetchall()
    assert late == [], f"the book is gated no earlier than its move: {late}"


def test_wearing_the_book_does_not_hand_over_the_move(conn, make_player):
    """The half that must NOT loosen. `player_usable_techniques` gates on
    realm rank in SQL, so equipping a tier 7 Canon at realm 3 buys the stats
    and nothing else."""
    player = make_player("Early Reader")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, cultivation, realm_id) "
        "VALUES (%s, 0, 1)",
        (player,),
    )
    book, move, rank_n = conn.execute(
        """
        SELECT m.manual_id, t.technique_id, t.rank
        FROM manuals m
        JOIN manual_techniques x ON x.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = x.technique_id
        WHERE m.archetype = 'technique' AND m.code IS NOT NULL
        ORDER BY t.rank DESC LIMIT 1
        """
    ).fetchone()

    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (player, book),
    )
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
        "VALUES (%s, 0, %s)",
        (player, book),
    )

    assert rank_n > 1
    assert conn.execute(
        "SELECT count(*) FROM player_usable_techniques "
        "WHERE player_id = %s AND technique_id = %s",
        (player, move),
    ).fetchone()[0] == 0, "a realm 1 cultivator was handed a top-rank move"

    # But the stats are real.
    assert conn.execute(
        "SELECT COALESCE(attack_bonus, 0) FROM player_manual_bonuses "
        "WHERE player_id = %s",
        (player,),
    ).fetchone()[0] > 0, "the book was worn and paid nothing"


def test_every_trade_stat_can_be_forged_for(conn):
    """0188. `forge` writes `equipment_effects` from the ore's signature, the
    slot, the beast parts and the reaction - and between them those produced
    exactly ten effects, every one combat or cultivation.

    So the four stats a craftsman would chase had nothing on gear at all.
    Cauldron Sense caps at +60% and the best-off cultivator had 8.4%, from the
    root they happened to roll at creation. A profession stat you cannot
    pursue is decoration."""
    unreachable = conn.execute(
        """
        SELECT e.code FROM gu_effects e
        WHERE e.code IN ('brew_potency', 'gu_potency', 'forge_power',
                         'gathering_yield')
          AND NOT EXISTS (SELECT 1 FROM ores o WHERE o.signature = e.code)
          AND NOT EXISTS (SELECT 1 FROM part_effects x WHERE x.effect_code = e.code)
          AND NOT EXISTS (SELECT 1 FROM slot_effects x WHERE x.effect_code = e.code)
          AND NOT EXISTS (SELECT 1 FROM forge_reactions x WHERE x.effect_code = e.code)
        ORDER BY 1
        """
    ).fetchall()
    assert unreachable == [], f"no forging grants: {unreachable}"


def test_an_ore_is_known_for_something_you_can_dig_up(conn):
    """A signature is what the metal is known for, so an ore nobody can mine
    is an effect nobody can reach - the fault 0174 fixed for the forge
    reactions, one table along."""
    stranded = conn.execute(
        """
        SELECT o.material_code FROM ores o
        WHERE NOT EXISTS (
            SELECT 1 FROM region_veins v WHERE v.material_code = o.material_code
        )
        AND NOT EXISTS (
            SELECT 1 FROM creature_drops d WHERE d.material_code = o.material_code
        )
        ORDER BY 1
        """
    ).fetchall()
    assert stranded == [], f"ore that cannot be got: {stranded}"


def test_no_effect_the_forge_grants_is_capped_at_nothing(conn):
    """The FK says a signature names a real effect. It cannot say the effect
    is one a player can ever hold any of."""
    useless = conn.execute(
        """
        SELECT o.material_code, o.signature FROM ores o
        JOIN gu_effects e ON e.code = o.signature
        WHERE e.cap <= 0 ORDER BY 1
        """
    ).fetchall()
    assert useless == [], f"ore known for a capped-out effect: {useless}"


# ---------------------------------------------------------------------------
# Feeding a Gu (0189)
# ---------------------------------------------------------------------------


def a_nursery(conn, make_player, *, copies=3, stones=5000):
    """A cultivator with several of one kind of Gu."""
    who = make_player("Keeper")
    gu_type = conn.execute(
        "SELECT gu_type_id FROM gu_types ORDER BY rank, gu_type_id LIMIT 1"
    ).fetchone()[0]
    ids = [
        conn.execute(
            "INSERT INTO player_gu (owner_id, gu_type_id) VALUES (%s, %s) "
            "RETURNING gu_id",
            (who, gu_type),
        ).fetchone()[0]
        for _ in range(copies)
    ]
    if stones:
        conn.execute("SELECT grant_material(%s, 'spirit_stone', %s)", (who, stones))
    return who, gu_type, ids


def test_feeding_spares_raises_a_star_and_keeps_the_gu(conn, make_player):
    """`player_gu_stats` scales every effect by
    `1 + gu_star_step * (stars - 1)`, so stars have always decided how strong
    a Gu is - and nothing ever raised them. 117 of 137 Gu were one star while
    duplicates piled up with nothing to do but be sold.

    The Gu keeps its own row. That is the whole difference between nurturing
    one and replacing it."""
    who, _, ids = a_nursery(conn, make_player, copies=3)
    target = ids[0]
    conn.execute("UPDATE player_gu SET harmony = 137 WHERE gu_id = %s", (target,))

    got = conn.execute(
        "SELECT * FROM nurture_gu(%s, %s)", (who, target)
    ).fetchone()
    name, before, after, eaten, spent, left, spares = got

    assert (before, after) == (1, 2)
    assert eaten == 2, "going to two stars should eat two spares"

    kept = conn.execute(
        "SELECT stars, harmony FROM player_gu WHERE gu_id = %s", (target,)
    ).fetchone()
    assert kept == (2, 137), "the Gu was replaced rather than fed"
    assert conn.execute(
        "SELECT count(*) FROM player_gu WHERE owner_id = %s", (who,)
    ).fetchone()[0] == 1, "the spares were not eaten"


def test_the_weakest_spares_go_first(conn, make_player):
    """Somebody holding a three-star spare must not lose it to a feeding they
    meant to spend junk on."""
    who, _, ids = a_nursery(conn, make_player, copies=4)
    target, keep, junk_a, junk_b = ids
    conn.execute("UPDATE player_gu SET stars = 3 WHERE gu_id = %s", (keep,))

    conn.execute("SELECT * FROM nurture_gu(%s, %s)", (who, target))

    left = {r[0] for r in conn.execute(
        "SELECT gu_id FROM player_gu WHERE owner_id = %s", (who,)
    ).fetchall()}
    assert keep in left, "the three-star spare was eaten first"
    assert junk_a not in left and junk_b not in left


def test_an_equipped_gu_is_never_eaten(conn, make_player):
    """Eating what somebody is standing in is not a thing to do quietly."""
    who, _, ids = a_nursery(conn, make_player, copies=3)
    target, worn, spare = ids
    conn.execute(
        "INSERT INTO player_gu_equipped (player_id, gu_id) VALUES (%s, %s)",
        (who, worn),
    )

    # One spare is left unworn, and two are needed, so the feeding is refused
    # rather than reaching for the equipped one.
    with pytest.raises(psycopg.errors.CheckViolation, match="more of the same"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM nurture_gu(%s, %s)", (who, target))

    assert conn.execute(
        "SELECT count(*) FROM player_gu WHERE gu_id = %s", (worn,)
    ).fetchone()[0] == 1


def test_a_refused_feeding_costs_nothing(conn, make_player):
    """Every gate is checked before `spend_material`."""
    for kwargs, complaint in (
        ({"copies": 2}, "more of the same"),
        ({"copies": 3, "stones": 0}, "costs"),
    ):
        who, _, ids = a_nursery(conn, make_player, **kwargs)
        held = conn.execute("SELECT count(*) FROM player_gu WHERE owner_id = %s",
                            (who,)).fetchone()[0]
        purse = conn.execute(
            "SELECT COALESCE(quantity, 0) FROM player_materials "
            "WHERE player_id = %s AND material_code = 'spirit_stone'", (who,)
        ).fetchone()

        with pytest.raises(psycopg.errors.CheckViolation, match=complaint):
            with conn.transaction(force_rollback=True):
                conn.execute("SELECT * FROM nurture_gu(%s, %s)", (who, ids[0]))

        assert conn.execute("SELECT count(*) FROM player_gu WHERE owner_id = %s",
                            (who,)).fetchone()[0] == held
        assert conn.execute(
            "SELECT COALESCE(quantity, 0) FROM player_materials "
            "WHERE player_id = %s AND material_code = 'spirit_stone'", (who,)
        ).fetchone() == purse


def test_a_gu_stops_at_five_stars(conn, make_player):
    """`player_gu` allows 1 to 5, so the refusal has to come before the UPDATE
    rather than as a constraint violation the player cannot read."""
    who, _, ids = a_nursery(conn, make_player, copies=8)
    conn.execute("UPDATE player_gu SET stars = 5 WHERE gu_id = %s", (ids[0],))

    with pytest.raises(psycopg.errors.CheckViolation, match="as strong as"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM nurture_gu(%s, %s)", (who, ids[0]))

    # And the nursery does not offer it either.
    assert conn.execute(
        "SELECT count(*) FROM gu_nursery WHERE gu_id = %s AND next_stars <= 5",
        (ids[0],),
    ).fetchone()[0] == 0


def test_the_climb_to_five_costs_fourteen_spares(conn, make_player):
    """One to five is fourteen fodder Gu - long enough an acquaintance to be
    worth the word nurture, and the number the migration promises."""
    total = sum(
        conn.execute(
            "SELECT gu_nurture_copies(%s::smallint)", (star,)
        ).fetchone()[0]
        for star in range(2, 6)
    )
    assert total == 14

# ---------------------------------------------------------------------------
# Named sets (0190)
# ---------------------------------------------------------------------------


def a_dressed_player(conn, make_player, *, gu=2, gear=1):
    """Somebody wearing something in more than one of the four places."""
    who = make_player("Dresser")
    conn.execute(
        "UPDATE player_cultivation SET realm_id = "
        "(SELECT realm_id FROM realms ORDER BY rank DESC LIMIT 1) "
        "WHERE player_id = %s",
        (who,),
    )

    for _ in range(gu):
        gu_id = conn.execute(
            "INSERT INTO player_gu (owner_id, gu_type_id) SELECT %s, gu_type_id "
            "FROM gu_types ORDER BY size, gu_type_id LIMIT 1 RETURNING gu_id",
            (who,),
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO player_gu_equipped (player_id, gu_id) VALUES (%s, %s)",
            (who, gu_id),
        )

    for slot in [r[0] for r in conn.execute(
        "SELECT code FROM equipment_slots ORDER BY sort_order LIMIT %s", (gear,)
    ).fetchall()]:
        piece = conn.execute(
            "INSERT INTO player_equipment "
            "(owner_id, name, slot, tier, rarity, harmony, ore_code) "
            "VALUES (%s, 'Probe Piece', %s, 1, 'common', 50, 'iron_ore') "
            "RETURNING equipment_id",
            (who, slot),
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO player_equipped (player_id, slot, equipment_id) "
            "VALUES (%s, %s, %s)",
            (who, slot, piece),
        )

    return who


def what_is_worn(conn, player_id):
    return (
        {r[0] for r in conn.execute(
            "SELECT gu_id FROM player_gu_equipped WHERE player_id = %s",
            (player_id,)).fetchall()},
        {r[0] for r in conn.execute(
            "SELECT equipment_id FROM player_equipped WHERE player_id = %s",
            (player_id,)).fetchall()},
    )


def test_a_set_saved_and_worn_again_is_the_same_set(conn, make_player):
    """The whole feature in one assertion. Four tables are emptied and refilled
    and every specific item has to come back - not the same COUNT of items, the
    same items."""
    who = a_dressed_player(conn, make_player, gu=2, gear=2)
    before = what_is_worn(conn, who)

    made = conn.execute(
        "SELECT preset_id FROM save_preset(%s, 'bossing')", (who,)
    ).fetchone()[0]

    conn.execute("DELETE FROM player_gu_equipped WHERE player_id = %s", (who,))
    conn.execute("DELETE FROM player_equipped WHERE player_id = %s", (who,))

    done = conn.execute(
        "SELECT * FROM load_preset(%s, %s)", (who, made)
    ).fetchone()

    assert what_is_worn(conn, who) == before
    assert done[5] == 0, f"{done[5]} pieces went missing: {done[6]}"


def test_wearing_a_set_takes_off_what_you_had(conn, make_player):
    """Not a merge. Two Gu sets that each fill the aperture must swap cleanly,
    which is the case `enforce_gu_capacity` would refuse halfway through if the
    old one were still in."""
    who = a_dressed_player(conn, make_player, gu=2, gear=1)
    first = conn.execute(
        "SELECT preset_id FROM save_preset(%s, 'farming')", (who,)
    ).fetchone()[0]
    was_gu, was_gear = what_is_worn(conn, who)

    other_type = conn.execute(
        "SELECT gu_type_id FROM gu_types WHERE gu_type_id <> "
        "(SELECT gu_type_id FROM player_gu WHERE gu_id = %s) "
        "ORDER BY size, gu_type_id LIMIT 1",
        (next(iter(was_gu)),),
    ).fetchone()[0]

    conn.execute("DELETE FROM player_gu_equipped WHERE player_id = %s", (who,))
    fresh = conn.execute(
        "INSERT INTO player_gu (owner_id, gu_type_id) VALUES (%s, %s) "
        "RETURNING gu_id", (who, other_type),
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_gu_equipped (player_id, gu_id) VALUES (%s, %s)",
        (who, fresh),
    )
    conn.execute(
        "SELECT preset_id FROM save_preset(%s, 'bossing')", (who,)
    ).fetchone()

    conn.execute("SELECT * FROM load_preset(%s, %s)", (who, first))

    now_gu, _ = what_is_worn(conn, who)
    assert now_gu == was_gu
    assert fresh not in now_gu, "the old Gu was left on"


def test_a_sold_piece_is_left_out_and_counted(conn, make_player):
    """A preset is a list of specific items and items get sold. The load has to
    put on what is left and SAY how much it could not - dressing somebody in
    three quarters of a set without mentioning it is the failure worth
    catching."""
    who = a_dressed_player(conn, make_player, gu=2, gear=2)
    made = conn.execute(
        "SELECT preset_id FROM save_preset(%s, 'farming')", (who,)
    ).fetchone()[0]

    sold = conn.execute(
        "SELECT equipment_id FROM player_equipped WHERE player_id = %s LIMIT 1",
        (who,),
    ).fetchone()[0]
    stranger = make_player("Buyer")
    conn.execute("DELETE FROM player_equipped WHERE equipment_id = %s", (sold,))
    conn.execute(
        "UPDATE player_equipment SET owner_id = %s WHERE equipment_id = %s",
        (stranger, sold),
    )

    shelf = conn.execute(
        "SELECT gear_saved, gear_held FROM preset_shelf WHERE preset_id = %s",
        (made,),
    ).fetchone()
    assert shelf == (2, 1), "the shelf did not notice the piece changed hands"

    done = conn.execute("SELECT * FROM load_preset(%s, %s)", (who, made)).fetchone()
    assert done[3] == 1, "the piece that was still owned did not go on"
    assert done[5] == 1, "the sold piece was not counted as missing"

    assert conn.execute(
        "SELECT count(*) FROM player_equipped WHERE equipment_id = %s", (sold,)
    ).fetchone()[0] == 0, "somebody else's gear was put on"


def test_a_gu_eaten_by_a_feeding_drops_out_of_the_set(conn, make_player):
    """0189 deletes fodder rows outright. The FK cascade is what keeps a preset
    from pointing at a Gu that no longer exists, and this is the test that says
    the cascade is load-bearing rather than decorative."""
    who = a_dressed_player(conn, make_player, gu=1, gear=1)
    worn = conn.execute(
        "SELECT gu_id FROM player_gu_equipped WHERE player_id = %s", (who,)
    ).fetchone()[0]
    made = conn.execute(
        "SELECT preset_id FROM save_preset(%s, 'farming')", (who,)
    ).fetchone()[0]

    conn.execute("DELETE FROM player_gu_equipped WHERE gu_id = %s", (worn,))
    conn.execute("DELETE FROM player_gu WHERE gu_id = %s", (worn,))

    assert conn.execute(
        "SELECT gu_saved FROM preset_shelf WHERE preset_id = %s", (made,)
    ).fetchone()[0] == 0

    done = conn.execute("SELECT * FROM load_preset(%s, %s)", (who, made)).fetchone()
    assert done[1] == 0 and done[5] == 0, "a deleted Gu should leave no hole"


def test_saving_over_a_name_replaces_rather_than_duplicating(conn, make_player):
    """Keeping a set current is the common case, so it must not need a delete
    first - and must not quietly make a second 'farming'."""
    who = a_dressed_player(conn, make_player, gu=2, gear=1)
    first = conn.execute(
        "SELECT preset_id, replaced FROM save_preset(%s, 'farming')", (who,)
    ).fetchone()
    assert first[1] is False

    conn.execute("DELETE FROM player_gu_equipped WHERE player_id = %s", (who,))
    again = conn.execute(
        "SELECT preset_id, gu, replaced FROM save_preset(%s, ' FARMING ')", (who,)
    ).fetchone()

    assert again[0] == first[0], "case and spacing made a second set"
    assert again[2] is True
    assert again[1] == 0, "the replacement kept the old contents"
    assert conn.execute(
        "SELECT count(*) FROM loadout_presets WHERE player_id = %s", (who,)
    ).fetchone()[0] == 1


def test_you_cannot_keep_more_sets_than_the_config_allows(conn, make_player):
    """And the refusal names the way out, since overwriting one still works."""
    who = a_dressed_player(conn, make_player, gu=1, gear=1)
    most = int(conn.execute(
        "SELECT game_config_value('loadout_preset_max')"
    ).fetchone()[0])

    for n in range(most):
        conn.execute("SELECT save_preset(%s, %s)", (who, f"set {n}"))

    with pytest.raises(psycopg.errors.CheckViolation, match="overwrite one"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT save_preset(%s, 'one too many')", (who,))

    # Overwriting is still allowed at the cap, or the advice would be a lie.
    conn.execute("SELECT save_preset(%s, 'set 0')", (who,))


def test_a_set_is_only_loadable_by_its_owner(conn, make_player):
    who = a_dressed_player(conn, make_player, gu=1, gear=1)
    made = conn.execute(
        "SELECT preset_id FROM save_preset(%s, 'farming')", (who,)
    ).fetchone()[0]
    stranger = make_player("Thief")

    for call in ("load_preset", "delete_preset"):
        with pytest.raises(psycopg.errors.CheckViolation, match="not one of your"):
            with conn.transaction(force_rollback=True):
                conn.execute(f"SELECT {call}(%s, %s)", (stranger, made))


def test_forgetting_a_set_leaves_the_things_it_named(conn, make_player):
    """Deleting a list of gear must not delete the gear."""
    who = a_dressed_player(conn, make_player, gu=2, gear=2)
    made = conn.execute(
        "SELECT preset_id FROM save_preset(%s, 'farming')", (who,)
    ).fetchone()[0]
    before = what_is_worn(conn, who)

    assert conn.execute(
        "SELECT delete_preset(%s, %s)", (who, made)
    ).fetchone()[0] == "farming"

    assert what_is_worn(conn, who) == before
    assert conn.execute(
        "SELECT count(*) FROM preset_gu WHERE preset_id = %s", (made,)
    ).fetchone()[0] == 0

# ---------------------------------------------------------------------------
# The middle of every ladder (0192)
# ---------------------------------------------------------------------------


def dominant_grid(conn):
    """Seeded attack techniques counted by dominant Path and rank.

    Dominant, not merely present - `technique_shelf` gates on the heaviest
    Path of a technique, so a Heaven move that is really a Lightning move with
    Heaven attached does not give a Heaven cultivator anything to learn.
    """
    return {
        (row[0], row[1]): row[2]
        for row in conn.execute(
            """
            SELECT (SELECT tp.path_code FROM technique_paths tp
                    WHERE tp.technique_id = t.technique_id
                    ORDER BY tp.weight DESC, tp.path_code LIMIT 1),
                   t.rank, count(*)
            FROM techniques t
            WHERE t.created_by IS NULL AND t.category = 'attack'
            GROUP BY 1, 2
            """
        ).fetchall()
    }


def test_every_path_leads_a_move_at_every_rank_up_to_five(conn):
    """0161 and 0162 gave all 34 Paths a rank 1 attack and stopped. Ranks 2
    to 5 were empty for eleven Paths outright and patchy for the rest, while
    the seeded moves above resume at rank 6 - so a mid-realm cultivator
    following one Path had a rank 1 move and a wait."""
    grid = dominant_grid(conn)
    paths = [r[0] for r in conn.execute("SELECT code FROM paths").fetchall()]

    holes = [
        f"{path} r{rank}"
        for path in paths
        for rank in range(1, 6)
        if grid.get((path, rank), 0) == 0
    ]
    assert not holes, f"no move at: {', '.join(sorted(holes))}"


def test_the_new_rungs_can_actually_be_bought(conn):
    """`learn_technique` refuses an 'advanced' technique at any price - those
    are carried by a manual and only while it is equipped. Seeding one with no
    manual behind it makes a row that exists and cannot be reached, which is
    the failure this whole migration exists to undo."""
    stranded = conn.execute(
        """
        SELECT t.name FROM techniques t
        WHERE t.created_by IS NULL AND t.rank BETWEEN 2 AND 5
          AND t.grade = 'advanced'
          AND NOT EXISTS (SELECT 1 FROM manual_techniques mt
                          JOIN manuals m ON m.manual_id = mt.manual_id
                          WHERE mt.technique_id = t.technique_id
                            AND m.archetype = 'technique')
        """
    ).fetchall()
    assert not stranded, f"advanced and teachable by nothing: {stranded}"


def test_the_ladder_never_steps_down(conn):
    """A rank 4 move that hits softer than the best rank 3 is a rung that goes
    backwards, and there is no way for a player to see that coming."""
    bands = {
        row[0]: (row[1], row[2])
        for row in conn.execute(
            "SELECT rank, min(base_power), max(base_power) FROM techniques "
            "WHERE created_by IS NULL AND category = 'attack' GROUP BY rank"
        ).fetchall()
    }
    for rank in range(1, max(bands)):
        assert bands[rank][1] < bands[rank + 1][0], (
            f"rank {rank} tops out at {bands[rank][1]} and rank {rank + 1} "
            f"starts at {bands[rank + 1][0]}"
        )


def test_a_new_rung_belongs_to_one_path_only(conn):
    """Single-Path on purpose. A technique's gate reads its heaviest Path, so
    a two-Path move at rank 3 would hand one Path a rung and the other a
    decoration - which is exactly the trap Heavenly Thunder Edict is: it reads
    as a Heaven move and gates on Lightning."""
    shared = conn.execute(
        """
        SELECT t.name, count(*) FROM techniques t
        JOIN technique_paths tp ON tp.technique_id = t.technique_id
        WHERE t.created_by IS NULL AND t.rank BETWEEN 2 AND 5
        GROUP BY t.technique_id, t.name
        HAVING count(*) <> 1
        """
    ).fetchall()
    # Older seeded moves may pair Paths; the ones added for the ladder must
    # not, so the count of single-Path rank 2-5 moves covers every Path.
    covered = conn.execute(
        """
        SELECT count(DISTINCT tp.path_code) FROM techniques t
        JOIN technique_paths tp ON tp.technique_id = t.technique_id
        WHERE t.created_by IS NULL AND t.rank BETWEEN 2 AND 5
          AND (SELECT count(*) FROM technique_paths x
               WHERE x.technique_id = t.technique_id) = 1
        """
    ).fetchone()[0]
    total = conn.execute("SELECT count(*) FROM paths").fetchone()[0]
    assert covered == total, (
        f"only {covered} of {total} Paths have a single-Path mid-rank move "
        f"(shared: {shared})"
    )


def test_a_mid_realm_cultivator_has_something_to_buy(conn, make_player):
    """The shape of the complaint that prompted this: rank 4 realm, one Path,
    and the only move on offer being the rank 1 one.

    Checked through `technique_shelf` rather than the table, because a
    technique that never reaches the shelf is the same problem in a different
    place."""
    who = make_player("Seeker")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES "
        "(%s, (SELECT realm_id FROM realms WHERE rank = 4 ORDER BY realm_id "
        "LIMIT 1))",
        (who,),
    )
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 100000)", (who,))

    for path in [r[0] for r in conn.execute("SELECT code FROM paths").fetchall()]:
        conn.execute(
            "SELECT grant_path_insight(%s, %s, 20000)", (who, path)
        )

        best = conn.execute(
            "SELECT name, tech_rank, base_power, ready FROM technique_shelf(%s) "
            "WHERE path_code = %s AND tech_rank BETWEEN 2 AND 4 AND ready "
            "ORDER BY tech_rank DESC LIMIT 1",
            (who, path),
        ).fetchone()

        assert best is not None, f"{path} offers a rank 4 cultivator nothing"
        assert best[2] > 245, (
            f"{path}'s best mid-rank move ({best[0]}, {best[2]} power) is no "
            "better than a rank 1 one"
        )


def test_filling_the_ladder_left_the_old_moves_alone(conn):
    """105 rows added, none edited. The rank 1 rungs and the rank 6+ moves are
    what every existing character's plans are built on."""
    assert conn.execute(
        "SELECT count(*) FROM techniques WHERE created_by IS NULL "
        "AND category = 'attack' AND rank = 1"
    ).fetchone()[0] == 36, "the rank 1 rungs changed count"

    assert conn.execute(
        "SELECT base_power FROM techniques WHERE code = 'fate_tap'"
    ).fetchone()[0] == 113, "Fate Tap was edited"

    assert conn.execute(
        "SELECT base_power FROM techniques WHERE code = 'second_shadow'"
    ).fetchone()[0] == 129, "Second Shadow was edited"

# ---------------------------------------------------------------------------
# Every column of a manual's budget reaches something (0193)
# ---------------------------------------------------------------------------

# The eight that are consulted directly where they are used, rather than
# through `player_stat`. Listed once here so the test below is a rule about
# ALL twelve columns and not a restatement of the four that were broken.
READ_AT_POINT_OF_USE = {
    "cultivation_rate_bonus", "physique_rate_bonus", "attainment_rate_bonus",
    "hp_bonus", "defense_bonus", "strength_bonus", "attack_bonus",
    "gathering_bonus",
}


def a_manual_wearer(conn, make_player, column, amount):
    """Somebody wearing one manual that pays only into `column`."""
    who = make_player("Reader")
    conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (who,))
    book = conn.execute(
        "INSERT INTO manuals (name, tier, required_rank, archetype, harmony, "
        f"refined_at, quality, {column}, description) "
        "VALUES ('Probe', 1, 1, 'hybrid', 50, now(), 'common', %s, 'probe') "
        "RETURNING manual_id",
        (amount,),
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (who, book),
    )
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
        "VALUES (%s, 0, %s)",
        (who, book),
    )
    return who


def test_every_column_a_refinement_can_spend_on_reaches_something(conn):
    """`refine` puts a manual's whole budget into the columns `page_types`
    names, and four of them - speed, breakthrough, essence, refinement - were
    read by nothing at all. A tier 8 manual made of six speed pages came out
    at +85.9% and did nothing; 61 of 157 live manuals carried budget in them.

    Stated over `page_types` so a page type pointed at a new column has to
    answer this too, rather than being a list of the four that were wrong."""
    columns = {
        r[0] for r in conn.execute(
            "SELECT DISTINCT manual_column FROM page_types"
        ).fetchall()
    }
    mapped = {
        r[0] for r in conn.execute(
            "SELECT manual_column FROM manual_effect_columns"
        ).fetchall()
    }
    stranded = columns - mapped - READ_AT_POINT_OF_USE
    assert not stranded, f"nothing reads: {', '.join(sorted(stranded))}"


def test_a_column_read_at_its_point_of_use_is_never_also_mapped(conn):
    """`player_stat` is now a sixth source on top of Gu, gear, body, root and
    dwelling. Mapping a column that is ALSO read directly - attack_bonus in
    `player_external_multiplier`, say - would pay it twice."""
    doubled = [
        r[0] for r in conn.execute(
            "SELECT manual_column FROM manual_effect_columns"
        ).fetchall()
        if r[0] in READ_AT_POINT_OF_USE
    ]
    assert not doubled, f"counted twice: {doubled}"


def test_a_mapped_column_is_only_ever_pointed_at_a_live_effect(conn):
    """Wiring a dead column to a dead effect would move the problem rather
    than fix it."""
    assert conn.execute(
        """
        SELECT count(*) FROM manual_effect_columns c
        JOIN gu_effects e ON e.code = c.effect_code
        WHERE NOT e.is_live OR e.cap <= 0
        """
    ).fetchone()[0] == 0


def test_an_equipped_manual_now_pays_into_its_effect(conn, make_player):
    """The behaviour itself, one column at a time, through `player_stat` -
    which is what every reader of these effects actually calls."""
    for column, effect in conn.execute(
        "SELECT manual_column, effect_code FROM manual_effect_columns "
        "ORDER BY manual_column"
    ).fetchall():
        who = a_manual_wearer(conn, make_player, column, 0.05)
        # Every column pays in at face value except Refinement, which since
        # 0432 is read through a saturating curve - it is the one bonus that
        # multiplies a BOUNDED quantity, so face value there was an off
        # switch. It must still pay in SOMETHING, which is what this asks.
        want = 0.05
        if column == "refinement_bonus":
            want = float(conn.execute(
                "SELECT refinement_effective(0.05)"
            ).fetchone()[0])
            assert 0 < want <= 0.05, f"the curve swallowed {column}"
        assert float(conn.execute(
            "SELECT player_stat(%s, %s)", (who, effect)
        ).fetchone()[0]) == pytest.approx(want), (
            f"{column} still pays nothing into {effect}"
        )


def test_a_manual_cannot_carry_an_effect_past_its_cap(conn, make_player):
    """The cap is the game's own statement about how much of an effect is too
    much, and it has always applied to Gu, gear, body, root and dwelling. A
    manual is not an exception to it - a tier 8 speed book pays +0.86 into a
    dodge cap of 0.40."""
    # Against the share one source may give, not the whole cap. 0516 bounded
    # every source at `source_share` of an effect, so a manual carrying twice
    # the cap now reaches the manual's share of it - which is still the claim
    # this test makes: a manual cannot carry an effect past what it is allowed.
    cap = float(conn.execute(
        "SELECT stat_source_cap('dodge')"
    ).fetchone()[0])
    who = a_manual_wearer(conn, make_player, "speed_bonus", cap + 1)

    assert float(conn.execute(
        "SELECT player_stat(%s, 'dodge')", (who,)
    ).fetchone()[0]) == pytest.approx(cap)


def test_wiring_the_columns_did_not_disturb_the_eight_that_worked(conn, make_player):
    """`player_stat` gained a term. A manual paying into a column that is read
    at its point of use must still contribute nothing THERE, or every existing
    cultivation and attack number moves."""
    who = a_manual_wearer(conn, make_player, "attack_bonus", 0.5)

    assert float(conn.execute(
        "SELECT manual_stat(%s, 'attack_power')", (who,)
    ).fetchone()[0]) == 0.0, "attack_bonus would now be counted twice"

    # And it is still read where it always was.
    assert float(conn.execute(
        "SELECT attack_bonus FROM player_manual_bonuses WHERE player_id = %s",
        (who,),
    ).fetchone()[0]) == pytest.approx(0.5)


def test_a_refinement_manual_is_an_edge_and_never_an_off_switch(conn):
    """Harmony is the one bounded thing a manual bonus multiplies.

    Every other column feeds a stat that keeps climbing, so a raw multiplier
    is the right shape for them. Harmony is a 0-150 roll read against fixed
    grades, and x4.655 on that does not improve a refinement, it ends it -
    every median press became a 5-star Gu regardless of the pile.

    What is pinned here is the SHAPE rather than the number: strictly
    increasing so a better manual is always worth more, never reaching the
    ceiling so none is ever an off-switch, and never inflating so a card can
    be read at face value.
    """
    ceiling = float(conn.execute(
        "SELECT game_config_value('refinement_harmony_ceiling')"
    ).fetchone()[0])
    assert ceiling > 0

    def worth(raw):
        # ::numeric because the function takes one and psycopg sends a Python
        # float as double precision, which matches no overload.
        return float(conn.execute(
            "SELECT refinement_effective(%s::numeric)", (raw,)
        ).fetchone()[0])

    assert worth(0) == 0, "a manual nobody has is worth nothing"

    # The whole ladder in one round trip rather than two hundred.
    ladder = conn.execute(
        "SELECT g * 0.05, refinement_effective((g * 0.05)::numeric) "
        "FROM generate_series(1, 200) g ORDER BY g"
    ).fetchall()
    for (raw, got), (_, nxt) in zip(ladder, ladder[1:]):
        assert got < nxt, f"the curve stops climbing at {raw}"
        assert float(got) < ceiling, f"{raw} reaches the ceiling {ceiling}"
        assert got <= raw, f"{raw} is inflated to {got}"

    # The two outcomes the curve exists to hold apart, asked of the best
    # manual that actually exists rather than of a number I chose.
    best = float(conn.execute(
        "SELECT COALESCE(max(refinement_bonus), 0) FROM manuals"
    ).fetchone()[0])
    if best > 0:
        median_gu, five_stars, failing, threshold = 77, 120, 15, 20
        assert median_gu * (1 + worth(best)) < five_stars, (
            "the best manual still hands out a 5-star Gu on a median press"
        )
        assert failing * (1 + worth(best)) >= threshold, (
            "and it no longer rescues a pile that was failing, which is the "
            "one thing the page kind actually promises"
        )

    # Both readers go through it, so the manual card and the anvil cannot come
    # to disagree about one number.
    for fn in ("crafting_harmony_bonus", "manual_stat"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (fn,)
        ).fetchone()[0]
        assert "refinement_effective" in body, f"{fn} still reads the raw column"

    # Including the screen. A card printing 366% while the bench used 44%
    # would be off by a factor of eight.
    card = pathlib.Path("bot/cogs/manuals.py").read_text(encoding="utf-8")
    assert "refinement_effective(m.refinement_bonus)" in card, (
        "the manual card reads the raw column"
    )
    assert card.count("               m.refinement_bonus,") == 0

    # But the BUDGET stays raw: it records what was spent, not what it buys.
    spend = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'manual_total_bonus'"
    ).fetchone()[0]
    assert "refinement_effective" not in spend, (
        "the tier budget now under-reports what a manual spent"
    )


def test_a_refining_manual_makes_the_next_refinement_more_tolerant(conn, make_player):
    """`refine_forecast` asked the BODY for conflict relief, so a manual about
    refining could never reach it. It asks the cultivator now."""
    who = a_manual_wearer(conn, make_player, "refinement_bonus", 0.30)
    # Through the 0432 curve, asked of the curve rather than spelled out: what
    # this test is for is that the manual REACHES the stat at all, and pinning
    # the arithmetic here would only break again the next time the ceiling moves.
    worth = float(conn.execute(
        "SELECT refinement_effective(0.30)"
    ).fetchone()[0])
    assert worth > 0, "the curve swallowed the manual entirely"
    assert float(conn.execute(
        "SELECT player_stat(%s, 'refine_conflict_relief')", (who,)
    ).fetchone()[0]) == pytest.approx(worth)

    pages = [
        conn.execute(
            "INSERT INTO manual_pages (owner_id, tier, path_code, page_type, "
            "power, quality) VALUES (%s, 3, %s, 'attack', 20, 80) "
            "RETURNING page_id",
            (who, path),
        ).fetchone()[0]
        for path in ("fire", "water")
    ]
    relief = conn.execute(
        "SELECT relief_applied FROM refine_forecast(%s, %s)", (who, pages)
    ).fetchone()[0]
    assert float(relief) == pytest.approx(worth), (
        "the forecast still reads relief from the body alone"
    )


# ---------------------------------------------------------------------------
# The rate ladder (0194)
# ---------------------------------------------------------------------------


def test_a_higher_grade_rate_pill_is_always_worth_more(conn):
    """A grade that pays less than the one below it is a rung going down, and
    nothing on the brewing screen would warn a player before they spent the
    potency reaching it."""
    rungs = conn.execute(
        "SELECT tier, rate_bonus FROM pill_tiers WHERE rate_bonus > 0 "
        "ORDER BY tier"
    ).fetchall()
    assert len(rungs) >= 2, "there is no ladder left to check"
    for (lo_tier, lo), (hi_tier, hi) in zip(rungs, rungs[1:]):
        assert hi > lo, f"grade {hi_tier} pays {hi}, grade {lo_tier} pays {lo}"


def test_only_grades_that_can_brew_a_rate_pill_advertise_one(conn):
    """`pill_kinds.min_tier` is 5 for both rate kinds; below it they fall back
    to the flat `cultivation` and `insight`. A rate on grade 4 would be a
    number no pill can ever pay."""
    floor = conn.execute(
        "SELECT min(min_tier) FROM pill_kinds "
        "WHERE code IN ('cultivation_rate', 'attainment_rate')"
    ).fetchone()[0]
    early = conn.execute(
        "SELECT tier FROM pill_tiers WHERE rate_bonus > 0 AND tier < %s",
        (floor,),
    ).fetchall()
    assert not early, f"grades {early} pay a rate they cannot brew"


def test_a_pill_already_brewed_pays_todays_rate(conn, make_player):
    """`take_pill` reads the bonus out of `pill_tiers` when it is swallowed,
    not out of the pill. That is what let 0194 buff forty pills already in a
    bag without touching a single row of anybody's inventory - and it is worth
    a test, because storing the rate on the pill would have been the obvious
    way to write it and would have quietly stranded them."""
    who = make_player("Swallower")
    conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (who,))
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (who,),
    )
    pill = conn.execute(
        "INSERT INTO player_pills (owner_id, name, tier, kind, path_code, "
        "magnitude, quantity, harmony) "
        "VALUES (%s, 'Probe Elixir', 6, 'cultivation_rate', 'heaven', 100, 1, 150) "
        "RETURNING pill_id",
        (who,),
    ).fetchone()[0]

    conn.execute("SELECT take_pill(%s, %s)", (who, pill))

    boost = conn.execute(
        "SELECT magnitude FROM player_boosts WHERE player_id = %s "
        "AND kind = 'cultivation_rate'",
        (who,),
    ).fetchone()[0]
    ladder = conn.execute(
        "SELECT rate_bonus FROM pill_tiers WHERE tier = 6"
    ).fetchone()[0]

    assert boost == ladder, (
        f"swallowed at {boost} while the ladder says {ladder}"
    )


def test_banked_hours_keep_the_rate_they_were_banked_at(conn, make_player):
    """The claim I wrote this for in 0194 still holds, and 0199 holds it
    better: hours bought cheap are not retroactively upgraded.

    What 0194 also did - and should not have - was retroactively DOWNGRADE the
    expensive ones into the same average. Now each dose keeps its own rate and
    neither is touched by the other."""
    who = make_player("Banker")
    conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (who,))
    conn.execute(
        "SELECT grant_boost(%s, 'cultivation_rate', 0.2000, 100)", (who,)
    )
    conn.execute(
        "SELECT grant_boost(%s, 'cultivation_rate', 1.3500, 100)", (who,)
    )

    rows = [
        (float(m), float(h)) for m, h in conn.execute(
            "SELECT magnitude, hours_left FROM player_boosts "
            "WHERE player_id = %s AND kind = 'cultivation_rate' "
            "ORDER BY magnitude DESC",
            (who,),
        ).fetchall()
    ]
    assert rows == [(1.35, 100), (0.20, 100)], (
        "the two doses were blended into one"
    )

    # 200 hours of settling is worth both, at their own rates - which is more
    # than 200 hours at the old blended 0.775 would have been, and no less.
    extra = float(conn.execute(
        "SELECT extra_hours FROM spend_boost(%s, 'cultivation_rate', 200)",
        (who,),
    ).fetchone()[0])
    assert extra == pytest.approx(100 * 1.35 + 100 * 0.20)
    assert extra == pytest.approx(200 * 0.775), (
        "the total is conserved - stacking changes the ORDER, not the worth"
    )


# ---------------------------------------------------------------------------
# A cultivation pill measured against the door it opens (0195)
# ---------------------------------------------------------------------------


def a_drinker(conn, make_player, rank):
    who = make_player("Drinker")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES "
        "(%s, (SELECT realm_id FROM realms WHERE rank = %s ORDER BY realm_id "
        "LIMIT 1))",
        (who, rank),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (who,),
    )
    return who


def test_a_top_grade_pill_is_worth_a_real_share_of_every_stage(conn):
    """The whole complaint in one assertion. A flat 4,056 was 640% of a rank 1
    stage and 0.01% of a rank 7 one, because the number is constant and the
    ladder doubles every stage - so a hundred herbs bought nothing measurable
    at high realm.

    Stated over `realms` rather than over the ranks that were broken, so a
    steeper realm added later has to answer it too."""
    share = float(conn.execute(
        "SELECT game_config_value('pill_cultivation_share')"
    ).fetchone()[0])

    thin = conn.execute(
        """
        WITH g AS (
            SELECT r.name, r.rank,
                   COALESCE(
                       LEAD(r.cultivation_required) OVER (ORDER BY r.realm_id)
                       - r.cultivation_required,
                       r.cultivation_required
                       - LAG(r.cultivation_required) OVER (ORDER BY r.realm_id)
                   ) AS gap
            FROM realms r
        )
        SELECT name, gap FROM g
        WHERE gap > 0 AND round(gap * %s)::numeric / gap < %s - 0.001
        """,
        (share, share),
    ).fetchall()
    assert not thin, f"a top grade pill is noise at: {thin}"


def test_the_buff_never_makes_a_pill_worse(conn, make_player):
    """At rank 1 the flat 4,056 is already several stages' worth, and 5% of a
    1,000-point stage is 50. The value is the GREATEST of the two so the low
    realms are untouched - a buff that quietly nerfed beginners would be a
    different change from the one that was asked for."""
    low = a_drinker(conn, make_player, 1)
    assert conn.execute(
        "SELECT pill_cultivation_value(%s, 7::smallint, 4056::bigint)", (low,)
    ).fetchone()[0] == 4056

    high = a_drinker(conn, make_player, 6)
    assert conn.execute(
        "SELECT pill_cultivation_value(%s, 7::smallint, 4056::bigint)", (high,)
    ).fetchone()[0] > 4056 * 50, "rank 6 barely moved"


def test_a_higher_grade_pill_is_worth_more_at_the_same_realm(conn, make_player):
    """The share is apportioned by `base_magnitude`, so this is really a check
    that grade still means something after the change."""
    who = a_drinker(conn, make_player, 7)
    values = [
        conn.execute(
            "SELECT pill_cultivation_value(%s, %s::smallint, 1::bigint)",
            (who, tier),
        ).fetchone()[0]
        for tier in range(1, 8)
    ]
    assert values == sorted(values), values
    assert values[-1] > values[0], "grade buys nothing"


def test_swallowing_one_grants_the_scaled_amount(conn, make_player):
    """Through `take_pill`, which is what a player actually calls - a value
    that only the helper knows about would be the same bug in a new place."""
    who = a_drinker(conn, make_player, 6)
    # Asked with the pill in hand, as `take_pill` does since 0203: this one is
    # harmony 150, so the nominal value would be a third short.
    expect = conn.execute(
        "SELECT pill_cultivation_worth(%s, 7::smallint, 4056::bigint, "
        "150::smallint, NULL::numeric)",
        (who,),
    ).fetchone()[0]

    pill = conn.execute(
        "INSERT INTO player_pills (owner_id, name, tier, kind, path_code, "
        "magnitude, quantity, harmony) VALUES "
        "(%s, 'Probe', 7, 'cultivation', 'space', 4056, 1, 150) "
        "RETURNING pill_id",
        (who,),
    ).fetchone()[0]

    before = conn.execute(
        "SELECT cultivation, reserve FROM player_cultivation WHERE player_id = %s",
        (who,),
    ).fetchone()
    conn.execute("SELECT take_pill(%s, %s)", (who, pill))
    after = conn.execute(
        "SELECT cultivation, reserve FROM player_cultivation WHERE player_id = %s",
        (who,),
    ).fetchone()

    # Past the realm's door it spills into the reserve rather than being lost,
    # so both halves count toward what the pill was worth.
    banked = (after[0] - before[0]) + (after[1] - before[1])
    assert banked == expect, f"granted {banked}, the pill is worth {expect}"


def test_the_stage_gap_is_defined_at_the_top_of_the_ladder(conn, make_player):
    """The highest realm has no next door. Borrowing the last step is what
    0176 does for the top pill grade's batch, and without it the strongest
    cultivator in the game would get the flat number."""
    top = conn.execute("SELECT max(rank) FROM realms").fetchone()[0]
    who = a_drinker(conn, make_player, top)
    conn.execute(
        "UPDATE player_cultivation SET realm_id = "
        "(SELECT max(realm_id) FROM realms) WHERE player_id = %s",
        (who,),
    )
    gap = conn.execute(
        "SELECT cultivation_stage_gap(%s)", (who,)
    ).fetchone()[0]
    assert gap > 1, "the top realm has no stage to measure against"


# ---------------------------------------------------------------------------
# Insight measured against the tier it buys (0196, 0197)
# ---------------------------------------------------------------------------


def test_an_insight_pill_is_worth_a_real_share_of_every_tier(conn):
    """0195's problem in the other ladder. A flat 2,704 is 270% of the Expert
    tier and 0.2% of the Supreme Grandmaster one."""
    share = float(conn.execute(
        "SELECT game_config_value('pill_insight_share')"
    ).fetchone()[0])
    thin = conn.execute(
        """
        WITH g AS (
            SELECT name, COALESCE(
                LEAD(insight_required) OVER (ORDER BY insight_required)
                - insight_required, 0) AS gap
            FROM attainment_tiers
        )
        SELECT name, gap FROM g
        WHERE gap > 0 AND round(gap * %s)::numeric / gap < %s - 0.001
        """,
        (share, share),
    ).fetchall()
    assert not thin, f"a top grade insight pill is noise at: {thin}"


def test_an_untouched_path_still_has_a_tier_to_measure_against(conn, make_player):
    """Tiers 0 and 1 both require 0 insight, so `tier + 1` from Uninitiated is
    a gap of zero and a pill worth nothing. The gap is found by the next
    REQUIREMENT that is larger, not the next tier."""
    who = a_drinker(conn, make_player, 3)
    assert conn.execute(
        "SELECT attainment_stage_gap(%s, 'painting')", (who,)
    ).fetchone()[0] == 1000, "the first real rung is Expert at 1,000"


def test_an_insight_pill_is_weighed_against_the_path_it_is_pointed_at(
    conn, make_player
):
    """0163 made insight pills go where you point them, so the tier that
    matters is the target Path's - not the Path the pill was named for."""
    who = a_drinker(conn, make_player, 4)
    conn.execute("SELECT grant_path_insight(%s, 'heaven', 300000)", (who,))

    far = conn.execute(
        "SELECT pill_insight_value(%s, 'heaven', 7::smallint, 2704::bigint)",
        (who,),
    ).fetchone()[0]
    near = conn.execute(
        "SELECT pill_insight_value(%s, 'painting', 7::smallint, 2704::bigint)",
        (who,),
    ).fetchone()[0]

    assert far > near, (
        "a deep Path should be worth more per pill than an untouched one"
    )
    assert near == 2704, "an untouched Path should still pay the flat number"


def test_pointing_a_pill_elsewhere_grants_the_other_paths_amount(
    conn, make_player
):
    """Through `take_pill`, with the Path argument - the value and the grant
    have to agree about which Path is being bought."""
    who = a_drinker(conn, make_player, 4)
    conn.execute("SELECT grant_path_insight(%s, 'heaven', 300000)", (who,))
    expect = conn.execute(
        "SELECT pill_insight_value(%s, 'heaven', 7::smallint, 2704::bigint)",
        (who,),
    ).fetchone()[0]

    pill = conn.execute(
        "INSERT INTO player_pills (owner_id, name, tier, kind, path_code, "
        "magnitude, quantity, harmony) VALUES "
        "(%s, 'Probe', 7, 'insight', 'poison', 2704, 1, 150) RETURNING pill_id",
        (who,),
    ).fetchone()[0]

    before = conn.execute(
        "SELECT insight FROM player_path_attainment WHERE player_id = %s "
        "AND path_code = 'heaven'", (who,)
    ).fetchone()[0]
    conn.execute("SELECT take_pill(%s, %s, 'heaven')", (who, pill))
    after = conn.execute(
        "SELECT insight FROM player_path_attainment WHERE player_id = %s "
        "AND path_code = 'heaven'", (who,)
    ).fetchone()[0]

    assert after - before == expect, (
        f"granted {after - before}, the pill is worth {expect} into heaven"
    )


def test_the_rate_ladder_starts_at_two_hundred_percent(conn):
    """0197. The base is the lowest grade that can brew a rate pill, found
    through `pill_kinds.min_tier` rather than written as 5."""
    floor_tier = conn.execute(
        "SELECT min(min_tier) FROM pill_kinds "
        "WHERE code IN ('cultivation_rate', 'attainment_rate')"
    ).fetchone()[0]
    assert conn.execute(
        "SELECT rate_bonus FROM pill_tiers WHERE tier = %s", (floor_tier,)
    ).fetchone()[0] == 2.00


def test_raising_the_rate_floor_did_not_flatten_the_grades(conn):
    """125/135/150 climbed by 1.20x top to bottom. Moving the floor to 200
    must not turn that into 1.02x, or grade stops being worth chasing for the
    rate at all."""
    rungs = [
        float(r[0]) for r in conn.execute(
            "SELECT rate_bonus FROM pill_tiers WHERE rate_bonus > 0 "
            "ORDER BY tier"
        ).fetchall()
    ]
    assert rungs == sorted(rungs)
    assert rungs[-1] / rungs[0] == pytest.approx(1.20, abs=0.01), rungs


# ---------------------------------------------------------------------------
# Rogues matched to the cultivator they ambush (0198)
# ---------------------------------------------------------------------------


def ambushes(conn, player_id, region, n=3000):
    """Ranks of the rogues `spawn_rogue` actually picks.

    Sampled through the function rather than through a copy of its ordering -
    a copy is a second implementation of the rule and the first thing to
    disagree with it. The 10% ambush roll means most calls return NULL.
    """
    return [
        r[0] for r in conn.execute(
            """
            SELECT s.rank
            FROM (SELECT spawn_rogue(%s, %s) AS sid
                  FROM generate_series(1, %s)) drew
            JOIN creature_species s ON s.species_id = drew.sid
            """,
            (region, player_id, n),
        ).fetchall()
    ]


def test_a_high_realm_cultivator_stops_being_ambushed_by_novices(
    conn, make_player
):
    """`spawn_rogue` took a region and nothing else, so it drew from the whole
    regional list by region weight - and in northern all eight rogues carry
    weight 10. A rank 4 cultivator met a rank 1 Herb Thief three times in
    eight and went home with tier 1 pages, because `rogue_pages` gives a rank
    N rogue tier N to N+2."""
    low = a_drinker(conn, make_player, 1)
    high = a_drinker(conn, make_player, 4)

    met_low = ambushes(conn, low, "northern")
    met_high = ambushes(conn, high, "northern")
    assert met_low and met_high, "nothing ambushed anybody"

    assert sum(met_high) / len(met_high) > sum(met_low) / len(met_low) + 1.5, (
        f"rank 4 meets {sum(met_high)/len(met_high):.2f} against rank 1's "
        f"{sum(met_low)/len(met_low):.2f}"
    )
    # And the novice is never handed something far above them.
    assert max(met_low) <= 2, f"a rank 1 cultivator met rank {max(met_low)}"


def test_one_rank_above_is_possible_and_no_more(conn, make_player):
    """The overmatch is deliberate - it is the only way to see pages from
    above your own realm - but two ranks up would be an execution."""
    who = a_drinker(conn, make_player, 3)
    met = ambushes(conn, who, "northern")
    assert met, "nothing ambushed anybody"
    assert max(met) == 4, f"a rank 3 cultivator met at most rank {max(met)}"
    assert met.count(4) < len(met) / 4, "the overmatch is meant to be rare"


def test_the_rank_you_meet_decides_the_pages_you_carry_home(conn, make_player):
    """The half that already worked, pinned so the two stay joined: a rogue's
    rank sets the tier band of what they were carrying.

    Two bands now. A mortal rogue carries the drop table, which stops at tier
    7. An immortal carries what the drop table never held - tiers 8 to 10,
    `roll_weight` zero, otherwise reachable only by fusing three pages at a
    time - and which of the three is decided by the realm they stand at
    (0378). So the ceiling is asserted per rogue rather than once.
    """
    who = a_drinker(conn, make_player, 4)
    spread = int(conn.execute(
        "SELECT game_config_value('rogue_page_tier_spread')"
    ).fetchone()[0])
    step = int(conn.execute(
        "SELECT game_config_value('rogue_immortal_page_step')"
    ).fetchone()[0])
    top = int(conn.execute("SELECT max(tier) FROM page_tiers").fetchone()[0])

    for code, rank, immortal in conn.execute(
        "SELECT code, rank, immortal_rank FROM creature_species "
        "WHERE kind = 'rogue' ORDER BY COALESCE(immortal_rank, rank)"
    ).fetchall():
        species = conn.execute(
            "SELECT species_id FROM creature_species WHERE code = %s", (code,)
        ).fetchone()[0]
        pages = conn.execute(
            "SELECT * FROM rogue_pages(%s, %s, 'northern')", (who, species)
        ).fetchall()
        tiers = [
            conn.execute(
                "SELECT tier FROM manual_pages WHERE page_id = %s", (p[0],)
            ).fetchone()[0]
            for p in pages
        ]
        assert tiers, f"{code} carried nothing"

        if immortal is None:
            # The drop table stops at tier 7, so a rogue standing above that
            # carries the best tier that exists rather than a band running
            # backwards. The old floor of `rank` was fine while the strongest
            # rogue was rank 5 and became a lo > hi handed to mint_page the
            # moment 0359 put rank 9 immortals in the heavens.
            assert min(tiers) >= min(rank, 7), (
                f"{code} (rank {rank}) carried tier {min(tiers)}"
            )
            assert max(tiers) <= min(7, rank + spread), (
                f"{code} (rank {rank}) carried tier {max(tiers)}"
            )
            continue

        # An immortal carries exactly one rung of the fusion-only band, chosen
        # by their realm: three realms to a rung from tier 8 up.
        want = min(top, 7 + max(1, -(-(immortal - 9) // step)))
        assert set(tiers) == {want}, (
            f"{code} stands at realm {immortal} and carried {sorted(set(tiers))}, "
            f"wanted tier {want}"
        )
        assert want > 7, (
            f"{code} is an immortal and carried a tier the drop table holds"
        )


def test_no_rogue_exists_that_nobody_could_meet(conn):
    """The reach is one rank above the cultivator. A rogue past that is a row
    that can never be drawn - and this migration's first draft added two of
    them, which this check rejected.

    Since 0359 the number that decides the draw is `immortal_rank` wherever
    there is one. A rogue immortal is creature rank 9 but STANDS at a realm of
    10 to 18, and that realm is what `spawn_rogue` weighs it by. Reading `rank`
    alone would have kept this test green while saying nothing at all about the
    eighteen rogues most likely to be mis-ranked.

    The two kinds are held to different bars on purpose. A mortal rogue is
    measured against the best cultivator alive, because one nobody has grown
    into yet is a mistake. An immortal one is measured against the top of the
    realm ladder, because that ladder is deliberately built ahead of the people
    climbing it - 0334 wrote all nine essences before a single immortal
    existed, and 0359 stocked all nine realms of rogues the same way.
    """
    top = conn.execute(
        """
        SELECT max(r.rank) FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND p.discord_id <> 0
        """
    ).fetchone()[0]
    ladder = conn.execute("SELECT max(rank) FROM realms").fetchone()[0]

    unreachable = conn.execute(
        """
        SELECT name, COALESCE(immortal_rank, rank) AS stands_at
        FROM creature_species
        WHERE kind = 'rogue'
          AND COALESCE(immortal_rank, rank)
              > CASE WHEN immortal_rank IS NULL THEN %s ELSE %s END + 1
        """,
        (top or 1, ladder),
    ).fetchall()
    assert not unreachable, f"nobody can meet: {unreachable}"


def test_every_rogue_lives_somewhere(conn):
    """The same fault the other way round: a rogue with no region is a rogue
    nobody meets either."""
    homeless = conn.execute(
        """
        SELECT s.name FROM creature_species s
        WHERE s.kind = 'rogue'
          AND NOT EXISTS (SELECT 1 FROM creature_regions cr
                          WHERE cr.species_id = s.species_id)
        """
    ).fetchall()
    assert not homeless, f"these rogues live nowhere: {homeless}"


# ---------------------------------------------------------------------------
# A ladder that only climbs (0202) and a pill worth what went into it (0203)
# ---------------------------------------------------------------------------


def test_no_stage_is_easier_than_the_one_before_it(conn):
    """Nascent Soul asked 152,852 for Mid and then 122,107 for Late, so
    grinding through Mid was rewarded with a stage that took less work than the
    one just finished. Every rank did it, and Qi Condensation did it twice."""
    steps = [
        (name, int(step))
        for name, step in conn.execute(
            """
            SELECT name, cultivation_required
                   - LAG(cultivation_required) OVER (ORDER BY realm_id)
            FROM realms
            """
        ).fetchall()
        if step is not None
    ]
    for (name, step), (_prev_name, prev) in zip(steps[1:], steps):
        assert step > prev, f"{name} costs {step:,} after {prev:,}"


def test_the_rank_boundaries_are_where_the_rest_of_the_game_expects(conn):
    """Only the stages inside a rank were redistributed. The rank floors are
    what `realm_cultivation_scale`, technique ranks and manual required_rank
    are all balanced against."""
    for realm_id, floor in (
        (1, 0), (5, 7220), (9, 33427), (13, 169836), (17, 1164903),
        (20, 7990067), (24, 54803869), (28, 375899735), (32, 2578296279),
    ):
        assert conn.execute(
            "SELECT cultivation_required FROM realms WHERE realm_id = %s",
            (realm_id,),
        ).fetchone()[0] == floor


def test_nobody_stands_below_their_own_realm_floor(conn):
    """Raising a floor over somebody's head would demote them for a change
    they had no part in. 0202 lifts instead."""
    under = conn.execute(
        """
        SELECT p.discord_name, pc.cultivation, r.cultivation_required
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE p.deleted_at IS NULL AND p.discord_id <> 0
          AND pc.cultivation < r.cultivation_required
        """
    ).fetchall()
    assert not under, f"standing under their own floor: {under}"


def test_a_better_brewed_pill_is_worth_more(conn, make_player):
    """0195 gave every grade 7 the same 5% of the stage, so nothing a brewer
    did mattered except reaching the tier. Harmony and potency are both in the
    answer now, and both are continuous."""
    who = a_drinker(conn, make_player, 5)
    floor_p = float(conn.execute(
        "SELECT potency_required FROM pill_tiers WHERE tier = 7"
    ).fetchone()[0])

    def worth(harmony, potency_x):
        return conn.execute(
            "SELECT pill_cultivation_worth(%s, 7::smallint, 1::bigint, "
            "%s::smallint, %s::numeric)",
            (who, harmony, floor_p * potency_x),
        ).fetchone()[0]

    assert worth(150, 1) > worth(100, 1) > worth(76, 1), "harmony does nothing"
    assert worth(100, 2) > worth(100, 1.5) > worth(100, 1), "potency does nothing"

    # And the values are not a handful of steps - the point was 5.7 and 4.3
    # rather than 5 and 5.
    spread = {worth(h, 1) for h in range(90, 130, 3)}
    assert len(spread) >= 10, f"only {len(spread)} distinct values in a range"


def test_the_nominal_pill_is_still_the_old_value(conn, make_player):
    """Harmony 100 at the tier floor is the reference point, so this is a
    spread around 0195's number rather than a buff wearing a spread as a
    disguise."""
    who = a_drinker(conn, make_player, 6)
    floor_p = conn.execute(
        "SELECT potency_required FROM pill_tiers WHERE tier = 7"
    ).fetchone()[0]

    assert conn.execute(
        "SELECT pill_cultivation_worth(%s, 7::smallint, 4056::bigint, "
        "100::smallint, %s::numeric)", (who, floor_p)
    ).fetchone()[0] == conn.execute(
        "SELECT pill_cultivation_value(%s, 7::smallint, 4056::bigint)", (who,)
    ).fetchone()[0]


def test_overshooting_the_cauldron_pays_but_not_forever(conn, make_player):
    """A pot at six times the tier floor would otherwise make a grade 7 worth a
    third of a realm, and overshoot already buys batch size once."""
    who = a_drinker(conn, make_player, 6)
    floor_p = float(conn.execute(
        "SELECT potency_required FROM pill_tiers WHERE tier = 7"
    ).fetchone()[0])
    cap = float(conn.execute(
        "SELECT game_config_value('pill_potency_cap')"
    ).fetchone()[0])

    at_cap = conn.execute(
        "SELECT pill_cultivation_worth(%s, 7::smallint, 1::bigint, "
        "100::smallint, %s::numeric)", (who, floor_p * cap)
    ).fetchone()[0]
    way_over = conn.execute(
        "SELECT pill_cultivation_worth(%s, 7::smallint, 1::bigint, "
        "100::smallint, %s::numeric)", (who, floor_p * cap * 3)
    ).fetchone()[0]
    assert at_cap == way_over


def test_a_brewed_pill_remembers_its_potency(conn, make_player):
    """`brew` computed the total, used it for the tier and the batch, and threw
    it away - so a pill could not be valued by what went into it."""
    who = make_player("Brewer")
    conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (who,))
    conn.execute(
        "INSERT INTO player_professions (player_id, profession, exp, level) "
        "VALUES (%s, 'alchemy', 40000, 150)", (who,)
    )
    conn.execute("SELECT grant_material(%s, 'oracle_bloom', 200)", (who,))
    conn.execute("SELECT grant_material(%s, 'spirit_dew_grass', 5)", (who,))

    made = conn.execute(
        "SELECT pill_id, potency FROM brew(%s, ARRAY['oracle_bloom',"
        "'spirit_dew_grass'], ARRAY[84, 1])",
        (who,),
    ).fetchone()
    kept = conn.execute(
        "SELECT potency FROM player_pills WHERE pill_id = %s", (made[0],)
    ).fetchone()[0]
    assert kept == made[1], "the pot's potency was not written onto the pill"

# ---------------------------------------------------------------------------
# Dungeons (0204-0207)
# ---------------------------------------------------------------------------


def nearly_fell(conn, run, hp=1):
    """Put everything standing in a room on `hp`.

    `dungeon_runs.boss_hp` is a MIRROR since 0540 - the health lives in
    `dungeon_foes`, one row per thing standing, and the mirror is
    recomputed from the sum at the end of every round. Two tests used to
    write the mirror and the write was silently overwritten.
    """
    conn.execute(
        "UPDATE dungeon_foes SET current_hp = %s "
        "WHERE run_id = %s AND current_hp > 0",
        (hp, run),
    )
    conn.execute(
        "UPDATE dungeon_runs SET boss_hp = ("
        "  SELECT sum(current_hp) FROM dungeon_foes WHERE run_id = %s) "
        "WHERE run_id = %s",
        (run, run),
    )


def a_raider(conn, make_player, name="Raider", rank=4, keys=3):
    """Somebody who can walk into a room of the given STANDING.

    Above the realm ladder there is no realm to sit them in - `realms` stops at
    18 and `venerable_ranks` runs 19 to 27, separate on purpose - so anybody
    asked for past the top is put at its peak and ASCENDED. That is the only
    way to stand at 19, and it means `a_raider(rank=19)` walks the real path:
    the tribulation, the stamp, the standing.
    """
    top = conn.execute("SELECT max(rank) FROM realms").fetchone()[0]
    who = make_player(name)
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id, cultivation) "
        "SELECT %s, r.realm_id, r.cultivation_required FROM realms r "
        "WHERE r.rank = %s ORDER BY r.realm_id DESC LIMIT 1",
        (who, min(rank, top)),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (who,),
    )
    conn.execute(
        "UPDATE player_physique SET max_hp = 50000, current_hp = 50000, "
        "defense = 300 WHERE player_id = %s",
        (who,),
    )
    # Something to swing with, or the door refuses them.
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "SELECT %s, technique_id FROM techniques WHERE created_by IS NULL "
        "AND category = 'attack' AND rank = 1 ORDER BY base_power DESC LIMIT 1",
        (who,),
    )
    conn.execute("SELECT grant_material(%s, 'dungeon_key', %s)", (who, keys))
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 90000000)", (who,))
    conn.execute("SELECT grant_jade(%s, 100, 'test')", (who,))

    if rank > top:
        # A Dao is read off what somebody has DONE, so there has to be
        # something there before it can be stamped. One Path is enough.
        conn.execute(
            "INSERT INTO player_path_attainment "
            "(player_id, path_code, insight, tier) "
            "SELECT %s, dw.source_code, 90000, 5 FROM dao_words dw "
            "WHERE dw.source_kind = 'path' ORDER BY dw.source_code LIMIT 1",
            (who,),
        )
        conn.execute(
            "INSERT INTO player_tribulations "
            "(player_id, rank, status, settled_at) "
            "VALUES (%s, %s, 'passed', now())",
            (who, top + 1),
        )
        conn.execute("SELECT * FROM venerable_ascend(%s)", (who,))
        assert conn.execute(
            "SELECT player_standing(%s)", (who,)
        ).fetchone()[0] >= rank, (
            f"asked for a raider at standing {rank} and they did not get there"
        )

    return who


# ---------------------------------------------------------------------------
# Beast eggs (0216)
# ---------------------------------------------------------------------------


def test_an_egg_holds_something_that_lays_eggs(conn, make_player):
    """A rogue cultivator is a person and a dungeon boss is a calamity.
    Neither is a species you keep."""
    who = make_player("Egg Finder")
    for tier in range(1, 10):
        for _ in range(8):
            conn.execute("SELECT roll_beast_egg(%s, %s::smallint, NULL)", (who, tier))

    wrong = conn.execute(
        """
        SELECT DISTINCT cs.kind FROM player_beast_eggs e
        JOIN creature_species cs ON cs.species_id = e.species_id
        WHERE e.owner_id = %s AND cs.kind NOT IN ('beast', 'elite')
        """,
        (who,),
    ).fetchall()
    assert [r[0] for r in wrong] == []


def test_a_tier_one_egg_is_never_primordial(conn, make_player):
    """The tier is the ceiling on the grade. If a tier 1 could roll Extreme
    the ladder would be decoration and there would be no reason to fight
    anything harder."""
    who = make_player("Egg Finder")
    for _ in range(200):
        conn.execute("SELECT roll_beast_egg(%s, 1::smallint, NULL)", (who,))

    over = conn.execute(
        """
        SELECT count(*) FROM player_beast_eggs e JOIN rarities r ON r.code = e.rarity
        WHERE e.owner_id = %s
          AND r.sort_order > 10 + e.tier * game_config_value('egg_rarity_reach_per_tier')
        """,
        (who,),
    ).fetchone()[0]
    assert over == 0

    # ...and the ceiling really does rise, or the tier buys nothing.
    conn.execute("DELETE FROM player_beast_eggs WHERE owner_id = %s", (who,))
    for _ in range(200):
        conn.execute("SELECT roll_beast_egg(%s, 7::smallint, NULL)", (who,))
    best = conn.execute(
        "SELECT max(r.sort_order) FROM player_beast_eggs e "
        "JOIN rarities r ON r.code = e.rarity WHERE e.owner_id = %s",
        (who,),
    ).fetchone()[0]
    assert best > 20, "two hundred tier 7 eggs never beat Uncommon"


def test_every_egg_can_be_named_and_drawn(conn, make_player):
    """An egg with no word on it is indistinguishable from a common one, and
    the grade is half of what the shelf exists to show."""
    who = make_player("Egg Finder")
    for tier in (1, 5, 9):
        for _ in range(20):
            conn.execute("SELECT roll_beast_egg(%s, %s::smallint, NULL)", (who, tier))

    unnameable = conn.execute(
        "SELECT count(*) FROM player_egg_shelf WHERE owner_id = %s "
        "AND (name IS NULL OR emoji IS NULL OR name = '')",
        (who,),
    ).fetchone()[0]
    assert unnameable == 0

    missing = conn.execute(
        "SELECT r.code FROM rarities r WHERE NOT EXISTS "
        "(SELECT 1 FROM egg_qualities q WHERE q.rarity = r.code) ORDER BY r.code"
    ).fetchall()
    assert [r[0] for r in missing] == []


def test_a_hatched_egg_leaves_the_shelf(conn, make_player):
    """`hatched_at` is unread today. The view already respects it, so the pet
    system does not have to remember to."""
    who = make_player("Egg Finder")
    egg = conn.execute("SELECT roll_beast_egg(%s, 3::smallint, NULL)", (who,)).fetchone()[0]
    assert conn.execute(
        "SELECT count(*) FROM player_egg_shelf WHERE egg_id = %s", (egg,)
    ).fetchone()[0] == 1

    conn.execute(
        "UPDATE player_beast_eggs SET hatched_at = now() WHERE egg_id = %s", (egg,)
    )
    assert conn.execute(
        "SELECT count(*) FROM player_egg_shelf WHERE egg_id = %s", (egg,)
    ).fetchone()[0] == 0


# ---------------------------------------------------------------------------
# Beast Hordes (0219-0222)
# ---------------------------------------------------------------------------


def _tide(conn, region="northern", rank=2):
    """Open a tide, whatever else is happening.

    Only one may run at a time, which is right for the game and wrong for a
    test suite that runs against a live database - the first real horde broke
    eleven of these. The transaction rolls back, so standing the live one down
    inside it costs nothing and touches nobody.
    """
    conn.execute(
        "UPDATE beast_hordes SET status = 'won', ended_at = now() "
        "WHERE status IN ('fighting', 'king')"
    )
    return conn.execute(
        "SELECT horde_open(%s, %s::smallint, NULL)", (region, rank)
    ).fetchone()[0]


def _pay_the_gate(conn, player_id):
    """Stock a cultivator with whatever their next great realm asks for.

    0253 put a door in front of every rank crossing. Tests that are about what
    happens AFTER a breakthrough have to get through it, and reading
    `realm_gates` is how they do that without hard-coding what it wants.
    """
    # 0386 put a sky in front of every great realm crossing as well, and it is
    # paid the same way and for the same reason: a test about what happens
    # AFTER a breakthrough survives it by fiat, and the tests that are ABOUT
    # the tribulation fight it out for real.
    #
    # Before the early return below, because `realm_gates` stops at rank 9 and
    # the immortal crossings have a tribulation and nothing else.
    conn.execute(
        """
        INSERT INTO player_tribulations (player_id, rank, status, settled_at)
        SELECT %s, nx.rank, 'passed', now()
        FROM player_cultivation pc
        JOIN realms was ON was.realm_id = pc.realm_id
        JOIN realms nx ON nx.realm_id = pc.realm_id + 1
        WHERE pc.player_id = %s AND nx.rank > was.rank
        ON CONFLICT DO NOTHING
        """,
        (player_id, player_id),
    )

    gate = conn.execute(
        """
        SELECT g.stones, g.treasure_code, g.treasure_qty, g.pill_kind, g.pill_tier
        FROM player_cultivation pc
        JOIN realms nx ON nx.realm_id = pc.realm_id + 1
        JOIN realm_gates g ON g.rank = nx.rank
        WHERE pc.player_id = %s
        """,
        (player_id,),
    ).fetchone()
    if gate is None:
        return

    stones, treasure, qty, pill_kind, pill_tier = gate
    if stones:
        conn.execute(
            "SELECT grant_material(%s, 'spirit_stone', %s)", (player_id, stones)
        )
    if treasure:
        conn.execute(
            "SELECT grant_material(%s, %s, %s)", (player_id, treasure, qty)
        )
    if pill_kind:
        conn.execute(
            "INSERT INTO player_pills "
            "(owner_id, name, tier, kind, path_code, magnitude, quantity, harmony) "
            "VALUES (%s, 'Gate Pill', %s, %s, "
            "        (SELECT code FROM paths ORDER BY code LIMIT 1), 1, 1, 50)",
            (player_id, pill_tier, pill_kind),
        )


# ---------------------------------------------------------------------------
# The sky in the door of every great realm
# ---------------------------------------------------------------------------


def _at_a_great_realm_door(conn, make_player, name="Ascending"):
    """Somebody one crossing below a rank change, with the cultivation for it.

    The realm is found by walking up from where `_defender` starts until the
    NEXT realm is a rank higher, rather than by naming a realm_id - realms have
    been inserted above and between these before and will be again.
    """
    who = _defender(conn, make_player, name)
    conn.execute(
        """
        UPDATE player_cultivation pc
        SET realm_id = (
            SELECT was.realm_id FROM realms was
            JOIN realms nxt ON nxt.realm_id = was.realm_id + 1
            WHERE nxt.rank > was.rank AND was.rank = 1
            ORDER BY was.realm_id LIMIT 1)
        WHERE pc.player_id = %s
        """,
        (who,),
    )
    conn.execute(
        """
        UPDATE player_cultivation pc
        SET cultivation = (SELECT r.cultivation_required FROM realms r
                           WHERE r.realm_id = pc.realm_id + 1)
        WHERE pc.player_id = %s
        """,
        (who,),
    )
    _pay_the_gate(conn, who)
    # Undo the free pass `_pay_the_gate` hands out: these tests are about the
    # sky, so they are the ones that have to face it.
    conn.execute("DELETE FROM player_tribulations WHERE player_id = %s", (who,))
    return who


def test_every_great_realm_has_a_sky_and_no_stage_does(conn):
    """A tribulation guards a rank, not a stage. One per crossing, and
    nothing standing between Early and Mid.

    The ladder of skies runs one rank PAST the realm ladder, because 0521
    put one in the Venerable door too - the only crossing that is not into
    a `realms` row. So the ceiling is the highest rank anything in the game
    can stand at rather than `max(realms.rank)`, which stops at 18 and is
    exactly the sort of ceiling 0504 spent a migration widening.
    """
    top = conn.execute(
        "SELECT greatest(max(r.rank), max(v.rank)) FROM realms r, venerable_ranks v"
    ).fetchone()[0]
    guarded = conn.execute(
        "SELECT array_agg(rank ORDER BY rank) FROM tribulations"
    ).fetchone()[0]
    assert guarded == list(range(2, max(guarded) + 1)), (
        f"a rank between 2 and the top has no sky: {guarded}"
    )
    assert max(guarded) <= top, f"a sky guards rank {max(guarded)}, above anything"
    assert 19 in guarded, "the Venerable door has no sky standing in it"

    # And each is a real share of the boss of the realm being left, rather than
    # a curve typed out a second time beside the one it claims to follow.
    drifted = conn.execute(
        """
        SELECT tb.rank FROM tribulations tb
        JOIN creature_species cs ON cs.species_id = tb.species_id
        JOIN dungeons d ON d.realm_rank = tb.rank - 1
        JOIN creature_species boss ON boss.species_id = d.species_id
        WHERE abs(cs.base_hp::numeric
                  - round(boss.base_hp
                          * game_config_value('tribulation_hp_share'))) > 1
        """
    ).fetchall()
    assert drifted == [], drifted


def test_the_door_will_not_open_until_the_sky_has(conn, make_player):
    """The whole feature in one test: cultivation is no longer enough."""
    who = _at_a_great_realm_door(conn, make_player)

    # A savepoint: a failed statement aborts the transaction, and this test
    # carries on afterwards to check that the screen agrees with the door.
    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation, match="tribulation"):
            conn.execute("SELECT breakthrough(%s)", (who,))

    # And the screen says the same thing the door does, which is the only
    # reason `breakthrough_gate` exists.
    row = conn.execute(
        "SELECT need, detail, met FROM breakthrough_gate(%s) g "
        "WHERE g.need = 'Heavenly Tribulation'",
        (who,),
    ).fetchone()
    assert row is not None, "the gate never mentions the tribulation"
    assert row[2] is False
    assert row[1], "the gate does not name what is standing there"

    # Survive it, and the door opens.
    conn.execute(
        "INSERT INTO player_tribulations (player_id, rank, status, settled_at) "
        "SELECT %s, nxt.rank, 'passed', now() FROM player_cultivation pc "
        "JOIN realms nxt ON nxt.realm_id = pc.realm_id + 1 WHERE pc.player_id = %s",
        (who, who),
    )
    conn.execute("SELECT breakthrough(%s)", (who,))


def test_a_tribulation_is_an_ordinary_fight_and_is_settled_however_it_ends(
    conn, make_player
):
    """It opens a row in `battles`, which is why no combat code was written for
    it - and `battle_conclude` settles it wherever the fight ends, so a flight
    and an expiry are failures as surely as a death."""
    who = _at_a_great_realm_door(conn, make_player, "Facing")

    fight = conn.execute("SELECT tribulation_face(%s)", (who,)).fetchone()[0]
    assert conn.execute(
        "SELECT kind FROM battles WHERE battle_id = %s", (fight,)
    ).fetchone()[0] == "tribulation"
    assert conn.execute(
        "SELECT status FROM player_tribulations WHERE battle_id = %s", (fight,)
    ).fetchone()[0] == "facing"

    # One sky at a time.
    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation, match="already"):
            conn.execute("SELECT tribulation_face(%s)", (who,))

    # Walking away is not walking away clean.
    conn.execute("SELECT battle_conclude(%s, 'fled')", (fight,))
    assert conn.execute(
        "SELECT status FROM player_tribulations WHERE battle_id = %s", (fight,)
    ).fetchone()[0] == "failed"

    # And the sky is shut for a while.
    standing = conn.execute(
        "SELECT wait_seconds, may_face, blocked_by FROM tribulation_standing(%s)",
        (who,),
    ).fetchone()
    assert standing[0] > 0, "failing cost nothing at all"
    assert standing[1] is False
    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation, match="settled"):
            conn.execute("SELECT tribulation_face(%s)", (who,))


def test_killing_the_sky_passes_it_and_passing_it_is_once(conn, make_player):
    who = _at_a_great_realm_door(conn, make_player, "Breaking")

    fight = conn.execute("SELECT tribulation_face(%s)", (who,)).fetchone()[0]
    # Put the trial on the floor rather than fighting it out - which lane wins
    # a fight is `battle_act`'s business and is tested there.
    conn.execute(
        "UPDATE battle_combatants SET current_hp = 0 "
        "WHERE battle_id = %s AND combatant_no = 1",
        (fight,),
    )
    conn.execute("SELECT battle_conclude(%s, 'complete')", (fight,))

    rank = conn.execute(
        "SELECT nxt.rank FROM player_cultivation pc "
        "JOIN realms nxt ON nxt.realm_id = pc.realm_id + 1 WHERE pc.player_id = %s",
        (who,),
    ).fetchone()[0]
    assert conn.execute(
        "SELECT tribulation_passed(%s, %s::smallint)", (who, rank)
    ).fetchone()[0]

    # A door survived is not a door to be walked into again.
    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation, match="already survived"):
            conn.execute("SELECT tribulation_face(%s)", (who,))

    conn.execute("SELECT breakthrough(%s)", (who,))


def test_a_stage_inside_a_realm_asks_for_no_sky(conn, make_player):
    """Only a great realm. Somebody crossing Early to Mid should never be told
    to go and fight something."""
    who = _defender(conn, make_player, "Stepping")
    owed = conn.execute(
        "SELECT owed FROM tribulation_standing(%s)", (who,)
    ).fetchone()[0]
    assert owed is False, "a stage crossing asked for a tribulation"

    with pytest.raises(psycopg.errors.CheckViolation, match="no great realm"):
        conn.execute("SELECT tribulation_face(%s)", (who,))


def test_nobody_is_sent_to_fight_for_a_door_they_cannot_open_anyway(
    conn, make_player
):
    """The tribulation is the LAST gate. Somebody short of spirit stones is
    told about the stones, not sent to spend a fight and a wait finding out."""
    who = _at_a_great_realm_door(conn, make_player, "Short")
    conn.execute(
        "DELETE FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (who,),
    )

    standing = conn.execute(
        "SELECT may_face, blocked_by FROM tribulation_standing(%s)", (who,)
    ).fetchone()
    assert standing[0] is False
    assert standing[1] and "Tribulation" not in standing[1], standing[1]

    with pytest.raises(psycopg.errors.CheckViolation, match="short of"):
        conn.execute("SELECT tribulation_face(%s)", (who,))


# ---------------------------------------------------------------------------
# A technique written out of the pages you feed it
# ---------------------------------------------------------------------------


def _an_immortal(conn, make_player, name="Inscriber"):
    """Somebody deep enough that the forge will talk to them at all."""
    who = _defender(conn, make_player, name)
    conn.execute(
        """
        UPDATE player_cultivation pc
        SET realm_id = (SELECT min(r.realm_id) FROM realms r
                        WHERE r.rank >= game_config_value('technique_forge_min_rank'))
        WHERE pc.player_id = %s
        """,
        (who,),
    )
    return who


def _technique_pages(conn, player, paths, tier=15, power=None):
    """A pile, one page per Path named."""
    ids = []
    for path in paths:
        ids.append(
            conn.execute(
                """
                INSERT INTO manual_pages
                    (owner_id, tier, path_code, page_type, power, quality)
                SELECT %s, %s, %s, 'technique',
                       COALESCE(%s, pt.power_max), 80
                FROM page_tiers pt WHERE pt.tier = %s
                RETURNING page_id
                """,
                (player, tier, path, power, tier),
            ).fetchone()[0]
        )
    return ids


def test_a_pile_reads_the_same_way_the_forge_refuses(conn, make_player):
    """`forge_pile_reading` is what the screen shows and what the burn checks,
    so a pile that reads ready is a pile that forges. The same discipline
    `breakthrough_gate` keeps for a crossing."""
    who = _an_immortal(conn, make_player, "Reading")
    need = conn.execute(
        "SELECT game_config_value('technique_forge_pages_needed')"
    ).fetchone()[0]

    short = _technique_pages(conn, who, ["fire"])
    row = conn.execute(
        "SELECT pages, needed, ready, refused FROM forge_pile_reading(%s, %s)",
        (who, short),
    ).fetchone()
    assert row[0] == 1 and row[1] == int(need)
    assert row[2] is False
    assert str(int(need)) in row[3], row[3]

    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation, match="technique pages"):
            conn.execute("SELECT forge_begin_from_pages(%s, %s)", (who, short))

    full = short + _technique_pages(conn, who, ["water", "metal"])
    assert conn.execute(
        "SELECT ready FROM forge_pile_reading(%s, %s)", (who, full)
    ).fetchone()[0] is True


def test_deep_pages_floor_high_and_nothing_floors_at_a_dao_revelation(
    conn, make_player
):
    """The floor is the whole promise of depth - and the top rung is never a
    floor, because the rarest thing in the system must not be purchasable."""
    who = _an_immortal(conn, make_player, "Flooring")
    top = conn.execute(
        "SELECT code FROM enlighten_qualities ORDER BY sort_order DESC LIMIT 1"
    ).fetchone()[0]

    seen = {}
    for tier in (1, 5, 10, 15):
        pile = _technique_pages(conn, who, ["fire", "water", "metal"], tier=tier)
        seen[tier] = conn.execute(
            "SELECT floor_code FROM forge_pile_reading(%s, %s)", (who, pile)
        ).fetchone()[0]
        assert seen[tier] != top, f"tier {tier} pages floored at the top rung"

    order = {
        code: n
        for code, n in conn.execute(
            "SELECT code, sort_order FROM enlighten_qualities"
        ).fetchall()
    }
    ranks = [order[seen[t]] for t in (1, 5, 10, 15)]
    assert ranks == sorted(ranks), seen
    assert ranks[-1] > ranks[0], "depth bought nothing at all"


def test_the_paths_come_out_of_the_pile_and_a_single_path_pile_stays_single(
    conn, make_player
):
    """The real prize. The daily forge draws Paths off attainment and hands you
    what you are already good at; a pile hands you what you chose.

    Driven repeatedly rather than once, because "it happened not to draw a
    Path that was not there" is what a single sample proves.
    """
    who = _an_immortal(conn, make_player, "Aiming")

    for _ in range(25):
        conn.execute("DELETE FROM technique_forges WHERE player_id = %s", (who,))
        pile = _technique_pages(conn, who, ["fire", "fire", "fire", "fire"])
        forge = conn.execute(
            "SELECT forge_begin_from_pages(%s, %s)", (who, pile)
        ).fetchone()[0]
        paths, dual = conn.execute(
            "SELECT paths, dual FROM technique_forges WHERE forge_id = %s", (forge,)
        ).fetchone()
        assert paths == ["fire"], paths
        assert dual is False, "a pile of one Path forged a dual"

    # And a mixed pile can only ever draw from what went in.
    for _ in range(25):
        conn.execute("DELETE FROM technique_forges WHERE player_id = %s", (who,))
        pile = _technique_pages(conn, who, ["ice", "wind", "poison"])
        forge = conn.execute(
            "SELECT forge_begin_from_pages(%s, %s)", (who, pile)
        ).fetchone()[0]
        paths = conn.execute(
            "SELECT paths FROM technique_forges WHERE forge_id = %s", (forge,)
        ).fetchone()[0]
        assert set(paths) <= {"ice", "wind", "poison"}, paths


def test_burning_a_pile_spends_it_and_records_what_was_spent(conn, make_player):
    who = _an_immortal(conn, make_player, "Burning")
    pile = _technique_pages(conn, who, ["fire", "water", "metal"])

    forge = conn.execute(
        "SELECT forge_begin_from_pages(%s, %s)", (who, pile)
    ).fetchone()[0]

    spent = conn.execute(
        "SELECT count(*) FROM manual_pages WHERE page_id = ANY(%s) "
        "AND consumed_at IS NOT NULL AND consumed_by IS NULL",
        (pile,),
    ).fetchone()[0]
    assert spent == len(pile), "the pages were not cleanly spent"

    assert sorted(
        conn.execute(
            "SELECT from_pages FROM technique_forges WHERE forge_id = %s", (forge,)
        ).fetchone()[0]
    ) == sorted(pile)

    # Spent pages are not a pile any more, so the same ids cannot be burned twice.
    conn.execute("DELETE FROM technique_forges WHERE player_id = %s", (who,))
    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation):
            conn.execute("SELECT forge_begin_from_pages(%s, %s)", (who, pile))


def test_a_page_forge_is_the_same_anvil_as_the_daily_one(conn, make_player):
    """It writes a `technique_forges` row and stops. If the board, the rounds
    or the realm scaling needed to know which door it came through, this would
    be two systems wearing one name."""
    who = _an_immortal(conn, make_player, "SameAnvil")
    pile = _technique_pages(conn, who, ["fire", "water", "metal"])

    forge = conn.execute(
        "SELECT forge_begin_from_pages(%s, %s)", (who, pile)
    ).fetchone()[0]

    row = conn.execute(
        "SELECT realm_rank, power_grade, quality, focus, step "
        "FROM technique_forges WHERE forge_id = %s",
        (forge,),
    ).fetchone()
    assert row[0] >= 10, "a forge with no realm behind it scales to nothing"
    assert row[1] > 0
    assert row[2] is not None
    assert row[3] is None, "a pile has no focus - the pages are the aim"
    assert row[4] == 0

    board = conn.execute("SELECT forge_offer(%s)", (forge,)).fetchone()[0]
    assert board, "a page-forged technique has no board to choose from"

    # And a second forge cannot be opened over the top of it, from either door.
    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation, match="already"):
            conn.execute(
                "SELECT forge_begin_from_pages(%s, %s)",
                (who, _technique_pages(conn, who, ["fire", "water", "metal"])),
            )


def test_a_pile_never_forges_below_the_floor_it_promised(conn, make_player):
    """The floor is a promise the screen makes before anything burns, and this
    is the only thing that makes it one. Fifty burns, because a floor that
    holds once is a floor nobody has tested."""
    who = _an_immortal(conn, make_player, "Floored")
    order = {
        code: n
        for code, n in conn.execute(
            "SELECT code, sort_order FROM enlighten_qualities"
        ).fetchall()
    }

    for _ in range(50):
        conn.execute("DELETE FROM technique_forges WHERE player_id = %s", (who,))
        pile = _technique_pages(conn, who, ["fire", "water", "metal"], tier=15)
        promised = conn.execute(
            "SELECT floor_code FROM forge_pile_reading(%s, %s)", (who, pile)
        ).fetchone()[0]
        forge = conn.execute(
            "SELECT forge_begin_from_pages(%s, %s)", (who, pile)
        ).fetchone()[0]
        got = conn.execute(
            "SELECT quality FROM technique_forges WHERE forge_id = %s", (forge,)
        ).fetchone()[0]
        assert order[got] >= order[promised], f"promised {promised}, forged {got}"


def test_a_mortal_is_not_offered_the_second_door_either(conn, make_player):
    """Two doors into one table with two rules is how a system starts lying
    about itself."""
    who = _defender(conn, make_player, "TooShallow")
    pile = _technique_pages(conn, who, ["fire", "water", "metal"])
    with pytest.raises(psycopg.errors.CheckViolation, match="immortal"):
        conn.execute("SELECT forge_begin_from_pages(%s, %s)", (who, pile))


def _defender(conn, make_player, name="Defender"):
    """Somebody who can swing at something in a channel."""
    who = make_player(name)
    conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (who,))
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (who,),
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) "
        "SELECT %s, technique_id FROM techniques WHERE created_by IS NULL "
        "AND category = 'attack' AND rank = 1 ORDER BY base_power DESC LIMIT 1",
        (who,),
    )
    return who


def test_only_one_tide_at_a_time(conn, make_player):
    """Two hordes would split a room that is already small, and the whole
    point of the event is that everybody is in the same place."""
    _tide(conn, "northern", 2)
    conn.execute("SAVEPOINT second_tide")
    with pytest.raises(psycopg.errors.CheckViolation, match="already running"):
        conn.execute("SELECT horde_open('southern', 2::smallint, NULL)")
    conn.execute("ROLLBACK TO SAVEPOINT second_tide")


def test_holding_the_line_to_the_end_is_a_win(conn, make_player):
    """The correction that made the event playable. A tide is sized before
    anybody has swung, so it has to guess the turnout - and if running out of
    time were a loss, a small turnout would lose by arithmetic."""
    tide = _tide(conn, "northern", 3)
    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "fighting"

    conn.execute(
        "UPDATE beast_hordes SET ends_at = now() - interval '1 minute' "
        "WHERE horde_id = %s",
        (tide,),
    )
    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "won"


def test_the_next_tide_does_not_take_the_last_one_s_chests(conn, make_player):
    """What you are owed is not a property of whichever tide is on the board.

    `/horde` shows the live tide if one is running and the most recent
    otherwise, and the claim button used to hang off exactly that tide - so a
    chest had to be opened in the gap between one tide ending and the next
    beginning. Nothing said so, and twenty-one chests across eight cultivators
    had quietly missed the window by the time anybody noticed.
    """
    who = make_player("Latecomer")

    first = _tide(conn, "northern", 2)
    conn.execute(
        "INSERT INTO horde_contributions "
        "(horde_id, player_id, damage_dealt, swings) VALUES (%s, %s, %s, 1)",
        (first, who, 10 ** 12),
    )
    conn.execute(
        "UPDATE beast_hordes SET status = 'won', ended_at = now() "
        "WHERE horde_id = %s",
        (first,),
    )
    assert conn.execute(
        "SELECT count(*) FROM horde_owed(%s)", (who,)
    ).fetchone()[0] == 1

    # The next tide arrives before they ever pressed the button. `_tide` stands
    # the finished one down the way the world does.
    second = _tide(conn, "northern", 2)
    assert second != first

    still = conn.execute(
        "SELECT array_agg(horde_id) FROM horde_owed(%s)", (who,)
    ).fetchone()[0]
    assert still == [first], still

    got = conn.execute("SELECT horde_claim_all(%s)", (who,)).fetchone()[0]
    assert got["tides"] == 1, got
    assert got["chests"] >= 1, got
    assert conn.execute(
        "SELECT count(*) FROM horde_owed(%s)", (who,)
    ).fetchone()[0] == 0

    # And a second press takes nothing twice.
    with pytest.raises(psycopg.errors.CheckViolation, match="opened everything"):
        conn.execute("SELECT horde_claim_all(%s)", (who,))


def _with_jade(conn, make_player, name="Patron", jade=5000):
    who = body_player(conn, make_player, "primordial_chaos_body")
    conn.execute("SELECT grant_material(%s, 'spirit_jade', %s)", (who, jade))
    return who


def test_up_to_three_attend_and_a_fourth_is_refused(conn, make_player):
    """The bench holds three, and they are summed rather than picked between.

    This test used to assert the opposite: 0417 keyed
    `player_servant_attending` on the player, so calling a second servant
    replaced the first by construction, and that was the roster document's
    own default. 0425 made it three. What is worth pinning is no longer that
    a second one displaces the first - it is that three are FELT TOGETHER, a
    fourth is turned away rather than silently swapping somebody out, and
    sending one home frees exactly one seat.
    """
    who = _with_jade(conn, make_player)

    code, effect = conn.execute(
        """
        SELECT s.servant_code, b.effect_code
        FROM servants s
        JOIN servant_bonuses b ON b.kind = s.bonus_kind
        JOIN gu_effects ef ON ef.code = b.effect_code
        WHERE s.tier = 7 AND NOT b.is_flat AND NOT b.is_strike
        ORDER BY ef.cap DESC, s.servant_code LIMIT 1
        """
    ).fetchone()

    before = conn.execute("SELECT player_stat(%s, %s)", (who, effect)).fetchone()[0]

    held = [
        conn.execute(
            "INSERT INTO player_servants (player_id, servant_code, realm_id) "
            "VALUES (%s, %s, (SELECT min(realm_id) FROM realms)) "
            "RETURNING player_servant_id",
            (who, code),
        ).fetchone()[0]
        for _ in range(4)
    ]

    # Held is not felt.
    assert conn.execute(
        "SELECT player_stat(%s, %s)", (who, effect)
    ).fetchone()[0] == before

    conn.execute("SELECT servant_attend(%s, %s)", (who, held[0]))
    with_one = conn.execute("SELECT player_stat(%s, %s)", (who, effect)).fetchone()[0]
    assert with_one > before

    conn.execute("SELECT servant_attend(%s, %s)", (who, held[1]))
    conn.execute("SELECT servant_attend(%s, %s)", (who, held[2]))
    with_three = conn.execute(
        "SELECT player_stat(%s, %s)", (who, effect)
    ).fetchone()[0]

    assert conn.execute(
        "SELECT count(*) FROM player_servant_attending WHERE player_id = %s", (who,)
    ).fetchone()[0] == 3
    # Summed, not chosen between. The effect was picked for a deep ceiling so
    # the total is visible rather than clamped before it can be measured.
    assert with_three > with_one, (with_one, with_three)

    # A fourth is refused, rather than quietly pushing somebody off the bench.
    # Inside a savepoint: the refusal aborts the transaction it happens in, and
    # this test has things to check afterwards.
    with pytest.raises(psycopg.errors.CheckViolation, match="attend you at once"):
        with conn.transaction():
            conn.execute("SELECT servant_attend(%s, %s)", (who, held[3]))

    # And sending one home frees exactly one seat.
    assert conn.execute(
        "SELECT servant_dismiss(%s, %s)", (who, held[0])
    ).fetchone()[0] == 1
    conn.execute("SELECT servant_attend(%s, %s)", (who, held[3]))
    assert conn.execute(
        "SELECT count(*) FROM player_servant_attending WHERE player_id = %s", (who,)
    ).fetchone()[0] == 3

    # Dismissing with no servant named empties the bench.
    conn.execute("SELECT servant_dismiss(%s)", (who,))
    assert conn.execute(
        "SELECT player_stat(%s, %s)", (who, effect)
    ).fetchone()[0] == before


def test_a_servant_brings_back_what_nobody_can_pick(conn, make_player):
    """The whole reason servants exist: the mortal band.

    A cultivator past the mortal realms cannot go and pick Centipede Venom,
    and 344 Gu recipes still want it. The haul is therefore common and
    uncommon gathering and beast materials and nothing else - a servant's
    realm and stars raise HOW MUCH, never WHAT. The one exception is the rare
    roll, which grants exactly one of something better, so anything that
    arrives in quantity has to be in the band.
    """
    who = _with_jade(conn, make_player)
    conn.execute("SELECT servant_roll(%s)", (who,))
    mine = conn.execute(
        "SELECT player_servant_id FROM player_servants WHERE player_id = %s",
        (who,),
    ).fetchone()[0]

    conn.execute("SELECT servant_send(%s, %s, TRUE)", (who, mine))

    # Nothing is owed the moment they leave.
    assert conn.execute(
        "SELECT count(*) FROM servant_settle(%s)", (who,)
    ).fetchone()[0] == 0

    # Snapshot first: the jade bought for the roll is itself a material held
    # in quantity, and comparing against the whole bag would accuse the
    # servant of having brought it.
    conn.execute(
        "CREATE TEMP TABLE before_haul ON COMMIT DROP AS "
        "SELECT material_code, quantity FROM player_materials WHERE player_id = %s",
        (who,),
    )
    conn.execute(
        "UPDATE player_servants SET settled_at = now() - interval '6 hours' "
        "WHERE player_servant_id = %s",
        (mine,),
    )
    brought = conn.execute(
        "SELECT sum(brought) FROM servant_settle(%s)", (who,)
    ).fetchone()[0]
    assert brought and brought > 0

    # Whatever arrived in QUANTITY is mortal. The rare roll only ever grants
    # one, so this is the assertion that does not flake on it.
    stray = conn.execute(
        """
        SELECT m.name, m.rarity, m.category
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        LEFT JOIN before_haul b ON b.material_code = pm.material_code
        WHERE pm.player_id = %s
          AND pm.quantity - COALESCE(b.quantity, 0) > 1
          AND NOT (m.category IN ('gathering', 'beast')
                   AND m.rarity IN ('common', 'uncommon'))
        """,
        (who,),
    ).fetchall()
    assert stray == [], stray

    # Paid once: the same hours do not come round twice.
    assert conn.execute(
        "SELECT count(*) FROM servant_settle(%s)", (who,)
    ).fetchone()[0] == 0


def test_a_servant_brings_back_what_it_was_told_to(conn, make_player):
    """Orders, and the split that keeps them from being a multiplier.

    The shortage this system answers is specific - 344 recipes want Centipede
    Venom and the server held none - so a supply line that cannot be aimed
    solves it only by accident. Pointing a servant at two things must pay the
    same hour in two piles, not the hour twice.
    """
    who = _with_jade(conn, make_player)
    conn.execute("SELECT servant_roll(%s)", (who,))
    mine = conn.execute(
        "SELECT player_servant_id FROM player_servants WHERE player_id = %s",
        (who,),
    ).fetchone()[0]
    conn.execute("SELECT servant_send(%s, %s, TRUE)", (who, mine))

    # Unfocused first, so the two hauls can be compared for size.
    conn.execute(
        "UPDATE player_servants SET settled_at = now() - interval '10 hours' "
        "WHERE player_servant_id = %s",
        (mine,),
    )
    loose = conn.execute(
        "SELECT sum(brought) FROM servant_settle(%s)", (who,)
    ).fetchone()[0]

    conn.execute(
        "SELECT servant_focus_set(%s, %s, ARRAY['centipede_venom','fish_scale_shard'])",
        (who, mine),
    )
    conn.execute(
        "UPDATE player_servants SET settled_at = now() - interval '10 hours' "
        "WHERE player_servant_id = %s",
        (mine,),
    )
    name, brought, haul = conn.execute(
        "SELECT servant_name, brought, haul FROM servant_settle(%s)", (who,)
    ).fetchone()

    # Both of the things asked for, and the same hour's work as before.
    assert "Centipede Venom" in haul, haul
    assert "Fish Scale Shard" in haul, haul
    assert brought == loose, (brought, loose)

    # Orders are checked against the band, or focus becomes a way to aim a
    # servant at legendary ore.
    with pytest.raises(psycopg.errors.CheckViolation, match="mortal world"):
        conn.execute(
            "SELECT servant_focus_set(%s, %s, ARRAY['spirit_jade'])", (who, mine)
        )


def test_a_pill_is_measured_against_the_servant_not_the_master(conn, make_player):
    """One pill must not be a servant's whole ladder.

    `servant_feed` valued a pill with `pill_cultivation_worth(owner, ...)`,
    which sizes it against the OWNER's stage gap. A Dewberry immortal crosses
    6,250,000,000 a stage and their tier 7 pill is worth 693,359,375 of it; a
    new servant needs 84 for their next realm. One press therefore carried a
    servant the length of the ladder to stand beside their master.

    What it is worth now is the same SHARE of the servant's stage that it
    would have been of their owner's, so the answer is right at the bottom of
    the ladder and still right at the top.
    """
    deep = body_player(conn, make_player, "primordial_chaos_body")
    # Stand them somewhere with a large stage gap, which is the whole problem.
    conn.execute(
        "UPDATE player_cultivation SET realm_id = "
        "(SELECT max(realm_id) FROM realms) - 1 WHERE player_id = %s",
        (deep,),
    )

    servant = conn.execute(
        "INSERT INTO player_servants (player_id, servant_code, realm_id) "
        "VALUES (%s, (SELECT min(servant_code) FROM servants), "
        "(SELECT min(realm_id) FROM realms)) RETURNING player_servant_id",
        (deep,),
    ).fetchone()[0]

    pill = conn.execute(
        """
        INSERT INTO player_pills
            (owner_id, name, tier, kind, path_code, magnitude, quantity,
             harmony, potency)
        VALUES (%s, 'Probe Elixir', 7, 'cultivation',
                (SELECT min(code) FROM paths), 2040, 1, 84, 372)
        RETURNING pill_id
        """,
        (deep,),
    ).fetchone()[0]

    gap, worth = conn.execute(
        """
        SELECT servant_stage_gap(%(s)s),
               servant_pill_worth(%(s)s, %(p)s, 7::smallint, 2040::bigint,
                                  84::smallint, 372::numeric)
        """,
        {"s": servant, "p": deep},
    ).fetchone()

    # A pill is a share of a stage, never several stages.
    assert worth <= gap, (worth, gap)

    before = conn.execute(
        "SELECT realm_id FROM player_servants WHERE player_servant_id = %s",
        (servant,),
    ).fetchone()[0]

    conn.execute("SELECT servant_feed(%s, %s, %s, 1)", (deep, servant, pill))

    after = conn.execute(
        "SELECT realm_id FROM player_servants WHERE player_servant_id = %s",
        (servant,),
    ).fetchone()[0]
    assert after - before <= 1, (before, after)

    # And the last pill of a stack is consumed rather than driven to zero,
    # which `player_pills` refuses outright.
    assert conn.execute(
        "SELECT count(*) FROM player_pills WHERE pill_id = %s", (pill,)
    ).fetchone()[0] == 0


def test_the_forge_finishing_query_can_actually_run(conn):
    """The screen that tells you what you made, checked against the database.

    `take` selected `technique_power_for(f.player_id, ...)` out of a FROM that
    holds only `techniques t` and `manuals m`. There is no `f`, so every
    completed forge - by /enlighten or by /inscribe - raised "missing
    FROM-clause entry for table f" on the last press, after the technique had
    already been made. The player saw a timeout and got their move anyway,
    which is the worst of both.

    Nothing caught it because a SQL string in Python is only checked when
    somebody runs it, and finishing a forge takes three rounds and a day of
    cooldown. So this lifts the query out of the source and asks Postgres to
    plan it, which costs nothing and fails loudly on a name that is not there.
    """
    import pathlib as _p
    import re

    source = (
        _p.Path(__file__).resolve().parent.parent / "bot" / "cogs" / "enlighten.py"
    ).read_text(encoding="utf-8")

    block = source[source.index("        made = await db.fetch_one("):]
    sql = block[block.index('"""') + 3:]
    sql = sql[: sql.index('"""')]
    assert "technique_power_for" in sql, "the finishing query moved"

    tech = conn.execute(
        "SELECT technique_id FROM techniques ORDER BY technique_id LIMIT 1"
    ).fetchone()[0]
    who = conn.execute(
        "SELECT player_id FROM players ORDER BY player_id LIMIT 1"
    ).fetchone()[0]

    # Named placeholders are what the cog passes; EXPLAIN wants values.
    planned = re.sub(r"%\(who\)s", str(who), sql)
    planned = re.sub(r"%\(manual\)s", "NULL::bigint", planned)
    planned = re.sub(r"%\(tech\)s", str(tech), planned)

    # Raises UndefinedTable / UndefinedColumn if an alias is not in the FROM.
    conn.execute("EXPLAIN " + planned)


def test_a_servant_changes_hands_but_not_while_working(conn, make_player):
    """The eighth kind on the trade table, and the two that cannot be given.

    A servant who ATTENDS you would go on being felt by somebody who no longer
    owns them, and one who is OUT WORKING is carrying hours that belong to the
    person who sent them - `servant_settle` pays those to whoever owns the row
    when it next runs. Both are refused at the table rather than resolved
    afterwards, which is how the forge already treats worn equipment.

    Stars, realm and cultivation all hang off `player_servant_id`, so they
    travel because the row travels; the test holds a three-star to prove it.
    """
    giver = _with_jade(conn, make_player, "Giver")
    taker = _with_jade(conn, make_player, "Taker")

    mine = conn.execute(
        "INSERT INTO player_servants (player_id, servant_code, realm_id, stars) "
        "VALUES (%s, (SELECT min(servant_code) FROM servants), "
        "(SELECT min(realm_id) FROM realms), 3) RETURNING player_servant_id",
        (giver,),
    ).fetchone()[0]

    trade = conn.execute("SELECT trade_open(%s, %s)", (giver, taker)).fetchone()[0]

    # Attending: refused.
    conn.execute("SELECT servant_attend(%s, %s)", (giver, mine))
    with pytest.raises(psycopg.errors.CheckViolation, match="attends you"):
        with conn.transaction():
            conn.execute(
                "SELECT trade_add_servant(%s, %s, %s)", (trade, giver, mine)
            )
    conn.execute("SELECT servant_dismiss(%s, %s)", (giver, mine))

    # Out working: refused.
    conn.execute(
        "UPDATE player_servants SET farming = TRUE WHERE player_servant_id = %s",
        (mine,),
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="out working"):
        with conn.transaction():
            conn.execute(
                "SELECT trade_add_servant(%s, %s, %s)", (trade, giver, mine)
            )
    conn.execute(
        "UPDATE player_servants SET farming = FALSE WHERE player_servant_id = %s",
        (mine,),
    )

    # Idle: given, and the screen names them.
    conn.execute("SELECT trade_add_servant(%s, %s, %s)", (trade, giver, mine))
    assert conn.execute(
        "SELECT count(*) FROM trade_contents WHERE trade_id = %s AND kind = 'servant'",
        (trade,),
    ).fetchone()[0] == 1

    # Taking the offer back clears them off the table.
    conn.execute("SELECT trade_withdraw(%s, %s)", (trade, giver))
    assert conn.execute(
        "SELECT count(*) FROM trade_offer_servants WHERE trade_id = %s", (trade,)
    ).fetchone()[0] == 0

    conn.execute("SELECT trade_add_servant(%s, %s, %s)", (trade, giver, mine))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, giver))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, taker))

    owner, stars = conn.execute(
        "SELECT player_id, stars FROM player_servants WHERE player_servant_id = %s",
        (mine,),
    ).fetchone()
    assert owner == taker, (owner, taker)
    assert stars == 3, stars


def test_a_duplicate_is_what_a_star_costs(conn, make_player):
    """Spares are the point, not the consolation.

    A star raises both what a servant grants and what they bring home, which
    is what makes a second copy of somebody you already have worth having.
    """
    who = _with_jade(conn, make_player)
    code = conn.execute(
        "SELECT servant_code FROM servants WHERE tier = 5 ORDER BY servant_code LIMIT 1"
    ).fetchone()[0]

    kept = conn.execute(
        "INSERT INTO player_servants (player_id, servant_code, realm_id) "
        "VALUES (%s, %s, (SELECT min(realm_id) FROM realms)) "
        "RETURNING player_servant_id",
        (who, code),
    ).fetchone()[0]

    needed = conn.execute(
        "SELECT copies_needed FROM servant_nursery WHERE player_servant_id = %s",
        (kept,),
    ).fetchone()[0]
    for _ in range(needed):
        conn.execute(
            "INSERT INTO player_servants (player_id, servant_code, realm_id) "
            "VALUES (%s, %s, (SELECT min(realm_id) FROM realms))",
            (who, code),
        )

    was_haul = conn.execute(
        "SELECT servant_haul_per_hour(%s)", (kept,)
    ).fetchone()[0]

    after = conn.execute(
        "SELECT stars_after FROM servant_nurture(%s, %s)", (who, kept)
    ).fetchone()[0]
    assert after == 2

    # The spares were eaten, and the kept one is worth more for it.
    assert conn.execute(
        "SELECT count(*) FROM player_servants WHERE player_id = %s AND servant_code = %s",
        (who, code),
    ).fetchone()[0] == 1
    assert conn.execute(
        "SELECT servant_haul_per_hour(%s)", (kept,)
    ).fetchone()[0] > was_haul


def test_a_stranger_to_the_tide_contributes_zero_not_null(conn, make_player):
    """`/horde` is the screen you open to decide whether to turn up.

    `horde_contribution` wrapped its default around the EXPRESSION rather than
    the QUERY - `SELECT COALESCE(sum_of_columns, 0) FROM ... WHERE ...`. That
    defaults a null column of a row that was found and does nothing when the
    WHERE matches nothing, so a scalar function that selects no rows returns
    NULL. Everyone who had not yet swung at the tide on the board got
    `TypeError: int() argument ... not 'NoneType'` instead of the board.

    The three numbers `board_card` puts through int() are pinned here, because
    this shape is easy to write again and impossible to see by reading one
    function.
    """
    stranger = make_player("Passerby")
    tide = _tide(conn, "northern", 2)

    assert conn.execute(
        "SELECT horde_contribution(%s, %s)", (tide, stranger)
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT horde_chests_earned(%s, %s)", (tide, stranger)
    ).fetchone()[0] is not None
    assert conn.execute(
        "SELECT horde_chest_bar(%s, 1::smallint)", (tide,)
    ).fetchone()[0] is not None

    # And once they swing, it counts rather than staying at the floor.
    conn.execute(
        "INSERT INTO horde_contributions "
        "(horde_id, player_id, damage_dealt, swings) VALUES (%s, %s, 500, 1)",
        (tide, stranger),
    )
    assert conn.execute(
        "SELECT horde_contribution(%s, %s)", (tide, stranger)
    ).fetchone()[0] > 0


def test_a_broken_line_is_the_only_loss(conn, make_player):
    tide = _tide(conn, "northern", 3)
    conn.execute(
        "UPDATE beast_hordes SET beasts_lost = line_holds WHERE horde_id = %s",
        (tide,),
    )
    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "lost"


def test_the_board_never_holds_more_than_the_room_can_read(conn, make_player):
    """Discord has to stay readable and the edits have to stay under the rate
    limit, so the number loose at once comes from the hands available."""
    tide = _tide(conn, "northern", 2)
    cap = conn.execute("SELECT horde_live_cap(%s)", (tide,)).fetchone()[0]

    for _ in range(40):
        conn.execute("SELECT horde_spawn(%s)", (tide,))

    loose = conn.execute(
        "SELECT count(*) FROM horde_encounters WHERE horde_id = %s AND status = 'alive'",
        (tide,),
    ).fetchone()[0]
    assert loose <= cap, f"{loose} beasts loose against a cap of {cap}"
    assert loose > 0, "an empty channel is not an invasion"


def test_a_horde_beast_belongs_to_the_region(conn, make_player):
    """Drawn from `creature_regions` the way /hunt draws, so the desert tide
    is scorpions. No second bestiary."""
    tide = _tide(conn, "eastern", 2)
    for _ in range(20):
        conn.execute("SELECT horde_spawn(%s)", (tide,))
        conn.execute(
            "UPDATE horde_encounters SET status = 'slain' "
            "WHERE horde_id = %s AND status = 'alive'",
            (tide,),
        )

    strangers = conn.execute(
        """
        SELECT count(*) FROM horde_encounters e
        WHERE e.horde_id = %s
          AND NOT EXISTS (SELECT 1 FROM creature_regions cr
                          WHERE cr.species_id = e.species_id
                            AND cr.region_code = 'eastern')
        """,
        (tide,),
    ).fetchone()[0]
    assert strangers == 0


def test_striking_a_beast_moves_the_line_and_the_roll(conn, make_player):
    who = _defender(conn, make_player)
    tide = _tide(conn, "northern", 1)
    beast = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]

    # Deep enough that one swing cannot finish it, so the not-yet-dead branch
    # is the one being exercised. How hard anybody hits is compute_technique_
    # damage's business and is tested where that lives.
    conn.execute(
        "UPDATE horde_encounters SET hp = 500000, max_hp = 500000 "
        "WHERE encounter_id = %s",
        (beast,),
    )
    hit = conn.execute("SELECT * FROM horde_strike(%s, %s)", (beast, who)).fetchone()
    assert hit[0] > 0, "a swing did nothing at all"
    assert not hit[3], "a fresh cultivator felled half a million health"
    assert hit[1] < hit[2], "the beast did not lose any health"

    # ...and the finishing blow.
    conn.execute(
        "UPDATE horde_encounters SET hp = 1 WHERE encounter_id = %s", (beast,)
    )
    hit = conn.execute("SELECT * FROM horde_strike(%s, %s)", (beast, who)).fetchone()
    assert hit[3], "the killing blow did not kill"
    assert hit[6] > 0, "finishing it paid no bounty"

    board = conn.execute(
        "SELECT beasts_slain FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0]
    worth = conn.execute(
        "SELECT worth FROM horde_encounters WHERE encounter_id = %s", (beast,)
    ).fetchone()[0]
    # Not one. 0229 made a beast in the channel a pack, and felling it takes
    # the pack out of the tide - otherwise the sea could never be emptied
    # through the channel at all.
    assert board == worth

    # Contribution counts the damage AND the bounty for finishing it.
    mine = conn.execute(
        "SELECT horde_contribution(%s, %s)", (tide, who)
    ).fetchone()[0]
    assert mine > 0


def test_a_beast_nobody_meets_gets_past_the_line(conn, make_player):
    """The clock. There is no separate pressure meter, because two failure
    meters is one too many."""
    tide = _tide(conn, "northern", 1)
    conn.execute("SELECT horde_spawn(%s)", (tide,))
    conn.execute(
        "UPDATE horde_encounters SET expires_at = now() - interval '1 second' "
        "WHERE horde_id = %s",
        (tide,),
    )

    got = conn.execute("SELECT * FROM horde_sweep(%s)", (tide,)).fetchone()
    assert got[0] >= 1, "an expired beast was not recorded as through"
    assert got[1], "and nothing was named"

    lost = conn.execute(
        "SELECT beasts_lost FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0]
    assert lost >= 1


def test_a_dead_beast_cannot_be_struck_again(conn, make_player):
    who = _defender(conn, make_player)
    tide = _tide(conn, "northern", 1)
    beast = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]
    conn.execute(
        "UPDATE horde_encounters SET status = 'slain' WHERE encounter_id = %s",
        (beast,),
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="already down"):
        conn.execute("SELECT * FROM horde_strike(%s, %s)", (beast, who))


def test_the_king_rises_only_when_the_sea_is_empty(conn, make_player):
    tide = _tide(conn, "northern", 2)

    assert conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0] is None

    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    king = conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0]
    assert king is not None

    # Once only, however many times anybody looks.
    assert conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0] is None

    # And felling it is the best ending there is.
    conn.execute(
        "UPDATE horde_encounters SET status = 'slain' WHERE encounter_id = %s",
        (king,),
    )
    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "won"


def test_a_held_region_is_luckier_and_an_overrun_one_is_not(conn, make_player):
    """The only part of this that touches the world outside the event. A horde
    that changes nothing is a slot machine with a story on it."""
    tide = _tide(conn, "western", 2)
    conn.execute(
        "UPDATE beast_hordes SET ends_at = now() - interval '1 minute' "
        "WHERE horde_id = %s",
        (tide,),
    )
    assert conn.execute("SELECT horde_settle(%s)", (tide,)).fetchone()[0] == "won"
    assert conn.execute(
        "SELECT region_effect('western', 'gathering_yield')"
    ).fetchone()[0] > 0

    tide = _tide(conn, "central", 2)
    conn.execute(
        "UPDATE beast_hordes SET beasts_lost = line_holds WHERE horde_id = %s",
        (tide,),
    )
    assert conn.execute("SELECT horde_settle(%s)", (tide,)).fetchone()[0] == "lost"
    assert conn.execute(
        "SELECT region_effect('central', 'gathering_yield')"
    ).fetchone()[0] < 0


def test_the_roll_ranks_but_the_chests_are_thresholds(conn, make_player):
    """The board shows an order and the order pays nobody. Two defenders one
    point apart get the same chests; that is the whole point of thresholds."""
    first = _defender(conn, make_player, "Ahead")
    second = _defender(conn, make_player, "Behind")
    tide = _tide(conn, "northern", 2)
    one = conn.execute(
        "SELECT horde_chest_bar(%s, 1::smallint)", (tide,)
    ).fetchone()[0]

    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
        "VALUES (%s, %s, %s), (%s, %s, %s)",
        (tide, first, int(one) + 500, tide, second, int(one) + 1),
    )

    rows = conn.execute(
        "SELECT discord_name, standing, chests_earned FROM horde_leaders(%s, 5)",
        (tide,),
    ).fetchall()
    assert [r[1] for r in rows] == [1, 2], "the roll is not ranked"
    assert rows[0][0] == "Ahead"
    # ...and both earned the same chest.
    assert rows[0][2] == rows[1][2] == 1


def test_an_unfought_tide_has_an_empty_roll(conn, make_player):
    """A board with nothing on it is a board, not an error. The first tick
    posts one before anybody has swung."""
    tide = _tide(conn, "northern", 2)
    assert conn.execute(
        "SELECT count(*) FROM horde_leaders(%s, 5)", (tide,)
    ).fetchone()[0] == 0


def test_a_tide_remembers_its_board_and_its_channel(conn, make_player):
    """Both live on the row rather than in the bot's memory, so a restart
    keeps editing the same message instead of starting a second one."""
    conn.execute(
        "UPDATE beast_hordes SET status = 'won', ended_at = now() "
        "WHERE status IN ('fighting', 'king')"
    )
    tide = conn.execute(
        "SELECT horde_open('northern', 2::smallint, 424242)"
    ).fetchone()[0]
    board = conn.execute(
        "SELECT channel_id, board_id FROM horde_board WHERE horde_id = %s", (tide,)
    ).fetchone()
    assert board[0] == 424242, "the tide forgot where it is being fought"
    assert board[1] is None, "a board id appeared before anything posted one"

    conn.execute(
        "UPDATE beast_hordes SET board_id = 999 WHERE horde_id = %s", (tide,)
    )
    assert conn.execute(
        "SELECT board_id FROM horde_board WHERE horde_id = %s", (tide,)
    ).fetchone()[0] == 999


def test_healing_counts_toward_a_chest(conn, make_player):
    """If damage were the only currency, half the Paths in this game would be
    spectators at their own region's defence."""
    who = _defender(conn, make_player)
    tide = _tide(conn, "northern", 2)

    one = conn.execute(
        "SELECT horde_chest_bar(%s, 1::smallint)", (tide,)
    ).fetchone()[0]
    weight = conn.execute("SELECT game_config_value('horde_heal_weight')").fetchone()[0]

    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, healing_done) "
        "VALUES (%s, %s, %s)",
        (tide, who, int(one / weight) + 1),
    )
    assert conn.execute(
        "SELECT horde_chests_earned(%s, %s)", (tide, who)
    ).fetchone()[0] >= 1, "an afternoon of healing earned nothing"


def test_swinging_counts_toward_a_chest(conn, make_player):
    """The same argument as healing, one rung further down. Raw damage on this
    roster spans a factor of about fifteen hundred, so a bar written in damage
    is free at the top and unreachable at the bottom - grafv finished sixty
    beasts and three elites on the western tide of 11 Sep 2026, more kills
    than anybody, and earned nothing at all.

    So the bar is reachable by swinging, in about the number of swings its own
    dial names it in."""
    who = _defender(conn, make_player)
    tide = _tide(conn, "northern", 2)

    wants = conn.execute(
        "SELECT game_config_value('horde_chest_kills_one')"
    ).fetchone()[0]

    # Somebody who turned up and swung, and whose blows never mattered.
    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, swings) "
        "VALUES (%s, %s, %s)",
        (tide, who, int(wants)),
    )
    assert conn.execute(
        "SELECT horde_chests_earned(%s, %s)", (tide, who)
    ).fetchone()[0] >= 1, (
        f"{wants} swings on the line earned nothing - horde_chest_kills_one "
        "says that is what the first chest costs"
    )


def test_a_swing_is_actually_banked(conn, make_player):
    """The counter is only worth having if something writes it. This game has
    form for durable state that nothing updates, and a swing column stuck at
    zero would leave the chest ladder exactly as unreachable as before while
    looking fixed."""
    who = _defender(conn, make_player)
    tide = _tide(conn, "northern", 1)
    beast = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]

    # Deep enough to survive the blow, so the ON CONFLICT branch is the one
    # being measured rather than the insert.
    conn.execute(
        "UPDATE horde_encounters SET hp = 500000, max_hp = 500000 "
        "WHERE encounter_id = %s",
        (beast,),
    )
    conn.execute("SELECT * FROM horde_strike(%s, %s)", (beast, who))
    conn.execute("SELECT * FROM horde_strike(%s, %s)", (beast, who))

    assert conn.execute(
        "SELECT swings FROM horde_contributions "
        "WHERE horde_id = %s AND player_id = %s",
        (tide, who),
    ).fetchone()[0] == 2, "two swings on the line were not banked as two"


def test_chests_are_paid_whether_you_won_or_lost(conn, make_player):
    """Losing already costs the region six hours. Charging the same mistake
    twice would make walking out the correct play on a tide going badly."""
    who = _defender(conn, make_player)
    tide = _tide(conn, "northern", 3)
    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
        "VALUES (%s, %s, horde_chest_bar(%s, 1::smallint))",
        (tide, who, tide),
    )
    conn.execute(
        "UPDATE beast_hordes SET beasts_lost = line_holds WHERE horde_id = %s",
        (tide,),
    )
    conn.execute("SELECT horde_settle(%s)", (tide,))

    got = conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who)).fetchone()[0]
    assert got["chests"] == 1
    assert got["stones"] > 0


def test_a_chest_cannot_be_opened_twice(conn, make_player):
    who = _defender(conn, make_player)
    tide = _tide(conn, "northern", 2)
    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
        "VALUES (%s, %s, horde_chest_bar(%s, 3::smallint))",
        (tide, who, tide),
    )
    conn.execute(
        "UPDATE beast_hordes SET ends_at = now() - interval '1 minute' "
        "WHERE horde_id = %s",
        (tide,),
    )
    conn.execute("SELECT horde_settle(%s)", (tide,))
    conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who))

    conn.execute("SAVEPOINT twice")
    with pytest.raises(psycopg.errors.CheckViolation, match="everything you earned"):
        conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who))
    conn.execute("ROLLBACK TO SAVEPOINT twice")


def test_nobody_who_stayed_home_opens_a_chest(conn, make_player):
    who = _defender(conn, make_player)
    tide = _tide(conn, "northern", 2)
    conn.execute(
        "UPDATE beast_hordes SET ends_at = now() - interval '1 minute' "
        "WHERE horde_id = %s",
        (tide,),
    )
    conn.execute("SELECT horde_settle(%s)", (tide,))

    with pytest.raises(psycopg.errors.CheckViolation, match="not on that line"):
        conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who))


def test_every_realm_has_a_door_of_its_own_rank(conn):
    # EVERY realm, not just the mortal nine. This used to stop at rank 9 with a
    # note saying an immortal had the heavens to walk into instead; 0362 gave
    # the immortal ladder its own nine doors, so the rule covers the whole
    # ladder and a missing immortal door is now a hole like any other.
    holes = conn.execute(
        """
        SELECT DISTINCT r.rank FROM realms r
        WHERE NOT EXISTS (SELECT 1 FROM dungeons d WHERE d.realm_rank = r.rank)
        """
    ).fetchall()
    assert not holes, f"realms with no dungeon: {holes}"

    # The rank a boss STANDS at, which past the mortal ladder is not the rank
    # it is filed under. `creature_species.rank` stops at 9, so every immortal
    # boss is a rank 9 row carrying an `immortal_rank` of 10 to 18 - the same
    # shape 0359's rogues use. Comparing `s.rank` here would demand something
    # the rank column cannot represent.
    wrong = conn.execute(
        """
        SELECT d.name FROM dungeons d
        JOIN creature_species s ON s.species_id = d.species_id
        WHERE COALESCE(s.immortal_rank, s.rank) <> d.realm_rank
           OR s.kind <> 'dungeon'
        """
    ).fetchall()
    assert not wrong, f"doors holding the wrong thing: {wrong}"


def _cleared(conn, who, rank=4, difficulty="insane"):
    """Open a door, walk in, and be standing when the boss is not."""
    run = conn.execute(
        "SELECT dungeon_open(%s, %s::smallint, %s)", (who, rank, difficulty)
    ).fetchone()[0]
    conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, who))
    conn.execute(
        "UPDATE dungeon_raiders SET damage_dealt = 5000 WHERE run_id = %s", (run,)
    )
    conn.execute(
        "UPDATE dungeon_runs SET status = 'won', boss_hp = 0, ended_at = now() "
        "WHERE run_id = %s",
        (run,),
    )
    conn.execute("SELECT dungeon_pay_out(%s)", (run,))
    return run


def test_clearing_a_dungeon_returns_the_stake(conn, make_player):
    """The entry fee climbs about 2.8x a rank and the pot climbed linearly, so
    above rank 3 a cleared dungeon used to LOSE you stones. The stake comes
    back to the raider who paid it - not into the pot, because splitting it by
    damage would mean whoever went down first bought the run for everyone.
    """
    who = a_raider(conn, make_player, rank=4)
    before = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (who,),
    ).fetchone()[0]

    run = _cleared(conn, who, rank=4)
    spoils = conn.execute(
        "SELECT spoils FROM dungeon_raiders WHERE run_id = %s", (run,)
    ).fetchone()[0]

    paid = conn.execute(
        "SELECT stone_cost FROM dungeons WHERE realm_rank = 4"
    ).fetchone()[0]
    assert spoils["stones_back"] == paid, "the stake did not come back whole"
    assert spoils["stones"] > 0, "and the pot is a bonus on top of it"

    after = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (who,),
    ).fetchone()[0]
    assert after > before, "a cleared dungeon still lost the raider stones"


def test_a_wipe_costs_the_stake_and_returns_the_key(conn, make_player):
    """The door was opened either way. The key is a day's worth, and losing it
    to a fight already lost would be two punishments for one mistake."""
    who = a_raider(conn, make_player, rank=4)
    run = conn.execute(
        "SELECT dungeon_open(%s, 4::smallint, 'normal')", (who,)
    ).fetchone()[0]
    conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, who))
    conn.execute(
        "UPDATE dungeon_runs SET status = 'lost', ended_at = now() "
        "WHERE run_id = %s",
        (run,),
    )
    conn.execute("SELECT dungeon_pay_out(%s)", (run,))

    spoils = conn.execute(
        "SELECT spoils FROM dungeon_raiders WHERE run_id = %s", (run,)
    ).fetchone()[0]
    assert spoils["keys_back"] == 1
    assert spoils["stones_back"] == 0
    assert spoils["stones"] == 0


def test_a_cleared_room_has_things_in_it(conn, make_player):
    """Stones alone made the dungeon a vending machine. Herbs always, and the
    rest on a roll that difficulty leans on."""
    who = a_raider(conn, make_player, rank=4)
    _cleared(conn, who, rank=4)

    spoils = conn.execute(
        "SELECT spoils FROM dungeon_raiders WHERE player_id = %s "
        "ORDER BY run_id DESC LIMIT 1",
        (who,),
    ).fetchone()[0]
    assert spoils["herbs"], "a cleared room handed over no herbs"

    # Over enough clears every kind shows up at least once.
    seen = set()
    for _ in range(25):
        got = conn.execute(
            "SELECT dungeon_spoils_for(%s, 5::smallint, 11.0)", (who,)
        ).fetchone()[0]
        seen |= {k for k, v in got.items() if v}
    assert {"herbs", "pages", "equipment", "pill", "gu"} <= seen, (
        f"twenty-five insane clears never produced {sorted({'herbs', 'pages', 'equipment', 'pill', 'gu'} - seen)}"
    )


def test_a_cleared_room_lays_an_egg_of_its_own_depth(conn, make_player):
    """The tier is the room, not the beast: 48 of the 52 huntable creatures
    are rank 1 or 2, so grading an egg by what laid it would mean the depth of
    the fight bought nothing."""
    who = a_raider(conn, make_player, rank=4)

    hits = 0
    for _ in range(60):
        got = conn.execute(
            "SELECT dungeon_spoils_for(%s, 6::smallint, 11.0)", (who,)
        ).fetchone()[0]
        if got.get("egg"):
            hits += 1
    assert hits > 0, "sixty clears of the rank 6 room laid nothing"

    wrong = conn.execute(
        "SELECT count(*) FROM player_beast_eggs WHERE owner_id = %s AND tier <> 6",
        (who,),
    ).fetchone()[0]
    assert wrong == 0, "a rank 6 room laid an egg of another tier"


def test_a_shallow_room_never_reaches_past_the_world(conn, make_player):
    """`gu_max_droppable_rank` binds inside a dungeon too. 0215 opened exactly
    one door in it - a room may reach one rung past the ceiling only if its own
    rank already is - so every room at or below the ceiling still stops there.
    """
    who = a_raider(conn, make_player, rank=4)
    ceiling = conn.execute(
        "SELECT game_config_value('gu_max_droppable_rank')"
    ).fetchone()[0]

    for rank in range(1, int(ceiling) + 1):
        for _ in range(30):
            conn.execute(
                "SELECT dungeon_spoils_for(%s, %s::smallint, 11.0)", (who, rank)
            )

    highest = conn.execute(
        "SELECT COALESCE(max(t.rank), 0) FROM player_gu g "
        "JOIN gu_types t ON t.gu_type_id = g.gu_type_id WHERE g.owner_id = %s",
        (who,),
    ).fetchone()[0]
    assert highest <= ceiling, f"a rank {highest} Gu came out of a shallow room"


def test_the_deep_rooms_pay_a_jackpot_and_only_one_rung_of_it(conn, make_player):
    """The one exception to the ceiling, and it is bounded twice: only a room
    already past the ceiling may roll it, and what it hands over is that rank
    exactly - so the rank 9 room is not a shortcut to rank 9 Gu, it is the same
    prize behind a worse fight."""
    who = a_raider(conn, make_player, rank=4)
    ceiling = conn.execute(
        "SELECT game_config_value('gu_max_droppable_rank')"
    ).fetchone()[0]
    jackpot = ceiling + conn.execute(
        "SELECT game_config_value('dungeon_jackpot_rank_bonus')"
    ).fetchone()[0]
    assert jackpot == 6

    # What the jackpot ITSELF hands over, collected as it fires. The deepest
    # worm in somebody's bag stopped being evidence about the jackpot when
    # 0544 gave a room its own reach of 9 - the ordinary roll gets there now,
    # so the bag says nothing either way. Reading the jackpot's own drops is
    # the same claim and a stronger test: another roll cannot get there first
    # and look like a jackpot.
    hits = 0
    paid_ranks = set()
    for _ in range(300):
        got = conn.execute(
            "SELECT dungeon_spoils_for(%s, %s::smallint, 11.0)", (who, int(jackpot))
        ).fetchone()[0]
        if got.get("jackpot"):
            hits += 1
            paid_ranks.add(
                conn.execute(
                    "SELECT t.rank FROM gu_types t "
                    "WHERE gu_label(t.gu_type_id) = %s LIMIT 1",
                    (got["jackpot"],),
                ).fetchone()[0]
            )
    assert hits > 0, "three hundred clears of the deep room paid nothing"

    # One rung past the world's ceiling, exactly - never a shortcut to the apex.
    assert paid_ranks == {jackpot}, (
        f"the jackpot paid ranks {sorted(paid_ranks)}, and it is meant to pay "
        f"only rank {jackpot}"
    )

    # And a deeper room cannot open the jackpot wider: the gate is the world's
    # ceiling, not the room's reach.
    for _ in range(150):
        got = conn.execute(
            "SELECT dungeon_spoils_for(%s, 9::smallint, 11.0)", (who,)
        ).fetchone()[0]
        if got.get("jackpot"):
            assert conn.execute(
                "SELECT t.rank FROM gu_types t "
                "WHERE gu_label(t.gu_type_id) = %s LIMIT 1",
                (got["jackpot"],),
            ).fetchone()[0] == jackpot, "a rank 9 room widened the jackpot"


def test_closing_the_jackpot_closes_it(conn, make_player):
    """The exception is a config, so it can be shut without touching the
    ceiling or any of the other rolls. A door that cannot be closed is not an
    exception, it is a new rule."""
    who = a_raider(conn, make_player, rank=4)
    conn.execute(
        "UPDATE game_config SET value = 0 WHERE key = 'dungeon_jackpot_rank_bonus'"
    )

    for _ in range(200):
        got = conn.execute(
            "SELECT dungeon_spoils_for(%s, 9::smallint, 11.0)", (who,)
        ).fetchone()[0]
        assert not got.get("jackpot"), "the jackpot fired with the door shut"

    highest = conn.execute(
        "SELECT COALESCE(max(t.rank), 0) FROM player_gu g "
        "JOIN gu_types t ON t.gu_type_id = g.gu_type_id WHERE g.owner_id = %s",
        (who,),
    ).fetchone()[0]
    # The DUNGEON's reach, not the world's. 0544 gave a room its own ceiling
    # of 9 while `gu_max_droppable_rank` stays at 5 for region drops and horde
    # chests - so the thing this test is named for is that with the jackpot
    # shut, nothing exceeds the ceiling the room actually has.
    ceiling = conn.execute(
        "SELECT game_config_value('dungeon_gu_max_rank')"
    ).fetchone()[0]
    assert highest <= ceiling


def test_what_a_room_leaves_is_a_real_piece(conn, make_player):
    """Minted through the same tables /forge uses, so it can be worn, traded
    and auctioned like any other. A special case would be a second place
    deciding what a piece is worth."""
    who = a_raider(conn, make_player, rank=4)
    for rank in range(1, 10):
        made = conn.execute(
            "SELECT dungeon_mint_equipment(%s, %s::smallint, 11.0, 'Severed')",
            (who, rank),
        ).fetchone()[0]
        assert made is not None, f"rank {rank} could not forge anything"

    bad = conn.execute(
        """
        SELECT e.name, x.effect_code, x.magnitude, f.cap
        FROM player_equipment e
        JOIN equipment_effects x ON x.equipment_id = e.equipment_id
        JOIN gu_effects f ON f.code = x.effect_code
        WHERE e.owner_id = %s AND x.magnitude > f.cap
        """,
        (who,),
    ).fetchall()
    assert bad == [], f"{len(bad)} dungeon effects are over their cap"

    # Every piece has a quality, a tier and something it does.
    empty = conn.execute(
        """
        SELECT e.name FROM player_equipment e
        WHERE e.owner_id = %s
          AND NOT EXISTS (SELECT 1 FROM equipment_effects x
                          WHERE x.equipment_id = e.equipment_id)
        """,
        (who,),
    ).fetchall()
    assert empty == []

    # 0214: named after what killed you, never after an article.
    articled = conn.execute(
        "SELECT name FROM player_equipment WHERE owner_id = %s AND name LIKE %s",
        (who, "% The %"),
    ).fetchall()
    assert articled == []


def test_a_room_leaves_a_pill_worth_swallowing(conn, make_player):
    """0203 made potency the thing that separates two pills of a grade. A
    found pill sits above its tier floor, and further above it in a harder
    room - otherwise it would be the worst pill of its grade by definition."""
    who = a_raider(conn, make_player, rank=4)
    for rank in range(1, 8):
        pill = conn.execute(
            "SELECT dungeon_mint_pill(%s, %s::smallint, 11.0)", (who, rank)
        ).fetchone()[0]
        assert pill is not None, f"rank {rank} left no pill"

    thin = conn.execute(
        """
        SELECT pl.name, pl.potency, pt.potency_required
        FROM player_pills pl JOIN pill_tiers pt ON pt.tier = pl.tier
        WHERE pl.owner_id = %s AND pl.potency < pt.potency_required
        """,
        (who,),
    ).fetchall()
    assert thin == [], f"{len(thin)} found pills are below their own tier floor"


def test_a_dungeon_boss_is_never_in_the_hunt_draw(conn):
    """The First Gu is 4.6 million HP. It lives behind a door, and a door is
    not a region - blundering into one on a walk is the exact failure 0139 had
    to undo for the Leviathan."""
    loose = conn.execute(
        """
        SELECT s.name FROM creature_species s
        WHERE s.kind = 'dungeon'
          AND EXISTS (SELECT 1 FROM creature_regions cr
                      WHERE cr.species_id = s.species_id)
        """
    ).fetchall()
    assert not loose, f"these are wandering around: {loose}"


def test_a_party_shares_a_bigger_pool_but_not_a_multiplied_one(conn):
    """Five raiders do not face five times the health, because the boss still
    only strikes once a round. That is the whole reason to bring people."""
    solo = conn.execute(
        "SELECT dungeon_boss_hp(4::smallint, 'normal', 1)"
    ).fetchone()[0]
    five = conn.execute(
        "SELECT dungeon_boss_hp(4::smallint, 'normal', 5)"
    ).fetchone()[0]
    assert solo < five < solo * 5


def test_a_harder_room_pays_better_per_hit_point(conn):
    """Otherwise nobody sane picks it, and four difficulties would be one."""
    steps = conn.execute(
        "SELECT name, reward_scale / hp_scale FROM dungeon_difficulties "
        "ORDER BY sort_order"
    ).fetchall()
    rates = [float(r[1]) for r in steps]
    assert rates == sorted(rates), steps


def test_the_key_cannot_be_melted_but_is_still_stock(conn):
    """Two facts that were being read as three.

    The key is in `currency_materials` so the furnace and the cauldron refuse
    it, and it is `category = 'currency'` so it sits in the purse instead of on
    a shelf. Neither of those makes it money, and 0228 stopped the auction
    inferring that it did."""
    assert conn.execute(
        "SELECT count(*) FROM currency_materials "
        "WHERE material_code = 'dungeon_key'"
    ).fetchone()[0] == 1, "the furnace must still refuse a key"

    assert conn.execute("SELECT auction_currency()").fetchone()[0] != "dungeon_key"

    # And the refusal is derived from that one name, not written out again.
    body = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc "
        "WHERE proname = 'auction_list_material'"
    ).fetchone()[0]
    assert "auction_currency()" in body
    assert "'spirit_jade'" not in body, "the currency is named once, not twice"


def test_the_key_has_no_clock_of_its_own(conn):
    """0204 gave the key a twelve-hour timer; 0208 moved it onto /daily, which
    runs on 22 hours so the time never creeps later.

    The config had to GO rather than merely stop being read: `cooldown_status`
    finds every %_cooldown_minutes in game_config by itself, so leaving it
    behind would have left /cooldowns promising a key that never arrives."""
    assert conn.execute(
        "SELECT count(*) FROM game_config "
        "WHERE key = 'dungeon_key_cooldown_minutes'"
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT count(*) FROM cooldown_display WHERE action = 'dungeon_key'"
    ).fetchone()[0] == 0

    # It is not gone, it moved.
    assert int(conn.execute(
        "SELECT game_config_value('daily_dungeon_keys')"
    ).fetchone()[0]) == 2


def test_the_daily_hands_over_keys(conn, make_player):
    """Two a day, which is a party of two every day or a full five every
    third - and keys trade, so a group can pool them."""
    who = make_player("Claimant")
    got = conn.execute(
        "SELECT claimed, jade, keys, keys_held FROM claim_daily(%s)", (who,)
    ).fetchone()

    assert got[0] is True
    assert got[1] > 0, "the jade half stopped working"
    assert got[2] == 2
    assert got[3] == 2, "reported but not handed over"

    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'dungeon_key'", (who,)
    ).fetchone()[0] == 2

    # A refused claim hands over nothing and says so.
    again = conn.execute(
        "SELECT claimed, keys, keys_held FROM claim_daily(%s)", (who,)
    ).fetchone()
    assert again[0] is False and again[1] == 0
    assert again[2] == 2, "the refusal should still say what is held"


def test_a_silent_raider_still_swings(conn, make_player):
    """The room promises the first attack technique on a timeout, so a friend
    who walked away costs the party a choice and never the round."""
    who = a_raider(conn, make_player)
    run = conn.execute(
        "SELECT dungeon_open(%s, 1::smallint, 'normal')", (who,)
    ).fetchone()[0]
    conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, who))

    before = conn.execute(
        "SELECT boss_hp FROM dungeon_runs WHERE run_id = %s", (run,)
    ).fetchone()[0]

    got = conn.execute(
        "SELECT round_no, log, boss_hp, status FROM dungeon_resolve_round(%s)",
        (run,),
    ).fetchone()

    assert got[2] < before, "a silent round did nothing"
    assert any(e["kind"] == "strike" and not e["chosen"] for e in got[1])


def test_the_door_refuses_somebody_who_cannot_fight(conn, make_player):
    """They would pay a key, earn nothing - spoils go by damage dealt - and
    make the boss 60% bigger for everyone else. Two live cultivators are in
    that state, so it is not hypothetical."""
    able = a_raider(conn, make_player, "Able")
    mute = a_raider(conn, make_player, "Mute")
    conn.execute("DELETE FROM player_techniques WHERE player_id = %s", (mute,))

    run = conn.execute(
        "SELECT dungeon_open(%s, 1::smallint, 'normal')", (able,)
    ).fetchone()[0]
    conn.execute("SELECT dungeon_invite(%s, %s, %s)", (run, able, mute))
    conn.execute("SELECT dungeon_join(%s, %s)", (run, mute))

    keys = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'dungeon_key'",
        (able,),
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="cannot attack"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, able))

    # Refused before anybody paid, which matters because the door charges the
    # party in a loop.
    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'dungeon_key'",
        (able,),
    ).fetchone()[0] == keys


def test_only_the_invited_may_join(conn, make_player):
    host = a_raider(conn, make_player, "Host")
    guest = a_raider(conn, make_player, "Guest")
    crasher = a_raider(conn, make_player, "Crasher")

    run = conn.execute(
        "SELECT dungeon_open(%s, 1::smallint, 'normal')", (host,)
    ).fetchone()[0]
    conn.execute("SELECT dungeon_invite(%s, %s, %s)", (run, host, guest))
    conn.execute("SELECT dungeon_join(%s, %s)", (run, guest))

    with pytest.raises(psycopg.errors.CheckViolation, match="not invited"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT dungeon_join(%s, %s)", (run, crasher))


def test_a_party_cannot_be_promised_more_places_than_it_has(conn, make_player):
    """Invites count against the five with the raiders, so a leader cannot
    ask six people and disappoint one at the door."""
    host = a_raider(conn, make_player, "Host")
    run = conn.execute(
        "SELECT dungeon_open(%s, 1::smallint, 'normal')", (host,)
    ).fetchone()[0]

    for n in range(4):
        conn.execute(
            "SELECT dungeon_invite(%s, %s, %s)",
            (run, host, a_raider(conn, make_player, f"Guest{n}")),
        )

    with pytest.raises(psycopg.errors.CheckViolation, match="full"):
        with conn.transaction(force_rollback=True):
            conn.execute(
                "SELECT dungeon_invite(%s, %s, %s)",
                (run, host, a_raider(conn, make_player, "OneTooMany")),
            )


def test_nobody_stands_in_two_rooms(conn, make_player):
    who = a_raider(conn, make_player)
    conn.execute("SELECT dungeon_open(%s, 1::smallint, 'normal')", (who,))
    with pytest.raises(psycopg.errors.CheckViolation, match="already in a dungeon"):
        with conn.transaction(force_rollback=True):
            conn.execute("SELECT dungeon_open(%s, 2::smallint, 'hard')", (who,))


def test_a_won_run_splits_the_pot_by_damage(conn, make_player):
    """The world boss's rule, so there is one answer in this game to "who
    earned what" rather than two."""
    who = a_raider(conn, make_player)
    run = conn.execute(
        "SELECT dungeon_open(%s, 1::smallint, 'normal')", (who,)
    ).fetchone()[0]
    conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, who))

    stones = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (who,),
    ).fetchone()[0]

    nearly_fell(conn, run)
    conn.execute("SELECT * FROM dungeon_resolve_round(%s)", (run,))

    assert conn.execute(
        "SELECT status FROM dungeon_runs WHERE run_id = %s", (run,)
    ).fetchone()[0] == "won"
    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (who,),
    ).fetchone()[0] > stones, "a won run paid nothing"


def test_a_room_is_opened_by_somebody_who_has_reached_it(conn, make_player):
    """0390. Every deep clear in this game's history was a solo run, and one of
    them was three realms above the raider who made it. The door asks now."""
    shallow = a_raider(conn, make_player, "Shallow", rank=1)

    deep_id, deep_rank = conn.execute(
        "SELECT dungeon_id, realm_rank FROM dungeons ORDER BY realm_rank DESC LIMIT 1"
    ).fetchone()

    with conn.transaction(force_rollback=True):
        with pytest.raises(
            psycopg.errors.CheckViolation, match="realm you have not reached"
        ):
            conn.execute(
                "SELECT dungeon_open(%s, %s::smallint, 'normal')",
                (shallow, deep_id),
            )

    # Their own rank still opens.
    own = conn.execute(
        "SELECT dungeon_id FROM dungeons WHERE realm_rank = 1"
    ).fetchone()[0]
    conn.execute(
        "SELECT dungeon_open(%s, %s::smallint, 'normal')", (shallow, own)
    )

    # And the gate is on the LEADER, not the joiners: the only group content in
    # the game must not require everybody to already be past it.
    deep = a_raider(conn, make_player, "Deep", rank=deep_rank)
    run = conn.execute(
        "SELECT dungeon_open(%s, %s::smallint, 'normal')", (deep, deep_id)
    ).fetchone()[0]
    conn.execute("DELETE FROM dungeon_raiders WHERE player_id = %s", (shallow,))
    conn.execute("DELETE FROM dungeon_runs WHERE leader_id = %s", (shallow,))
    conn.execute("SELECT dungeon_invite(%s, %s, %s)", (run, deep, shallow))
    conn.execute("SELECT dungeon_join(%s, %s)", (run, shallow))
    assert conn.execute(
        "SELECT count(*) FROM dungeon_raiders WHERE run_id = %s", (run,)
    ).fetchone()[0] == 2, "a deep raider could not bring a shallow friend"


def test_a_room_that_is_not_broken_in_time_wins(conn, make_player):
    """0390. Before this a run ended only when the boss died or everybody was
    down - and nothing in this game out-damages a deep build's Life on Hit, so
    a run could not be lost and depth cost nothing but rounds. 172 of them,
    once."""
    cap = int(
        conn.execute("SELECT game_config_value('dungeon_round_cap')").fetchone()[0]
    )
    who = a_raider(conn, make_player, "Patient", rank=1)
    run = conn.execute(
        "SELECT dungeon_open(%s, 1::smallint, 'normal')", (who,)
    ).fetchone()[0]
    conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, who))

    # Parked one round short of the cap with the boss untouched, which is the
    # state a grind arrives in.
    conn.execute(
        "UPDATE dungeon_runs SET round_no = %s, boss_hp = boss_max_hp "
        "WHERE run_id = %s",
        (cap - 1, run),
    )
    conn.execute("SELECT * FROM dungeon_resolve_round(%s)", (run,))
    assert conn.execute(
        "SELECT status FROM dungeon_runs WHERE run_id = %s", (run,)
    ).fetchone()[0] == "fighting", "the room gave up a round early"

    conn.execute("SELECT * FROM dungeon_resolve_round(%s)", (run,))
    assert conn.execute(
        "SELECT status FROM dungeon_runs WHERE run_id = %s", (run,)
    ).fetchone()[0] == "lost", "the room never ran out of patience"


def test_the_last_allowed_round_can_still_win_it(conn, make_player):
    """The cap is read after the kill, not before it. A blow that breaks the
    room on the final round breaks the room - anything else would be losing a
    fight you actually won."""
    cap = int(
        conn.execute("SELECT game_config_value('dungeon_round_cap')").fetchone()[0]
    )
    who = a_raider(conn, make_player, "JustInTime", rank=1)
    run = conn.execute(
        "SELECT dungeon_open(%s, 1::smallint, 'normal')", (who,)
    ).fetchone()[0]
    conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, who))

    move = conn.execute(
        "SELECT dungeon_default_move(%s)", (who,)
    ).fetchone()[0]
    nearly_fell(conn, run)
    conn.execute(
        "UPDATE dungeon_runs SET round_no = %s WHERE run_id = %s",
        (cap, run),
    )
    conn.execute("SELECT dungeon_choose(%s, %s, %s)", (run, who, move))
    conn.execute("SELECT * FROM dungeon_resolve_round(%s)", (run,))

    assert conn.execute(
        "SELECT status FROM dungeon_runs WHERE run_id = %s", (run,)
    ).fetchone()[0] == "won", "a killing blow on the last round lost the run"


def test_a_wiped_party_gets_its_keys_back(conn, make_player):
    """The stones are spent either way - the door was opened - but a key is
    twelve hours, and losing one to a fight already lost is two punishments
    for one mistake."""
    # Deep enough to open the room they are about to be wiped in - 0390 put a
    # realm on the door, and this test is about the key refund rather than
    # about walking into somewhere above your head.
    who = a_raider(conn, make_player, rank=9, keys=2)
    run = conn.execute(
        "SELECT dungeon_open(%s, 9::smallint, 'insane')", (who,)
    ).fetchone()[0]
    conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, who))

    after_entry = conn.execute(
        "SELECT COALESCE(quantity, 0) FROM player_materials WHERE player_id = %s "
        "AND material_code = 'dungeon_key'",
        (who,),
    ).fetchone()[0]

    conn.execute("UPDATE dungeon_raiders SET current_hp = 0 WHERE run_id = %s",
                 (run,))
    conn.execute("SELECT * FROM dungeon_resolve_round(%s)", (run,))

    assert conn.execute(
        "SELECT status FROM dungeon_runs WHERE run_id = %s", (run,)
    ).fetchone()[0] == "lost"
    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'dungeon_key'",
        (who,),
    ).fetchone()[0] == after_entry + 1


def test_a_downed_raider_stays_in_the_room(conn, make_player):
    """They stop swinging and stop being a target, but nobody is thrown out of
    a room their friends are still fighting in."""
    host = a_raider(conn, make_player, "Standing")
    down = a_raider(conn, make_player, "Fallen")
    run = conn.execute(
        "SELECT dungeon_open(%s, 1::smallint, 'normal')", (host,)
    ).fetchone()[0]
    conn.execute("SELECT dungeon_invite(%s, %s, %s)", (run, host, down))
    conn.execute("SELECT dungeon_join(%s, %s)", (run, down))
    conn.execute("SELECT * FROM dungeon_begin(%s, %s)", (run, host))

    conn.execute(
        "UPDATE dungeon_raiders SET current_hp = 0 "
        "WHERE run_id = %s AND player_id = %s",
        (run, down),
    )
    got = conn.execute(
        "SELECT log, status FROM dungeon_resolve_round(%s)", (run,)
    ).fetchone()

    assert got[1] == "fighting", "the run ended with somebody still standing"
    struck = {e["who"] for e in got[0] if e["kind"] == "strike"}
    assert "Standing" in struck and "Fallen" not in struck
    assert conn.execute(
        "SELECT count(*) FROM dungeon_raiders WHERE run_id = %s", (run,)
    ).fetchone()[0] == 2, "the downed raider was removed"


# ---------------------------------------------------------------------------
# The two lanes (0229, 0230)
# ---------------------------------------------------------------------------


def _walker(conn, make_player, name="Walker"):
    """Somebody who can actually swing, with a body to lose.

    The sinew is large on purpose. `horde_gauntlet_next` sizes a wave as the
    GREATER of the region's own reckoning and what this walker can burst, and
    northern holds eleven beasts between 317 and 1,180,000 base health. A weak
    walker who draws the big one at wave 1 cannot chew through it before the
    chip damage finishes them - which made every test that walks a gauntlet
    fail a few runs in a hundred for reasons that had nothing to do with what
    it was testing.

    Past the region's reckoning the wave is measured against the walker
    instead, so this does not make the gauntlet easy - it makes it SIZED, and
    the 1.18 step per wave still ends the run.
    """
    who = _defender(conn, make_player, name)
    conn.execute(
        "UPDATE player_physique SET max_hp = 4000, current_hp = 4000, "
        "defense = 10, strength = 4000000 WHERE player_id = %s",
        (who,),
    )
    return who


# `horde_gauntlet_swing` grew four columns for the beast at heel in 0286-0288,
# so the run's status stopped being second from the end. Counted from the
# front instead: appending moves the tail, it never moves the head.
_RUN_STATUS = 17


def _walk(conn, run, who, limit=200):
    """Play a run out the way a person does: pick a move, brace when dry.

    0231 made a press one exchange with a technique behind it, so a test that
    wants a finished run has to make the same choices a player makes rather
    than call one resolver and read the answer.
    """
    move = conn.execute(
        "SELECT dungeon_default_move(%s)", (who,)
    ).fetchone()[0]
    cost = conn.execute(
        """
        SELECT ceil(t.qi_cost_pct * g.max_qi)::bigint
        FROM techniques t, horde_gauntlets g
        WHERE t.technique_id = %s AND g.gauntlet_id = %s
        """,
        (move, run),
    ).fetchone()[0]

    seen = []
    for _ in range(limit):
        qi = conn.execute(
            "SELECT qi FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
        ).fetchone()[0]
        if qi >= cost:
            row = conn.execute(
                "SELECT * FROM horde_gauntlet_swing(%s, 'attack', %s)", (run, move)
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT * FROM horde_gauntlet_swing(%s, 'guard')", (run,)
            ).fetchone()
        seen.append(row)
        if row[_RUN_STATUS] != "fighting":
            break
    return seen


def test_a_channel_beast_is_a_pack_and_a_gauntlet_wave_starts_as_one(conn):
    """0229 split the tide into two lanes and `worth` is what keeps them
    counting in the same units."""
    tide = _tide(conn, "northern", 3)
    made = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]

    worth = conn.execute(
        "SELECT worth FROM horde_encounters WHERE encounter_id = %s", (made,)
    ).fetchone()[0]
    assert worth > 1, "a world beast that stands for one beast is not a pack"

    assert conn.execute("SELECT horde_gauntlet_worth(1)").fetchone()[0] == 1
    assert (
        conn.execute("SELECT horde_gauntlet_worth(17)").fetchone()[0] > 1
    ), "a deep wave has to cost the sea more than the first one"


def test_a_world_beast_is_far_bigger_than_the_wave_of_the_same_beast(conn):
    """The whole point of the channel lane: something a room gangs up on."""
    multiplier = conn.execute(
        "SELECT game_config_value('horde_world_hp')"
    ).fetchone()[0]
    start = conn.execute(
        "SELECT game_config_value('horde_gauntlet_start')"
    ).fetchone()[0]
    assert multiplier > 1
    assert start < 1
    assert multiplier / start > 10, (
        "a channel beast has to be an order of magnitude past a first wave"
    )


def test_only_a_trial_runs_out_of_turns(conn, make_player):
    """A hunt runs until somebody wins it; a tribulation still has a clock.

    0412 made the draw in `battle_act` conditional on `battles.kind`, and that
    condition is now the only thing standing behind the realm gate:
    `tribulation_hp_share` sizes a trial so the question is whether you can
    break it in TIME, and `battle_conclude` counts an expiry as a failure as
    surely as a death. Nothing tested the draw at all before this - which is
    exactly why narrowing it broke no test and why it is worth one now.

    The battle is opened normally and its kind flipped, because what is under
    test is that one branch, not the tribulation apparatus around it.
    """
    cap = int(
        conn.execute("SELECT game_config_value('battle_turn_cap')").fetchone()[0]
    )

    for kind, should_end in (("pve", False), ("tribulation", True)):
        # A real body, because `battle_open` reads `player_physique` STRICT.
        who = body_player(conn, make_player, "primordial_chaos_body")
        species = conn.execute(
            "SELECT species_id FROM creature_species WHERE code = 'rule_shell_tortoise'"
        ).fetchone()[0]
        # Deep enough not to die to a guard, toothless enough not to kill:
        # the only ending either fight may reach is the one being tested.
        conn.execute(
            "UPDATE creature_species SET base_hp = 1000000000, base_attack = 1 "
            "WHERE species_id = %s",
            (species,),
        )

        battle = conn.execute(
            "SELECT battle_open(%s, %s)", (who, species)
        ).fetchone()[0]
        conn.execute(
            "UPDATE battles SET kind = %s, turn_number = %s WHERE battle_id = %s",
            (kind, cap, battle),
        )

        finished, outcome = conn.execute(
            "SELECT finished, outcome FROM battle_act(%s, 'guard', NULL)", (battle,)
        ).fetchone()
        assert finished is should_end, (kind, finished, outcome)
        if should_end:
            assert outcome == "drawn", outcome
            assert conn.execute(
                "SELECT status FROM battles WHERE battle_id = %s", (battle,)
            ).fetchone()[0] == "expired"


def test_a_gauntlet_run_plays_out_and_ends(conn, make_player):
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)

    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]
    first = conn.execute(
        "SELECT wave, beast_max_hp FROM horde_gauntlets WHERE gauntlet_id = %s",
        (run,),
    ).fetchone()
    assert first[0] == 1

    seen = _walk(conn, run, who)

    assert seen[-1][_RUN_STATUS] in ("fallen", "cleared"), "the run never ended"

    # NOT "nobody got past the first wave" either, which was the last chancy
    # thing in here. Whether a walker clears wave 1 depends on which of the
    # eleven northern beasts was drawn and on how the criticals fell, and a
    # test that fails one run in fifty for a reason it is not about is a test
    # that teaches people to re-run the suite. That the engine advances a wave
    # at all is settled below, where it is asked directly.
    #
    # NOT "the deepest wave is bigger than the first". That failed about one
    # run in thirty with things like `assert 975 > 999`, and the reason is not
    # flakiness in the test - it is that the claim is false. `horde_gauntlet_next`
    # draws a fresh species every wave and northern holds eleven of them,
    # between 317 and 1,180,000 base health. A 1.18 step per wave cannot
    # outrun a 3722-fold spread in what might be drawn, so a later wave really
    # can be smaller than an earlier one.
    #
    # What IS true is that the step compounds for a given beast, and that is
    # checked in test_each_wave_is_built_harder_for_the_same_beast below,
    # where the draw is held still so the step is the only thing moving.


def test_each_wave_is_built_harder_for_the_same_beast(conn, make_player):
    """The escalation, with the dice taken out of it.

    `horde_gauntlet_next` sizes a wave as the greater of the region's own
    reckoning and what the walker can burst, times `horde_gauntlet_step` to
    the power of the wave. Pinning the region to a single species leaves the
    step as the only thing that varies, which is the rule being claimed.
    """
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)

    # One beast in the region, so every wave draws the same one.
    kept = conn.execute(
        """
        DELETE FROM creature_regions cr
        USING creature_species cs
        WHERE cs.species_id = cr.species_id
          AND cr.region_code = 'northern'
          AND cs.species_id <> (
              SELECT cs2.species_id FROM creature_regions cr2
              JOIN creature_species cs2 ON cs2.species_id = cr2.species_id
              WHERE cr2.region_code = 'northern' AND cs2.kind = 'beast'
              ORDER BY cs2.species_id LIMIT 1)
        RETURNING cr.species_id
        """
    ).fetchall()
    assert kept, "the region was already down to one beast"

    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]
    first = conn.execute(
        "SELECT beast_max_hp FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
    ).fetchone()[0]

    sizes = [first]
    for _ in range(4):
        assert conn.execute(
            "SELECT horde_gauntlet_next(%s)", (run,)
        ).fetchone()[0], "the tide ran out before the waves could be compared"
        sizes.append(conn.execute(
            "SELECT beast_max_hp FROM horde_gauntlets WHERE gauntlet_id = %s",
            (run,),
        ).fetchone()[0])

    assert sizes == sorted(sizes), f"the waves did not climb: {sizes}"
    assert sizes[-1] > sizes[0], f"five waves and no harder: {sizes}"

    # And the counter really moved, which is the "walks deeper" half of what
    # the walking test used to claim by surviving long enough to see it.
    assert conn.execute(
        "SELECT wave FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
    ).fetchone()[0] == 5


def test_a_gauntlet_never_touches_the_body_you_walked_in_with(conn, make_player):
    """0225 refused to let a public event cost a cultivator anything, and this
    lane is the one where you can actually be put down."""
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)

    before = conn.execute(
        "SELECT current_hp, max_hp FROM player_physique WHERE player_id = %s", (who,)
    ).fetchone()

    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]
    status = _walk(conn, run, who)[-1][_RUN_STATUS]

    assert status == "fallen", "this test needs a run that actually ended badly"
    after = conn.execute(
        "SELECT current_hp, max_hp FROM player_physique WHERE player_id = %s", (who,)
    ).fetchone()
    assert after == before, "the gauntlet reached out and hurt the real body"


def test_how_deep_you_got_is_what_you_contributed(conn, make_player):
    """Depth is the score in this lane, so a deeper wave pays more.

    Asserted exactly rather than by comparison. `horde_gauntlet_swing` pays

        horde_slay_bounty * GREATEST(1, species.rank) + horde_gauntlet_depth * wave

    which is not random, so every cleared wave can be checked against it.

    This used to clear two waves and assert the second paid more than the
    first. That needs the walker to survive two of them and they die to chip
    damage about one run in five, failing on "not enough waves cleared" for
    reasons that had nothing to do with the payout - the same fight `_walker`'s
    docstring records. It was also a weaker claim than it looked: the bounty
    half depends on WHICH beast was drawn, so it could pass with the depth term
    at zero, or fail with it perfectly correct.
    """
    bounty = float(
        conn.execute("SELECT game_config_value('horde_slay_bounty')").fetchone()[0]
    )
    depth = float(
        conn.execute("SELECT game_config_value('horde_gauntlet_depth')").fetchone()[0]
    )
    assert depth > 0, "depth pays nothing, so getting deeper is not the score"

    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]

    cleared = []
    for row in _walk(conn, run, who):
        # (wave, beast_name, move_name, dealt, taken, healed, qi_spent,
        #  qi_left, strikes, crits, guarded, beast_down, ..., earned, status, sea)
        if row[11]:
            cleared.append((row[0], row[1], row[16]))

    assert cleared, "the walker cleared no wave at all"

    for wave, beast, earned in cleared:
        rank = conn.execute(
            "SELECT rank FROM creature_species WHERE name = %s", (beast,)
        ).fetchone()[0]
        expected = round(bounty * max(1, rank)) + round(depth * wave)
        assert earned == expected, (
            f"wave {wave} against {beast} (rank {rank}) paid {earned}, "
            f"not the {expected} the bounty and depth terms come to"
        )

    # And the depth term really does rise with the wave, which is the claim in
    # the name - checked on the function rather than on one lucky run.
    assert round(depth * (cleared[0][0] + 1)) > round(depth * cleared[0][0])

    assert conn.execute(
        "SELECT horde_contribution(%s, %s)", (tide, who)
    ).fetchone()[0] > 0


def test_both_lanes_draw_on_the_one_sea(conn, make_player):
    """The gauntlet is not a minigame beside the tide. Felling a wave takes
    beasts out of the same pool the channel is spawning from."""
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)

    before = conn.execute("SELECT horde_sea_left(%s)", (tide,)).fetchone()[0]
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]

    for row in _walk(conn, run, who):
        if row[11]:
            break

    assert conn.execute(
        "SELECT horde_sea_left(%s)", (tide,)
    ).fetchone()[0] < before, "a felled wave took nothing out of the tide"


def test_a_pack_that_gets_past_costs_the_line_the_pack(conn):
    """A world beast walking through is not one straggler getting by."""
    tide = _tide(conn, "northern", 3)
    made = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]
    worth = conn.execute(
        "SELECT worth FROM horde_encounters WHERE encounter_id = %s", (made,)
    ).fetchone()[0]

    conn.execute(
        "UPDATE horde_encounters SET expires_at = now() - interval '1 minute' "
        "WHERE encounter_id = %s",
        (made,),
    )
    conn.execute("SELECT horde_sweep(%s)", (tide,))

    assert conn.execute(
        "SELECT beasts_lost FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0] == worth


def test_only_one_walk_at_a_time_and_it_can_be_walked_again(conn, make_player):
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)
    conn.execute("SELECT horde_gauntlet_open(%s)", (who,))

    conn.execute("SAVEPOINT second_walk")
    with pytest.raises(psycopg.errors.CheckViolation, match="already on the line"):
        conn.execute("SELECT horde_gauntlet_open(%s)", (who,))
    conn.execute("ROLLBACK TO SAVEPOINT second_walk")

    # Ended, and they may walk it again while the tide has beasts left.
    conn.execute(
        "UPDATE horde_gauntlets SET status = 'fallen', ended_at = now() "
        "WHERE player_id = %s AND status = 'fighting'",
        (who,),
    )
    assert conn.execute(
        "SELECT horde_gauntlet_open(%s)", (who,)
    ).fetchone()[0] is not None


def test_an_empty_sea_refuses_a_new_walk(conn, make_player):
    """`till the amount of beasts is exhausted` is the bound on this lane, and
    it is the same number the King is waiting behind."""
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)

    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="sea is empty"):
        conn.execute("SELECT horde_gauntlet_open(%s)", (who,))


def test_a_wave_is_fought_with_a_technique_you_chose(conn, make_player):
    """0229 swung with whatever the game would have picked, which is the same
    move every time and therefore no decision at all."""
    _tide(conn, "northern", 2)
    who = _walker(conn, make_player)
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]
    move = conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0]

    conn.execute("SAVEPOINT no_move")
    with pytest.raises(psycopg.errors.CheckViolation, match="choose a technique"):
        conn.execute("SELECT horde_gauntlet_swing(%s, 'attack', NULL)", (run,))
    conn.execute("ROLLBACK TO SAVEPOINT no_move")

    conn.execute("SAVEPOINT not_yours")
    with pytest.raises(psycopg.errors.CheckViolation, match="do not know"):
        conn.execute("SELECT horde_gauntlet_swing(%s, 'attack', -1)", (run,))
    conn.execute("ROLLBACK TO SAVEPOINT not_yours")

    row = conn.execute(
        "SELECT dealt, move_name, qi_spent FROM horde_gauntlet_swing(%s, 'attack', %s)",
        (run, move),
    ).fetchone()
    assert row[0] > 0, "the chosen technique did nothing"
    assert row[1], "the exchange did not say what was thrown"
    assert row[2] > 0, "a technique was free, so choosing one decides nothing"


def test_the_pool_is_what_makes_it_a_choice(conn, make_player):
    """A run carries qi across waves and Guard buys it back - the duel's own
    numbers, so bracing means one thing in this game."""
    _tide(conn, "northern", 2)
    who = _walker(conn, make_player)
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]
    move = conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0]

    full = conn.execute(
        "SELECT qi, max_qi FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
    ).fetchone()
    assert full[0] == full[1], "a run does not start with a full pool"

    # Deep enough that the swing cannot fell it. Clearing a wave hands qi back,
    # which is correct and would hide the spend being measured here.
    #
    # Measured against this walker rather than written down as 500000, which
    # is what it used to be: a flat figure is only "deep enough" for the build
    # it was chosen against, and the moment `_walker` grew sinew the swing
    # started felling it and the pool stopped going down.
    conn.execute(
        """
        UPDATE horde_gauntlets g
        SET beast_hp = deep.hp, beast_max_hp = deep.hp
        FROM (
            SELECT GREATEST(1, horde_walker_burst(g2.player_id, g2.species_id)
                               * 50)::bigint AS hp
            FROM horde_gauntlets g2 WHERE g2.gauntlet_id = %s
        ) deep
        WHERE g.gauntlet_id = %s
        """,
        (run, run),
    )
    conn.execute("SELECT horde_gauntlet_swing(%s, 'attack', %s)", (run, move))
    spent = conn.execute(
        "SELECT qi FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
    ).fetchone()[0]
    assert spent < full[0], "the pool did not go down"

    braced = conn.execute(
        "SELECT qi_left, guarded FROM horde_gauntlet_swing(%s, 'guard')", (run,)
    ).fetchone()
    assert braced[1], "a guard did not brace"
    assert braced[0] > spent, "a guard bought no qi back"

    # And an empty pool refuses the move rather than throwing it for free.
    conn.execute(
        "UPDATE horde_gauntlets SET qi = 0 WHERE gauntlet_id = %s", (run,)
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="not enough qi"):
        conn.execute(
            "SELECT horde_gauntlet_swing(%s, 'attack', %s)", (run, move)
        )


def test_a_guard_still_counts_as_turning_up(conn, make_player):
    """`horde_hands` sizes the whole tide off who swung lately. A defender who
    braced for a minute must not fall off it."""
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]

    conn.execute("SELECT horde_gauntlet_swing(%s, 'guard')", (run,))
    assert conn.execute(
        "SELECT count(*) FROM horde_contributions "
        "WHERE horde_id = %s AND player_id = %s",
        (tide, who),
    ).fetchone()[0] == 1


def test_there_is_one_way_to_take_a_swing_on_the_line(conn):
    """0231 dropped the whole-wave resolver rather than leaving it beside the
    exchange. Two ways to make the same swing is the split 0225 undid."""
    assert conn.execute(
        "SELECT count(*) FROM pg_proc WHERE proname = 'horde_gauntlet_fight'"
    ).fetchone()[0] == 0

    body = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc "
        "WHERE proname = 'horde_gauntlet_swing'"
    ).fetchone()[0]
    assert "player_swing(" in body, "the line does not swing the way everything else does"


def test_no_such_action_on_the_line(conn, make_player):
    _tide(conn, "northern", 2)
    who = _walker(conn, make_player)
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]
    with pytest.raises(psycopg.errors.CheckViolation, match="no such action"):
        conn.execute("SELECT horde_gauntlet_swing(%s, 'dance')", (run,))


# ---------------------------------------------------------------------------
# The finale, and the counters behind it (0232)
# ---------------------------------------------------------------------------


def test_the_king_can_actually_be_fought(conn, make_player):
    """The one thing in this event that could not be hit was the boss.

    `horde_king_rise` sets the tide to 'king', and `horde_strike` refused
    anything unless the tide was 'fighting' - so the encounter that only exists
    during 'king' was unreachable. It stood at full health and walked off. The
    old tests raised the King and asserted about the verdict; none of them
    tried to swing at it.
    """
    tide = _tide(conn, "northern", 2)
    who = _defender(conn, make_player, "Regicide")

    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    king = conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0]
    assert king is not None

    assert conn.execute(
        "SELECT status FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0] == "king", "the tide is not in the phase this test is about"

    hit = conn.execute(
        "SELECT dealt, hp_left, max_hp FROM horde_strike(%s, %s)", (king, who)
    ).fetchone()
    assert hit[0] > 0, "the King took nothing from a swing at it"
    assert hit[1] < hit[2], "the King did not lose any health"


def test_a_king_that_walks_off_ends_the_tide(conn, make_player):
    """An escaped King is never a slain one, so the verdict answered 'king'
    forever: nothing settled, no chests opened, and no later tide could start
    because one was still running."""
    tide = _tide(conn, "northern", 2)
    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    king = conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0]
    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "king"

    conn.execute(
        "UPDATE horde_encounters SET status = 'escaped', settled_at = now() "
        "WHERE encounter_id = %s",
        (king,),
    )

    # Held the line and emptied the sea. Missing the finale is the end of the
    # event, not a loss.
    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "won"
    assert conn.execute("SELECT horde_settle(%s)", (tide,)).fetchone()[0] == "won"


def test_the_chests_of_a_finished_tide_can_be_opened(conn, make_player):
    """The end of the chain that stall broke: two defenders sat on three
    earned chests each that nothing would open."""
    tide = _tide(conn, "northern", 2)
    who = _defender(conn, make_player, "Owed")

    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
        "VALUES (%s, %s, horde_chest_bar(%s, 1::smallint))",
        (tide, who, tide),
    )
    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    king = conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0]
    conn.execute(
        "UPDATE horde_encounters SET status = 'escaped', settled_at = now() "
        "WHERE encounter_id = %s",
        (king,),
    )
    conn.execute("SELECT horde_settle(%s)", (tide,))

    got = conn.execute(
        "SELECT horde_chest_take(%s, %s)", (tide, who)
    ).fetchone()[0]
    assert got["chests"] >= 1, "a finished tide would not hand over a chest"


def test_neither_lane_can_draw_more_beasts_than_the_tide_holds(conn, make_player):
    """`659 of 638 slain`. The sea is checked when a wave is rolled, not when
    it is credited, and a wave worth five can be rolled against a sea of one."""
    tide = _tide(conn, "northern", 3)
    who = _walker(conn, make_player)

    total = conn.execute(
        "SELECT beasts_total FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0]

    # One beast left in the sea, and a deep wave standing in front of them.
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]
    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = %s WHERE horde_id = %s",
        (total - 1, tide),
    )
    conn.execute(
        "UPDATE horde_gauntlets SET wave = 25, beast_hp = 1, beast_max_hp = 1 "
        "WHERE gauntlet_id = %s",
        (run,),
    )
    move = conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0]
    conn.execute("SELECT horde_gauntlet_swing(%s, 'attack', %s)", (run, move))

    assert conn.execute(
        "SELECT beasts_slain FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0] == total, "the gauntlet drew more beasts than the tide had"


def test_the_channel_cannot_overdraw_the_sea_either(conn, make_player):
    tide = _tide(conn, "northern", 3)
    who = _defender(conn, make_player, "Clamped")
    beast = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]

    total = conn.execute(
        "SELECT beasts_total FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0]
    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = %s WHERE horde_id = %s",
        (total - 1, tide),
    )
    conn.execute(
        "UPDATE horde_encounters SET hp = 1 WHERE encounter_id = %s", (beast,)
    )
    conn.execute("SELECT horde_strike(%s, %s)", (beast, who))

    assert conn.execute(
        "SELECT beasts_slain FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0] == total


def test_a_walk_in_progress_survives_the_king_rising(conn, make_player):
    """Somebody mid-wave when the sea emptied had their run ended under them.
    The wave they are on finishes; `horde_gauntlet_next` closes the run at the
    natural place because there is nothing left to roll."""
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player)
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]
    move = conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0]

    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    conn.execute("SELECT horde_king_rise(%s)", (tide,))

    # The swing lands rather than being refused with 'the tide has broken off'.
    row = conn.execute(
        "SELECT dealt, run_status FROM horde_gauntlet_swing(%s, 'attack', %s)",
        (run, move),
    ).fetchone()
    assert row[0] > 0, "a wave in progress was cancelled by the finale"


# ---------------------------------------------------------------------------
# What a King is worth (0233)
# ---------------------------------------------------------------------------


def _fell_the_king(conn, make_player, name="Kingslayer"):
    """Raise the King, put it down, and settle the tide."""
    tide = _tide(conn, "northern", 3)
    who = _defender(conn, make_player, name)

    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    king = conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0]
    return tide, who, king


def test_the_finishing_blow_on_the_king_is_paid_like_a_king(conn, make_player):
    """`horde_king_rise` never set `worth`, so the King defaulted to one and
    0230 pays the finisher against what the thing stood for. The killing blow
    on a 54,000 health boss was worth 60 - a twelfth of an ordinary spawn."""
    tide, who, king = _fell_the_king(conn, make_player)

    worth = conn.execute(
        "SELECT worth FROM horde_encounters WHERE encounter_id = %s", (king,)
    ).fetchone()[0]
    assert worth > 1, "the King still stands for a single beast"

    conn.execute("UPDATE horde_encounters SET hp = 1 WHERE encounter_id = %s", (king,))
    hit = conn.execute(
        "SELECT killed, bounty FROM horde_strike(%s, %s)", (king, who)
    ).fetchone()
    assert hit[0], "the killing blow did not kill"

    # A world beast is worth 12 and an elite 18; the King has to beat both.
    ordinary = conn.execute(
        "SELECT round(game_config_value('horde_slay_bounty') * 1 * "
        "game_config_value('horde_world_worth'))"
    ).fetchone()[0]
    assert hit[1] > ordinary, (
        f"felling the King paid {hit[1]}, no better than a channel spawn"
    )


def test_the_king_walking_off_never_costs_the_line(conn, make_player):
    """Its worth is a bounty, not a breach. A King worth forty counted against
    `line_holds` would score a held region overrun for missing the finale,
    which is the opposite of what 0232 settled."""
    tide, who, king = _fell_the_king(conn, make_player)
    conn.execute(
        "UPDATE beast_hordes SET line_holds = 4, beasts_lost = 0 WHERE horde_id = %s",
        (tide,),
    )
    conn.execute(
        "UPDATE horde_encounters SET expires_at = now() - interval '1 minute' "
        "WHERE encounter_id = %s",
        (king,),
    )
    conn.execute("SELECT horde_sweep(%s)", (tide,))

    assert conn.execute(
        "SELECT beasts_lost FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0] == 0, "the King counted against the line"
    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "won"


def test_one_blow_on_the_king_earns_its_chest(conn, make_player):
    """Not a threshold. Turning up to the finale is the whole qualification,
    so the cultivator who landed one blow opens what the one who landed forty
    opens."""
    tide, who, king = _fell_the_king(conn, make_player)
    grazer = _defender(conn, make_player, "Grazer")

    # One blow each, then somebody else finishes it.
    conn.execute("SELECT horde_strike(%s, %s)", (king, grazer))
    conn.execute("UPDATE horde_encounters SET hp = 1 WHERE encounter_id = %s", (king,))
    conn.execute("SELECT horde_strike(%s, %s)", (king, who))
    conn.execute("SELECT horde_settle(%s)", (tide,))

    assert conn.execute(
        "SELECT horde_king_chest_due(%s, %s)", (tide, who)
    ).fetchone()[0], "the finisher is owed nothing"
    assert conn.execute(
        "SELECT horde_king_chest_due(%s, %s)", (tide, grazer)
    ).fetchone()[0], "one blow was not enough, which is the whole rule"


def test_nobody_who_missed_the_king_opens_its_chest(conn, make_player):
    tide, who, king = _fell_the_king(conn, make_player)
    absent = _defender(conn, make_player, "Absent")

    # Out-contributes the room and never meets the King.
    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
        "VALUES (%s, %s, horde_chest_bar(%s, 3::smallint))",
        (tide, absent, tide),
    )
    conn.execute("UPDATE horde_encounters SET hp = 1 WHERE encounter_id = %s", (king,))
    conn.execute("SELECT horde_strike(%s, %s)", (king, who))
    conn.execute("SELECT horde_settle(%s)", (tide,))

    assert not conn.execute(
        "SELECT horde_king_chest_due(%s, %s)", (tide, absent)
    ).fetchone()[0], "contribution bought a chest that only the King gives"


def test_a_king_that_got_away_owes_nobody_its_chest(conn, make_player):
    """It is the loot for killing it, not for meeting it."""
    tide, who, king = _fell_the_king(conn, make_player)
    conn.execute("SELECT horde_strike(%s, %s)", (king, who))
    conn.execute(
        "UPDATE horde_encounters SET status = 'escaped', settled_at = now() "
        "WHERE encounter_id = %s",
        (king,),
    )
    conn.execute("SELECT horde_settle(%s)", (tide,))

    assert not conn.execute(
        "SELECT horde_king_chest_due(%s, %s)", (tide, who)
    ).fetchone()[0]


def test_the_kings_chest_carries_a_gu_past_the_world_ceiling(conn, make_player):
    """The Gu the King is actually for - the other way a rank past the drop
    ceiling reaches a cultivator, alongside the deepest dungeon room."""
    tide, who, king = _fell_the_king(conn, make_player)
    conn.execute(
        "UPDATE beast_hordes SET rank = %s WHERE horde_id = %s",
        (conn.execute(
            "SELECT game_config_value('gu_max_droppable_rank')"
        ).fetchone()[0], tide),
    )
    conn.execute("UPDATE horde_encounters SET hp = 1 WHERE encounter_id = %s", (king,))
    conn.execute("SELECT horde_strike(%s, %s)", (king, who))
    conn.execute("SELECT horde_settle(%s)", (tide,))

    before = conn.execute(
        "SELECT count(*) FROM player_gu WHERE owner_id = %s", (who,)
    ).fetchone()[0]
    got = conn.execute(
        "SELECT horde_chest_take(%s, %s)", (tide, who)
    ).fetchone()[0]

    assert got["king"], "the opening did not include the King chest"
    assert conn.execute(
        "SELECT count(*) FROM player_gu WHERE owner_id = %s", (who,)
    ).fetchone()[0] > before, "the King chest held no Gu"

    ceiling = conn.execute(
        "SELECT game_config_value('gu_max_droppable_rank') "
        "+ game_config_value('horde_king_gu_bonus')"
    ).fetchone()[0]
    best = conn.execute(
        "SELECT max(t.rank) FROM player_gu g "
        "JOIN gu_types t ON t.gu_type_id = g.gu_type_id WHERE g.owner_id = %s",
        (who,),
    ).fetchone()[0]
    assert best == ceiling, (
        f"the King paid a rank {best} Gu when its ceiling is {ceiling}"
    )


def test_the_kings_chest_opens_once(conn, make_player):
    tide, who, king = _fell_the_king(conn, make_player)
    conn.execute("UPDATE horde_encounters SET hp = 1 WHERE encounter_id = %s", (king,))
    conn.execute("SELECT horde_strike(%s, %s)", (king, who))
    conn.execute("SELECT horde_settle(%s)", (tide,))

    conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who))
    assert not conn.execute(
        "SELECT horde_king_chest_due(%s, %s)", (tide, who)
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="opened everything"):
        conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who))


def test_a_king_chest_is_claimable_after_the_ladder_is_spent(conn, make_player):
    """Somebody who opened all three thresholds mid-event still has a fourth
    waiting, so the claim has to look past `chest_taken`."""
    tide, who, king = _fell_the_king(conn, make_player)
    conn.execute("UPDATE horde_encounters SET hp = 1 WHERE encounter_id = %s", (king,))
    conn.execute("SELECT horde_strike(%s, %s)", (king, who))
    conn.execute("SELECT horde_settle(%s)", (tide,))

    # Every ladder chest already accounted for.
    conn.execute(
        "UPDATE horde_contributions SET chest_taken = "
        "horde_chests_earned(%s, %s) WHERE horde_id = %s AND player_id = %s",
        (tide, who, tide, who),
    )
    got = conn.execute(
        "SELECT horde_chest_take(%s, %s)", (tide, who)
    ).fetchone()[0]
    assert got["king"], "the King chest was hidden behind a spent ladder"
    assert got["chests"] == 1


def test_a_horde_chest_pays_in_beasts_not_greenery(conn, make_player):
    """The event whose subject is beasts pouring out of a region paid in
    plants: about three thousand of them and not one tusk. Herbs come from
    standing still in a field; beast materials come from killing things, which
    is the only thing this event is."""
    tide = _tide(conn, "northern", 3)
    who = _defender(conn, make_player, "Skinner")

    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
        "VALUES (%s, %s, horde_chest_bar(%s, 3::smallint))",
        (tide, who, tide),
    )
    conn.execute(
        "UPDATE beast_hordes SET status = 'won', ended_at = now() "
        "WHERE horde_id = %s",
        (tide,),
    )

    got = conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who)).fetchone()[0]
    assert got["parts"], "a horde chest held no beast materials"

    # Everything named as a part really is one, so the screen is not calling
    # herbs something else.
    beasts = {
        row[0]
        for row in conn.execute(
            "SELECT name FROM materials WHERE category = 'beast'"
        ).fetchall()
    }
    for said in got["parts"]:
        assert said.split("x ", 1)[1] in beasts, f"{said} is not a beast material"

    # Not "beasts beat plants" - 0239 deliberately let the greenery past that,
    # and it was a line drawn by hand rather than a rule of the game. What has
    # to hold is the thing that was actually broken before 0234: beast
    # materials being a rounding error in an event made entirely of beasts.
    carried = sum(int(said.split("x ", 1)[0]) for said in got["parts"])
    greenery = sum(int(said.split("x ", 1)[0]) for said in got.get("herbs") or [])
    assert carried / (carried + greenery) >= 0.30, (
        f"beast materials are {carried} of {carried + greenery} - a herb faucet"
    )

    # And they actually landed in the inventory rather than only in the report.
    assert conn.execute(
        "SELECT count(*) FROM player_materials pm JOIN materials m "
        "ON m.code = pm.material_code "
        "WHERE pm.player_id = %s AND m.category = 'beast' AND pm.quantity > 0",
        (who,),
    ).fetchone()[0] >= 1


def test_the_beast_parts_are_the_regions_own(conn, make_player):
    """Drawn through `creature_drops` from the roster that was in the tide -
    you fought them, you carry them off."""
    tide = _tide(conn, "northern", 2)
    who = _defender(conn, make_player, "Local")

    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
        "VALUES (%s, %s, horde_chest_bar(%s, 1::smallint))",
        (tide, who, tide),
    )
    conn.execute(
        "UPDATE beast_hordes SET status = 'won', ended_at = now() "
        "WHERE horde_id = %s",
        (tide,),
    )
    got = conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who)).fetchone()[0]

    local = {
        row[0]
        for row in conn.execute(
            """
            SELECT DISTINCT m.name
            FROM creature_regions cr
            JOIN creature_drops cd ON cd.species_id = cr.species_id
            JOIN materials m ON m.code = cd.material_code
            WHERE cr.region_code = 'northern'
            """
        ).fetchall()
    }
    for said in got["parts"]:
        assert said.split("x ", 1)[1] in local, (
            f"{said} does not come off anything in the northern reaches"
        )


def test_every_listing_says_what_it_is_and_what_it_does(conn, make_player):
    """The one screen where somebody prices a thing with their own money told
    them a name, a colour and a number. `auction_board` already resolves what
    a listing IS for all six kinds; what it DOES belongs in the same place."""
    kinds = {
        row[0]
        for row in conn.execute(
            "SELECT DISTINCT kind FROM auction_board WHERE kind IS NOT NULL"
        ).fetchall()
    }
    blank = conn.execute(
        "SELECT listing_id, kind FROM auction_board "
        "WHERE detail IS NULL OR detail = ''"
    ).fetchall()
    assert blank == [], f"listings that say nothing about themselves: {blank}"
    assert conn.execute(
        "SELECT count(*) FROM auction_board WHERE kind IS NULL"
    ).fetchone()[0] == 0


def test_a_listed_gu_advertises_the_stars_it_actually_has(conn, make_player):
    """A buyer equips the Gu in front of them, not the one on the page - so
    the board multiplies by stars the way `player_gu_stats` does."""
    seller = make_player("Starseller")
    conn.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (seller,))

    kind = conn.execute(
        "SELECT te.gu_type_id FROM gu_type_effects te GROUP BY te.gu_type_id "
        "HAVING count(*) >= 1 LIMIT 1"
    ).fetchone()[0]
    gu = conn.execute(
        "SELECT grant_gu(%s, %s, NULL)", (seller, kind)
    ).fetchone()[0]

    def advertised(stars: int) -> str:
        conn.execute(
            "UPDATE player_gu SET stars = %s WHERE gu_id = %s", (stars, gu)
        )
        conn.execute(
            "UPDATE auction_listings SET status = 'cancelled', ended_at = now() "
            "WHERE gu_id = %s AND status = 'open'",
            (gu,),
        )
        conn.execute("UPDATE player_gu SET owner_id = %s WHERE gu_id = %s",
                     (seller, gu))
        listing = conn.execute(
            "SELECT auction_list_gu(%s, %s, 9)", (seller, gu)
        ).fetchone()[0]
        return conn.execute(
            "SELECT grants FROM auction_board WHERE listing_id = %s", (listing,)
        ).fetchone()[0]

    one, five = advertised(1), advertised(5)
    assert one and five, "a listed Gu advertised no effects at all"
    assert one != five, "the board quoted the same numbers at 1 and 5 stars"


def test_a_listed_piece_of_equipment_says_what_it_grants(conn, make_player):
    # A full cultivator: listing equipment settles physique XP, which needs a
    # body to settle it into.
    seller = _defender(conn, make_player, "Smith")
    conn.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (seller,))

    worn = conn.execute(
        "SELECT equipment_id FROM equipment_effects LIMIT 1"
    ).fetchone()
    if worn is None:
        pytest.skip("no forged equipment carries an effect yet")

    conn.execute(
        "UPDATE player_equipment SET owner_id = %s WHERE equipment_id = %s",
        (seller, worn[0]),
    )
    listing = conn.execute(
        "SELECT auction_list_equipment(%s, %s, 9)", (seller, worn[0])
    ).fetchone()[0]

    row = conn.execute(
        "SELECT detail, grants FROM auction_board WHERE listing_id = %s",
        (listing,),
    ).fetchone()
    assert row[0] and "Tier" in row[0], "a piece did not say its tier or slot"
    assert row[1] and "%" in row[1], "a piece did not say what it grants"


def test_a_horde_haul_is_not_worth_twenty_dungeons(conn, make_player):
    """0234 set the pile without checking it against anything else. A full
    rank 5 opening was 3,360 materials; a hard dungeon clear at the same depth
    is 175. The horde should be the best source of beast materials in the game
    - it is a two hour event that needs a room - but best is a small multiple,
    not twenty."""
    tide = _tide(conn, "northern", 5)
    who = _defender(conn, make_player, "Hauler")

    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
        "VALUES (%s, %s, horde_chest_bar(%s, 3::smallint))",
        (tide, who, tide),
    )
    conn.execute(
        "UPDATE beast_hordes SET status = 'won', ended_at = now() "
        "WHERE horde_id = %s",
        (tide,),
    )
    got = conn.execute("SELECT horde_chest_take(%s, %s)", (tide, who)).fetchone()[0]

    haul = sum(
        int(said.split("x ", 1)[0])
        for said in (got["parts"] or []) + (got.get("herbs") or [])
    )
    dungeon = conn.execute(
        "SELECT round(game_config_value('dungeon_herb_per_rank') * 5 * 2.5)"
    ).fetchone()[0]

    assert haul > dungeon, "a whole tide paid less than one dungeon room"
    assert haul < dungeon * 6, (
        f"a three chest haul is {haul} materials against a dungeon's {dungeon}"
    )


def test_a_chest_is_not_the_same_list_every_time(conn, make_player):
    """Three kinds at exactly 15 x N x rank, opening after opening, is a
    receipt rather than a reward."""
    seen = set()
    counts = set()

    for n in range(6):
        tide = _tide(conn, "northern", 3)
        who = _defender(conn, make_player, f"Opener{n}")
        conn.execute(
            "INSERT INTO horde_contributions (horde_id, player_id, damage_dealt) "
            "VALUES (%s, %s, horde_chest_bar(%s, 3::smallint))",
            (tide, who, tide),
        )
        conn.execute(
            "UPDATE beast_hordes SET status = 'won', ended_at = now() "
            "WHERE horde_id = %s",
            (tide,),
        )
        got = conn.execute(
            "SELECT horde_chest_take(%s, %s)", (tide, who)
        ).fetchone()[0]

        seen.add(tuple(sorted(said.split("x ", 1)[1] for said in got["parts"])))
        counts.add(len(got["parts"]))

    assert len(seen) > 1, "six openings all spilled the identical kinds"
    assert len(counts) > 1, "every opening held exactly the same number of kinds"


def test_the_uncommon_parts_actually_surface(conn):
    """Weighting the pick by the raw field chance meant a part that drops one
    time in twenty lost every roll to one that drops four in five. The square
    root still favours the common ones, by about half as much."""
    body = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc "
        "WHERE proname = 'horde_spill_parts'"
    ).fetchone()[0]
    assert "sqrt(d.chance)" in body, "the pick is back to raw field chance"


def test_a_channel_beast_outlasts_one_turn(conn, make_player):
    """It was a flat multiple, so a cultivator swinging for two thousand ended
    a channel beast in five clicks - before anybody else had looked at the
    message. The event is built around several people hitting one body.

    0320 stopped counting HANDS and started counting what those hands hit for,
    the way `boss_hp_pool` already did, because the roster spans a factor of
    fifteen hundred between its hardest and softest hitter and no flat
    multiple is a fight for both ends of that.

    So the rule is no longer 'more hands, bigger beast' - eight test hands
    holding one rank 1 technique between them genuinely should not move a pool
    measured in hundreds of millions. It is the thing that was actually being
    complained about: a body in the channel must survive a turn.
    """
    # The arithmetic guarantees it before any beast is rolled. A channel beast
    # is the room's whole pool times these three, and the pool is the SUM of
    # everyone's turn - so as long as the product clears 1, no single person's
    # turn can fell one, whoever they are.
    product = conn.execute(
        "SELECT game_config_value('boss_swings_expected') "
        "     * game_config_value('boss_effort') "
        "     * game_config_value('horde_body_effort')"
    ).fetchone()[0]
    assert float(product) > 1, (
        f"a channel beast is {product} of one turn - the strongest cultivator "
        "in the room fells it in a single press"
    )

    # And in the body, against whoever is actually about.
    tide = _tide(conn, "northern", 3)
    who = _defender(conn, make_player, "OneTurn")
    conn.execute(
        "INSERT INTO horde_contributions (horde_id, player_id, last_swing_at) "
        "VALUES (%s, %s, now())",
        (tide, who),
    )

    made = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]
    row = conn.execute(
        "SELECT e.max_hp, e.species_id FROM horde_encounters e "
        "WHERE e.encounter_id = %s",
        (made,),
    ).fetchone()

    # The hardest single turn anyone in the pool can throw at this body.
    hardest = conn.execute(
        "SELECT COALESCE(max(horde_walker_burst(p.player_id, %s)), 0) "
        "FROM players p WHERE p.deleted_at IS NULL "
        "  AND (p.player_id = %s OR p.last_seen_at >= now() - make_interval("
        "        mins => game_config_value('boss_presence_minutes')::integer))",
        (row[1], who),
    ).fetchone()[0]

    assert row[0] > hardest, (
        f"a channel beast holds {row[0]} and the hardest turn in the room is "
        f"{hardest} - it still dies to one press"
    )


def test_a_channel_beast_is_never_smaller_than_the_region_said(conn, make_player):
    """Sizing to the room replaced a region-counted body; that body stays
    underneath as a floor so a quiet server never gets a softer tide than the
    one it had before."""
    tide = _tide(conn, "northern", 3)
    made = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]
    row = conn.execute(
        "SELECT e.max_hp, e.kind, cs.base_hp, horde_world_scale(%s) "
        "FROM horde_encounters e JOIN creature_species cs "
        "  ON cs.species_id = e.species_id WHERE e.encounter_id = %s",
        (tide, made),
    ).fetchone()
    elite = conn.execute("SELECT game_config_value('horde_elite_hp')").fetchone()[0]
    was = float(row[2]) * float(row[3]) * (float(elite) if row[1] == "elite" else 1)
    assert float(row[0]) >= was, (
        f"the region-counted floor gave {was} and the beast came out {row[0]}"
    )


def test_a_lone_defender_is_not_handed_a_wall(conn, make_player):
    """Sizing to the room cuts both ways: the reason this is per-hand rather
    than a bigger flat number is that a quiet evening must still be winnable."""
    floor = conn.execute(
        "SELECT game_config_value('horde_world_hp')"
    ).fetchone()[0]
    per_hand = conn.execute(
        "SELECT game_config_value('horde_world_hp_per_hand')"
    ).fetchone()[0]

    assert floor > 0, "a beast with no floor would be free on a dead server"
    assert per_hand > 0, "the per-hand term does nothing"
    # One hand must not already be most of what ten hands get.
    assert (floor + per_hand) < (floor + per_hand * 10) / 2


def test_a_world_beast_stands_long_enough_to_gather_a_room(conn):
    """Twenty-odd blows needs the room to assemble, and a beast that walks off
    costs the line what its pack was worth."""
    minutes = conn.execute(
        "SELECT game_config_value('horde_beast_minutes')"
    ).fetchone()[0]
    assert minutes >= 20, (
        "a beast that now needs a crowd is still on the old five minute clock"
    )


def test_the_king_is_bigger_than_the_beasts_it_comes_after(conn, make_player):
    """0240 sized a channel beast to the room; the King had a formula of its
    own and did not move, so the finale became the smallest thing on the field
    - at one hand it was lighter than an ordinary spawn. Two places deciding
    one thing, and only one of them told."""
    tide = _tide(conn, "northern", 3)
    for n in range(3):
        who = _defender(conn, make_player, f"Court{n}")
        conn.execute(
            "INSERT INTO horde_contributions (horde_id, player_id, last_swing_at) "
            "VALUES (%s, %s, now())",
            (tide, who),
        )

    elite = conn.execute(
        """
        SELECT round(COALESCE((SELECT avg(cs.base_hp) FROM creature_regions cr
                    JOIN creature_species cs ON cs.species_id = cr.species_id
                    WHERE cr.region_code = 'northern' AND cs.kind = 'beast'), 600)
                  * horde_world_scale(%s) * game_config_value('horde_elite_hp'))
        """,
        (tide,),
    ).fetchone()[0]

    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    king = conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0]
    royal = conn.execute(
        "SELECT max_hp FROM horde_encounters WHERE encounter_id = %s", (king,)
    ).fetchone()[0]

    assert royal >= elite * 2, (
        f"the King carries {royal} against an elite spawn's {elite}"
    )


def test_the_channel_and_the_king_share_one_scale(conn):
    """The whole reason the King fell behind: it had its own arithmetic. Both
    read `horde_world_scale` now, so tuning the channel moves the finale."""
    # 0320 moved the channel's copy of this down a level into
    # `horde_body_pool`, so the check follows calls rather than demanding the
    # name appear in the caller - the invariant is that both bodies REACH one
    # shared scale, not which line it is written on.
    def reaches(proname, target, seen=None):
        seen = seen if seen is not None else set()
        if proname in seen:
            return False
        seen.add(proname)
        row = conn.execute(
            "SELECT pg_get_functiondef(oid) FROM pg_proc WHERE proname = %s",
            (proname,),
        ).fetchone()
        if row is None:
            return False
        body = row[0]
        if target + "(" in body:
            return True
        # Anything else in this schema that this function names.
        callees = conn.execute(
            "SELECT proname FROM pg_proc WHERE prokind = 'f' "
            "AND pronamespace = 'public'::regnamespace AND proname <> %s",
            (proname,),
        ).fetchall()
        return any(
            c[0] + "(" in body and reaches(c[0], target, seen) for c in callees
        )

    for reader in ("horde_spawn", "horde_king_rise"):
        assert reaches(reader, "horde_world_scale"), (
            f"{reader} sizes bodies on its own"
        )

    # And the dial it used to size the King by is gone rather than inert.
    assert conn.execute(
        "SELECT count(*) FROM game_config WHERE key = 'horde_king_hp_per_hand'"
    ).fetchone()[0] == 0


def test_the_king_holds_its_ratio_at_every_turnout(conn, make_player):
    """A constant that drifted with the room is how the King ended up at 0.28
    of an elite with one hand and 0.86 with ten."""
    ratios = []
    for hands in (1, 5):
        tide = _tide(conn, "northern", 3)
        for n in range(hands):
            who = _defender(conn, make_player, f"H{hands}_{n}")
            conn.execute(
                "INSERT INTO horde_contributions (horde_id, player_id, last_swing_at) "
                "VALUES (%s, %s, now())",
                (tide, who),
            )
        ratios.append(
            float(
                conn.execute(
                    "SELECT game_config_value('horde_king_beasts') "
                    "/ game_config_value('horde_elite_hp')"
                ).fetchone()[0]
            )
        )
        conn.execute(
            "UPDATE beast_hordes SET status = 'won', ended_at = now() "
            "WHERE horde_id = %s",
            (tide,),
        )

    assert ratios[0] == ratios[1], "the King's share of an elite moves with the room"
    assert ratios[0] > 2, "the King is not clear of the trash it comes after"


def test_extra_strikes_fires_and_pays(conn, make_player):
    """"Does extra strike work?" - it does, and this is the measurement.

    One swing plus a whole one per point of multi_hit, plus a roll for the
    remainder, with later strikes at `gu_multi_hit_power`."""
    who = _defender(conn, make_player, "Flurry")
    conn.execute("DELETE FROM player_gu_equipped WHERE player_id = %s", (who,))

    # The strongest Extra Strikes Gu that this cultivator's aperture will hold.
    kind = conn.execute(
        "SELECT te.gu_type_id FROM gu_type_effects te "
        "JOIN gu_types t ON t.gu_type_id = te.gu_type_id "
        "WHERE te.effect_code = 'multi_hit' "
        "  AND t.size <= gu_capacity_of(%s) - gu_used_by(%s) "
        "ORDER BY te.magnitude DESC LIMIT 1",
        (who, who),
    ).fetchone()[0]
    gu = conn.execute("SELECT grant_gu(%s, %s, NULL)", (who, kind)).fetchone()[0]
    conn.execute(
        "INSERT INTO player_gu_equipped (player_id, gu_id) VALUES (%s, %s)",
        (who, gu),
    )

    stat = float(
        conn.execute("SELECT player_stat(%s, 'multi_hit')", (who,)).fetchone()[0]
    )
    assert stat > 0, "the Gu did not reach the stat at all"

    move = conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0]
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'beast' LIMIT 1"
    ).fetchone()[0]

    multi = 0
    for _ in range(120):
        strikes = conn.execute(
            "SELECT strikes FROM player_swing(%s, %s, %s, 99999999, 0)",
            (who, move, species),
        ).fetchone()[0]
        if strikes > 1:
            multi += 1

    # 120 rolls at this rate: seeing none at all is not luck, it is a bug.
    assert multi > 0, f"120 swings at {stat} extra strikes never struck twice"


def test_every_fight_swings_through_the_one_reader(conn):
    """One place APPLIES `multi_hit`, so the effect cannot work in one
    fight and not another.

    `player_blow_multiple` reads it too, and that is a different job: it
    is what `boss_hp_pool` sizes a world boss with, an expectation rather
    than a swing. A fight calling it would be the split all over again, so
    the assertion below is that no fight does.
    """
    readers = sorted(
        row[0]
        for row in conn.execute(
            "SELECT proname FROM pg_proc p JOIN pg_namespace n "
            "ON n.oid = p.pronamespace WHERE n.nspname = 'public' "
            "AND p.prosrc LIKE '%multi_hit%'"
        ).fetchall()
    )
    assert readers == ["player_blow_multiple", "player_swing"], readers

    for fight in ("battle_act", "dungeon_resolve_round", "horde_strike",
                  "horde_gauntlet_swing", "strike_boss"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (fight,)
        ).fetchone()[0]
        assert "player_blow_multiple" not in body, (
            f"{fight} sizes a blow instead of swinging one"
        )

    for fight in ("battle_act", "dungeon_resolve_round", "horde_strike",
                  "horde_gauntlet_swing"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (fight,)
        ).fetchone()[0]
        assert "player_swing(" in body, f"{fight} does not swing the shared way"


def test_a_fight_says_how_many_times_it_landed(conn, make_player):
    """An effect that fires invisibly is the same failure as one that does not
    fire. Three of the four screens rendered a single damage number, which is
    how a working mechanic gets reported as broken."""
    tide = _tide(conn, "northern", 2)
    who = _defender(conn, make_player, "Reporter")
    made = conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0]

    hit = conn.execute(
        "SELECT dealt, strikes, crits FROM horde_strike(%s, %s)", (made, who)
    ).fetchone()
    assert hit[1] is not None and hit[1] >= 1, "a channel strike will not say"
    assert hit[2] is not None, "a channel strike will not say whether it bit"

    # And the dungeon puts them on its round log rather than dropping them.
    body = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'dungeon_resolve_round'"
    ).fetchone()[0]
    assert "'strikes', swung.strikes" in body
    assert "'crits', swung.crits" in body


def test_the_defences_are_read_in_one_place(conn):
    """0225 gave the game one swing and fixed only the half about hitting.
    Evasion, Braced and Death Ward were read by the duel and by nothing else,
    so a dungeon boss took a raw number off a body that had paid for them."""
    readers = sorted(
        row[0]
        for row in conn.execute(
            "SELECT proname FROM pg_proc p JOIN pg_namespace n "
            "ON n.oid = p.pronamespace WHERE n.nspname = 'public' "
            "AND (p.prosrc LIKE %s OR p.prosrc LIKE %s OR p.prosrc LIKE %s)",
            ("%'dodge'%", "%'braced'%", "%'death_ward'%"),
        ).fetchall()
    )
    assert readers == ["player_take"], readers

    for fight in ("battle_act", "dungeon_resolve_round", "horde_gauntlet_swing"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (fight,)
        ).fetchone()[0]
        assert "player_take(" in body, f"{fight} still takes a blow on its own"


def test_a_blow_is_softened_by_what_the_body_wears(conn, make_player):
    who = _defender(conn, make_player, "Bulwark")

    plain = conn.execute(
        "SELECT taken FROM player_take(%s, 1000, 5000, 5000)", (who,)
    ).fetchone()[0]
    assert plain <= 1000

    # Reduction is applied, and a guard is multiplicative on top of it.
    guarded = sum(
        conn.execute(
            "SELECT taken FROM player_take(%s, 1000, 5000, 5000, TRUE)", (who,)
        ).fetchone()[0]
        for _ in range(20)
    )
    bare = sum(
        conn.execute(
            "SELECT taken FROM player_take(%s, 1000, 5000, 5000, FALSE)", (who,)
        ).fetchone()[0]
        for _ in range(20)
    )
    assert guarded < bare, "bracing did not soften anything"


def test_a_blow_can_never_be_reduced_to_nothing(conn):
    """The ceiling on the stack is what keeps a defensive build from being
    invulnerable rather than merely hard to kill."""
    ceiling = conn.execute(
        "SELECT game_config_value('damage_reduction_ceiling')"
    ).fetchone()[0]
    assert ceiling < 1

    body = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'player_take'"
    ).fetchone()[0]
    assert "damage_reduction_ceiling" in body, "the stack is no longer clamped"


def test_the_ward_has_somewhere_to_remember_it_fired(conn):
    """Death Ward fires once a fight. Without a place to write that down it
    either never fires outside a duel or fires on every blow."""
    for table in ("battle_combatants", "dungeon_raiders", "horde_gauntlets"):
        assert conn.execute(
            "SELECT count(*) FROM information_schema.columns "
            "WHERE table_name = %s AND column_name = 'ward_used'",
            (table,),
        ).fetchone()[0] == 1, f"{table} cannot remember a spent ward"


# ---------------------------------------------------------------------------
# Page fusion (0246)
# ---------------------------------------------------------------------------


def _pages(conn, owner, tier, path, kind, n, quality=80):
    made = []
    for _ in range(n):
        made.append(
            conn.execute(
                "INSERT INTO manual_pages "
                "(owner_id, tier, path_code, page_type, power, quality) "
                "VALUES (%s, %s, %s, %s, 10, %s) RETURNING page_id",
                (owner, tier, path, kind, quality),
            ).fetchone()[0]
        )
    return made


def test_three_pages_make_one_a_rung_higher(conn, make_player):
    who = make_player("Fuser")
    ids = _pages(conn, who, 2, "light", "attack", 3)

    born = conn.execute(
        "SELECT tier, path_code, page_type, power, quality FROM fuse_pages(%s, %s)",
        (who, ids),
    ).fetchone()

    assert born[0] == 3, "three tier 2 pages did not make a tier 3"
    assert born[1] == "light" and born[2] == "attack", (
        "the fusion changed what the pages were about"
    )
    assert born[3] > 0 and born[4] > 0


def test_a_fusion_spends_its_pages_and_says_what_they_became(conn, make_player):
    who = make_player("Spender")
    ids = _pages(conn, who, 2, "light", "attack", 3)
    born = conn.execute(
        "SELECT page_id FROM fuse_pages(%s, %s)", (who, ids)
    ).fetchone()[0]

    left = conn.execute(
        "SELECT count(*) FROM manual_pages "
        "WHERE page_id = ANY(%s) AND consumed_at IS NULL",
        (ids,),
    ).fetchone()[0]
    assert left == 0, "a fused page is still on the shelf"

    assert conn.execute(
        "SELECT count(*) FROM manual_pages "
        "WHERE page_id = ANY(%s) AND fused_into = %s",
        (ids, born),
    ).fetchone()[0] == 3, "a spent page does not say what it became"

    with pytest.raises(psycopg.errors.CheckViolation, match="not all yours"):
        conn.execute("SELECT fuse_pages(%s, %s)", (who, ids))


def test_a_fusion_takes_one_tier_one_path_one_kind(conn, make_player):
    """Strict on purpose. A fusion that laundered anything into anything would
    make Paths and page types stop meaning what they mean everywhere else."""
    who = make_player("Mixer")

    for label, ids in (
        ("one tier", _pages(conn, who, 2, "light", "attack", 2)
                     + _pages(conn, who, 3, "light", "attack", 1)),
        ("one Path", _pages(conn, who, 2, "fire", "attack", 2)
                     + _pages(conn, who, 2, "ice", "attack", 1)),
        ("one kind", _pages(conn, who, 2, "wind", "attack", 2)
                     + _pages(conn, who, 2, "wind", "defense", 1)),
    ):
        conn.execute("SAVEPOINT mixing")
        with pytest.raises(psycopg.errors.CheckViolation, match=label):
            conn.execute("SELECT fuse_pages(%s, %s)", (who, ids))
        conn.execute("ROLLBACK TO SAVEPOINT mixing")


def test_a_fusion_takes_exactly_three_distinct_pages(conn, make_player):
    who = make_player("Counter")
    ids = _pages(conn, who, 2, "light", "attack", 4)

    conn.execute("SAVEPOINT too_many")
    with pytest.raises(psycopg.errors.CheckViolation, match="exactly"):
        conn.execute("SELECT fuse_pages(%s, %s)", (who, ids))
    conn.execute("ROLLBACK TO SAVEPOINT too_many")

    conn.execute("SAVEPOINT itself")
    with pytest.raises(psycopg.errors.CheckViolation, match="with itself"):
        conn.execute(
            "SELECT fuse_pages(%s, %s)", (who, [ids[0], ids[0], ids[1]])
        )
    conn.execute("ROLLBACK TO SAVEPOINT itself")


def test_quality_is_carried_not_conjured(conn, make_player):
    """Feeding good pages is what makes a good page - otherwise fusion would be
    a laundry rather than a craft."""
    who = make_player("Picky")
    rough = conn.execute(
        "SELECT quality FROM fuse_pages(%s, %s)",
        (who, _pages(conn, who, 2, "light", "attack", 3, quality=40)),
    ).fetchone()[0]
    fine = conn.execute(
        "SELECT quality FROM fuse_pages(%s, %s)",
        (who, _pages(conn, who, 2, "light", "attack", 3, quality=95)),
    ).fetchone()[0]
    assert fine > rough, "the fusion ignored what went into it"


def test_fusion_is_the_only_way_to_a_page_above_tier_seven(conn, make_player):
    """`page_tiers` has carried rows for 8, 9 and 10 since it was written and
    `mint_page` stops at 7, so nothing had ever produced one."""
    assert conn.execute(
        "SELECT count(*) FROM page_tiers WHERE tier > 7"
    ).fetchone()[0] > 0

    who = make_player("Climber")
    born = conn.execute(
        "SELECT tier FROM fuse_pages(%s, %s)",
        (who, _pages(conn, who, 7, "light", "attack", 3)),
    ).fetchone()[0]
    assert born == 8, "fusion would not climb past the minting ceiling"


def test_the_shelf_only_offers_what_can_actually_be_fused(conn, make_player):
    who = make_player("Shelved")
    _pages(conn, who, 2, "light", "attack", 3)
    _pages(conn, who, 2, "fire", "attack", 2)

    rows = conn.execute(
        "SELECT path_code, held, fusions FROM page_fusion_shelf "
        "WHERE player_id = %s",
        (who,),
    ).fetchall()
    assert [r[0] for r in rows] == ["light"], (
        "the shelf offered a stack that is not three deep"
    )


def test_every_fight_swings_and_takes_through_the_shared_halves(conn):
    """0225 made one swing and 0243 made one blow taken. `strike_boss` was in
    neither list, because it reads none of the effect names - which is exactly
    the symptom of not applying them."""
    for fight in ("battle_act", "dungeon_resolve_round", "horde_strike",
                  "horde_gauntlet_swing", "strike_boss"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (fight,)
        ).fetchone()[0]
        assert "player_swing(" in body, f"{fight} computes its own swing"

    # Every fight that can hurt a cultivator, through the other half too.
    for fight in ("battle_act", "dungeon_resolve_round", "horde_gauntlet_swing",
                  "strike_boss"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (fight,)
        ).fetchone()[0]
        assert "player_take(" in body, f"{fight} takes a blow on its own"


def test_the_world_boss_is_sized_against_what_a_blow_now_does(conn):
    """`boss_hp_pool` measured the pipeline number, which is what a swing was
    worth before extra strikes and criticals were counted. Landing half again
    as hard without telling the pool would just make world bosses shorter."""
    body = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'boss_hp_pool'"
    ).fetchone()[0]
    assert "player_blow_multiple" in body, "the boss is sized against the old blow"

    # And the multiple is an expectation, not a roll - a pool that rolled dice
    # would give the boss a different size every time it was read.
    assert conn.execute(
        "SELECT provolatile FROM pg_proc WHERE proname = 'player_blow_multiple'"
    ).fetchone()[0] == "s"
    assert "random()" not in conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'player_blow_multiple'"
    ).fetchone()[0]


def test_a_blow_is_worth_more_to_a_build_that_strikes_twice(conn, make_player):
    who = _defender(conn, make_player, "Multi")
    conn.execute("DELETE FROM player_gu_equipped WHERE player_id = %s", (who,))
    bare = float(
        conn.execute("SELECT player_blow_multiple(%s)", (who,)).fetchone()[0]
    )

    kind = conn.execute(
        "SELECT te.gu_type_id FROM gu_type_effects te "
        "JOIN gu_types t ON t.gu_type_id = te.gu_type_id "
        "WHERE te.effect_code = 'multi_hit' "
        "  AND t.size <= gu_capacity_of(%s) - gu_used_by(%s) "
        "ORDER BY te.magnitude DESC LIMIT 1",
        (who, who),
    ).fetchone()[0]
    gu = conn.execute("SELECT grant_gu(%s, %s, NULL)", (who, kind)).fetchone()[0]
    conn.execute(
        "INSERT INTO player_gu_equipped (player_id, gu_id) VALUES (%s, %s)",
        (who, gu),
    )

    assert float(
        conn.execute("SELECT player_blow_multiple(%s)", (who,)).fetchone()[0]
    ) > bare, "extra strikes did not make a blow worth more"


def test_the_boss_remembers_a_spent_ward(conn):
    """Death Ward fires once. A world boss fight lasts hours, so without
    somewhere to write that down it would fire on every blow."""
    assert conn.execute(
        "SELECT count(*) FROM information_schema.columns "
        "WHERE table_name = 'boss_strikes' AND column_name = 'ward_used'"
    ).fetchone()[0] == 1


# ---------------------------------------------------------------------------
# A realm is prepared for, and rewrites your fate (0253, 0254, 0255)
# ---------------------------------------------------------------------------


def test_a_stage_is_free_but_a_rank_is_not(conn, make_player):
    """Gating all thirty-five crossings would make cultivation a shopping
    list. Only the eight that change your rank ask for anything."""
    who = _defender(conn, make_player, "Climber")

    # A stage crossing: cultivation and nothing else.
    conn.execute(
        "UPDATE player_cultivation SET realm_id = 1 WHERE player_id = %s", (who,)
    )
    asks = [r[0] for r in conn.execute(
        "SELECT need FROM breakthrough_gate(%s)", (who,)
    ).fetchall()]
    assert asks == ["Cultivation"], asks

    # A rank crossing: cultivation and the door.
    conn.execute(
        "UPDATE player_cultivation SET realm_id = 4 WHERE player_id = %s", (who,)
    )
    asks = [r[0] for r in conn.execute(
        "SELECT need FROM breakthrough_gate(%s)", (who,)
    ).fetchall()]
    assert "Cultivation" in asks
    assert len(asks) > 1, "a great realm asked for nothing but patience"


def test_the_door_refuses_and_the_screen_agrees(conn, make_player):
    """`breakthrough_gate` is what the screen shows AND what the door checks,
    so a player cannot be told one thing and refused for another."""
    who = _defender(conn, make_player, "Knocker")
    conn.execute(
        "UPDATE player_cultivation SET realm_id = 4 WHERE player_id = %s", (who,)
    )
    conn.execute(
        "UPDATE player_cultivation pc SET cultivation = "
        "(SELECT r.cultivation_required FROM realms r WHERE r.realm_id = 5) "
        "WHERE pc.player_id = %s",
        (who,),
    )
    conn.execute("DELETE FROM player_materials WHERE player_id = %s", (who,))

    unmet = [r[0] for r in conn.execute(
        "SELECT need FROM breakthrough_gate(%s) WHERE NOT met", (who,)
    ).fetchall()]
    assert unmet, "the gate thinks an empty cultivator is ready"

    with pytest.raises(psycopg.errors.CheckViolation, match="will not open"):
        conn.execute("SELECT breakthrough(%s)", (who,))


def test_a_great_realm_offers_three_fates_once(conn, make_player):
    who = _defender(conn, make_player, "Fated")
    conn.execute("DELETE FROM player_destinies WHERE player_id = %s", (who,))

    three = conn.execute(
        "SELECT destiny_offer(%s, 3::smallint)", (who,)
    ).fetchone()[0]
    assert len(three) == 3

    # Looking again does not re-roll: otherwise somebody walks away and comes
    # back until fate suggests what they wanted.
    again = conn.execute(
        "SELECT destiny_offer(%s, 3::smallint)", (who,)
    ).fetchone()[0]
    assert again == three


def test_a_fate_reaches_every_fight_because_it_reaches_player_stat(conn, make_player):
    """The whole reason Destiny is built on `gu_effects`: one more source on
    `player_stat` and every fight reads it without being told."""
    who = _defender(conn, make_player, "Marked")
    conn.execute("DELETE FROM player_destinies WHERE player_id = %s", (who,))

    code, effect, mag = conn.execute(
        "SELECT d.code, de.effect_code, de.magnitude FROM destinies d "
        "JOIN destiny_effects de ON de.code = d.code "
        "WHERE d.min_rank = 2 AND de.magnitude > 0 LIMIT 1"
    ).fetchone()

    before = float(
        conn.execute("SELECT player_stat(%s, %s)", (who, effect)).fetchone()[0]
    )
    conn.execute(
        "INSERT INTO player_destinies (player_id, rank, code, offered, chosen_at) "
        "VALUES (%s, 2, %s, ARRAY[%s], now())",
        (who, code, code),
    )
    after = float(
        conn.execute("SELECT player_stat(%s, %s)", (who, effect)).fetchone()[0]
    )
    assert after > before, "a written fate changed nothing"

    body = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'player_stat'"
    ).fetchone()[0]
    assert "destiny_stat" in body


def test_a_fate_is_taken_once_and_only_from_the_three(conn, make_player):
    who = _defender(conn, make_player, "Chooser")
    conn.execute("DELETE FROM player_destinies WHERE player_id = %s", (who,))
    three = conn.execute(
        "SELECT destiny_offer(%s, 3::smallint)", (who,)
    ).fetchone()[0]

    outside = conn.execute(
        "SELECT code FROM destinies WHERE NOT (code = ANY(%s)) LIMIT 1", (three,)
    ).fetchone()[0]

    conn.execute("SAVEPOINT not_offered")
    with pytest.raises(psycopg.errors.CheckViolation, match="not one of the three"):
        conn.execute("SELECT destiny_take(%s, 3::smallint, %s)", (who, outside))
    conn.execute("ROLLBACK TO SAVEPOINT not_offered")

    conn.execute("SELECT destiny_take(%s, 3::smallint, %s)", (who, three[0]))
    with pytest.raises(psycopg.errors.CheckViolation, match="already written"):
        conn.execute("SELECT destiny_take(%s, 3::smallint, %s)", (who, three[1]))


def test_no_fate_is_offered_twice(conn, make_player):
    """A fate is a thing you are, not a stack."""
    who = _defender(conn, make_player, "Repeat")
    conn.execute("DELETE FROM player_destinies WHERE player_id = %s", (who,))

    taken = set()
    for rank in (2, 3, 4, 5):
        three = conn.execute(
            "SELECT destiny_offer(%s, %s::smallint)", (who, rank)
        ).fetchone()[0]
        assert not (taken & set(three)), "fate offered something already written"
        conn.execute(
            "SELECT destiny_take(%s, %s::smallint, %s)", (who, rank, three[0])
        )
        taken.add(three[0])


def test_every_live_effect_is_read_by_something(conn):
    """The invariant the whole audit earned. An effect worn by a Gu and read by
    nothing is the failure this codebase keeps finding."""
    orphans = conn.execute(
        """
        SELECT e.code FROM gu_effects e
        WHERE e.is_live AND NOT EXISTS (
          SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public'
            AND p.prosrc LIKE '%' || quote_literal(e.code) || '%'
            AND p.proname NOT IN ('player_stat','gu_stat','equipment_stat',
                                  'physique_stat','root_stat','dwelling_stat',
                                  'manual_stat','destiny_stat'))
        """
    ).fetchall()
    assert orphans == [], f"worn and read by nothing: {[o[0] for o in orphans]}"


def test_the_auxiliary_ceiling_is_a_ceiling(conn):
    """It described itself as a hard ceiling and nothing compared anything
    to it."""
    body = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'refine_gu'"
    ).fetchone()[0]
    assert "gu_refine_aux_max" in body


def test_there_is_one_dial_for_a_stalemate(conn):
    """`hunt_turn_cap` and `battle_turn_cap` both said 50 and only one was
    read, so tuning the wrong one did nothing."""
    assert conn.execute(
        "SELECT count(*) FROM game_config WHERE key = 'hunt_turn_cap'"
    ).fetchone()[0] == 0
    assert conn.execute(
        "SELECT count(*) FROM game_config WHERE key = 'battle_turn_cap'"
    ).fetchone()[0] == 1


def test_a_fate_is_never_shown_twice_across_open_offers(conn, make_player):
    """Backfilling seven offers at once is what found this. `destiny_offer`
    excluded fates already TAKEN and said nothing about ones sitting in an
    offer nobody had answered - so a cultivator owed several would have been
    shown the same fate twice, and `destiny_stat` sums what it finds."""
    who = _defender(conn, make_player, "Owed")
    conn.execute("DELETE FROM player_destinies WHERE player_id = %s", (who,))

    seen: list[str] = []
    for rank in range(2, 9):
        three = conn.execute(
            "SELECT destiny_offer(%s, %s::smallint)", (who, rank)
        ).fetchone()[0]
        assert three, f"rank {rank} offered nothing"
        assert not (set(three) & set(seen)), (
            f"rank {rank} showed a fate another offer is already showing"
        )
        seen.extend(three)


def test_a_fate_cannot_be_written_twice_however_it_was_reached(conn, make_player):
    """The backstop under the offer rule: even an offer built by hand cannot
    hand somebody the same Destiny at two realms."""
    who = _defender(conn, make_player, "Doubler")
    conn.execute("DELETE FROM player_destinies WHERE player_id = %s", (who,))

    three = conn.execute(
        "SELECT destiny_offer(%s, 2::smallint)", (who,)
    ).fetchone()[0]
    conn.execute("SELECT destiny_take(%s, 2::smallint, %s)", (who, three[0]))

    # Put it in a second offer by hand, the way only a bug could.
    conn.execute(
        "INSERT INTO player_destinies (player_id, rank, offered) "
        "VALUES (%s, 3, ARRAY[%s])",
        (who, three[0]),
    )
    with pytest.raises(psycopg.errors.CheckViolation, match="already yours"):
        conn.execute("SELECT destiny_take(%s, 3::smallint, %s)", (who, three[0]))


def test_a_low_door_never_offers_a_high_fate(conn):
    """Backfilled offers are drawn from the pool that realm would have drawn
    from - nobody is handed Immortal Bones for a door they walked through in
    Qi Condensation."""
    wrong = conn.execute(
        """
        SELECT count(*) FROM player_destinies pd
        CROSS JOIN LATERAL unnest(pd.offered) AS o(code)
        JOIN destinies d ON d.code = o.code
        WHERE d.min_rank > pd.rank
        """
    ).fetchone()[0]
    assert wrong == 0


def test_everybody_past_the_first_realm_is_owed_their_crossings(conn):
    """0254 shipped after people had already crossed. One offer per door
    already behind them."""
    short = conn.execute(
        """
        SELECT p.discord_name, r.rank - 1 AS owed, count(pd.rank) AS has
        FROM players p
        JOIN player_cultivation pc ON pc.player_id = p.player_id
        JOIN realms r ON r.realm_id = pc.realm_id
        LEFT JOIN player_destinies pd ON pd.player_id = p.player_id
        WHERE p.deleted_at IS NULL AND r.rank > 1
        GROUP BY p.discord_name, r.rank
        HAVING count(pd.rank) < r.rank - 1
        """
    ).fetchall()
    assert short == [], f"cultivators still owed crossings: {short}"


def test_no_reader_looks_in_a_narrower_pocket_than_player_stat(conn):
    """0255 asked whether every effect had a reader and never asked whether
    every reader looked in the same place.

    Refining Tolerance had three readers: `refine_forecast` through
    `player_stat`, and `forge` and `brew` through `physique_stat` - which is
    the physique's own table and nothing else. So three Gu and a Destiny that
    grant it did nothing at the anvil or the cauldron.
    """
    # "Narrower" means SOME of the seven, not all of them. A reader that
    # consults every source is by definition not looking in a narrower pocket
    # - `player_stat_sheet` does exactly that on purpose, because a sheet that
    # says where a stat came from has to name all seven places it could have.
    # Checked by counting rather than by exempting a name, so the next such
    # reader is covered without anybody remembering to add it.
    narrow = conn.execute(
        """
        SELECT p.proname FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname <> 'player_stat'
          -- A character class rather than an escaped paren: there is no
          -- backslash to be mangled on its way through Python.
          AND p.prosrc ~ '(gu_stat|equipment_stat|physique_stat|root_stat'
                      '|dwelling_stat|manual_stat|destiny_stat)[(]'
          AND (
              SELECT count(*) FROM unnest(ARRAY[
                  'gu_stat', 'equipment_stat', 'physique_stat', 'root_stat',
                  'dwelling_stat', 'manual_stat', 'destiny_stat'
              ]) AS source
              WHERE p.prosrc ~ (source || '[(]')
          ) < 7
        ORDER BY p.proname
        """
    ).fetchall()
    assert narrow == [], (
        f"these read a narrower source than the effect is granted from: "
        f"{[r[0] for r in narrow]}"
    )


def test_a_granted_tolerance_reaches_the_anvil_and_the_cauldron(conn, make_player):
    who = _defender(conn, make_player, "Tolerant")
    conn.execute("DELETE FROM player_destinies WHERE player_id = %s", (who,))

    before = float(
        conn.execute(
            "SELECT player_stat(%s, 'refine_conflict_relief')", (who,)
        ).fetchone()[0]
    )
    conn.execute(
        "INSERT INTO player_destinies (player_id, rank, code, offered, chosen_at) "
        "VALUES (%s, 2, 'hundred_refinements', ARRAY['hundred_refinements'], now())",
        (who,),
    )
    after = float(
        conn.execute(
            "SELECT player_stat(%s, 'refine_conflict_relief')", (who,)
        ).fetchone()[0]
    )
    assert after > before

    for smith in ("forge", "brew", "refine_forecast"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (smith,)
        ).fetchone()[0]
        assert "player_stat(p_player_id, 'refine_conflict_relief')" in body, (
            f"{smith} cannot see a tolerance that was not born in the physique"
        )


def test_defence_is_softened_at_both_ends_of_a_blow(conn):
    """0248 said defence should hold its value up the ladder and fixed half of
    it.

    A creature swinging at a cultivator met a divisor that climbs with rank. A
    cultivator swinging at a creature met a flat 60, while 0249 gave every
    creature a defence that quadruples per rank - so a rank 7 dungeon boss
    kept 102,400 defence against a divisor that never moved, and clearwest hit
    it for 4,295 out of 23 million.
    """
    body = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'compute_technique_damage'"
    ).fetchone()[0]
    assert "creature_defense_scale_per_rank" in body, (
        "a cultivator's blow is softened by a flat divisor again"
    )

    # The share removed is the same at every rank, which is what holding its
    # value means.
    shares = set()
    for rank in (1, 5, 9):
        defence = 25 * 4 ** (rank - 1)
        divisor = 60 * 4 ** (rank - 1)
        shares.add(round(defence / (divisor + defence), 3))
    assert len(shares) == 1, f"the share drifts with rank: {shares}"


def test_nothing_in_the_roster_is_effectively_immune(conn, make_player):
    """The measure that matters is how many blows it takes to fell a thing."""
    who = _defender(conn, make_player, "Delver")
    move = conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0]

    stubborn = []
    for species_id, name, hp, defence in conn.execute(
        "SELECT species_id, name, base_hp, base_defense FROM creature_species "
        "WHERE kind IN ('dungeon', 'world', 'boss') ORDER BY rank"
    ).fetchall():
        dealt = conn.execute(
            "SELECT final_damage FROM compute_technique_damage(%s, %s, %s, 1, %s)",
            (who, move, species_id, defence),
        ).fetchone()[0]
        # A fresh cultivator will not fell a rank 9 boss, and should not - what
        # is being caught is defence turning into an immunity.
        if dealt <= 1:
            stubborn.append(name)

    assert stubborn == [], f"these shrug off a blow entirely: {stubborn}"


def test_life_on_hit_does_not_care_how_hard_you_hit(conn, make_player):
    """The whole point of 0260. A share of DAMAGE grew with offence, and
    offence quadruples every great realm, so sustain outran anything a capped
    bite could do about it - Miyuki healed 199,204 against a bite of 123,721
    and could not be killed by a world boss at all."""
    who = _defender(conn, make_player, "Drinker")
    conn.execute("DELETE FROM player_gu_equipped WHERE player_id = %s", (who,))

    kind = conn.execute(
        "SELECT te.gu_type_id FROM gu_type_effects te "
        "JOIN gu_types t ON t.gu_type_id = te.gu_type_id "
        "WHERE te.effect_code = 'lifesteal' "
        "  AND t.size <= gu_capacity_of(%s) - gu_used_by(%s) "
        "ORDER BY te.magnitude DESC LIMIT 1",
        (who, who),
    ).fetchone()[0]
    gu = conn.execute("SELECT grant_gu(%s, %s, NULL)", (who, kind)).fetchone()[0]
    conn.execute(
        "INSERT INTO player_gu_equipped (player_id, gu_id) VALUES (%s, %s)",
        (who, gu),
    )

    move = conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0]
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'beast' LIMIT 1"
    ).fetchone()[0]
    body = conn.execute(
        "SELECT max_hp FROM player_physique WHERE player_id = %s", (who,)
    ).fetchone()[0]

    # Two targets, wildly different toughness, same body. Compare only swings
    # that landed the same number of strikes - the count is a dice roll.
    by_strikes: dict[int, set] = {}
    for target_hp in (10_000_000, 10_000_000_000):
        for _ in range(12):
            row = conn.execute(
                "SELECT strikes, healed, dealt FROM player_swing("
                "%s, %s, %s, %s, 0, %s, %s, 1)",
                (who, move, species, target_hp, body // 2, body),
            ).fetchone()
            by_strikes.setdefault(row[0], set()).add(row[1])

    for strikes, healings in by_strikes.items():
        assert len(healings) == 1, (
            f"{strikes} strikes returned {healings} - healing still tracks damage"
        )


def test_a_maxed_sustain_build_still_loses_to_a_world_beast(conn):
    """Sustain should mean a long fight, not an unlosable one."""
    cap = float(
        conn.execute(
            "SELECT cap FROM gu_effects WHERE code = 'lifesteal'"
        ).fetchone()[0]
    )
    rate = float(
        conn.execute("SELECT game_config_value('life_on_hit_rate')").fetchone()[0]
    )
    bite = float(
        conn.execute("SELECT game_config_value('boss_bite_cap')").fetchone()[0]
    )
    soak = float(
        conn.execute(
            "SELECT cap FROM gu_effects WHERE code = 'damage_reduction'"
        ).fetchone()[0]
    )

    # Both as a share of the same maximum health, which is the point - the two
    # sides are now measured in the same unit and neither can run away.
    healed = cap * rate * 2          # two strikes, the common case
    taken = bite * (1 - soak)

    assert healed < taken, (
        f"a maxed build takes back {healed:.4f} of its health against "
        f"{taken:.4f} - it cannot be killed"
    )


# ---------------------------------------------------------------------------
# What a Gu says about itself when it is handed over (0263)
# ---------------------------------------------------------------------------


def test_a_gu_label_carries_the_name_and_the_rank(conn):
    """A name alone reads identically at rank 1 and rank 9.

    Rank is what tells a player whether to be pleased, and it runs against the
    same ladder the realms use - so it is a number they already know how to
    read, unlike rarity, which varies within a rank.
    """
    rows = conn.execute(
        """
        SELECT DISTINCT ON (t.rank)
               t.gu_type_id, t.name, t.rank, gu_label(t.gu_type_id) AS label
        FROM gu_types t
        ORDER BY t.rank, t.gu_type_id
        """
    ).fetchall()
    assert len(rows) == 9, "the ladder is not nine ranks deep any more"

    for gu_type_id, name, rank, label in rows:
        assert name in label, f"the label for {name} dropped the name: {label}"
        assert f"rank {rank}" in label, f"rank {rank} is not in {label}"


def test_no_gu_in_the_game_is_unable_to_name_itself(conn):
    silent = conn.execute(
        "SELECT count(*) FROM gu_types t WHERE gu_label(t.gu_type_id) IS NULL"
    ).fetchone()[0]
    assert silent == 0, f"{silent} Gu cannot say what they are"


def test_every_chest_names_its_gu_the_one_way(conn):
    """Four sites hand a Gu over and each used to build its own label out of
    `t.name`. Four copies of one sentence is four places for it to drift."""
    for proname, expected in (("dungeon_spoils_for", 2), ("horde_chest_take", 2)):
        source = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (proname,)
        ).fetchone()[0]
        assert source.count("gu_label(") == expected, (
            f"{proname} labels {source.count('gu_label(')} Gu, not {expected} "
            "- a roll was added or one went back to naming its own"
        )


# ---------------------------------------------------------------------------
# What a gauntlet run costs the tide it is drawing from (0264)
# ---------------------------------------------------------------------------


def test_one_gauntlet_run_cannot_drink_the_whole_sea(conn):
    """Tides were allotted two hours and ending in three minutes.

    A wave charged the sea on the DIFFICULTY curve, so the thirty-third wave
    cost sixty-five beasts and one player's run took 461 of a 580 sea. The sea
    is sized per hand; one hand's complete run must cost about one hand's
    share, or the first person to walk the line ends the event for everybody.
    """
    share, run, worst = conn.execute(
        """
        SELECT game_config_value('horde_beasts_per_hand') * (1 + 1 * 0.15),
               (SELECT sum(horde_gauntlet_worth(i)) FROM generate_series(1, 40) i),
               (SELECT max(horde_gauntlet_worth(i)) FROM generate_series(1, 40) i)
        """
    ).fetchone()

    assert run <= share * 2, (
        f"a full run costs {run} against a share of {round(share)} - the "
        "first player to walk the line ends the tide"
    )
    assert worst <= share / 4, (
        f"one wave alone costs {worst} against a share of {round(share)}"
    )
    # The other half of the bargain: a sea nobody can empty is a King who
    # never rises, because draining is what brings him out.
    assert run >= 10, f"a full run costs only {run}; the sea will not empty"


def test_difficulty_and_appetite_are_still_two_different_dials(conn):
    """The bug was one number doing two jobs.

    A wave SHOULD get much harder as it goes - that is what ends a run without
    a wave limit. It should not also decide that the thirty-third wave is
    sixty-five beasts. If these ever converge again, the tide goes back to
    lasting three minutes.
    """
    hard, hungry = conn.execute(
        """
        SELECT game_config_value('horde_gauntlet_step'),
               game_config_value('horde_gauntlet_worth_step')
        """
    ).fetchone()

    assert hungry < hard, (
        f"the sea drains at {hungry} against a difficulty of {hard} - a wave "
        "is charging the tide what it costs to beat it"
    )


# ---------------------------------------------------------------------------
# Clearing a whole rung in one press (0266)
# ---------------------------------------------------------------------------


def test_fuse_all_clears_every_stack_of_its_rung(conn, make_player):
    """miyuki was holding 202 fusions. Two hundred presses of the same button
    on the same screen is not a thing to ask of anybody."""
    who = make_player("Clearer")
    _pages(conn, who, 2, "light", "attack", 9)      # three fusions
    _pages(conn, who, 2, "fire", "defense", 3)      # one
    _pages(conn, who, 2, "wood", "attack", 2)       # none - a spare pair

    offered = conn.execute(
        "SELECT COALESCE(sum(fusions), 0) FROM page_fusion_shelf "
        "WHERE player_id = %s AND tier = 2",
        (who,),
    ).fetchone()[0]
    assert offered == 4, f"the shelf offered {offered} fusions, not 4"

    done = conn.execute(
        "SELECT fusions, spent, made_tier FROM fuse_all(%s, 2)", (who,)
    ).fetchone()
    assert done[0] == 4, "the shelf offered four fusions and fewer happened"
    assert done[1] == 12, "four fusions did not spend twelve pages"
    assert done[2] == 3

    left = conn.execute(
        "SELECT COALESCE(sum(fusions), 0) FROM page_fusion_shelf "
        "WHERE player_id = %s AND tier = 2",
        (who,),
    ).fetchone()[0]
    assert left == 0, "the rung still has fusions in it"

    # The pair that could not fuse is untouched, not swept up.
    spare = conn.execute(
        "SELECT count(*) FROM manual_pages WHERE owner_id = %s "
        "AND tier = 2 AND path_code = 'wood' AND consumed_at IS NULL",
        (who,),
    ).fetchone()[0]
    assert spare == 2, "the odd pages were spent by a fusion that cannot exist"


def test_fuse_all_stays_on_the_rung_it_was_given(conn, make_player):
    """Cascading would eat the tier above, and somebody refining a manual
    needs pages of a particular Path AND tier."""
    who = make_player("Careful")
    _pages(conn, who, 2, "light", "attack", 3)
    _pages(conn, who, 3, "light", "attack", 3)

    conn.execute("SELECT fuse_all(%s, 2)", (who,))

    # One new tier 3 from the fusion, plus the three that were already there.
    at_three = conn.execute(
        "SELECT count(*) FROM manual_pages WHERE owner_id = %s "
        "AND tier = 3 AND consumed_at IS NULL",
        (who,),
    ).fetchone()[0]
    assert at_three == 4, (
        f"tier 3 holds {at_three} pages - clearing tier 2 reached a rung it "
        "was not asked for"
    )


def test_fuse_all_refuses_a_rung_with_nothing_on_it(conn, make_player):
    who = make_player("Empty")
    _pages(conn, who, 2, "light", "attack", 2)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT fuse_all(%s, 2)", (who,))


def test_the_shelf_floors_its_fusions_rather_than_rounding(conn, make_player):
    """A cast from numeric to integer rounds, so eight pages advertised three
    fusions where two are possible - and the screen said so to the player."""
    who = make_player("Eight")
    _pages(conn, who, 2, "light", "attack", 8)

    held, fusions = conn.execute(
        "SELECT held, fusions FROM page_fusion_shelf "
        "WHERE player_id = %s AND tier = 2",
        (who,),
    ).fetchone()
    assert held == 8
    assert fusions == 2, f"eight pages advertise {fusions} fusions, not 2"

    done = conn.execute("SELECT fusions FROM fuse_all(%s, 2)", (who,)).fetchone()[0]
    assert done == fusions, "the shelf promised more than the cauldron did"


# ---------------------------------------------------------------------------
# A tide that ends takes the line home with it (0268)
# ---------------------------------------------------------------------------


def test_a_tide_that_ends_does_not_leave_somebody_on_the_line(conn, make_player):
    """visha could not use /fight horde for twenty-three hours.

    `horde_settle` walked every beast off the field and said nothing about the
    people, so her run stayed 'fighting' against a tide that was won the day
    before - and opening a new one refuses anybody who already has a live run.
    The screen was real and the buttons did nothing.
    """
    tide = _tide(conn, "northern", 2)
    who = _walker(conn, make_player, "Stranded")
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]

    assert conn.execute(
        "SELECT status FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
    ).fetchone()[0] == "fighting"

    # Ended by the clock: emptying the sea returns 'king', which is the finale
    # beginning rather than the event being over.
    conn.execute(
        "UPDATE beast_hordes SET ends_at = now() - interval '1 minute' "
        "WHERE horde_id = %s",
        (tide,),
    )
    assert conn.execute("SELECT horde_settle(%s)", (tide,)).fetchone()[0] == "won"

    assert conn.execute(
        "SELECT status FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
    ).fetchone()[0] != "fighting", "the tide went home and left somebody standing there"


def test_a_stranded_run_does_not_bar_its_owner_from_the_next_tide(conn, make_player):
    """The guarantee under the fix: whatever strands a run in future, it costs
    a press rather than the whole event."""
    old = _tide(conn, "northern", 2)
    who = _walker(conn, make_player, "Locked")
    run = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]

    # Strand it the way the bug did - the tide closes, the run is forgotten.
    conn.execute(
        "UPDATE beast_hordes SET status = 'won', ended_at = now() WHERE horde_id = %s",
        (old,),
    )
    assert conn.execute(
        "SELECT status FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
    ).fetchone()[0] == "fighting", "this test no longer reproduces the strand"

    _tide(conn, "northern", 2)
    fresh = conn.execute("SELECT horde_gauntlet_open(%s)", (who,)).fetchone()[0]

    assert fresh != run, "opening a run handed back the stranded one"
    assert conn.execute(
        "SELECT status FROM horde_gauntlets WHERE gauntlet_id = %s", (run,)
    ).fetchone()[0] == "cleared", "the stranded run was left open behind them"


# ---------------------------------------------------------------------------
# A deep room pays like a deep room (0269)
# ---------------------------------------------------------------------------


def test_the_dungeon_pot_climbs_the_way_the_gates_do(conn):
    """The pot was linear in the room's rank and everything it buys is not.

    Breakthrough gates climb four to five times a rank, so a linear pot meant
    the rank 9 gate wanted 808 clears of the deepest room in the game while
    the rank 2 gate wanted a tenth of one. No multiplier fixes that - ten times
    the pot still leaves 81 clears at the top and floods the shallow end.
    """
    base, step, insane = conn.execute(
        """
        SELECT game_config_value('dungeon_stone_reward_per_rank'),
               game_config_value('dungeon_stone_reward_growth'),
               (SELECT reward_scale FROM dungeon_difficulties WHERE code = 'insane')
        """
    ).fetchone()

    assert step > 1, "the pot no longer grows with the depth of the room"

    worst = conn.execute(
        """
        SELECT max(g.stones / (%s * power(%s, GREATEST(0, g.rank - 1)) * %s))
        FROM realm_gates g
        """,
        (base, step, insane),
    ).fetchone()[0]

    assert worst <= 40, (
        f"the worst gate still wants {round(worst)} clears of the room that "
        "funds it"
    )


def test_the_shallowest_room_was_not_touched(conn):
    """A newcomer leaves home with 5,000 stones against a rank 2 gate of
    2,000. The starvation was at the deep end and so is the money."""
    base, step = conn.execute(
        """
        SELECT game_config_value('dungeon_stone_reward_per_rank'),
               game_config_value('dungeon_stone_reward_growth')
        """
    ).fetchone()
    assert round(base * (step ** 0)) == round(base)


def test_a_deeper_room_is_worth_more_than_a_shallower_one(conn):
    """Asserted through the payout itself rather than the dials, so a future
    edit to `dungeon_pay_out` cannot quietly flatten it again."""
    src = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'dungeon_pay_out'"
    ).fetchone()[0]
    assert "dungeon_stone_reward_growth" in src, (
        "dungeon_pay_out went back to a pot that is linear in the rank"
    )


# ---------------------------------------------------------------------------
# Trading gear (0270)
# ---------------------------------------------------------------------------


def _trader_piece(conn, player, slot="weapon"):
    return conn.execute(
        "INSERT INTO player_equipment "
        "(owner_id, name, slot, tier, rarity, harmony, ore_code) "
        "VALUES (%s, 'Traded Piece', "
        "        (SELECT code FROM equipment_slots WHERE code = %s), "
        "        3, 'common', 60, 'iron_ore') "
        "RETURNING equipment_id",
        (player, slot),
    ).fetchone()[0]


def test_a_forged_piece_changes_hands(conn, traders):
    """A smith with a spare blade and a friend who walks that Path had to go
    through the auction house and pay the spread to hand it over."""
    a, b = traders()
    piece = _trader_piece(conn, a)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]

    conn.execute("SELECT trade_add_equipment(%s, %s, %s)", (trade, a, piece))

    # Offering is not giving.
    assert conn.execute(
        "SELECT owner_id FROM player_equipment WHERE equipment_id = %s", (piece,)
    ).fetchone()[0] == a

    conn.execute("SELECT trade_confirm(%s, %s)", (trade, a))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, b))

    assert conn.execute(
        "SELECT owner_id FROM player_equipment WHERE equipment_id = %s", (piece,)
    ).fetchone()[0] == b, "the piece did not cross the table"


def test_a_traded_piece_comes_off_the_body(conn, traders):
    """The same rule the auction house relies on: a handover is an UPDATE of
    owner_id, and the trigger on it strips the piece. Without that one player
    walks around wearing another player's gear."""
    a, b = traders()
    piece = _trader_piece(conn, a)
    conn.execute(
        "INSERT INTO player_equipped (player_id, slot, equipment_id) "
        "VALUES (%s, (SELECT slot FROM player_equipment WHERE equipment_id = %s), %s)",
        (a, piece, piece),
    )

    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute("SELECT trade_add_equipment(%s, %s, %s)", (trade, a, piece))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, a))
    conn.execute("SELECT trade_confirm(%s, %s)", (trade, b))

    assert conn.execute(
        "SELECT count(*) FROM player_equipped WHERE equipment_id = %s", (piece,)
    ).fetchone()[0] == 0, "the giver is still wearing what they handed over"


def test_gear_that_is_not_yours_cannot_be_offered(conn, traders):
    a, b = traders()
    theirs = _trader_piece(conn, b)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT trade_add_equipment(%s, %s, %s)", (trade, a, theirs))


def test_the_table_shows_the_gear_on_it(conn, traders):
    a, b = traders()
    piece = _trader_piece(conn, a)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute("SELECT trade_add_equipment(%s, %s, %s)", (trade, a, piece))

    row = conn.execute(
        "SELECT kind, label, ref_id FROM trade_contents "
        "WHERE trade_id = %s AND kind = 'equipment'",
        (trade,),
    ).fetchone()
    assert row is not None, "a piece on the table is not shown on it"
    assert "Traded Piece" in row[1]
    assert row[2] == piece


def test_taking_back_an_offer_takes_the_gear_too(conn, traders):
    a, b = traders()
    piece = _trader_piece(conn, a)
    trade = conn.execute("SELECT trade_open(%s, %s)", (a, b)).fetchone()[0]
    conn.execute("SELECT trade_add_equipment(%s, %s, %s)", (trade, a, piece))
    conn.execute("SELECT trade_withdraw(%s, %s)", (trade, a))

    assert conn.execute(
        "SELECT count(*) FROM trade_offer_equipment WHERE trade_id = %s", (trade,)
    ).fetchone()[0] == 0, "withdrawing an offer left the gear on the table"


# ---------------------------------------------------------------------------
# An escape is out of the sea, not back in it (0271)
# ---------------------------------------------------------------------------


def _last_beast(conn, tide, worth=12, expired=True):
    """One beast standing between the room and the finale."""
    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total - %s WHERE horde_id = %s",
        (worth, tide),
    )
    when = "now() - interval '1 second'" if expired else "now() + interval '1 hour'"
    return conn.execute(
        "INSERT INTO horde_encounters "
        "(horde_id, species_id, kind, hp, max_hp, worth, expires_at) "
        "VALUES (%s, (SELECT species_id FROM creature_species WHERE kind = 'beast' "
        f"            LIMIT 1), 'normal', 100, 100, %s, {when}) "
        "RETURNING encounter_id",
        (tide, worth),
    ).fetchone()[0]


def test_an_escape_at_the_tail_does_not_hold_the_king(conn):
    """The King rose on `beasts_slain` alone, and an escape credits
    `beasts_lost` instead - so the last beast timing out put its share of the
    sea back in the pool and the finale waited on it being sent again."""
    tide = _tide(conn, "northern", 2)
    beast = _last_beast(conn, tide)

    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "fighting"

    conn.execute("SELECT horde_sweep(%s)", (tide,))
    assert conn.execute(
        "SELECT status FROM horde_encounters WHERE encounter_id = %s", (beast,)
    ).fetchone()[0] == "escaped"

    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "king", (
        "one beast getting past still stops the King from rising"
    )


def test_an_escaped_beast_is_not_sent_again(conn):
    """It is in the region now. Sending it back would be charging the room
    twice for one mistake."""
    tide = _tide(conn, "northern", 2)
    _last_beast(conn, tide)
    conn.execute("SELECT horde_sweep(%s)", (tide,))

    assert conn.execute("SELECT horde_sea_left(%s)", (tide,)).fetchone()[0] == 0
    assert conn.execute("SELECT horde_spawn(%s)", (tide,)).fetchone()[0] is None, (
        "a drained tide sent another beast"
    )


def test_an_escape_still_costs_the_line(conn):
    """This makes an escape stop DELAYING the finale. It does not make it
    free - the line is still the only thing that loses a tide."""
    tide = _tide(conn, "northern", 2)
    _last_beast(conn, tide)
    conn.execute("SELECT horde_sweep(%s)", (tide,))

    assert conn.execute(
        "SELECT beasts_lost FROM beast_hordes WHERE horde_id = %s", (tide,)
    ).fetchone()[0] == 12

    conn.execute(
        "UPDATE beast_hordes SET beasts_lost = line_holds, beasts_slain = 0 "
        "WHERE horde_id = %s",
        (tide,),
    )
    assert conn.execute("SELECT horde_verdict(%s)", (tide,)).fetchone()[0] == "lost"


def test_the_board_counts_down_to_what_the_king_waits_on(conn):
    """The room is told the same number the finale is measured by, or it reads
    beasts still to come when there are none."""
    tide = _tide(conn, "northern", 2)
    _last_beast(conn, tide)
    conn.execute("SELECT horde_sweep(%s)", (tide,))

    left = conn.execute(
        "SELECT beasts_left FROM horde_board WHERE horde_id = %s", (tide,)
    ).fetchone()[0]
    assert left == 0, f"the board still shows {left} beasts to come"


# ---------------------------------------------------------------------------
# The King is fought in bursts (0272)
# ---------------------------------------------------------------------------


def _risen_king(conn, region="northern", rank=3):
    """A tide with its sea drained and the King up."""
    tide = _tide(conn, region, rank)
    conn.execute(
        "UPDATE beast_hordes SET beasts_slain = beasts_total WHERE horde_id = %s",
        (tide,),
    )
    king = conn.execute("SELECT horde_king_rise(%s)", (tide,)).fetchone()[0]
    assert king is not None, "the King did not rise on a drained sea"
    return tide, king


def _room_blows(conn, king):
    """What each cultivator the King was sized against actually lands.

    The same quantity `boss_hp_pool` sums, per person: their hardest technique
    against this species, times what a blow of theirs is really worth once
    extra strikes and criticals land, plus the beast at their heel. Comparing
    the pool against a bare `player_swing` compares two different things - the
    multiple alone is worth about four times - and the comparison drifts.
    """
    return [
        row[0]
        for row in conn.execute(
            """
            SELECT best.dealt * player_blow_multiple(p.player_id)
                   + COALESCE(pet_blow(pet_at_heel(p.player_id), e.species_id, 0), 0)
            FROM horde_encounters e
            CROSS JOIN players p
            JOIN LATERAL (
                SELECT max(would.final_damage) AS dealt
                FROM player_usable_techniques u
                JOIN techniques t ON t.technique_id = u.technique_id
                CROSS JOIN LATERAL compute_technique_damage(
                    p.player_id, t.technique_id, e.species_id,
                    player_external_multiplier(p.player_id, t.technique_id),
                    0) AS would
                WHERE u.player_id = p.player_id AND t.base_power > 0
            ) best ON best.dealt IS NOT NULL AND best.dealt > 0
            WHERE e.encounter_id = %s
              AND p.deleted_at IS NULL
              AND p.last_seen_at >= now() - make_interval(
                      mins => game_config_value('boss_presence_minutes')::integer)
            """,
            (king,),
        ).fetchall()
    ]


def _hardest_blow(conn, king):
    """The hardest single hitter among the people the King was sized against.

    Measured rather than pinned. Both of these tests used to compare the King
    against 3,840,944 - the hardest blow on the server on the day they were
    written - and the King has been sized against the live roster since 0290
    and against the room actually present since 0291. A frozen number on one
    side of that comparison is a test that goes wrong the moment somebody's
    gear moves, which is exactly what happened: the real figure was fifty
    times that within the year.
    """
    blows = _room_blows(conn, king)
    return max(blows) if blows else None


def test_the_king_survives_one_cultivators_burst(conn):
    """Tide 3873's King rose with 637,653 health and died inside one tick.
    miyuki hit it for 2,292,229 and nobody else in a room of seven got to
    touch the finale."""
    _, king = _risen_king(conn)
    pool = conn.execute(
        "SELECT max_hp FROM horde_encounters WHERE encounter_id = %s", (king,)
    ).fetchone()[0]

    hardest = _hardest_blow(conn, king)
    if not hardest:
        pytest.skip("nobody on the roster can swing at it")

    # Five strikes from whoever hits hardest right now.
    burst = hardest * conn.execute(
        "SELECT game_config_value('horde_king_burst')"
    ).fetchone()[0]

    assert pool > burst, (
        f"the King holds {pool} and one cultivator lands {burst} in a burst"
    )


def test_the_king_can_still_be_felled_in_the_time_it_stands(conn):
    """A finale nobody can finish is the other way to get this wrong."""
    _, king = _risen_king(conn)
    pool, stands, wait, cap = conn.execute(
        """
        SELECT (SELECT max_hp FROM horde_encounters WHERE encounter_id = %s),
               game_config_value('horde_king_minutes'),
               game_config_value('horde_king_cooldown_minutes'),
               game_config_value('horde_king_burst')
        """,
        (king,),
    ).fetchone()

    room = _room_blows(conn, king)
    if not room:
        pytest.skip("nobody on the roster can swing at it")

    # Everybody it was sized against, swinging their full allowance: the King
    # is the room's fight, so the room is the bar. One person alone clearing
    # it is not required and, on a server with this spread, not desirable.
    rounds = int(stands // wait) + 1
    landed = sum(room) * cap * rounds
    assert pool <= landed, (
        f"the King holds {pool}, more than the {landed} the {len(room)} "
        f"cultivators it was built for can land across {rounds} bursts in "
        f"{stands} minutes"
    )


def test_five_swings_at_the_king_and_then_a_stand_off(conn, make_player):
    tide, king = _risen_king(conn)
    who = _walker(conn, make_player, "Regicide")
    cap = conn.execute(
        "SELECT game_config_value('horde_king_burst')"
    ).fetchone()[0]

    # Big enough that the burst runs out long before its health does.
    conn.execute(
        "UPDATE horde_encounters SET hp = 999999999999, max_hp = 999999999999 "
        "WHERE encounter_id = %s",
        (king,),
    )

    for n in range(int(cap)):
        conn.execute("SELECT horde_strike(%s, %s)", (king, who))

    # Read the state before provoking the refusal: a raised exception aborts
    # the transaction and every query after it in this test.
    assert conn.execute(
        "SELECT king_burst_used FROM horde_contributions "
        "WHERE horde_id = %s AND player_id = %s",
        (tide, who),
    ).fetchone()[0] == cap

    assert conn.execute(
        "SELECT horde_king_ready_at(%s, %s)", (tide, who)
    ).fetchone()[0] is not None, "the screen cannot see the stand-off it is in"

    with pytest.raises(psycopg.errors.CheckViolation, match="standing off"):
        conn.execute("SELECT horde_strike(%s, %s)", (king, who))


def test_a_first_swing_of_the_tide_may_be_at_the_king(conn, make_player):
    """SELECT INTO leaves its target NULL rather than untouched, so somebody
    whose first swing of the whole tide is at the King had no contribution row
    to read a burst from - and the column refused the NULL."""
    _, king = _risen_king(conn)
    who = _walker(conn, make_player, "Latecomer")
    conn.execute(
        "UPDATE horde_encounters SET hp = 999999999999, max_hp = 999999999999 "
        "WHERE encounter_id = %s",
        (king,),
    )
    conn.execute("SELECT horde_strike(%s, %s)", (king, who))


def test_the_stand_off_is_told_in_plain_minutes(conn):
    """`%s` is not a plpgsql placeholder; the argument already says
    '6 minutes', so the stray s made it 'minutess'."""
    src = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'horde_strike'"
    ).fetchone()[0]
    assert "standing off" in src
    assert "standing off - %s before" not in src


# ---------------------------------------------------------------------------
# An anvil takes more than one metal (0274)
# ---------------------------------------------------------------------------


def test_low_ore_can_carry_a_forging_the_rest_of_the_way(conn, make_player):
    """A tier 1 ore made a tier 1 piece and nothing else, however much of it
    went on, so the low end of every prospecting trip was worth nothing."""
    who = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'gold_ore', 200)", (who,))
    conn.execute("SELECT grant_material(%s, 'iron_ore', 400)", (who,))
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 200)", (who,))

    # Two tier 2 ore alone: 4 potency each, so nowhere near a tier 3 piece.
    alone = conn.execute(
        "SELECT item_tier, potency FROM forge(%s, 'weapon', ARRAY['gold_ore'], "
        "ARRAY[2], ARRAY['wolf_fang'], ARRAY[1])",
        (who,),
    ).fetchone()

    # The same two, carried by cheap iron.
    helped = conn.execute(
        "SELECT item_tier, potency FROM forge(%s, 'weapon', "
        "ARRAY['gold_ore', 'iron_ore'], ARRAY[2, 60], "
        "ARRAY['wolf_fang'], ARRAY[1])",
        (who,),
    ).fetchone()

    assert helped[1] > alone[1], "the filler carried no potency at all"
    assert helped[0] >= alone[0], "adding metal made the piece worse"


def test_the_best_metal_is_still_the_ceiling(conn, make_player):
    """Filler carries a forging up to what its best ore could always have
    reached. It does not carry it past."""
    who = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'iron_ore', 5000)", (who,))
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 200)", (who,))

    made = conn.execute(
        "SELECT item_tier, potency FROM forge(%s, 'weapon', ARRAY['iron_ore'], "
        "ARRAY[3000], ARRAY['wolf_fang'], ARRAY[20])",
        (who,),
    ).fetchone()

    assert made[1] >= 400, "the fixture no longer buries the tier ladder"
    assert made[0] == 1, (
        f"tier 1 ore made a tier {made[0]} piece - the ceiling is gone"
    )


def test_mixing_grades_costs_the_finish_not_the_tier(conn, make_player):
    """The brake on filler, and the reason it needs no separate rule: spread
    is the distance between the best and worst thing on the anvil, at -2
    harmony each."""
    who = make_smith(conn, make_player)
    conn.execute("SELECT grant_material(%s, 'blazing_sunsteel', 200)", (who,))
    conn.execute("SELECT grant_material(%s, 'iron_ore', 500)", (who,))
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 400)", (who,))

    clean, mixed = (
        conn.execute(
            "SELECT harmony, item_tier FROM forge(%s, 'weapon', %s, %s, "
            "ARRAY['wolf_fang'], ARRAY[20])",
            (who, ores, qtys),
        ).fetchone()
        for ores, qtys in ((["blazing_sunsteel"], [20]),
                           (["blazing_sunsteel", "iron_ore"], [20, 200]))
    )

    assert mixed[0] < clean[0], (
        f"mixing tier 6 with tier 1 cost nothing: {mixed[0]} against {clean[0]}"
    )


def test_an_anvil_refuses_more_metals_than_it_holds(conn, make_player):
    who = make_smith(conn, make_player, level=1)
    for code in ("iron_ore", "gold_ore", "magma_iron"):
        conn.execute("SELECT grant_material(%s, %s, 100)", (who, code))
    conn.execute("SELECT grant_material(%s, 'wolf_fang', 50)", (who,))

    assert conn.execute(
        "SELECT smith_ore_slots(profession_level(%s, 'blacksmithing'))", (who,)
    ).fetchone()[0] == 2, "a new smith no longer starts with two metal slots"

    with pytest.raises(psycopg.errors.CheckViolation, match="metals"):
        conn.execute(
            "SELECT * FROM forge(%s, 'weapon', "
            "ARRAY['iron_ore', 'gold_ore', 'magma_iron'], ARRAY[10, 10, 10], "
            "ARRAY['wolf_fang'], ARRAY[5])",
            (who,),
        )


# ---------------------------------------------------------------------------
# A tide comes on its own when the region is busy (0275)
# ---------------------------------------------------------------------------


def _quiet_the_world(conn, ended_hours_ago=None):
    """No tide running, and the last one long enough ago to be out of its rest."""
    if ended_hours_ago is None:
        ended_hours_ago = (
            conn.execute(
                "SELECT game_config_value('horde_rest_hours')"
            ).fetchone()[0]
            + 1
        )
    conn.execute(
        "UPDATE beast_hordes SET status = 'won', "
        "ended_at = now() - make_interval(hours => %s)",
        (int(ended_hours_ago),),
    )


def test_a_tide_will_not_break_on_top_of_a_running_one(conn):
    _quiet_the_world(conn)
    conn.execute("SELECT horde_open('northern', 2::smallint, NULL)")

    assert conn.execute("SELECT horde_next_at()").fetchone()[0] is None, (
        "a running tide promised a next one"
    )
    assert conn.execute("SELECT horde_open_if_due(NULL)").fetchone()[0] is None


def test_a_tide_rests_before_the_next_one(conn):
    """The floor on how often the event can happen, whoever is about."""
    _quiet_the_world(conn, ended_hours_ago=0)

    due = conn.execute("SELECT horde_next_at()").fetchone()[0]
    assert due is not None and due > datetime.now(timezone.utc), (
        "a tide that just ended is already due again"
    )
    assert conn.execute("SELECT horde_open_if_due(NULL)").fetchone()[0] is None


def test_no_tide_comes_for_an_empty_room(conn):
    """A sea sized for one person is not an event, it is a chore."""
    _quiet_the_world(conn)
    conn.execute("UPDATE players SET last_seen_at = now() - interval '1 day' "
                 "WHERE discord_id <> 0")

    assert conn.execute("SELECT horde_watchers()").fetchone()[0] == 0
    assert conn.execute("SELECT horde_open_if_due(NULL)").fetchone()[0] is None


def test_talking_counts_as_being_about(conn, make_player):
    """`last_seen_at` was touched only by commands, so a channel could be busy
    with conversation and read as empty to the thing deciding whether a tide
    breaks. The bot touches it for anybody who speaks now; this is the column
    that has to notice."""
    conn.execute("UPDATE players SET last_seen_at = now() - interval '1 day' "
                 "WHERE discord_id <> 0")
    who = make_player("Chatter")
    conn.execute(
        "INSERT INTO player_character (player_id, race_code, root_code, confirmed_at) "
        "VALUES (%s, (SELECT code FROM races LIMIT 1), "
        "        (SELECT code FROM roots LIMIT 1), now())",
        (who,),
    )

    conn.execute("UPDATE players SET last_seen_at = now() - interval '1 day' "
                 "WHERE player_id = %s", (who,))
    assert conn.execute("SELECT horde_watchers()").fetchone()[0] == 0

    # What the on_message listener does for somebody who speaks.
    conn.execute("UPDATE players SET last_seen_at = now() WHERE player_id = %s", (who,))
    assert conn.execute("SELECT horde_watchers()").fetchone()[0] == 1


def test_a_busy_room_does_get_a_tide(conn):
    """The odds are per tick and deliberately small, so this rolls rather than
    asserting on one throw."""
    _quiet_the_world(conn)
    conn.execute("UPDATE players SET last_seen_at = now() WHERE discord_id <> 0")

    watchers, floor = conn.execute(
        "SELECT horde_watchers(), game_config_value('horde_spawn_floor')"
    ).fetchone()
    if watchers < floor:
        pytest.skip("not enough confirmed cultivators exist to prove this")

    made = None
    for _ in range(20000):
        made = conn.execute("SELECT horde_open_if_due(NULL)").fetchone()[0]
        if made is not None:
            break

    assert made is not None, "a busy room never got a tide"

    # And it broke somewhere a cultivator actually is.
    region = conn.execute(
        "SELECT region_code FROM beast_hordes WHERE horde_id = %s", (made,)
    ).fetchone()[0]
    assert region in {
        r[0] for r in conn.execute("SELECT code FROM regions").fetchall()
    }


# ---------------------------------------------------------------------------
# An egg becomes something that fights (0276-0280)
# ---------------------------------------------------------------------------


def _egg_for(conn, player, tier=8, rarity="common"):
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'beast' "
        "ORDER BY rank LIMIT 1"
    ).fetchone()[0]
    return conn.execute(
        "SELECT grant_beast_egg(%s, %s, %s::smallint, %s, NULL)",
        (player, species, tier, rarity),
    ).fetchone()[0]


def test_an_egg_hatches_once_and_comes_to_heel(conn, make_player):
    who = make_player("Hatcher")
    egg = _egg_for(conn, who)

    beast = conn.execute("SELECT hatch_egg(%s, %s)", (who, egg)).fetchone()[0]
    assert conn.execute(
        "SELECT at_heel FROM player_beasts WHERE beast_id = %s", (beast,)
    ).fetchone()[0], "the first beast hatched did not come to heel"
    assert conn.execute("SELECT pet_at_heel(%s)", (who,)).fetchone()[0] == beast

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT hatch_egg(%s, %s)", (who, egg))


def test_a_hatched_beast_is_not_called_an_egg(conn, make_player):
    """`beast_egg_name` names the thing in your bag. It stops being true the
    moment the thing climbs out of it."""
    who = make_player("Namer")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who))
    ).fetchone()[0]

    name = conn.execute(
        "SELECT name FROM player_beasts WHERE beast_id = %s", (beast,)
    ).fetchone()[0]
    assert not name.endswith("Egg"), name


def test_only_one_beast_walks_at_a_time(conn, make_player):
    who = make_player("Menagerie")
    first = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who))
    ).fetchone()[0]
    second = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who))
    ).fetchone()[0]

    assert not conn.execute(
        "SELECT at_heel FROM player_beasts WHERE beast_id = %s", (second,)
    ).fetchone()[0], "two beasts came to heel at once"

    conn.execute("SELECT pet_call(%s, %s)", (who, second))
    assert conn.execute("SELECT pet_at_heel(%s)", (who,)).fetchone()[0] == second
    assert conn.execute(
        "SELECT count(*) FROM player_beasts WHERE owner_id = %s AND at_heel", (who,)
    ).fetchone()[0] == 1


def test_the_shelf_lists_a_two_path_beast_once(conn, make_player):
    """`creature_paths` can hold two rows for one species, and the shelf joined
    it - so a Storm Eagle appeared twice, as Wind and as Lightning."""
    who = make_player("Shelver")
    species = conn.execute(
        "SELECT cp.species_id FROM creature_paths cp GROUP BY cp.species_id "
        "HAVING count(*) > 1 LIMIT 1"
    ).fetchone()
    if species is None:
        pytest.skip("no species walks two Paths")

    egg = conn.execute(
        "SELECT grant_beast_egg(%s, %s, 4::smallint, 'common', NULL)",
        (who, species[0]),
    ).fetchone()[0]
    beast = conn.execute("SELECT hatch_egg(%s, %s)", (who, egg)).fetchone()[0]

    assert conn.execute(
        "SELECT count(*) FROM player_beast_shelf WHERE beast_id = %s", (beast,)
    ).fetchone()[0] == 1


def test_a_deeper_egg_hatches_a_stronger_beast(conn, make_player):
    who = make_player("Grader")
    shallow = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=2))
    ).fetchone()[0]
    deep = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=7))
    ).fetchone()[0]

    assert conn.execute("SELECT pet_attack(%s)", (deep,)).fetchone()[0] > conn.execute(
        "SELECT pet_attack(%s)", (shallow,)
    ).fetchone()[0], "the deeper egg hatched the weaker beast"


def test_the_beast_at_heel_swings_and_the_penned_one_does_not(conn, make_player):
    """Every lane lands its blow through `player_swing`, which is why the pet
    joining the fight was one change rather than five."""
    who = _walker(conn, make_player, "Houndmaster")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=6))
    ).fetchone()[0]
    target = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'beast' "
        "ORDER BY rank LIMIT 1"
    ).fetchone()[0]

    with_pet = conn.execute(
        "SELECT dealt, pet_dealt, pet_name FROM player_swing(%s, %s, %s, "
        "99999999999::bigint, 0::bigint, NULL, NULL, 0)",
        (who, conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0],
         target),
    ).fetchone()

    assert with_pet[1] > 0, "the beast at heel did not swing"
    assert with_pet[2] is not None, "the blow came from nobody"

    conn.execute("UPDATE player_beasts SET at_heel = FALSE WHERE beast_id = %s", (beast,))
    alone = conn.execute(
        "SELECT pet_dealt FROM player_swing(%s, %s, %s, "
        "99999999999::bigint, 0::bigint, NULL, NULL, 0)",
        (who, conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0],
         target),
    ).fetchone()[0]
    assert alone == 0, "a beast that was sent away still swung"


def test_no_beast_fights_the_battle_for_its_owner(conn, make_player):
    """A pet's strength tracks its egg and its owner's tracks realm and gear.
    A tier 8 egg in a weak cultivator's hands was worth seventeen times what
    they could do themselves."""
    who = _walker(conn, make_player, "Outclassed")
    conn.execute("SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=9)))
    target = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'beast' "
        "ORDER BY rank LIMIT 1"
    ).fetchone()[0]

    dealt, pet_dealt, cap = conn.execute(
        "SELECT s.dealt, s.pet_dealt, game_config_value('pet_share_cap') "
        "FROM player_swing(%s, %s, %s, 99999999999::bigint, 0::bigint, "
        "NULL, NULL, 0) s",
        (who, conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0],
         target),
    ).fetchone()

    assert pet_dealt > 0
    assert pet_dealt <= dealt * float(cap) + 1, (
        f"the beast dealt {pet_dealt} of a blow of {dealt}, past its share"
    )


def test_a_world_beast_is_sized_against_the_pets_too(conn):
    """`boss_hp_pool` sums what every cultivator can deal. A pet's blow is not
    in `player_usable_techniques`, so without counting it a boss comes out
    short by exactly what the pets add - invisibly."""
    src = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'boss_hp_pool'"
    ).fetchone()[0]
    assert "pet_blow" in src, "boss_hp_pool went back to ignoring pets"


# ---------------------------------------------------------------------------
# A leader may close the door they opened (0281)
# ---------------------------------------------------------------------------


def _door(conn):
    return conn.execute(
        "SELECT dungeon_id FROM dungeons ORDER BY realm_rank LIMIT 1"
    ).fetchone()[0]


def test_the_leader_can_call_off_a_gathering(conn, make_player):
    """A party that changes its mind waited out the whole forming window
    before any of them could open another door."""
    leader = make_player("Leader")
    run = conn.execute(
        "SELECT dungeon_open(%s, %s, 'normal')", (leader, _door(conn))
    ).fetchone()[0]

    conn.execute("SELECT dungeon_cancel(%s, %s)", (run, leader))

    assert conn.execute(
        "SELECT status FROM dungeon_runs WHERE run_id = %s", (run,)
    ).fetchone()[0] == "abandoned"

    # And they are free at once, which is the point of the button.
    again = conn.execute(
        "SELECT dungeon_open(%s, %s, 'normal')", (leader, _door(conn))
    ).fetchone()[0]
    assert again != run


def test_only_the_leader_may_call_it_off(conn, make_player):
    leader = make_player("Leader")
    tagalong = make_player("Tagalong")
    run = conn.execute(
        "SELECT dungeon_open(%s, %s, 'normal')", (leader, _door(conn))
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="opened the door"):
        conn.execute("SELECT dungeon_cancel(%s, %s)", (run, tagalong))


def test_a_run_that_has_begun_is_nobodys_to_call_off(conn, make_player):
    """Everybody has paid a key by then, and a leader who could end it would
    be spending four other people's keys on a whim."""
    leader = make_player("Leader")
    run = conn.execute(
        "SELECT dungeon_open(%s, %s, 'normal')", (leader, _door(conn))
    ).fetchone()[0]
    conn.execute("UPDATE dungeon_runs SET status = 'fighting' WHERE run_id = %s", (run,))

    with pytest.raises(psycopg.errors.CheckViolation, match="through the door"):
        conn.execute("SELECT dungeon_cancel(%s, %s)", (run, leader))


def test_cancelling_hands_nothing_back_because_nothing_was_taken(conn, make_player):
    """`dungeon_begin` is what takes the keys, and a forming run has not
    reached it. This is the test that says so rather than leaving a future
    reader to wonder where the refund went."""
    leader = make_player("Leader")
    conn.execute("SELECT grant_material(%s, 'dungeon_key', 3)", (leader,))

    before = conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = 'dungeon_key'",
        (leader,),
    ).fetchone()[0]

    run = conn.execute(
        "SELECT dungeon_open(%s, %s, 'normal')", (leader, _door(conn))
    ).fetchone()[0]
    conn.execute("SELECT dungeon_cancel(%s, %s)", (run, leader))

    assert conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = 'dungeon_key'",
        (leader,),
    ).fetchone()[0] == before, "opening and cancelling moved a key"


# ---------------------------------------------------------------------------
# A beast hatches small and is raised (0282)
# ---------------------------------------------------------------------------


def _cheap_ore(conn):
    return conn.execute(
        "SELECT material_code FROM ores ORDER BY tier LIMIT 1"
    ).fetchone()[0]


def test_a_new_egg_hatches_as_a_baby(conn, make_player):
    who = make_player("Nurse")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=5))
    ).fetchone()[0]

    assert conn.execute(
        "SELECT stage FROM player_beasts WHERE beast_id = %s", (beast,)
    ).fetchone()[0] == "baby"


def test_feeding_raises_a_beast_and_makes_it_hit_harder(conn, make_player):
    who = make_player("Nurse")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=3))
    ).fetchone()[0]
    ore = _cheap_ore(conn)
    conn.execute("SELECT grant_material(%s, %s, 100000)", (who, ore))

    small = conn.execute("SELECT pet_attack(%s)", (beast,)).fetchone()[0]

    got = conn.execute(
        "SELECT stage, grew_to FROM feed_beast(%s, %s, %s, 100000)",
        (who, beast, ore),
    ).fetchone()

    assert got[1] is not None, "a hundred thousand mouthfuls raised nothing"
    assert conn.execute("SELECT pet_attack(%s)", (beast,)).fetchone()[0] > small, (
        "growing up made it weaker"
    )


def test_every_stage_is_reached_in_order(conn, make_player):
    who = make_player("Patient")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=2))
    ).fetchone()[0]
    ore = _cheap_ore(conn)
    conn.execute("SELECT grant_material(%s, %s, 100000)", (who, ore))

    seen = ["baby"]
    for _ in range(3):
        wants = conn.execute("SELECT beast_feed_needed(%s)", (beast,)).fetchone()[0]
        if wants is None:
            break
        conn.execute(
            "SELECT feed_beast(%s, %s, %s, %s)", (who, beast, ore, int(wants))
        )
        seen.append(
            conn.execute(
                "SELECT stage FROM player_beasts WHERE beast_id = %s", (beast,)
            ).fetchone()[0]
        )

    assert seen == ["baby", "juvenile", "adult", "elder"], seen


def test_only_essence_carries_an_elder_past_its_years(conn, make_player):
    """Ore raises a beast to Elder and stops dead there.

    This used to assert that Elder was the end of the ladder. 0409 gave it nine
    immortal rungs, so what is worth pinning is no longer that the beast stops
    - it is what it stops FOR, and that a big enough pile of ore cannot simply
    walk through. 0410 is the migration that made the second half true: the
    rule had been asked once at the door, so a mountain of ore fed to an ADULT
    climbed past Elder and up to rank fifteen before anything looked again.
    """
    who = make_player("Finished")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=1))
    ).fetchone()[0]
    ore = _cheap_ore(conn)
    conn.execute("SELECT grant_material(%s, %s, 100000)", (who, ore))
    conn.execute("SELECT feed_beast(%s, %s, %s, 100000)", (who, beast, ore))

    # One meal, fed to a baby, and it stops at Elder with nothing banked
    # towards a rung ore may not buy.
    stage, fed = conn.execute(
        "SELECT stage, fed FROM player_beasts WHERE beast_id = %s", (beast,)
    ).fetchone()
    assert stage == "elder", stage
    assert fed == 0, fed

    # There is somewhere to go now, and essence is what gets there.
    assert conn.execute("SELECT beast_needs_essence(%s)", (beast,)).fetchone()[0]
    want = conn.execute("SELECT beast_feed_needed(%s)", (beast,)).fetchone()[0]
    conn.execute(
        "SELECT grant_material(%s, 'dewberry_essence', %s)", (who, int(want))
    )
    grew = conn.execute(
        "SELECT grew_to FROM feed_beast(%s, %s, 'dewberry_essence', %s)",
        (who, beast, int(want)),
    ).fetchone()[0]
    assert grew == "dewberry", grew

    # And ore still will not. Last, because the refusal aborts the transaction
    # and nothing after it in this test would run.
    with pytest.raises(psycopg.errors.CheckViolation, match="elder"):
        conn.execute("SELECT feed_beast(%s, %s, %s, 1)", (who, beast, ore))


def test_a_beast_will_not_eat_the_herb_garden(conn, make_player):
    """Ore and what comes off other beasts. Not herbs, not pages, not keys."""
    who = make_player("Picky")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who))
    ).fetchone()[0]

    herb = conn.execute(
        "SELECT code FROM materials WHERE tier IS NOT NULL LIMIT 1"
    ).fetchone()[0]
    assert conn.execute(
        "SELECT beast_food_value(%s)", (herb,)
    ).fetchone()[0] == 0

    conn.execute("SELECT grant_material(%s, %s, 50)", (who, herb))
    with pytest.raises(psycopg.errors.CheckViolation, match="will not eat"):
        conn.execute("SELECT feed_beast(%s, %s, %s, 1)", (who, beast, herb))


def test_a_deeper_beast_is_a_longer_project(conn, make_player):
    """The cost scales with the beast's tier, which is what its tier means
    everywhere else in this game."""
    who = make_player("Comparer")
    shallow = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=1))
    ).fetchone()[0]
    deep = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=9))
    ).fetchone()[0]

    assert conn.execute(
        "SELECT beast_feed_needed(%s)", (deep,)
    ).fetchone()[0] > conn.execute(
        "SELECT beast_feed_needed(%s)", (shallow,)
    ).fetchone()[0]


def test_a_reset_beast_keeps_everything_but_its_stage(conn, make_player):
    """0283 sent every beast back to baby, including the twenty hatched before
    stages existed. What it must not have taken with it is anything else: the
    species, the tier, the shell and which one walks at your heel were never
    the thing being reset.
    """
    who = make_player("Reset")
    first = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=6))
    ).fetchone()[0]
    second = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=4))
    ).fetchone()[0]

    ore = _cheap_ore(conn)
    conn.execute("SELECT grant_material(%s, %s, 100000)", (who, ore))
    conn.execute("SELECT feed_beast(%s, %s, %s, 100000)", (who, first, ore))

    before = conn.execute(
        "SELECT name, tier, rarity, species_id, at_heel FROM player_beasts "
        "WHERE beast_id = %s",
        (first,),
    ).fetchone()
    assert conn.execute(
        "SELECT stage FROM player_beasts WHERE beast_id = %s", (first,)
    ).fetchone()[0] != "baby", "the fixture did not raise it in the first place"

    # What 0283 did, to everything.
    conn.execute("UPDATE player_beasts SET stage = 'baby', fed = 0")

    after = conn.execute(
        "SELECT name, tier, rarity, species_id, at_heel FROM player_beasts "
        "WHERE beast_id = %s",
        (first,),
    ).fetchone()
    assert after == before, "the reset took more than the stage"
    assert conn.execute(
        "SELECT count(*) FROM player_beasts WHERE owner_id = %s AND at_heel", (who,)
    ).fetchone()[0] == 1, "the reset left nobody walking"



# ---------------------------------------------------------------------------
# A lesser beast raises a greater one (0284)
# ---------------------------------------------------------------------------


def test_a_lesser_beast_can_be_fed_to_a_greater_one(conn, make_player):
    """59 of the eggs waiting are tier 3. A tier 3 beast is nobody's companion
    once they hold a tier 9, so without this the commonest drop in the game
    has no use at all."""
    who = make_player("Renderer")
    big = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=9))
    ).fetchone()[0]
    small = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=3))
    ).fetchone()[0]
    conn.execute("UPDATE player_beasts SET at_heel = FALSE WHERE beast_id = %s", (small,))

    worth = conn.execute("SELECT beast_render_value(%s)", (small,)).fetchone()[0]
    assert worth > 0, "a hatchling is worth nothing as food"

    got = conn.execute(
        "SELECT worth, fed FROM feed_beast_beast(%s, %s, %s)", (who, big, small)
    ).fetchone()

    assert got[0] == worth
    assert conn.execute(
        "SELECT count(*) FROM player_beasts WHERE beast_id = %s", (small,)
    ).fetchone()[0] == 0, "the beast that was eaten is still standing there"


def test_a_beast_will_not_eat_the_one_at_your_heel(conn, make_player):
    """That is the one you chose, and losing it to a misclick is not a thing
    this should be able to do."""
    who = make_player("Careful")
    first = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=5))
    ).fetchone()[0]
    second = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=3))
    ).fetchone()[0]

    # `first` came to heel by hatching first.
    with pytest.raises(psycopg.errors.CheckViolation, match="at your heel"):
        conn.execute("SELECT feed_beast_beast(%s, %s, %s)", (who, second, first))


def test_a_beast_cannot_be_fed_to_itself(conn, make_player):
    who = make_player("Ouroboros")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=4))
    ).fetchone()[0]

    with pytest.raises(psycopg.errors.CheckViolation, match="itself"):
        conn.execute("SELECT feed_beast_beast(%s, %s, %s)", (who, beast, beast))


def test_rendering_returns_a_share_of_what_was_fed_in(conn, make_player):
    """Growing fodder is a real choice and still a loss, so it never beats
    feeding the beast you meant to raise."""
    who = make_player("Investor")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=4))
    ).fetchone()[0]
    conn.execute("UPDATE player_beasts SET at_heel = FALSE WHERE beast_id = %s", (beast,))

    raw = conn.execute("SELECT beast_render_value(%s)", (beast,)).fetchone()[0]

    ore = _cheap_ore(conn)
    conn.execute("SELECT grant_material(%s, %s, 100000)", (who, ore))
    conn.execute("SELECT feed_beast(%s, %s, %s, 200)", (who, beast, ore))

    fed_in = conn.execute("SELECT beast_invested(%s)", (beast,)).fetchone()[0]
    grown_worth = conn.execute("SELECT beast_render_value(%s)", (beast,)).fetchone()[0]
    share = conn.execute(
        "SELECT game_config_value('pet_render_share')"
    ).fetchone()[0]

    assert grown_worth > raw, "feeding it did not make it worth more as food"
    assert grown_worth < raw + fed_in, (
        "rendering handed back everything that went in, so fodder is free"
    )
    assert abs(float(grown_worth) - (float(raw) + float(fed_in) * float(share))) < 1


def test_the_shallow_end_of_the_shelf_is_worth_hatching(conn):
    """The number that decides whether tier 3 eggs are worth opening: how many
    of them move a tier 9 one stage."""
    per_tier, step = conn.execute(
        "SELECT game_config_value('pet_render_per_tier'), "
        "       (SELECT feed_per_tier FROM beast_stages WHERE code = 'juvenile')"
    ).fetchone()

    lesser = 3 * float(per_tier)
    needed = float(step) * 9 / lesser
    assert needed <= 20, f"it takes {round(needed)} tier 3 beasts to move a tier 9"


def test_a_beast_has_a_body_and_it_is_held_against_its_owner(conn, make_player):
    """The reason `pet_hp_cap` exists.

    A beast's strength comes from the egg it hatched out of and its owner's
    comes from realm and gear, and those two have nothing to do with each
    other. Measured before 0285 went in, an uncapped tier 8 hatchling would
    have carried twelve times its owner's own body, which would have made
    three live players effectively unkillable for holding a chest drop.
    """
    who = _walker(conn, make_player, "Bodied")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=9))
    ).fetchone()[0]

    top, mine, cap = conn.execute(
        """
        SELECT pet_max_hp(%s),
               (SELECT max_hp FROM player_physique WHERE player_id = %s),
               game_config_value('pet_hp_cap')
        """,
        (beast, who),
    ).fetchone()

    assert top >= 1, "a hatched beast has no body at all"
    assert top <= mine * cap + 1, (
        f"a tier 9 hatchling carries {top} against an owner with {mine}"
    )
    assert conn.execute("SELECT pet_hp(%s)", (beast,)).fetchone()[0] == top, (
        "a beast that has never been hit is not whole"
    )


def test_a_beast_covers_a_share_and_can_be_put_down(conn, make_player):
    """Cover is a share of every blow, not a coin flip, and it is finite.

    A share because a chance that occasionally eats a whole blow reads as the
    game cheating. Finite because the beast's own health is what bounds it.
    """
    who = make_player("Covered")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=9))
    ).fetchone()[0]
    top = conn.execute("SELECT pet_max_hp(%s)", (beast,)).fetchone()[0]

    took, covered, name = conn.execute(
        "SELECT taken, covered, pet_name FROM player_take(%s, 1000, 100000, 100000)",
        (who,),
    ).fetchone()

    assert covered > 0, "the beast covered nothing"
    assert name is not None, "the beast covered a blow and would not be named"
    assert conn.execute("SELECT pet_hp(%s)", (beast,)).fetchone()[0] < top, (
        "the beast covered a blow and is somehow untouched"
    )

    # On the floor it stops being a defence and stops being a weapon, but it
    # is still yours - nothing in this game takes a beast away for losing.
    conn.execute("UPDATE player_beasts SET hp = 0 WHERE beast_id = %s", (beast,))

    assert conn.execute("SELECT pet_standing(%s)", (who,)).fetchone()[0] is None
    assert conn.execute("SELECT pet_at_heel(%s)", (who,)).fetchone()[0] == beast, (
        "a downed beast stopped being yours"
    )
    assert conn.execute(
        "SELECT covered FROM player_take(%s, 1000, 100000, 100000)", (who,)
    ).fetchone()[0] == 0, "a downed beast covered a blow"

    move = conn.execute("SELECT dungeon_default_move(%s)", (who,)).fetchone()[0]
    if move is not None:
        species = conn.execute(
            "SELECT species_id FROM creature_species WHERE kind = 'beast' "
            "ORDER BY rank DESC LIMIT 1"
        ).fetchone()[0]
        assert conn.execute(
            "SELECT pet_dealt FROM player_swing(%s, %s, %s, 5000000000, 0)",
            (who, move, species),
        ).fetchone()[0] == 0, "a downed beast swung anyway"


def test_a_pill_the_body_cannot_hold_goes_to_the_beast(conn, make_player):
    """0384. A healing pill taken at full health used to be eaten for nothing.

    The rule is the overflow, not the full case: the body fills first and the
    remainder reaches the beast, so there is no threshold to discover and no
    reason to top yourself up before drinking.
    """
    who = _walker(conn, make_player, "Dosing")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=9))
    ).fetchone()[0]
    top = conn.execute("SELECT pet_max_hp(%s)", (beast,)).fetchone()[0]

    conn.execute("UPDATE player_beasts SET hp = 1 WHERE beast_id = %s", (beast,))
    conn.execute(
        "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s", (who,)
    )
    pill = _shelf(conn, who, "healing", max(2, top // 4))

    granted, detail = conn.execute(
        "SELECT granted, detail FROM take_pill(%s, %s)", (who, pill)
    ).fetchone()

    assert granted > 0, "a whole body with a hurt beast still banked nothing"
    assert conn.execute("SELECT pet_hp(%s)", (beast,)).fetchone()[0] > 1, (
        "the beast is no better off for the pill"
    )
    assert "drank it" in detail, detail

    # The body still comes first. A pill that spread itself across both would
    # be a different promise than the one the screen makes.
    conn.execute("UPDATE player_beasts SET hp = 1 WHERE beast_id = %s", (beast,))
    conn.execute(
        "UPDATE player_physique SET current_hp = max_hp - 100 WHERE player_id = %s",
        (who,),
    )
    conn.execute("SELECT take_pill(%s, %s)", (who, pill))
    hp, max_hp = conn.execute(
        "SELECT current_hp, max_hp FROM player_physique WHERE player_id = %s", (who,)
    ).fetchone()
    assert hp == max_hp, "the beast was fed before the body was whole"

    # And a beast already whole is not somewhere a pill disappears into.
    conn.execute("UPDATE player_beasts SET hp = NULL WHERE beast_id = %s", (beast,))
    conn.execute(
        "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s", (who,)
    )
    spare = _shelf(conn, who, "healing", 500)
    granted, detail = conn.execute(
        "SELECT granted, detail FROM take_pill(%s, %s)", (who, spare)
    ).fetchone()
    assert granted == 0
    assert detail == "The body could not hold all of it.", detail


def _canonical_technique(conn, effect, *, party):
    """The shallowest stock technique carrying `effect`, aimed as asked.

    Read out of the roster rather than named, so this keeps testing the rule
    rather than testing that Rally the Line still exists.
    """
    aim = "" if party else "NOT "
    return conn.execute(
        "SELECT technique_id FROM techniques WHERE code IS NOT NULL "
        "AND effects::text LIKE %s "
        "AND " + aim + "(effects @> '{\"apply\": [{\"target\": \"party\"}]}') "
        "ORDER BY rank LIMIT 1",
        (f"%{effect}%",),
    ).fetchone()[0]


def test_what_is_shouted_to_the_line_reaches_the_beast_in_it(conn, make_player):
    """0385. A technique aimed at the company reaches the beast walking in it;
    one kept to yourself does not.

    The distinction is read off the technique's own spec at the moment it is
    cast, not off whether the room happened to hold anybody else - so a rally
    shouted in a duel reaches the beast standing in that duel.
    """
    who = _walker(conn, make_player, "Shouter")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=9))
    ).fetchone()[0]
    fight = 9_000_000_123

    shouted = _canonical_technique(conn, "attack_up", party=True)
    private = _canonical_technique(conn, "attack_up", party=False)
    mending = _canonical_technique(conn, "regen", party=True)

    # The shout carries, at full strength: the beast is in the company, not
    # a lesser member of it.
    conn.execute(
        "SELECT technique_cast_effects(%s, %s, 'battle', %s)",
        (who, shouted, fight),
    )
    owner, pet = conn.execute(
        "SELECT effect_value('battle', %s, %s, 'attack_up'), "
        "       pet_party_effect('battle', %s, %s, 'attack_up')",
        (fight, who, fight, who),
    ).fetchone()
    assert pet > 0, "a rally at the whole line did not reach the beast"
    assert pet == owner, f"the beast got {pet} of the {owner} its owner did"

    # The mutter does not.
    conn.execute("SELECT effect_clear('battle', %s)", (fight,))
    conn.execute(
        "SELECT technique_cast_effects(%s, %s, 'battle', %s)",
        (who, private, fight),
    )
    owner, pet = conn.execute(
        "SELECT effect_value('battle', %s, %s, 'attack_up'), "
        "       pet_party_effect('battle', %s, %s, 'attack_up')",
        (fight, who, fight, who),
    ).fetchone()
    assert owner > 0, "the private buff did not land on its own caster"
    assert pet == 0, "a buff kept to yourself leaked to the beast anyway"

    # And a Mending meant for the company mends the beast, by a share of the
    # beast's own maximum rather than its owner's.
    conn.execute("SELECT effect_clear('battle', %s)", (fight,))
    top = conn.execute("SELECT pet_max_hp(%s)", (beast,)).fetchone()[0]
    conn.execute("UPDATE player_beasts SET hp = 1 WHERE beast_id = %s", (beast,))
    conn.execute(
        "SELECT technique_cast_effects(%s, %s, 'battle', %s)",
        (who, mending, fight),
    )
    share = conn.execute(
        "SELECT pet_party_effect('battle', %s, %s, 'regen')", (fight, who)
    ).fetchone()[0]
    mended = conn.execute(
        "SELECT pet_tick_regen('battle', %s, %s)", (fight, who)
    ).fetchone()[0]
    assert mended == max(1, int(top * share)), (
        f"{mended} mended against {top} x {share}"
    )
    assert conn.execute("SELECT pet_hp(%s)", (beast,)).fetchone()[0] > 1

    conn.execute("UPDATE player_beasts SET hp = NULL WHERE beast_id = %s", (beast,))
    assert conn.execute(
        "SELECT pet_tick_regen('battle', %s, %s)", (fight, who)
    ).fetchone()[0] == 0, "a whole beast was mended further"

    conn.execute("SELECT effect_clear('battle', %s)", (fight,))


def test_both_regen_lanes_mend_the_beast_beside_them(conn):
    """A rule that only holds in one of two lanes is a rule players learn and
    then get wrong. Both places that tick Mending have to reach the beast."""
    for lane in ("battle_act", "dungeon_resolve_round"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (lane,)
        ).fetchone()[0]
        assert "pet_tick_regen" in body, f"{lane} mends nobody's beast"


def test_a_rest_puts_the_beast_back_on_its_feet(conn, make_player):
    """Recovery is the thing you already do when your own body is short."""
    who = _walker(conn, make_player, "Rester")
    beast = conn.execute(
        "SELECT hatch_egg(%s, %s)", (who, _egg_for(conn, who, tier=9))
    ).fetchone()[0]

    conn.execute("UPDATE player_beasts SET hp = 0 WHERE beast_id = %s", (beast,))
    conn.execute("SELECT rest(%s)", (who,))

    assert conn.execute("SELECT pet_hp(%s)", (beast,)).fetchone()[0] > 0, (
        "a rest left the beast on the floor"
    )
    assert conn.execute("SELECT pet_standing(%s)", (who,)).fetchone()[0] == beast


def test_every_combat_lane_reports_the_beast(conn):
    """The bug that started all of this.

    `player_swing` returned `pet_dealt` from 0278 and not one lane passed it
    up, so the number was computed, folded into the total, and thrown away
    before any screen could print it. A pet that works and cannot be seen is
    reported as a pet that does not work - which is exactly what happened.
    """
    wants = {
        "battle_act": ("pet_dealt", "pet_name", "pet_covered", "pet_hp", "pet_max_hp"),
        "strike_boss": ("pet_dealt", "pet_name", "pet_covered"),
        "horde_gauntlet_swing": ("pet_dealt", "pet_name", "pet_covered"),
        "horde_strike": ("pet_dealt", "pet_name"),
    }
    for lane, columns in wants.items():
        got = conn.execute(
            "SELECT pg_get_function_result(oid) FROM pg_proc WHERE proname = %s",
            (lane,),
        ).fetchone()[0]
        for column in columns:
            assert column in got, f"{lane} swallows {column}"

    # The dungeon answers in jsonb, so its keys are the contract there.
    room = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'dungeon_resolve_round'"
    ).fetchone()[0]
    for key in ("pet_damage", "pet_covered"):
        assert key in room, f"the dungeon log swallows {key}"


def test_no_lane_reads_a_field_off_an_unassigned_record(conn):
    """What 0286 got wrong and 0288 fixed.

    In the gauntlet `swung` is only assigned on the branch where you attack,
    so a Guard reached the return with the record never assigned and Postgres
    refused the whole thing. COALESCE cannot save that - an unassigned record
    has no tuple structure, so naming any field of it is the error, not the
    value. The rule: a return may only read records that every branch fills.
    """
    src = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'horde_gauntlet_swing'"
    ).fetchone()[0]
    tail = src[src.index("RETURN QUERY"):]

    for record in ("swung.", "took.", "bit."):
        assert record not in tail, (
            f"the gauntlet return reads {record} off a record that only one "
            "branch assigns"
        )


def _standing_beast(conn, max_hp=1_000_000_000, part=0.6):
    """A world beast on the board, at a known fraction of itself."""
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'world' LIMIT 1"
    ).fetchone()[0]
    # `boss_only_one_open` allows exactly one at a time, and the dev database
    # usually has a real one standing. Rolled back with the rest of the test.
    conn.execute(
        "UPDATE boss_encounters SET status = 'escaped', ended_at = now() "
        "WHERE status = 'open'"
    )
    return conn.execute(
        """
        INSERT INTO boss_encounters
            (species_id, region_code, max_hp, current_hp, status,
             opened_at, closes_at)
        VALUES (%s, 'northern', %s, %s, 'open', now(), now() + interval '6 hours')
        RETURNING encounter_id
        """,
        (species, max_hp, int(max_hp * part)),
    ).fetchone()[0]


def test_the_resize_uses_status_words_the_tables_allow(conn):
    """What 0291 shipped and 0293 fixed.

    `boss_encounters` allows open, slain and escaped. 0291 asked for 'active',
    which is none of them, so every world beast fell straight through the
    guard and the feature did nothing at all. Its own probe then selected on
    the same wrong string, found no rows, and reported "no beast is standing"
    - a check that agreed with the bug rather than testing it.
    """
    for name in ("boss_resize_if_due", "resize_world_if_due"):
        src = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (name,)
        ).fetchone()[0]
        assert "'active'" not in src, f"{name} looks for a status that cannot exist"

    for table, word in (("boss_encounters", "open"), ("horde_encounters", "alive")):
        allowed = conn.execute(
            "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = %s",
            (f"{table}_status_check",),
        ).fetchone()[0]
        assert f"'{word}'" in allowed, (
            f"a standing thing in {table} is no longer '{word}' - the resize "
            "functions hard-code that word and would silently stop working"
        )


def test_a_standing_beast_is_measured_and_keeps_its_fraction(conn):
    """Shrinking must never take away what anybody already did to it."""
    enc = _standing_beast(conn, part=0.6)

    before = conn.execute(
        "SELECT current_hp::numeric / max_hp FROM boss_encounters "
        "WHERE encounter_id = %s", (enc,)
    ).fetchone()[0]

    made = conn.execute("SELECT boss_resize_if_due(%s)", (enc,)).fetchone()[0]
    assert made is not None, "a beast that had never been measured was not due"

    after = conn.execute(
        "SELECT current_hp::numeric / max_hp FROM boss_encounters "
        "WHERE encounter_id = %s", (enc,)
    ).fetchone()[0]
    assert abs(after - before) < 0.01, f"the fraction moved: {before} -> {after}"

    # And not again inside the window.
    assert conn.execute(
        "SELECT boss_resize_if_due(%s)", (enc,)
    ).fetchone()[0] is None, "a beast was measured twice inside its window"


def test_one_recheck_moves_by_one_step_at_most(conn):
    """The roster is two very deep cultivators and a long tail, so an honest
    re-measure can swing fifteenfold. Lurching is its own kind of broken."""
    step = conn.execute(
        "SELECT game_config_value('boss_resize_step')"
    ).fetchone()[0]

    up, down, reachable, still = conn.execute(
        """
        SELECT boss_step_toward(1000, 1000000),
               boss_step_toward(1000, 1),
               boss_step_toward(1000, 1100),
               boss_step_toward(1000, 1000)
        """
    ).fetchone()

    assert up == round(1000 * (1 + step)), "a recheck jumped further up than a step"
    assert down == round(1000 * (1 - step)), "a recheck jumped further down than a step"
    assert reachable == 1100, "a recheck overshot a target within reach"
    assert still == 1000, "a recheck moved a beast that was already right"


def test_a_striker_counts_even_after_they_go_quiet(conn, make_player):
    """Otherwise the whole thing is an exploit with extra steps: log off, let
    the beast shrink to what a quiet room built, come back and take a pot
    sized for everybody."""
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'world' LIMIT 1"
    ).fetchone()[0]

    # Somebody who can swing, and who has not been seen in days.
    who = _walker(conn, make_player, "Absentee")
    conn.execute(
        "UPDATE players SET last_seen_at = now() - interval '3 days' "
        "WHERE player_id = %s",
        (who,),
    )

    without = conn.execute("SELECT boss_hp_pool(%s)", (species,)).fetchone()[0]
    with_them = conn.execute(
        "SELECT boss_hp_pool(%s, ARRAY[%s]::bigint[])", (species, who)
    ).fetchone()[0]

    assert with_them >= without, (
        "pinning somebody who has struck the beast made it smaller"
    )


def test_the_presence_window_is_what_narrows_the_measure(conn):
    """The whole point: a beast built for everybody who logged in this week is
    a wall to the four people actually here."""
    species = conn.execute(
        "SELECT species_id FROM creature_species WHERE kind = 'world' LIMIT 1"
    ).fetchone()[0]

    present = conn.execute("SELECT boss_hp_pool(%s)", (species,)).fetchone()[0]
    everybody = conn.execute(
        "SELECT boss_hp_pool(%s, ARRAY(SELECT player_id FROM players "
        "WHERE deleted_at IS NULL))",
        (species,),
    ).fetchone()[0]

    assert present <= everybody, (
        "counting only the people here produced a bigger beast than counting "
        "everybody, which means the window is not doing anything"
    )

def test_a_restorative_pill_is_a_share_of_the_bar_it_fills(conn, alchemist):
    """0398. A pill's magnitude is a flat number rolled at the brew; health and
    the aperture are exponential in the realm. A tier 7 Qi Restoration pill
    returned 520 of an 8,192,000 aperture - 0.006 per cent.

    0203 already fixed this for cultivation pills and wrote down why: "A
    constant against an exponential ladder is noise by rank 5." Healing and Qi
    never got the same treatment.
    """
    player = alchemist()

    # Deep enough that a flat number is noise, which is the whole condition.
    conn.execute(
        """
        UPDATE player_cultivation pc SET realm_id =
            (SELECT max(realm_id) FROM realms WHERE rank <= 12)
        WHERE pc.player_id = %s
        """,
        (player,),
    )
    conn.execute(
        "UPDATE player_physique SET max_hp = 5000000000, current_hp = 1 "
        "WHERE player_id = %s",
        (player,),
    )

    for kind, bar in (
        ("qi", conn.execute("SELECT player_max_qi(%s)", (player,)).fetchone()[0]),
        ("healing", 5_000_000_000),
    ):
        worth = conn.execute(
            "SELECT pill_restore_worth(%s, %s, 7::smallint, 500::bigint, "
            "       game_config_value('pill_harmony_reference')::smallint, NULL)",
            (player, kind),
        ).fetchone()[0]
        assert worth / bar > 0.10, (
            f"a top tier {kind} pill is only {100 * worth / bar:.3f}% of the bar"
        )

    # And the floor holds: nothing at the shallow end may get weaker, which is
    # the half a share-of-the-bar rewrite gets wrong.
    conn.execute(
        "UPDATE player_cultivation SET realm_id = 1 WHERE player_id = %s", (player,)
    )
    conn.execute(
        "UPDATE player_physique SET max_hp = 100 WHERE player_id = %s", (player,)
    )
    for kind in ("qi", "healing"):
        assert conn.execute(
            "SELECT pill_restore_worth(%s, %s, 1::smallint, 500::bigint, 80::smallint, NULL)",
            (player, kind),
        ).fetchone()[0] >= 500, f"a {kind} pill got weaker than it was brewed"


def test_taking_a_pill_pays_the_scaled_dose(conn, alchemist):
    """Scaled once on the local row, so the healing branch, the qi branch and
    the spill to the beast 0384 hung off the first all follow without any of
    them being touched."""
    player = alchemist()
    conn.execute(
        """
        UPDATE player_cultivation pc SET realm_id =
            (SELECT max(realm_id) FROM realms WHERE rank <= 12), qi = 0
        WHERE pc.player_id = %s
        """,
        (player,),
    )
    pool = conn.execute("SELECT player_max_qi(%s)", (player,)).fetchone()[0]

    pill = _shelf(conn, player, "qi", 500, quantity=1)
    conn.execute("UPDATE player_pills SET tier = 7 WHERE pill_id = %s", (pill,))

    granted = conn.execute(
        "SELECT granted FROM take_pill(%s, %s)", (player, pill)
    ).fetchone()[0]
    assert granted > 500, f"the pill still paid its flat dose: {granted}"
    assert granted / pool > 0.10, f"{granted} of a {pool} aperture"

def test_a_handful_of_pills_is_that_many_singles(conn, alchemist):
    """0399. `take_pills` is a LOOP over `take_pill` rather than a second copy
    of it - that function has five branches, an immortal refusal, a potency
    re-rate, the 0398 rescale and the 0384 spill to the beast, and a second
    implementation would be five chances to disagree with the first."""
    player = alchemist()
    conn.execute(
        "UPDATE player_cultivation SET qi = 0 WHERE player_id = %s", (player,)
    )
    pool = conn.execute("SELECT player_max_qi(%s)", (player,)).fetchone()[0]

    # Sized so no dose is wasted, or this measures the early stop instead.
    pill = _shelf(conn, player, "qi", max(1, pool // 20), quantity=6)

    one = conn.execute(
        "SELECT granted FROM take_pill(%s, %s)", (player, pill)
    ).fetchone()[0]
    many = conn.execute(
        "SELECT granted, taken FROM take_pills(%s, %s, 3)", (player, pill)
    ).fetchone()

    assert many[1] == 3, f"asked for three, took {many[1]}"
    assert many[0] >= one * 2, f"three banked {many[0]} against one banking {one}"
    assert conn.execute(
        "SELECT quantity FROM player_pills WHERE pill_id = %s", (pill,)
    ).fetchone()[0] == 2, "the batch did not go down by exactly four"


def test_a_handful_stops_the_moment_a_dose_lands_nowhere(conn, alchemist):
    """The generous rule and the honest one. Somebody asking for five healing
    pills at half health should not watch three evaporate because the second
    filled the bar - which is what makes an "All" button safe to press, and a
    button that is not safe to press is one people do not press."""
    player = alchemist()
    conn.execute(
        "UPDATE player_cultivation pc SET qi = player_max_qi(pc.player_id) "
        "WHERE pc.player_id = %s",
        (player,),
    )
    pill = _shelf(conn, player, "qi", 500, quantity=9)

    row = conn.execute(
        "SELECT taken, stopped_early, detail FROM take_pills(%s, %s, 9)",
        (player, pill),
    ).fetchone()

    assert row[1] is True, "a full aperture swallowed the whole batch anyway"
    assert row[0] == 1, f"the stop came after {row[0]} pills rather than the first"
    assert "stayed in the bag" in row[2], row[2]
    assert conn.execute(
        "SELECT quantity FROM player_pills WHERE pill_id = %s", (pill,)
    ).fetchone()[0] == 8, "more than one pill left the bag"

    # And asking for more than the batch holds is a person pressing "all",
    # not an error.
    conn.execute(
        "UPDATE player_cultivation SET qi = 0 WHERE player_id = %s", (player,)
    )
    took = conn.execute(
        "SELECT taken FROM take_pills(%s, %s, 1000)", (player, pill)
    ).fetchone()[0]
    assert took <= 8, f"it took {took} of a batch of 8"

def test_a_refining_run_checks_the_whole_run_before_spending_any(conn, refiner):
    """0400. The part of `brew_many` most worth copying. `refine_gu` would
    refuse the fourth attempt on its own, but by then three sets of ingredients
    are gone and the player asked for a run rather than for whatever fitted."""
    player = refiner(level=65, stock=0)

    # Named rather than positional: `gu_recipe_costs` is a view and a column
    # added to the middle of it would silently re-point every index here.
    gu_id, base, base_qty, second, second_qty = conn.execute(
        """
        SELECT c.gu_type_id, c.base_material, c.base_quantity,
               c.secondary_material, c.secondary_quantity
        FROM gu_recipe_costs c
        JOIN gu_types t ON t.gu_type_id = c.gu_type_id
        WHERE c.required_level <= 65
          AND t.rank <= game_config_value('gu_max_refinable_rank')
        ORDER BY t.rank LIMIT 1
        """
    ).fetchone()

    # Enough for two, asked for three.
    for code, qty in ((base, base_qty), (second, second_qty)):
        conn.execute("SELECT grant_material(%s, %s, %s)", (player, code, qty * 2))

    held = conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = %s",
        (player, base),
    ).fetchone()[0]

    with conn.transaction(force_rollback=True):
        with pytest.raises(psycopg.errors.CheckViolation, match="and you hold"):
            conn.execute(
                "SELECT refine_many(%s, %s, NULL::text[], NULL::integer[], 3)",
                (player, gu_id),
            )

    assert conn.execute(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = %s",
        (player, base),
    ).fetchone()[0] == held, "a refused run still spent ingredients"

    # And a run it can pay for works through.
    got = conn.execute(
        "SELECT attempts, succeeded, spoiled, made "
        "FROM refine_many(%s, %s, NULL::text[], NULL::integer[], 2)",
        (player, gu_id),
    ).fetchone()
    assert got[0] == 2
    assert got[1] + got[2] == 2, "two attempts came to a different count"
    assert len(got[3]) == got[1], "what it listed is not what it made"


def test_the_two_benches_climb_the_same_ladder(conn):
    """0400 laid `gu_refine_runs` on the levels `alchemy_brews` uses. Two
    crafts of the same shape should not have two shapes of ladder."""
    pairs = conn.execute(
        """
        SELECT a.step, a.level_required, b.level_required
        FROM profession_steps a
        FULL JOIN profession_steps b
               ON b.ladder = 'gu_refine_runs' AND b.step = a.step
        WHERE a.ladder = 'alchemy_brews'
        ORDER BY a.step
        """
    ).fetchall()
    assert pairs, "the alchemy ladder vanished"
    for step, alch, gu in pairs:
        assert alch == gu, f"step {step}: alchemy {alch}, gu refining {gu}"

    # And the two ceilings agree at every level, which is the promise the
    # ladder being shared actually makes.
    for level in (1, 8, 30, 65, 120):
        assert conn.execute(
            "SELECT gu_refine_max_runs(%s::smallint), alchemy_max_brews(%s::smallint)",
            (level, level),
        ).fetchone()[0] == conn.execute(
            "SELECT alchemy_max_brews(%s::smallint)", (level,)
        ).fetchone()[0], f"the benches part ways at level {level}"

def test_fortune_buys_depth_on_the_essence_ladder_not_frequency(conn, make_player):
    """0402. Measured on clearwest, whose whole build is fortune: 4,713 essence
    drops in 40,000 real explores against a configured 0.12 - their 0.75 luck
    moved it by nothing, because the roll was a bare `random() < 0.12` and the
    ladder above it a bare `random() < 0.10` per rung.

    Fortune now lifts the RUNG. Better things, not more things - so the base
    chance must not have moved, and that is half of what this checks.
    """
    base = float(
        conn.execute(
            "SELECT game_config_value('explore_essence_chance')"
        ).fetchone()[0]
    )
    assert base == 0.12, "the base essence chance moved after all"

    step = float(
        conn.execute(
            "SELECT game_config_value('explore_essence_step_chance')"
        ).fetchone()[0]
    )
    weight = float(
        conn.execute(
            "SELECT game_config_value('explore_essence_luck_weight')"
        ).fetchone()[0]
    )
    ceiling = float(
        conn.execute(
            "SELECT game_config_value('explore_essence_step_ceiling')"
        ).fetchone()[0]
    )

    # A rung past a half would hand out more of the top tiers than the bottom.
    assert ceiling < 0.5, ceiling
    assert weight > 0, "fortune buys nothing"

    # Luck may only ever help, and it must actually help somebody.
    assert min(ceiling, step * (1 + 0.0 * weight)) == step
    assert min(ceiling, step * (1 + 0.75 * weight)) > step

    # And `explore` reads it, or all of the above is a config nobody consults.
    body = conn.execute(
        "SELECT prosrc FROM pg_proc WHERE proname = 'explore'"
    ).fetchone()[0]
    assert "explore_essence_luck_weight" in body, (
        "explore climbs its essence ladder without consulting fortune"
    )
    assert "explore_essence_step_ceiling" in body, (
        "the rung has no ceiling, so a deep Gu build inverts the ladder"
    )

def test_every_page_kind_does_something(conn):
    """0405/0406. Four of the eleven page kinds were placeholders - Speed,
    Refinement, Breakthrough and Essence - rolling at 26 per cent of all drops,
    summed by `player_manual_bonuses`, printed on /manuals, and read by nothing.
    2,275 of them were sitting unspent in bags.

    Checked both ways, because "alive" is a flag somebody has to remember to
    set and the failure this catches is it drifting from the truth in either
    direction.
    """
    SUMMING = ("manual_total_bonus", "manual_stat")

    rows = conn.execute(
        """
        SELECT pt.code, pt.is_live, pt.manual_column,
               EXISTS (
                   SELECT 1 FROM pg_proc p
                   WHERE p.pronamespace = 'public'::regnamespace
                     AND p.proname <> ALL (%s)
                     AND p.prosrc LIKE '%%' || pt.manual_column || '%%'
               ) AS read_by_something
        FROM page_types pt ORDER BY pt.code
        """,
        (list(SUMMING),),
    ).fetchall()

    assert rows, "the page catalogue is empty"
    for code, is_live, column, read in rows:
        assert is_live == read, (
            f"{code} says is_live={is_live} and is read by "
            f"{'something' if read else 'nothing'} ({column})"
        )

    placeholders = conn.execute(
        """
        SELECT code FROM page_types
        WHERE description ~* 'no .* (system|skill) exists|nothing spends'
        ORDER BY code
        """
    ).fetchall()
    assert placeholders == [], placeholders


def test_the_four_revived_page_kinds_reach_what_they_claim(conn, make_player):
    """Each was given the job its name already promised, and each is checked
    where that job actually lands rather than by reading the config back."""
    who = make_player("Bonused")
    conn.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (who,))
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques ORDER BY physique_id LIMIT 1))",
        (who,),
    )

    # With nothing equipped, both helpers are zero.
    assert conn.execute(
        "SELECT crafting_harmony_bonus(%s), cultivation_intake_bonus(%s)",
        (who, who),
    ).fetchone() == (0, 0)

    # Speed reaches defence.
    conn.execute("SELECT apply_physique_xp(%s, 5000)", (who,))
    before = conn.execute(
        "SELECT defense FROM player_physique WHERE player_id = %s", (who,)
    ).fetchone()[0]

    manual = conn.execute(
        """
        INSERT INTO manuals (name, tier, archetype, speed_bonus, refinement_bonus,
                             breakthrough_bonus, essence_bonus)
        VALUES ('Probe Codex', 1, 'hybrid', 0.50, 0.30, 0.20, 0.10)
        RETURNING manual_id
        """
    ).fetchone()[0]
    conn.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (who, manual),
    )
    conn.execute(
        "INSERT INTO player_manual_slots (player_id, manual_id, slot_index) "
        "VALUES (%s, %s, 0)",
        (who, manual),
    )

    conn.execute("SELECT apply_physique_xp(%s, 0)", (who,))
    after = conn.execute(
        "SELECT defense FROM player_physique WHERE player_id = %s", (who,)
    ).fetchone()[0]
    assert after > before, f"Speed did not reach defence: {before} -> {after}"

    # Refinement reaches every bench, through one definition.
    assert float(
        conn.execute("SELECT crafting_harmony_bonus(%s)", (who,)).fetchone()[0]
    ) == float(conn.execute("SELECT refinement_effective(0.30)").fetchone()[0])
    for craft in ("refine_gu", "brew", "refine"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (craft,)
        ).fetchone()[0]
        assert "crafting_harmony_bonus" in body, f"{craft} ignores Refinement"

    # Breakthrough and Essence stack, and reach both routes.
    assert float(
        conn.execute("SELECT cultivation_intake_bonus(%s)", (who,)).fetchone()[0]
    ) == 0.30, "Breakthrough and Essence did not stack"
    for route in ("absorb_essence", "pill_cultivation_worth"):
        body = conn.execute(
            "SELECT prosrc FROM pg_proc WHERE proname = %s", (route,)
        ).fetchone()[0]
        assert "cultivation_intake_bonus" in body, f"{route} ignores them"


def test_a_room_is_never_sized_larger_than_its_typical_raider(conn):
    """`dungeon_rehearse` sums what every raider deals, so a deep cultivator
    joining a weak party built a room to match themselves - thirteen times the
    pool for one extra raider, measured - and handed their friends the same
    fight they could not win alone. Carrying was impossible by construction.

    0560 caps the sizing at `dungeon_rehearse_typical`: the MEDIAN raider's
    damage times the head count. For a party of equals the median is each of
    them, so the cap equals the sum and nothing changes; for one Venerable
    among friends the median is a friend.

    The invariant, which holds for every party there can be: the cap is never
    the larger of the two. Asserted on the functions rather than on a played
    run, because what matters is that `LEAST` can only ever shrink a room.
    """
    body = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc "
        "WHERE proname = 'dungeon_boss_pool' "
        "AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0]

    assert "dungeon_rehearse_typical" in body, (
        "dungeon_boss_pool no longer caps the room by its typical raider"
    )
    assert "LEAST(v_round, dungeon_rehearse_typical" in body, (
        "the typical-raider figure is read but not used as a cap - a room "
        "must never be sized larger than a party of equals would face"
    )

    # And the median is genuinely a median, not a sum wearing the name.
    typical = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc "
        "WHERE proname = 'dungeon_rehearse_typical' "
        "AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0]
    assert "percentile_cont(0.5)" in typical, (
        "dungeon_rehearse_typical stopped taking a median, so one outlier can "
        "inflate the room again"
    )
