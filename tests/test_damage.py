"""Tests for the damage pipeline (migration 0008).

Wherever the design doc works an example, the test IS that example - if one of
these fails after a rebalance, the schema has drifted from the design, not just
from an arbitrary expectation.
"""

from decimal import Decimal

import pytest


def set_attainment(conn, player_id, path_code, tier):
    conn.execute(
        "INSERT INTO player_path_attainment (player_id, path_code, insight, tier) "
        "VALUES (%s, %s, 1, %s) "
        "ON CONFLICT (player_id, path_code) DO UPDATE SET tier = EXCLUDED.tier",
        (player_id, path_code, tier),
    )


def damage(conn, player_id, technique_id, species_id, *, external=1, defense=0):
    # Named rather than `*`: every caller here unpacks five stages
    # positionally and 0245 added `body_power` as a sixth. Asking for what
    # is unpacked keeps a new column from being a thirteen-site edit.
    return conn.execute(
        "SELECT base_power, attainment_bonus, matchup_modifier, "
        "       pre_defense, final_damage "
        "FROM compute_technique_damage(%s, %s, %s, %s, %s)",
        (player_id, technique_id, species_id, external, defense),
    ).fetchone()


# ---------------------------------------------------------------------------
# The sum of a technique and a body
# ---------------------------------------------------------------------------


def test_a_deep_swing_does_not_overflow_an_integer(conn, make_player,
                                                    make_technique, make_species):
    """0392. `raw := (tech_base + thews) * ...` had both terms declared INTEGER,
    so the ADDITION overflowed before anything was multiplied.

    It was live: pashu0's own Ascendant Refinement Art came to 1,834,454,352 of
    technique and 934,054,724 of body, and the only reason nobody saw a
    database error mid-fight is that he had not equipped the manual.

    The numbers here are deliberately past INT_MAX on the sum while each term
    is under it, because that is the shape of the bug - clamping one side and
    adding an unclamped one to it.
    """
    player_id = make_player()
    species_id = make_species("plain_beast", paths=["strength"])
    technique_id = make_technique(
        "deep_swing_fixture", paths={"blood": "1.0"}, base_power=2_000_000_000
    )

    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques ORDER BY physique_id LIMIT 1)) "
        "ON CONFLICT (player_id) DO NOTHING",
        (player_id,),
    )
    conn.execute(
        "UPDATE player_physique SET strength = 900000000 WHERE player_id = %s",
        (player_id,),
    )

    row = damage(conn, player_id, technique_id, species_id)
    assert row is not None, "the swing came back with nothing"
    assert row[4] > 0, "a two-billion technique behind a real body did nothing"

    # And the two terms are handed back wide, not truncated on the way out.
    base, body = conn.execute(
        "SELECT base_power, body_power FROM compute_technique_damage(%s, %s, %s, 1, 0)",
        (player_id, technique_id, species_id),
    ).fetchone()
    assert base == 2_000_000_000
    assert body >= 900_000_000


def test_every_column_the_damage_pipeline_writes_is_wide_enough(conn):
    """A number that fits in the function and not in the row it is logged to is
    the same bug one table along. `battle_actions.base_power` is where a duel
    writes what `compute_technique_damage` just handed it."""
    narrow = conn.execute(
        """
        SELECT c.table_name, c.column_name, c.data_type
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND (c.table_name, c.column_name) IN (('battle_actions', 'base_power'))
          AND c.data_type <> 'bigint'
        """
    ).fetchall()
    assert narrow == [], narrow

    returns = conn.execute(
        "SELECT pg_get_function_result(oid) FROM pg_proc "
        "WHERE proname = 'compute_technique_damage'"
    ).fetchone()[0]
    assert "base_power bigint" in returns, returns
    assert "body_power bigint" in returns, returns


def test_the_screens_and_the_swing_read_one_number(conn, make_player,
                                                   make_technique, make_species):
    """0395. `techniques.base_power` is a souvenir of the day a technique was
    made; a forged or fated one stores a GRADE and is recomputed against its
    owner's current realm every swing.

    Five screens printed the souvenir, and it had drifted by up to 128x - the
    technique picker in a fight showed a 28,663,349 move beside a 1,852,204,646
    one when the first was the stronger of the two.

    Both now ask `technique_power_for`, and this is what keeps them one number:
    it compares the function against what the damage pipeline actually used.
    """
    player = make_player()
    species = make_species("power_probe_beast", paths=["strength"])
    # No code: `techniques_canonical_has_code` insists that a technique
    # somebody made has none, and one nobody made has one.
    technique = make_technique(
        None, name="Power Probe", paths={"blood": "1.0"}, base_power=1000,
        created_by=player,
    )
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id) VALUES (%s, 1) "
        "ON CONFLICT (player_id) DO NOTHING",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques ORDER BY physique_id LIMIT 1)) "
        "ON CONFLICT (player_id) DO NOTHING",
        (player,),
    )

    # Unforged: worth exactly what is written on it, which for a canonical
    # technique is the true number and always was.
    assert conn.execute(
        "SELECT technique_power_for(%s, %s)", (player, technique)
    ).fetchone()[0] == 1000

    # Forged: the written figure stops being the answer.
    conn.execute(
        """
        INSERT INTO technique_forges
            (player_id, realm_rank, power_grade, dual, paths, step,
             technique_id, finished_at)
        VALUES (%s, 10, 2.0, FALSE, ARRAY['blood'], 3, %s, now())
        """,
        (player, technique),
    )
    live = conn.execute(
        "SELECT technique_power_for(%s, %s)", (player, technique)
    ).fetchone()[0]
    assert live != 1000, "a forged technique is still worth its souvenir"

    # And the pipeline agrees, which is the invariant - one definition, not two.
    assert conn.execute(
        "SELECT base_power FROM compute_technique_damage(%s, %s, %s, 1, 0)",
        (player, technique, species),
    ).fetchone()[0] == live

    # Climbing a realm moves it, because that is the entire point.
    conn.execute(
        """
        UPDATE player_cultivation SET realm_id =
            (SELECT realm_id FROM realms WHERE rank = 2 ORDER BY realm_id LIMIT 1)
        WHERE player_id = %s
        """,
        (player,),
    )
    assert conn.execute(
        "SELECT technique_power_for(%s, %s)", (player, technique)
    ).fetchone()[0] > live, "a realm crossing did not reach the technique"


def test_no_screen_orders_or_prints_a_stored_technique_power(conn):
    """The souvenir is not a thing a screen may reach for. Five did; a sixth is
    the thing to catch, which is why this reads the source rather than the
    database."""
    import pathlib
    import re

    root = pathlib.Path(__file__).resolve().parent.parent
    offenders = []
    for path in sorted((root / "bot").rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        for n, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("--") or line.lstrip().startswith("#"):
                continue
            # Selecting or ordering by the column. `t.base_power > 0` is a
            # presence test - a technique with no power of its own is not an
            # attack - and says nothing about how strong anything is.
            if re.search(r"\bt\.base_power\b", line) and "base_power > 0" not in line:
                offenders.append(f"{path.relative_to(root)}:{n}: {line.strip()}")
    assert offenders == [], "\n".join(offenders)


# ---------------------------------------------------------------------------
# The spec's own worked examples
# ---------------------------------------------------------------------------

def test_spec_section_3_blood_blade_example(conn, make_player, make_technique, make_species):
    """Rank 6 Blood Blade: 10,000 base, Blood Grandmaster +20%, vulnerable
    target +25% => exactly 15,000."""
    player_id = make_player()
    set_attainment(conn, player_id, "blood", 6)  # Grandmaster
    technique_id = make_technique("blood_blade_fixture", paths={"blood": "1.0"}, base_power=10_000)
    # Blood beats Strength in the chart, so a Strength creature is vulnerable.
    species_id = make_species("strength_beast", paths=["strength"])

    base, attainment, matchup, pre, final = damage(conn, player_id, technique_id, species_id)
    assert base == 10_000
    assert attainment == Decimal("0.2000")
    assert matchup == Decimal("0.2500")
    assert final == 15_000


def test_spec_section_5_average_dual_path(conn, make_player, make_technique, make_species):
    """Sword +20% and Fire +10% on an even split average to +15%."""
    player_id = make_player()
    set_attainment(conn, player_id, "sword", 6)  # Grandmaster, +20%
    set_attainment(conn, player_id, "fire", 4)   # Master, +10%
    technique_id = make_technique(
        "blazing_heaven_sword_even", paths={"sword": "0.5", "fire": "0.5"}, base_power=10_000
    )
    species_id = make_species("neutral_beast", paths=["human"])  # neutral to both

    _, attainment, matchup, _, final = damage(conn, player_id, technique_id, species_id)
    assert attainment == Decimal("0.1500")
    assert matchup == 0
    assert final == 11_500


def test_spec_section_5_weighted_dual_path(conn, make_player, make_technique, make_species):
    """The rare-move variant: 70% Sword / 30% Fire weights the same bonuses to
    (0.20 x 0.7) + (0.10 x 0.3) = +17%."""
    player_id = make_player()
    set_attainment(conn, player_id, "sword", 6)
    set_attainment(conn, player_id, "fire", 4)
    technique_id = make_technique(
        "blazing_heaven_sword_rare", paths={"sword": "0.7", "fire": "0.3"}, base_power=10_000
    )
    species_id = make_species("neutral_beast_2", paths=["human"])

    _, attainment, _, _, final = damage(conn, player_id, technique_id, species_id)
    assert attainment == Decimal("0.1700")
    assert final == 11_700


def test_spec_section_5_dual_weakness_hits_the_cap(conn, make_player, make_technique, make_species):
    """Both advantages apply but the total is capped at +50%.

    Sword and Fire each have +25% into this target; 25 + 25 = 50, exactly the
    cap. Then an override pushes one to major advantage (+50), making the raw
    sum 75 - and the clamp must hold it at 50.
    """
    player_id = make_player()
    technique_id = make_technique(
        "blazing_heaven_sword_cap", paths={"sword": "0.5", "fire": "0.5"}, base_power=10_000
    )
    # Sword beats transformation; fire is neutral to it, so override fire.
    species_id = make_species("doubly_weak", paths=["transformation"])
    conn.execute(
        "INSERT INTO creature_path_modifiers (species_id, path_code, interaction) "
        "VALUES (%s, 'fire', 'advantage')",
        (species_id,),
    )

    _, _, matchup, _, final = damage(conn, player_id, technique_id, species_id)
    assert matchup == Decimal("0.5000")
    assert final == 15_000

    # Push past the cap: fire becomes a major advantage, raw total 75%.
    conn.execute(
        "UPDATE creature_path_modifiers SET interaction = 'major_advantage' "
        "WHERE species_id = %s AND path_code = 'fire'",
        (species_id,),
    )
    _, _, matchup, _, final = damage(conn, player_id, technique_id, species_id)
    assert matchup == Decimal("0.5000"), "cap did not hold"
    assert final == 15_000


def test_spec_section_5_mixed_matchup_partially_cancels(conn, make_player, make_technique, make_species):
    """Weak to Fire (+25%) but resistant to Sword (-20%) nets +5%."""
    player_id = make_player()
    technique_id = make_technique(
        "blazing_heaven_sword_mixed", paths={"sword": "0.5", "fire": "0.5"}, base_power=10_000
    )
    species_id = make_species("mixed_beast", paths=["human"])
    conn.execute(
        "INSERT INTO creature_path_modifiers (species_id, path_code, interaction) VALUES "
        "(%s, 'fire', 'advantage'), (%s, 'sword', 'resistance')",
        (species_id, species_id),
    )

    _, _, matchup, _, final = damage(conn, player_id, technique_id, species_id)
    assert matchup == Decimal("0.0500")
    assert final == 10_500


# ---------------------------------------------------------------------------
# Attainment stage
# ---------------------------------------------------------------------------

def test_uninitiated_player_gets_no_bonus(conn, make_player, make_technique, make_species):
    """Sparse attainment: no row at all must read as tier 0, not as an error."""
    player_id = make_player()
    technique_id = make_technique("plain_strike", paths={"fire": "1.0"}, base_power=1_000)
    species_id = make_species("plain_target", paths=["human"])

    _, attainment, _, _, final = damage(conn, player_id, technique_id, species_id)
    assert attainment == 0
    assert final == 1_000


def test_attainment_follows_the_technique_not_the_player(conn, make_player, make_technique, make_species):
    """Spec section 2: switching techniques switches which attainment applies."""
    player_id = make_player()
    set_attainment(conn, player_id, "blood", 6)     # Grandmaster +20%
    set_attainment(conn, player_id, "strength", 4)  # Master +10%
    blood_move = make_technique("blood_move", paths={"blood": "1.0"}, base_power=1_000)
    strength_move = make_technique("strength_move", paths={"strength": "1.0"}, base_power=1_000)
    # Time is neutral against BOTH blood and strength in the chart. (Human is
    # not - Blood beats Human - which is exactly the kind of thing this system
    # is built to make matter.)
    species_id = make_species("attainment_target", paths=["time"])

    assert damage(conn, player_id, blood_move, species_id)[4] == 1_200
    assert damage(conn, player_id, strength_move, species_id)[4] == 1_100


# ---------------------------------------------------------------------------
# Immunity
# ---------------------------------------------------------------------------

def test_total_immunity_zeroes_the_hit(conn, make_player, make_technique, make_species):
    player_id = make_player()
    set_attainment(conn, player_id, "fire", 10)  # even Supreme Grandmaster
    technique_id = make_technique("fire_vs_immune", paths={"fire": "1.0"}, base_power=99_999)
    species_id = make_species("fire_immune", paths=["human"])
    conn.execute(
        "INSERT INTO creature_path_modifiers (species_id, path_code, interaction) "
        "VALUES (%s, 'fire', 'immunity')",
        (species_id,),
    )

    _, _, matchup, _, final = damage(conn, player_id, technique_id, species_id)
    assert matchup == -1
    assert final == 0


def test_partial_immunity_is_floored_not_zeroed(conn, make_player, make_technique, make_species):
    """One immune component of a dual-Path move feeds -1.0 into the sum, where
    the -50% floor catches it: the un-immune half still lands, weakened."""
    player_id = make_player()
    technique_id = make_technique(
        "half_immune", paths={"fire": "0.5", "sword": "0.5"}, base_power=10_000
    )
    species_id = make_species("half_immune_beast", paths=["human"])
    conn.execute(
        "INSERT INTO creature_path_modifiers (species_id, path_code, interaction) "
        "VALUES (%s, 'fire', 'immunity')",
        (species_id,),
    )

    _, _, matchup, _, final = damage(conn, player_id, technique_id, species_id)
    assert matchup == Decimal("-0.5000")
    assert final == 5_000


# ---------------------------------------------------------------------------
# Later stages
# ---------------------------------------------------------------------------

def test_external_multiplier_hook_applies(conn, make_player, make_technique, make_species):
    """The Dao Marks / equipment / buffs stage, as a passthrough multiplier."""
    player_id = make_player()
    technique_id = make_technique("buffed_strike", paths={"fire": "1.0"}, base_power=1_000)
    species_id = make_species("buff_target", paths=["human"])

    assert damage(conn, player_id, technique_id, species_id, external="1.30")[4] == 1_300


def test_defense_has_diminishing_returns(conn, make_player, make_technique, make_species):
    """Defence divides, it never subtracts - so it can soften a blow without
    ever erasing one.

    The scale moved from 100 to 60 in 0248 so a defence stat soaks about a
    quarter of an equal-rank blow at every rank instead of decaying up the
    ladder, so the shape is asserted against the dial rather than against the
    three numbers it used to produce."""
    player_id = make_player()
    technique_id = make_technique("def_test", paths={"fire": "1.0"}, base_power=10_000)
    species_id = make_species("armored_target", paths=["human"])

    scale = int(
        conn.execute("SELECT game_config_value('defense_scale')").fetchone()[0]
    )

    assert damage(conn, player_id, technique_id, species_id, defense=0)[4] == 10_000
    # Defence equal to the scale is exactly half.
    assert damage(conn, player_id, technique_id, species_id, defense=scale)[4] == 5_000
    # Three times the scale is a quarter.
    assert damage(
        conn, player_id, technique_id, species_id, defense=scale * 3
    )[4] == 2_500
    # Absurd defense still cannot reduce a landed hit below 1 (chip damage).
    assert damage(conn, player_id, technique_id, species_id, defense=10_000_000)[4] == 1


def test_zero_base_power_deals_zero_not_one(conn, make_player, make_technique, make_species):
    """Support techniques must not chip for 1 through the minimum-damage rule."""
    player_id = make_player()
    technique_id = make_technique(
        "support_move", paths={"wisdom": "1.0"}, category="support", base_power=0
    )
    species_id = make_species("support_target", paths=["human"])

    assert damage(conn, player_id, technique_id, species_id)[4] == 0


def test_exotic_path_technique_is_neutral_everywhere(conn, make_player, make_technique, make_species):
    """uses_matchups = false: a Dream technique consults no chart at all."""
    player_id = make_player()
    technique_id = make_technique("dream_strike", paths={"dream": "1.0"}, base_power=1_000)
    # Wood is riddled with chart interactions; none may apply to a Dream move.
    species_id = make_species("chartful_target", paths=["wood"])

    _, _, matchup, _, final = damage(conn, player_id, technique_id, species_id)
    assert matchup == 0
    assert final == 1_000


def test_breakdown_multiplies_through(conn, make_player, make_technique, make_species):
    """Every stage at once, so the stages compose the way the log will claim."""
    player_id = make_player()
    set_attainment(conn, player_id, "blood", 6)  # +20%
    technique_id = make_technique("full_stack", paths={"blood": "1.0"}, base_power=10_000)
    species_id = make_species("full_stack_target", paths=["strength"])  # +25% matchup

    scale = int(
        conn.execute("SELECT game_config_value('defense_scale')").fetchone()[0]
    )
    base, attainment, matchup, pre, final = damage(
        conn, player_id, technique_id, species_id, external="1.10", defense=scale
    )
    # 10,000 * 1.20 * 1.25 * 1.10 = 16,500 pre-defense; defence equal to the
    # scale halves it, whatever the scale currently is.
    assert pre == Decimal("16500.0000000000")
    assert final == 8_250

def test_nothing_in_the_damage_path_narrows_a_power(conn):
    """The 32-bit ceiling has been found four times in two days, and every time
    by somebody hitting it rather than by looking:

        0392  compute_technique_damage's locals and returns
        0392  battle_actions.base_power
        0394  techniques.base_power and both writers
        0403  battle_act casting back down into the column 0392 had widened -
              which read to the player as "GuV2 didn't respond in time"

    So this sweeps instead of waiting. A cast to integer on a line that names a
    power, a damage or a body's strength is the shape of all four.
    """
    # Narrow RETURN COLUMNS. 0403 swept for casts; 0404 found the same
    # mistake wearing a different hat - a plpgsql RETURN QUERY matches its
    # declared shape exactly, so a column still typed integer breaks the
    # whole function the moment the value it selects is widened underneath
    # it. That is what stopped m_i_y_u_k_i refining.
    returns = conn.execute(
        r"""
        SELECT p.proname, pg_get_function_result(p.oid)
        FROM pg_proc p
        WHERE p.pronamespace = 'public'::regnamespace
          AND p.prorettype = 'record'::regtype
          AND pg_get_function_result(p.oid) ~ '(power|damage|attack|thews) integer'
          AND p.prosrc ~ 'RETURN QUERY'
        ORDER BY 1
        """
    ).fetchall()
    assert returns == [], returns

    # And narrow LOCALS reading a column that is not one.
    held = conn.execute(
        r"""
        SELECT proname FROM pg_proc
        WHERE pronamespace = 'public'::regnamespace
          AND prosrc ~ 'atk\s+INTEGER|tech_base\s+INTEGER|thews\s+INTEGER'
        ORDER BY 1
        """
    ).fetchall()
    assert held == [], held

    narrow = conn.execute(
        r"""
        SELECT p.proname, trim(l.line)
        FROM pg_proc p
        CROSS JOIN LATERAL unnest(string_to_array(p.prosrc, chr(10))) AS l(line)
        WHERE p.pronamespace = 'public'::regnamespace
          AND l.line ~ '::integer'
          AND l.line ~* 'power|damage|dealt|thews'
          AND l.line !~ '^\s*--'
        ORDER BY 1
        """
    ).fetchall()
    assert narrow == [], narrow


def test_the_deepest_cultivator_can_actually_swing(conn, make_player,
                                                    make_technique, make_species):
    """0403. Driven end to end through `battle_act` rather than through the
    damage function alone, because the crash was not in the arithmetic - it was
    in writing the answer down afterwards."""
    player = make_player()
    species = make_species("swing_probe_beast", paths=["strength"])
    technique = make_technique(
        None, name="Swing Probe", paths={"blood": "1.0"}, base_power=1000,
        created_by=player,
    )
    conn.execute(
        "INSERT INTO player_cultivation (player_id, realm_id, qi) VALUES (%s, 1, 0) "
        "ON CONFLICT (player_id) DO NOTHING",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES "
        "(%s, (SELECT physique_id FROM physiques ORDER BY physique_id LIMIT 1)) "
        "ON CONFLICT (player_id) DO NOTHING",
        (player,),
    )
    conn.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s)",
        (player, technique),
    )

    # A grade that puts the live power well past INT_MAX, which is the state
    # pashu0 was actually in.
    conn.execute(
        """
        INSERT INTO technique_forges
            (player_id, realm_rank, power_grade, dual, paths, step,
             technique_id, finished_at)
        VALUES (%s, 14, 4.0, FALSE, ARRAY['blood'], 3, %s, now())
        """,
        (player, technique),
    )
    # The forge row's `realm_rank` is only a record of where it was made -
    # `technique_power_for` recomputes from where the owner stands NOW, so the
    # player has to actually be deep or the fixture never reaches the ceiling
    # it exists to test.
    conn.execute(
        """
        UPDATE player_cultivation pc
        SET realm_id = (SELECT max(realm_id) FROM realms)
        WHERE pc.player_id = %s
        """,
        (player,),
    )
    conn.execute(
        """
        UPDATE player_physique pp
        SET body_rank = 12, physique_xp = 400000,
            max_hp = 5000000000, current_hp = 5000000000, strength = 900000000
        WHERE pp.player_id = %s
        """,
        (player,),
    )
    conn.execute(
        "UPDATE player_cultivation pc SET qi = player_max_qi(pc.player_id) "
        "WHERE pc.player_id = %s",
        (player,),
    )

    assert conn.execute(
        "SELECT technique_power_for(%s, %s)", (player, technique)
    ).fetchone()[0] > 2_147_483_647, "the fixture is not past the old ceiling"

    battle = conn.execute(
        "SELECT battle_open(%s, %s)", (player, species)
    ).fetchone()[0]
    dealt = conn.execute(
        "SELECT dealt FROM battle_act(%s, 'attack', %s)", (battle, technique)
    ).fetchone()[0]
    assert dealt > 0, "the swing landed nothing"
