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
    return conn.execute(
        "SELECT * FROM compute_technique_damage(%s, %s, %s, %s, %s)",
        (player_id, technique_id, species_id, external, defense),
    ).fetchone()


# ---------------------------------------------------------------------------
# The spec's own worked examples
# ---------------------------------------------------------------------------

def test_spec_section_3_blood_blade_example(conn, make_player, make_technique, make_species):
    """Rank 6 Blood Blade: 10,000 base, Blood Grandmaster +20%, vulnerable
    target +25% => exactly 15,000."""
    player_id = make_player()
    set_attainment(conn, player_id, "blood", 6)  # Grandmaster
    technique_id = make_technique("blood_blade", paths={"blood": "1.0"}, base_power=10_000)
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
    """defense_scale=100: 100 defense halves damage, and no value zeroes it."""
    player_id = make_player()
    technique_id = make_technique("def_test", paths={"fire": "1.0"}, base_power=10_000)
    species_id = make_species("armored_target", paths=["human"])

    assert damage(conn, player_id, technique_id, species_id, defense=0)[4] == 10_000
    assert damage(conn, player_id, technique_id, species_id, defense=100)[4] == 5_000
    assert damage(conn, player_id, technique_id, species_id, defense=300)[4] == 2_500
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

    base, attainment, matchup, pre, final = damage(
        conn, player_id, technique_id, species_id, external="1.10", defense=100
    )
    # 10,000 * 1.20 * 1.25 * 1.10 = 16,500 pre-defense; halved by 100 defense.
    assert pre == Decimal("16500.0000000000")
    assert final == 8_250
