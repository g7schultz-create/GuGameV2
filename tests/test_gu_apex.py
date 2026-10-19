"""The top of the worm ladder (0492-0494).

Rank 9 Gu were the weakest thing in the Gu system and the commonest thing at
the top of it. Four separate faults, each measured:

    1. The fifteen rank 9 worms carried neither crit_damage nor multi_hit -
       the two effects that decide a damage build.
    2. Per point of APERTURE, which is the only fair comparison when size
       equals rank, neither ladder climbed. multi_hit was at its best on a
       rank 1 worm. crit_damage sagged in the middle.
    3. A flat cap meant volume always caught tier: 57 rank 1 worms at five
       stars sum to 9.27 crit_damage against a cap of 2.00.
    4. `gu_max_refinable_rank` was 8, so the fifteen recipes could not be
       used, and the two repeatable bosses carrying a rank 9 crest handed it
       over with no roll - 158 owned against 10 at rank 8.
"""

import psycopg
import pytest


APEX = ("crit_damage", "multi_hit")


def cfg(conn, key):
    return float(conn.execute("SELECT game_config_value(%s)", (key,)).fetchone()[0])


def per_point(conn, effect, rank):
    """The best value of an effect per point of aperture at a given rank."""
    row = conn.execute(
        """
        SELECT max(e.magnitude / t.size) FROM gu_type_effects e
        JOIN gu_types t USING (gu_type_id)
        WHERE e.effect_code = %s AND t.rank = %s
        """,
        (effect, rank),
    ).fetchone()[0]
    return float(row) if row is not None else None


# ---------------------------------------------------------------------------
# The lid (0492)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("effect", APEX)
def test_the_lid_rises_with_the_realm(conn, effect):
    low = float(
        conn.execute("SELECT GREATEST(cap, cap_per_rank * 1) FROM gu_effects WHERE code = %s", (effect,)).fetchone()[0]
    )
    high = float(
        conn.execute("SELECT GREATEST(cap, cap_per_rank * 18) FROM gu_effects WHERE code = %s", (effect,)).fetchone()[0]
    )
    assert high > low


@pytest.mark.parametrize("rank", [1, 5, 9, 14, 18])
def test_the_lid_never_falls_below_the_flat_cap(conn, rank):
    """A cultivator must not be nerfed by a realm they have not reached."""
    bad = conn.execute(
        "SELECT code FROM gu_effects WHERE GREATEST(cap, cap_per_rank * %s) < cap",
        (rank,),
    ).fetchall()
    assert bad == []


def test_only_the_two_flattening_effects_scale(conn):
    """Everything else keeps the flat lid it has.

    The point was never to lift every ceiling in the game - it was that these
    two make the Gu ladder converge.
    """
    scaled = {
        r[0]
        for r in conn.execute(
            "SELECT code FROM gu_effects WHERE cap_per_rank > 0"
        ).fetchall()
    }
    assert scaled == set(APEX)


def test_a_cultivator_with_no_realm_gets_the_flat_cap(conn):
    for effect in APEX:
        flat = conn.execute(
            "SELECT cap FROM gu_effects WHERE code = %s", (effect,)
        ).fetchone()[0]
        assert conn.execute(
            "SELECT gu_effect_cap(%s, NULL)", (effect,)
        ).fetchone()[0] == flat


def test_the_view_reads_the_lid_through_the_one_function(conn):
    """`player_gu_stats` must not reach for gu_effects.cap directly again."""
    body = conn.execute(
        "SELECT pg_get_viewdef('player_gu_stats'::regclass, true)"
    ).fetchone()[0]
    # Through `stat_source_cap` since 0516, which reads `gu_effect_cap` itself -
    # worms are one source and may not finish an effect alone. Either is the
    # one function; what must never come back is the raw column.
    assert "stat_source_cap" in body or "gu_effect_cap" in body
    assert "ef.cap" not in body


def test_no_living_cultivator_reads_above_their_own_lid(conn):
    over = conn.execute(
        """
        SELECT s.player_id, s.effect_code, s.total
        FROM player_gu_stats s
        WHERE s.total > gu_effect_cap(s.effect_code, s.player_id)
        """
    ).fetchall()
    assert over == []


# ---------------------------------------------------------------------------
# The ladder (0493)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("effect", APEX)
def test_rank_nine_finally_carries_the_effect(conn, effect):
    assert per_point(conn, effect, 9) is not None


@pytest.mark.parametrize("effect", APEX)
def test_the_apex_beats_its_own_aperture_in_rank_one_worms(conn, effect):
    """The user's test, made exact.

    A rank 9 worm occupies 9 points of aperture, so the thing it has to beat
    is NINE rank 1 worms - and the best of them, at five stars, not the
    average one. My first pass used averages and the migration's own probe
    refused it.
    """
    best_r1 = float(
        conn.execute(
            """
            SELECT max(e.magnitude) FROM gu_type_effects e
            JOIN gu_types t USING (gu_type_id)
            WHERE e.effect_code = %s AND t.rank = 1
            """,
            (effect,),
        ).fetchone()[0]
    )
    weakest_r9 = float(
        conn.execute(
            """
            SELECT min(e.magnitude) FROM gu_type_effects e
            JOIN gu_types t USING (gu_type_id)
            WHERE e.effect_code = %s AND t.rank = 9
            """,
            (effect,),
        ).fetchone()[0]
    )
    nine_at_max_star = 9 * best_r1 * (1 + cfg(conn, "gu_star_step") * 4)
    assert weakest_r9 > nine_at_max_star, (weakest_r9, nine_at_max_star)


@pytest.mark.parametrize("effect", APEX)
def test_the_ladder_climbs_per_point_of_aperture_above_rank_five(conn, effect):
    """Size equals rank, so per-slot value is the only honest comparison.

    Below rank 5 the sag is left alone deliberately - fixing it would move
    eleven live builds and that is a separate decision.
    """
    seen = [(r, per_point(conn, effect, r)) for r in range(5, 10)]
    have = [(r, v) for r, v in seen if v is not None]
    assert len(have) >= 2, have
    values = [v for _, v in have]
    assert values == sorted(values), have
    assert len(set(values)) == len(values), have


def test_the_strike_ladder_has_no_gap_from_six_to_nine(conn):
    """multi_hit stopped at rank 5 and resumed nowhere."""
    ranks = {
        r[0]
        for r in conn.execute(
            """
            SELECT DISTINCT t.rank FROM gu_type_effects e
            JOIN gu_types t USING (gu_type_id)
            WHERE e.effect_code = 'multi_hit' AND t.rank BETWEEN 6 AND 9
            """
        ).fetchall()
    }
    assert ranks == {6, 7, 8, 9}


def test_the_strike_ladder_rides_the_armour_pen_worms(conn):
    """0037's own note: a multi-strike build "wants penetration badly".

    The two effects were designed to want each other and were never put on one
    worm above rank 5.
    """
    mismatched = conn.execute(
        """
        SELECT t.code FROM gu_types t
        JOIN gu_type_effects m ON m.gu_type_id = t.gu_type_id AND m.effect_code = 'multi_hit'
        WHERE t.rank BETWEEN 6 AND 8
          AND NOT EXISTS (SELECT 1 FROM gu_type_effects a
                          WHERE a.gu_type_id = t.gu_type_id AND a.effect_code = 'armor_pen')
        """
    ).fetchall()
    assert mismatched == []


@pytest.mark.parametrize(
    "code",
    [
        "dao_heavenly_birth_gu",
        "destiny_gu",
        "fate_gu",
        "dao_wisdom_gu",
        "venerable_immortal_formation_gu",
        "venerable_brocade_immortal_formation_gu",
    ],
)
def test_the_worms_that_are_not_about_fighting_were_left_alone(conn, code):
    """Fifteen worms with identities worth keeping. Only the combat ones bite."""
    assert conn.execute(
        """
        SELECT count(*) FROM gu_types t JOIN gu_type_effects e USING (gu_type_id)
        WHERE t.code = %s AND e.effect_code IN ('crit_damage', 'multi_hit')
        """,
        (code,),
    ).fetchone()[0] == 0


def test_two_apex_strike_worms_fit_under_the_lid(conn):
    """One worm that caps you out is not a build.

    0492 set the multi_hit lid to 0.28 per rank, which is 5.04 at rank 18 -
    room for exactly one. 0493 raised it so a second is worth wearing.
    """
    best = float(
        conn.execute(
            """
            SELECT max(e.magnitude) FROM gu_type_effects e
            JOIN gu_types t USING (gu_type_id)
            WHERE e.effect_code = 'multi_hit' AND t.rank = 9
            """
        ).fetchone()[0]
    )
    lid = float(
        conn.execute(
            "SELECT GREATEST(cap, cap_per_rank * 18) FROM gu_effects WHERE code = 'multi_hit'"
        ).fetchone()[0]
    )
    assert lid >= 2 * best, (lid, best)


@pytest.mark.parametrize(
    "rank,effect,magnitude",
    [(8, "crit_damage", 1.0237), (5, "multi_hit", 0.3173)],
)
def test_nothing_already_worn_was_changed(conn, rank, effect, magnitude):
    """Live cultivators are wearing these. Only absent rows were added."""
    assert float(
        conn.execute(
            """
            SELECT round(max(e.magnitude), 4) FROM gu_type_effects e
            JOIN gu_types t USING (gu_type_id)
            WHERE t.rank = %s AND e.effect_code = %s
            """,
            (rank, effect),
        ).fetchone()[0]
    ) == magnitude


# ---------------------------------------------------------------------------
# The price and the rarity (0494)
# ---------------------------------------------------------------------------


def test_every_apex_recipe_can_be_used_at_all(conn):
    """They sat behind gu_max_refinable_rank = 8 since 0036.

    This counted exactly fifteen, which was the census on the day it was
    written and stopped being true the moment 0555 added a sixteenth - the apex
    qi worm, because rank 9 had nothing for the breath. The rule it was
    standing in for is that EVERY rank 9 worm is reachable, which is what 0494
    was about and what cannot go stale.
    """
    assert cfg(conn, "gu_max_refinable_rank") >= 9

    unreachable = conn.execute(
        """
        SELECT t.code
        FROM gu_types t
        LEFT JOIN gu_recipe_costs c ON c.gu_type_id = t.gu_type_id
        WHERE t.rank = 9 AND c.gu_type_id IS NULL
        ORDER BY t.code
        """
    ).fetchall()
    assert unreachable == [], (
        f"these rank 9 Gu cannot be refined at all: {[r[0] for r in unreachable]}"
    )

    # And there is still an apex to speak of.
    assert conn.execute(
        "SELECT count(*) FROM gu_recipe_costs WHERE rank = 9"
    ).fetchone()[0] >= 15


def test_the_apex_step_is_the_largest_in_the_curve(conn):
    """It was the smallest: 1.50 against 2.50 at the bottom."""
    steps = conn.execute(
        """
        SELECT a.rank + 1, round(b.base_quantity::numeric / a.base_quantity, 2)
        FROM gu_refine_costs a JOIN gu_refine_costs b ON b.rank = a.rank + 1
        ORDER BY a.rank
        """
    ).fetchall()
    by_rank = {int(r): float(s) for r, s in steps}
    assert by_rank[9] == max(by_rank.values()), by_rank


def test_the_cost_curve_only_climbs(conn):
    broken = conn.execute(
        """
        SELECT a.rank FROM gu_refine_costs a JOIN gu_refine_costs b ON b.rank = a.rank + 1
        WHERE b.base_quantity <= a.base_quantity
           OR b.secondary_quantity <= a.secondary_quantity
           OR b.required_level <= a.required_level
           OR b.exp_reward <= a.exp_reward
        """
    ).fetchall()
    assert broken == []


def test_nobody_can_already_afford_one(conn):
    """The biggest stock of a rank 9 base material measured 48,242."""
    cheapest = conn.execute(
        "SELECT min(base_quantity) FROM gu_recipe_costs WHERE rank = 9"
    ).fetchone()[0]
    richest = conn.execute(
        """
        SELECT COALESCE(max(held), 0) FROM (
            SELECT sum(pm.quantity) AS held FROM player_materials pm
            WHERE pm.material_code IN (SELECT base_material FROM gu_recipe_costs WHERE rank = 9)
            GROUP BY pm.material_code
        ) s
        """
    ).fetchone()[0]
    assert cheapest > richest, (cheapest, richest)


def test_the_gate_is_reachable_by_a_specialist(conn):
    """A cost nobody can ever pay is not a goal. The measured ceiling is 98."""
    gate = conn.execute(
        "SELECT required_level FROM gu_refine_costs WHERE rank = 9"
    ).fetchone()[0]
    assert gate <= 98


def test_an_apex_crest_is_rolled_for_rather_than_handed_over(conn):
    """Two repeatable bosses were granting the strongest worms unconditionally.

    Shadow Demon King carries heaven_defying_chaos_gu and the Heavenly Court
    General carries heavenly_web_gu - which 0493 made the highest crit_damage
    and the highest multi_hit in the game.
    """
    body = conn.execute(
        "SELECT pg_get_functiondef('claim_boss_reward(bigint,bigint)'::regprocedure)"
    ).fetchone()[0]
    assert "boss_crest_rare_chance" in body
    assert "boss_crest_rare_from" in body


def test_the_rare_crest_rule_covers_only_the_apex(conn):
    """Every other boss in the game behaves exactly as it did."""
    rolled = conn.execute(
        """
        SELECT count(*) FROM creature_species cs
        JOIN gu_types gt ON gt.gu_type_id = cs.signature_gu_type_id
        WHERE gt.rank >= game_config_value('boss_crest_rare_from')
        """
    ).fetchone()[0]
    assert rolled == 2
    assert 0 < cfg(conn, "boss_crest_rare_chance") < 0.5


def test_nobody_lost_a_worm_they_already_had(conn):
    """Repricing changes what arrives, not what is owned.

    This counted 158, the census on the day 0514 was written, and it read
    147 two days later - not because anything was taken, but because
    nurturing and fusing CONSUME worms and ten people are playing. A flat
    count against a live world measures the world.

    So it asserts the property instead: every worm in play is still a whole
    worm on a real type with a real owner, and nobody is over the aperture
    that holds it. That is what "nobody lost a worm" means, and unlike a
    census it is still true tomorrow.
    """
    assert conn.execute(
        """
        SELECT count(*) FROM player_gu pg JOIN gu_types gt USING (gu_type_id)
        WHERE gt.rank = 9
        """
    ).fetchone()[0] > 0, "no rank 9 worm is in play at all"

    orphaned = conn.execute(
        """
        SELECT count(*) FROM player_gu pg
        WHERE NOT EXISTS (SELECT 1 FROM gu_types gt
                          WHERE gt.gu_type_id = pg.gu_type_id)
           OR NOT EXISTS (SELECT 1 FROM players p
                          WHERE p.player_id = pg.owner_id)
        """
    ).fetchone()[0]
    assert orphaned == 0, f"{orphaned} worms lost their type or their owner"

    over = conn.execute(
        """
        SELECT array_agg(p.discord_name) FROM players p
        WHERE p.deleted_at IS NULL
          AND gu_used_by(p.player_id) > gu_capacity_of(p.player_id)
        """
    ).fetchone()[0]
    assert over is None, (
        f"the repricing put these cultivators over their aperture: {over}"
    )
