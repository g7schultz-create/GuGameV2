"""Tests that the schema's guarantees are real.

These deliberately assert on things the database is supposed to make
IMPOSSIBLE, not on things the application is supposed to avoid doing. A
constraint nobody has ever seen reject anything is only a comment.
"""

import psycopg
import pytest


# ---------------------------------------------------------------------------
# Reference data
# ---------------------------------------------------------------------------

def test_all_paths_seeded(conn):
    counts = dict(
        conn.execute("SELECT category, count(*) FROM paths GROUP BY category").fetchall()
    )
    assert counts == {"combat": 21, "special": 2, "exotic": 5}


def test_exotic_paths_opt_out_of_matchups(conn):
    """Spec section 12: exotic Paths get value from unique mechanics, not typing."""
    rows = conn.execute(
        "SELECT code FROM paths WHERE category = 'exotic' AND uses_matchups"
    ).fetchall()
    assert rows == []


def test_matchup_chart_is_complete(conn):
    total = conn.execute("SELECT count(*) FROM path_matchups").fetchone()[0]
    assert total == 108

    # Spec section 4: roughly 2-3 favourable and 2-3 unfavourable per Path, so
    # no single type is strictly best. Heaven is the documented exception - its
    # "Weak Against" cell is a note about special counters, not a resistance.
    lopsided = conn.execute(
        """
        SELECT p.code,
               count(*) FILTER (WHERE m.interaction = 'advantage')  AS adv,
               count(*) FILTER (WHERE m.interaction = 'resistance') AS res
        FROM paths p
        JOIN path_matchups m ON m.attacker_path = p.code
        WHERE p.category IN ('combat', 'special')
        GROUP BY p.code
        HAVING count(*) FILTER (WHERE m.interaction = 'advantage') NOT BETWEEN 2 AND 3
            OR count(*) FILTER (WHERE m.interaction = 'resistance') NOT BETWEEN 2 AND 3
        """
    ).fetchall()
    assert [r[0] for r in lopsided] == ["heaven"]


def test_metal_has_no_offensive_matchups(conn):
    """Known gap, asserted so it cannot be fixed silently or forgotten.

    Metal appears only as a DEFENDER in the design chart. When its attacking row
    is decided, this test should fail - that is the point of it.
    """
    attacks = conn.execute(
        "SELECT count(*) FROM path_matchups WHERE attacker_path = 'metal'"
    ).fetchone()[0]
    assert attacks == 0, "Metal now has attacking matchups - update this test and the README gap list"

    defends = conn.execute(
        "SELECT count(*) FROM path_matchups WHERE defender_path = 'metal'"
    ).fetchone()[0]
    assert defends == 3


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
    technique_id = make_technique("blazing_heaven_sword", paths={"sword": "0.7", "fire": "0.3"})
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
    species_id = make_species("nine_distortion_wolf", paths=["wood"])
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
