"""Tests for the battle engine's state tables (migration 0007)."""

import psycopg
import pytest


def make_battle(conn, kind="pve"):
    return conn.execute(
        "INSERT INTO battles (kind, rng_seed) VALUES (%s, 12345) RETURNING battle_id",
        (kind,),
    ).fetchone()[0]


def add_player_combatant(conn, battle_id, combatant_no, player_id, *, side=0, hp=1000):
    conn.execute(
        """
        INSERT INTO battle_combatants
            (battle_id, combatant_no, side, player_id, snapshot, max_hp, current_hp)
        VALUES (%s, %s, %s, %s, '{}'::jsonb, %s, %s)
        """,
        (battle_id, combatant_no, side, player_id, hp, hp),
    )


def add_creature_combatant(conn, battle_id, combatant_no, species_id, *, side=1, hp=1000):
    conn.execute(
        """
        INSERT INTO battle_combatants
            (battle_id, combatant_no, side, species_id, snapshot, max_hp, current_hp)
        VALUES (%s, %s, %s, %s, '{}'::jsonb, %s, %s)
        """,
        (battle_id, combatant_no, side, species_id, hp, hp),
    )


# ---------------------------------------------------------------------------
# Battles and combatants
# ---------------------------------------------------------------------------

def test_combatant_is_a_player_or_a_creature_never_both(conn, make_player, make_species):
    battle_id = make_battle(conn)
    player_id = make_player()
    species_id = make_species("both_beast")

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """
            INSERT INTO battle_combatants
                (battle_id, combatant_no, side, player_id, species_id, snapshot, max_hp, current_hp)
            VALUES (%s, 0, 0, %s, %s, '{}'::jsonb, 100, 100)
            """,
            (battle_id, player_id, species_id),
        )


def test_combatant_must_be_someone(conn):
    battle_id = make_battle(conn)
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            """
            INSERT INTO battle_combatants
                (battle_id, combatant_no, side, snapshot, max_hp, current_hp)
            VALUES (%s, 0, 0, '{}'::jsonb, 100, 100)
            """,
            (battle_id,),
        )


def test_same_player_cannot_enter_a_battle_twice(conn, make_player):
    battle_id = make_battle(conn, kind="duel")
    player_id = make_player()
    add_player_combatant(conn, battle_id, 0, player_id, side=0)

    with pytest.raises(psycopg.errors.UniqueViolation):
        add_player_combatant(conn, battle_id, 1, player_id, side=1)


def test_active_battle_cannot_carry_an_end_time(conn):
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO battles (kind, rng_seed, status, ended_at) "
            "VALUES ('pve', 1, 'active', now())"
        )


def test_finished_battle_requires_an_end_time(conn):
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO battles (kind, rng_seed, status) VALUES ('pve', 1, 'complete')"
        )


def test_winner_requires_a_finished_battle(conn):
    battle_id = make_battle(conn)
    # Savepoint via conn.transaction(), so the expected failure aborts only the
    # inner block and the connection stays usable for the follow-up.
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute(
                "UPDATE battles SET winner_side = 0 WHERE battle_id = %s", (battle_id,)
            )
    # Ending it properly is fine.
    conn.execute(
        "UPDATE battles SET status = 'complete', ended_at = now(), winner_side = 0 "
        "WHERE battle_id = %s",
        (battle_id,),
    )


def test_combatant_hp_stays_within_its_cap(conn, make_player):
    battle_id = make_battle(conn)
    player_id = make_player()
    add_player_combatant(conn, battle_id, 0, player_id, hp=500)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "UPDATE battle_combatants SET current_hp = 501 "
            "WHERE battle_id = %s AND combatant_no = 0",
            (battle_id,),
        )


def test_battle_history_blocks_player_deletion(conn, make_player):
    """Like the audit log: history involving other people survives the account."""
    battle_id = make_battle(conn)
    player_id = make_player()
    add_player_combatant(conn, battle_id, 0, player_id)

    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        conn.execute("DELETE FROM players WHERE player_id = %s", (player_id,))


# ---------------------------------------------------------------------------
# One fight at a time
# ---------------------------------------------------------------------------

def test_player_cannot_claim_two_active_battles(conn, make_player):
    player_id = make_player()
    first = make_battle(conn)
    second = make_battle(conn, kind="duel")
    conn.execute(
        "INSERT INTO player_active_battle (player_id, battle_id) VALUES (%s, %s)",
        (player_id, first),
    )

    with pytest.raises(psycopg.errors.UniqueViolation):
        conn.execute(
            "INSERT INTO player_active_battle (player_id, battle_id) VALUES (%s, %s)",
            (player_id, second),
        )


def test_deleting_the_battle_releases_the_claim(conn, make_player):
    player_id = make_player()
    battle_id = make_battle(conn)
    conn.execute(
        "INSERT INTO player_active_battle (player_id, battle_id) VALUES (%s, %s)",
        (player_id, battle_id),
    )

    conn.execute("DELETE FROM battles WHERE battle_id = %s", (battle_id,))

    remaining = conn.execute(
        "SELECT count(*) FROM player_active_battle WHERE player_id = %s", (player_id,)
    ).fetchone()[0]
    assert remaining == 0


# ---------------------------------------------------------------------------
# The action log
# ---------------------------------------------------------------------------

def test_action_actor_must_be_in_the_battle(conn, make_player):
    battle_id = make_battle(conn)
    player_id = make_player()
    add_player_combatant(conn, battle_id, 0, player_id)

    with pytest.raises(psycopg.errors.ForeignKeyViolation):
        conn.execute(
            "INSERT INTO battle_actions (battle_id, actor_no, turn_number, action) "
            "VALUES (%s, 5, 1, 'pass')",  # combatant 5 does not exist
            (battle_id,),
        )


def test_technique_action_must_be_named(conn, make_player):
    battle_id = make_battle(conn)
    player_id = make_player()
    add_player_combatant(conn, battle_id, 0, player_id)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "INSERT INTO battle_actions (battle_id, actor_no, turn_number, action) "
            "VALUES (%s, 0, 1, 'technique')",
            (battle_id,),
        )


def test_log_survives_deletion_of_a_generated_technique(conn, make_player, make_species, make_technique):
    """A player-created killer move can vanish; the log keeps name and numbers."""
    battle_id = make_battle(conn)
    player_id = make_player()
    species_id = make_species("log_target")
    add_player_combatant(conn, battle_id, 0, player_id)
    add_creature_combatant(conn, battle_id, 1, species_id)

    technique_id = make_technique(None, name="Crimson Rend", created_by=player_id)
    conn.execute(
        """
        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, technique_id, technique_name,
             target_no, base_power, attainment_bonus, matchup_modifier, damage)
        VALUES (%s, 0, 1, 'technique', %s, 'Crimson Rend', 1, 100, 0.20, 0.25, 150)
        """,
        (battle_id, technique_id),
    )

    conn.execute("DELETE FROM techniques WHERE technique_id = %s", (technique_id,))

    row = conn.execute(
        "SELECT technique_id, technique_name, damage FROM battle_actions "
        "WHERE battle_id = %s",
        (battle_id,),
    ).fetchone()
    assert row == (None, "Crimson Rend", 150)


# ---------------------------------------------------------------------------
# World bosses
# ---------------------------------------------------------------------------

def spawn_boss(conn, species_id, *, hp=1_000_000):
    return conn.execute(
        """
        INSERT INTO world_boss_instances (species_id, max_hp, current_hp, expires_at)
        VALUES (%s, %s, %s, now() + interval '3 days')
        RETURNING instance_id
        """,
        (species_id, hp, hp),
    ).fetchone()[0]


def test_one_living_instance_per_species(conn, make_species):
    species_id = make_species("wb_unique", base_hp=1_000_000)
    spawn_boss(conn, species_id)

    with pytest.raises(psycopg.errors.UniqueViolation):
        spawn_boss(conn, species_id)


def test_a_dead_boss_frees_the_slot_for_a_respawn(conn, make_species):
    species_id = make_species("wb_respawn", base_hp=1_000_000)
    first = spawn_boss(conn, species_id)
    conn.execute(
        "UPDATE world_boss_instances "
        "SET status = 'defeated', current_hp = 0, ended_at = now() "
        "WHERE instance_id = %s",
        (first,),
    )

    spawn_boss(conn, species_id)  # must not raise


def test_boss_cannot_be_defeated_with_hp_remaining(conn, make_species):
    species_id = make_species("wb_hp_check", base_hp=1_000_000)
    instance_id = spawn_boss(conn, species_id)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "UPDATE world_boss_instances SET status = 'defeated', ended_at = now() "
            "WHERE instance_id = %s",
            (instance_id,),
        )


def test_contribution_upsert_accumulates(conn, make_player, make_species):
    """The write pattern every boss attack uses: one upsert per hit."""
    player_id = make_player()
    species_id = make_species("wb_tally", base_hp=1_000_000)
    instance_id = spawn_boss(conn, species_id)

    for hit in (4_000, 6_000, 5_000):
        conn.execute(
            """
            INSERT INTO world_boss_contributions
                (instance_id, player_id, damage_dealt, attacks, highest_hit)
            VALUES (%s, %s, %s, 1, %s)
            ON CONFLICT (instance_id, player_id) DO UPDATE SET
                damage_dealt   = world_boss_contributions.damage_dealt + EXCLUDED.damage_dealt,
                attacks        = world_boss_contributions.attacks + 1,
                highest_hit    = GREATEST(world_boss_contributions.highest_hit, EXCLUDED.highest_hit),
                last_attack_at = now()
            """,
            (instance_id, player_id, hit, hit),
        )

    total, attacks, highest = conn.execute(
        "SELECT damage_dealt, attacks, highest_hit FROM world_boss_contributions "
        "WHERE instance_id = %s AND player_id = %s",
        (instance_id, player_id),
    ).fetchone()
    assert (total, attacks, highest) == (15_000, 3, 6_000)


# ---------------------------------------------------------------------------
# End to end: the spec's combat loop (section 13)
# ---------------------------------------------------------------------------

def test_full_combat_loop(conn, make_player, make_technique, make_species):
    """Identify -> discover weakness -> choose technique -> attainment ->
    matchup -> final damage, with every write the real flow would make."""
    # A cultivator with Grandmaster Blood, carrying a Blood technique.
    player_id = make_player("Loop Fighter")
    conn.execute(
        "INSERT INTO player_path_attainment (player_id, path_code, insight, tier) "
        "VALUES (%s, 'blood', 50000, 6)",
        (player_id,),
    )
    technique_id = make_technique("loop_blood_blade", paths={"blood": "1.0"}, base_power=10_000)
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s)",
        (player_id, technique_id),
    )
    conn.execute(
        "INSERT INTO player_loadout (player_id, slot_index, technique_id) VALUES (%s, 0, %s)",
        (player_id, technique_id),
    )

    # Identify: a Strength-path beast (vulnerable to Blood, per the chart).
    species_id = make_species("loop_wolf", name="Nine Distortion Wolf", paths=["strength"], base_hp=20_000)

    # Enter battle.
    battle_id = make_battle(conn)
    add_player_combatant(conn, battle_id, 0, player_id, hp=5_000)
    add_creature_combatant(conn, battle_id, 1, species_id, hp=20_000)
    conn.execute(
        "INSERT INTO player_active_battle (player_id, battle_id) VALUES (%s, %s)",
        (player_id, battle_id),
    )

    # Resolve the hit through the pipeline.
    base, attainment, matchup, _, final = conn.execute(
        "SELECT base_power, attainment_bonus, matchup_modifier, "
        "       pre_defense, final_damage "
        "FROM compute_technique_damage(%s, %s, %s)",
        (player_id, technique_id, species_id),
    ).fetchone()
    assert final == 15_000  # 10,000 * 1.20 * 1.25

    # Apply it, log it, and record the discovery - one transaction in the app.
    conn.execute(
        "UPDATE battle_combatants SET current_hp = GREATEST(0, current_hp - %s) "
        "WHERE battle_id = %s AND combatant_no = 1",
        (final, battle_id),
    )
    conn.execute(
        """
        INSERT INTO battle_actions
            (battle_id, actor_no, turn_number, action, technique_id, technique_name,
             target_no, base_power, attainment_bonus, matchup_modifier, damage,
             discovered_path)
        VALUES (%s, 0, 1, 'technique', %s, 'Loop Blood Blade', 1, %s, %s, %s, %s, 'blood')
        """,
        (battle_id, technique_id, base, attainment, matchup, final),
    )
    conn.execute(
        "INSERT INTO player_bestiary (player_id, species_id, times_encountered) "
        "VALUES (%s, %s, 1)",
        (player_id, species_id),
    )
    conn.execute(
        "INSERT INTO player_bestiary_paths (player_id, species_id, path_code, discovered_via) "
        "VALUES (%s, %s, 'blood', 'combat')",
        (player_id, species_id),
    )

    # The beast took the hit.
    remaining = conn.execute(
        "SELECT current_hp FROM battle_combatants WHERE battle_id = %s AND combatant_no = 1",
        (battle_id,),
    ).fetchone()[0]
    assert remaining == 5_000

    # The bestiary now shows the discovered weakness, read live from the truth.
    known = conn.execute(
        """
        SELECT ci.interaction
        FROM player_bestiary_paths pbp
        JOIN creature_incoming_paths ci
          ON ci.species_id = pbp.species_id AND ci.path_code = pbp.path_code
        WHERE pbp.player_id = %s AND pbp.species_id = %s
        """,
        (player_id, species_id),
    ).fetchall()
    assert known == [("advantage",)]

    # "Unknown Traits: N" - the count difference, not a stored number.
    unknown = conn.execute(
        """
        SELECT count(*)
        FROM creature_incoming_paths ci
        WHERE ci.species_id = %s
          AND NOT EXISTS (
              SELECT 1 FROM player_bestiary_paths pbp
              WHERE pbp.player_id = %s
                AND pbp.species_id = ci.species_id
                AND pbp.path_code = ci.path_code
          )
        """,
        (species_id, player_id),
    ).fetchone()[0]
    # Strength has 7 chart entries against it; blood is known, 6 remain.
    # 7 since 0018: `wind -> strength: resistance` gives every Strength
    # creature one more thing to learn. This number tracks the chart on
    # purpose - it is how an unintended chart change gets noticed.
    assert unknown == 7

    # End the battle and release the claim.
    conn.execute(
        "UPDATE battles SET status = 'complete', ended_at = now(), winner_side = 0 "
        "WHERE battle_id = %s",
        (battle_id,),
    )
    conn.execute("DELETE FROM player_active_battle WHERE player_id = %s", (player_id,))


def test_battle_open_measures_the_creature_exactly_once(conn):
    """`battle_open` used to ask `creature_body_for` twice.

    That function is VOLATILE by design - it rehearses a real `player_swing`
    against the species to size the creature to what this cultivator actually
    deals per round, so it rolls crits and extra strikes. Two calls were two
    different numbers, one landing in `max_hp` and one in `current_hp`, and
    whenever the second came out larger `battle_combatants_hp_within_cap`
    rejected the row and the fight refused to start. Measured against a live
    rank 17 cultivator: ten of twelve pairs differed, five of twelve failed -
    about two fights in five, at random.

    Worse, the cog reported it as "You have nothing left to fight with",
    because a CHECK constraint failure is `check_violation` too. Players at
    full health were told they had no health. 0554 measures once.

    THIS COUNTS THE CALL SITES, which is the one assertion that cannot go
    vacuous. The behavioural version below needs a cultivator whose swing
    actually varies, and a fixture player has no crit or multi-hit source at
    all - their `creature_body_for` is flat, so opening a hundred fights with
    one would have proved nothing. That was the first version of this test and
    it passed against the bug.
    """
    src = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc "
        "WHERE proname = 'battle_open' AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0]

    calls = src.count("creature_body_for(")
    assert calls == 1, (
        f"battle_open calls creature_body_for {calls} times - a volatile "
        "function asked twice is two different answers, and the second one "
        "lands in current_hp"
    )


def test_a_creature_opens_at_full_health(conn, make_player, make_species):
    """The invariant the doubled call was breaking.

    Weaker than the call count above - this fixture's cultivator has no
    variance to expose a second measurement - but it is the property players
    actually depend on, and it costs one query.
    """
    who = make_player("Measured")
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id, cultivation) "
        "SELECT %s, r.realm_id, r.cultivation_required FROM realms r "
        "WHERE r.rank = 6 ORDER BY r.realm_id DESC LIMIT 1",
        (who,),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques WHERE code = 'mortal_body'))",
        (who,),
    )
    conn.execute(
        "UPDATE player_physique SET max_hp = 500000, current_hp = 500000, "
        "defense = 2000, strength = 40000 WHERE player_id = %s",
        (who,),
    )

    species = make_species(
        "rogue_who_stops_you", name="A Rogue Who Stops You", base_hp=50_000
    )
    conn.execute(
        "UPDATE creature_species SET kind = 'rogue', rank = 6 WHERE species_id = %s",
        (species,),
    )

    battle = conn.execute(
        "SELECT battle_open(%s, %s)", (who, species)
    ).fetchone()[0]

    max_hp, current_hp = conn.execute(
        "SELECT max_hp, current_hp FROM battle_combatants "
        "WHERE battle_id = %s AND combatant_no = 1",
        (battle,),
    ).fetchone()
    assert current_hp == max_hp, (
        f"the creature opened at {current_hp} of {max_hp} health"
    )
