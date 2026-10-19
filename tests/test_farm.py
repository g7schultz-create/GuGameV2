"""The farm, the breakdown, and the merchant's new shelf.

Three features landed together in 0580-0582, and all three are rules somebody
can break later rather than facts that were true on the day they were written -
which is what makes them worth a test file and not only a migration probe.

  0580  the merchant could not stock a beast material at all, because his
        material lane draws `WHERE tier IS NOT NULL` and not one of the 62
        beast materials has a tier
  0581  a Gu had one way out of the jar that was not a trade, and it ate
        SAME-KIND copies only, so a lone spare was dead weight forever
  0582  1405 unhatched eggs in the live world and one thing to do with them

The thing all three can quietly break is the same: a yield that multiplies. The
delve paid four sets of Ancient Venerable Notes off one corpse until 0578
capped it, because its drop table was rolled twenty-four times and each roll was
scaled again. `test_butchering_rolls_each_drop_once` is that lesson written down
where the next person will trip over it.

TWO CONVENTIONS THIS FILE FOLLOWS, both learned the hard way here:

  * `conn` yields PLAIN TUPLES, so every query names its columns explicitly and
    reads them by position. A bare `SELECT *` off a function with eight output
    columns is an index nobody can check by eye.
  * A refusal aborts the surrounding transaction, so anything that asserts a
    refusal AND then keeps querying wraps the call in `conn.transaction()` - a
    savepoint, which is what lets the outer transaction survive being told no.
"""

import psycopg
import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def farmer(conn, make_player, name, *, stage=3, essence=20_000_000):
    # 20 million, because 0584 repriced a pen: a tier 9 one costs
    # 2,430,000 of essence value where it used to cost 4050.
    """Somebody with pens to use and essence to fill them."""
    who = make_player(name)
    conn.execute(
        "INSERT INTO player_dwelling (player_id, stage) VALUES (%s, %s) "
        "ON CONFLICT (player_id) DO UPDATE SET stage = EXCLUDED.stage",
        (who, stage),
    )
    if essence:
        conn.execute(
            "SELECT grant_material(%s, 'dewberry_essence', %s)", (who, essence)
        )
    return who


def dropping_species(conn, least=2):
    """A species that actually drops things, or the butcher tests prove nothing.

    0554's first probe passed against the bug it was written for because the
    fixture it used had no variance in it. A species with an empty drop table
    would do exactly the same here.
    """
    row = conn.execute(
        "SELECT cd.species_id FROM creature_drops cd "
        "GROUP BY cd.species_id HAVING count(*) >= %s LIMIT 1",
        (least,),
    ).fetchone()
    assert row is not None, "no species drops enough to be worth butchering"
    return row[0]


def an_egg(conn, who, species, tier=3, rarity="rare"):
    conn.execute(
        "SELECT grant_beast_egg(%s, %s, %s::smallint, %s, NULL)",
        (who, species, tier, rarity),
    )
    return conn.execute(
        "SELECT egg_id FROM player_beast_eggs "
        "WHERE owner_id = %s AND hatched_at IS NULL ORDER BY egg_id DESC LIMIT 1",
        (who,),
    ).fetchone()[0]


def pen_an_egg(conn, who, species, tier=3, essence="dewberry_essence"):
    """Returns (pen_no, essence_spent)."""
    egg = an_egg(conn, who, species, tier)
    return conn.execute(
        "SELECT pen_no, essence_spent FROM farm_place(%s, %s, %s)",
        (who, egg, essence),
    ).fetchone()


def ripen(conn, who, pen):
    conn.execute(
        "UPDATE player_farm SET ready_at = now() - interval '1 minute' "
        "WHERE player_id = %s AND pen_no = %s",
        (who, pen),
    )


def butcher(conn, who, pen):
    """Returns [(material_code, quantity), ...]."""
    return conn.execute(
        "SELECT material_code, quantity FROM farm_butcher(%s, %s::smallint)",
        (who, pen),
    ).fetchall()


def held(conn, who, code):
    row = conn.execute(
        "SELECT quantity FROM player_materials "
        "WHERE player_id = %s AND material_code = %s",
        (who, code),
    ).fetchone()
    return row[0] if row else 0


# ---------------------------------------------------------------------------
# The farm
# ---------------------------------------------------------------------------

def test_penning_takes_the_egg_off_the_shelf(conn, make_player):
    """The egg row is DELETED, which is the whole reason no reader of the egg
    shelf had to learn a new rule. If it were left in place and merely marked,
    `/eggs`, `hatch_egg` and the trade screens would each need teaching - and
    this game's recurring bug is a guard that moved while a reader did not.
    """
    who = farmer(conn, make_player, "penner")
    egg = an_egg(conn, who, dropping_species(conn))

    conn.execute("SELECT pen_no FROM farm_place(%s, %s, 'dewberry_essence')", (who, egg))

    assert conn.execute(
        "SELECT count(*) FROM player_beast_eggs WHERE egg_id = %s", (egg,)
    ).fetchone()[0] == 0, "the penned egg is still on the shelf"
    assert conn.execute(
        "SELECT count(*) FROM player_farm WHERE player_id = %s", (who,)
    ).fetchone()[0] == 1


def test_a_pen_charges_the_essence_it_says_it_will(conn, make_player):
    who = farmer(conn, make_player, "payer", essence=500_000)
    before = held(conn, who, "dewberry_essence")

    _pen, spent = pen_an_egg(conn, who, dropping_species(conn), tier=4)
    wants = conn.execute("SELECT farm_essence_needed(4::smallint)").fetchone()[0]

    assert spent == wants
    assert held(conn, who, "dewberry_essence") == before - wants, (
        "the essence was reported spent but not taken"
    )


def test_a_deeper_essence_goes_further(conn, make_player):
    """Paid by what the essence is WORTH, not by the unit - which is what being
    a deeper essence means. Jade Plum is worth three Dewberry, so a pen takes a
    third as many of them.
    """
    who = farmer(conn, make_player, "deeper", essence=0)
    conn.execute("SELECT grant_material(%s, 'jade_plum_essence', 100000)", (who,))

    _pen, spent = pen_an_egg(
        conn, who, dropping_species(conn), tier=3, essence="jade_plum_essence"
    )

    need = conn.execute("SELECT farm_essence_needed(3::smallint)").fetchone()[0]
    unit = conn.execute(
        "SELECT unit_value FROM immortal_essences "
        "WHERE material_code = 'jade_plum_essence'"
    ).fetchone()[0]
    assert spent == -(-need // unit), "a deeper essence was not counted by its worth"
    assert spent < need


def test_only_immortal_essence_raises_a_beast(conn, make_player):
    who = farmer(conn, make_player, "wrongfood")
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 1000000)", (who,))
    egg = an_egg(conn, who, dropping_species(conn), tier=2)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "SELECT pen_no FROM farm_place(%s, %s, 'spirit_stone')", (who, egg)
        )


def test_a_pen_is_not_ready_before_its_hours(conn, make_player):
    """A clock that could be skipped would make the whole feature decorative."""
    who = farmer(conn, make_player, "impatient")
    pen, _spent = pen_an_egg(conn, who, dropping_species(conn))

    for call in ("farm_butcher", "farm_hatch"):
        with pytest.raises(psycopg.errors.CheckViolation):
            with conn.transaction():
                conn.execute(f"SELECT * FROM {call}(%s, %s::smallint)", (who, pen))

    assert conn.execute(
        "SELECT count(*) FROM player_farm WHERE player_id = %s", (who,)
    ).fetchone()[0] == 1, "a refused pen was emptied anyway"


def test_pens_are_bounded_by_the_dwelling(conn, make_player):
    who = farmer(conn, make_player, "cramped", stage=2)
    species = dropping_species(conn)
    pen_an_egg(conn, who, species, tier=1)
    pen_an_egg(conn, who, species, tier=1)

    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            pen_an_egg(conn, who, species, tier=1)

    assert conn.execute(
        "SELECT count(*) FROM player_farm WHERE player_id = %s", (who,)
    ).fetchone()[0] == 2


def test_no_dwelling_means_no_pens(conn, make_player):
    who = make_player("homeless")
    conn.execute("SELECT grant_material(%s, 'dewberry_essence', 100000)", (who,))
    egg = an_egg(conn, who, dropping_species(conn), tier=1, rarity="common")

    assert conn.execute("SELECT farm_pens(%s)", (who,)).fetchone()[0] == 0
    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute(
            "SELECT pen_no FROM farm_place(%s, %s, 'dewberry_essence')", (who, egg)
        )


def test_an_essence_too_dear_for_the_pen_is_refused(conn, make_player):
    """The trap 0584 closed. Essence is spent in whole units, so a 4050 bill
    paid with one White Litchi worth 2,430,000 destroyed 99.8% of it - and
    White Litchi and Yellow Apricot were the ONLY essences the richest
    cultivator in the live world held. Refusing caps the overpay below one unit.
    """
    who = farmer(conn, make_player, "overpayer", essence=0)
    conn.execute("SELECT grant_material(%s, 'yellow_apricot_essence', 10)", (who,))
    egg = an_egg(conn, who, dropping_species(conn), tier=9)

    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute(
                "SELECT pen_no FROM farm_place(%s, %s, 'yellow_apricot_essence')",
                (who, egg),
            )

    assert held(conn, who, "yellow_apricot_essence") == 10, (
        "the refusal still took the essence"
    )


def test_a_deep_egg_is_what_lets_you_spend_a_deep_essence(conn, make_player):
    """An emergent rule worth pinning down: the bill is tier squared, so a tier
    1 pen (30,000) will not swallow a White Litchi (2,430,000) while a tier 9
    pen (2,430,000 exactly) takes one. Nobody wrote that rule; it falls out of
    0584's guard meeting 0584's pricing, which is why it needs a test.
    """
    who = farmer(conn, make_player, "ladder", essence=0)
    conn.execute("SELECT grant_material(%s, 'white_litchi_essence', 10)", (who,))
    species = dropping_species(conn)

    shallow = an_egg(conn, who, species, tier=1)
    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute(
                "SELECT pen_no FROM farm_place(%s, %s, 'white_litchi_essence')",
                (who, shallow),
            )

    deep = an_egg(conn, who, species, tier=9)
    spent = conn.execute(
        "SELECT essence_spent FROM farm_place(%s, %s, 'white_litchi_essence')",
        (who, deep),
    ).fetchone()[0]
    assert spent == 1, f"a tier 9 pen took {spent} White Litchi, not 1"


# ---------------------------------------------------------------------------
# Butchering
# ---------------------------------------------------------------------------

def test_butchering_pays_only_beast_materials(conn, make_player):
    who = farmer(conn, make_player, "butcher")
    pen, _spent = pen_an_egg(conn, who, dropping_species(conn))
    ripen(conn, who, pen)

    rows = butcher(conn, who, pen)
    assert rows, "a grown pen yielded nothing"

    wrong = conn.execute(
        "SELECT string_agg(m.code, ', ') FROM player_materials pm "
        "JOIN materials m ON m.code = pm.material_code "
        "WHERE pm.player_id = %s AND pm.quantity > 0 "
        "  AND m.category <> 'beast' AND m.code <> 'dewberry_essence'",
        (who,),
    ).fetchone()[0]
    assert wrong is None, f"butchering also handed over: {wrong}"


def test_butchering_rolls_each_drop_once(conn, make_player):
    """THE DELVE LESSON. `delve_spoils` rolls a creature's whole drop table
    `p_rolls` times and scales each roll again, which is how one rogue came to
    be worth four sets of Ancient Venerable Notes before 0578 capped it.

    A pen must pay one line per drop on the species table - no more - however
    generous the per-tier multiple gets.
    """
    who = farmer(conn, make_player, "onceeach")
    species = dropping_species(conn, least=3)
    drops = conn.execute(
        "SELECT count(*) FROM creature_drops WHERE species_id = %s", (species,)
    ).fetchone()[0]

    pen, _spent = pen_an_egg(conn, who, species, tier=9)
    ripen(conn, who, pen)
    rows = butcher(conn, who, pen)

    assert len(rows) == drops, (
        f"a pen paid {len(rows)} lines against {drops} drops on the table"
    )
    assert len({code for code, _qty in rows}) == len(rows), (
        "the same material came off one carcass twice"
    )


def test_a_deeper_pen_pays_more(conn, make_player):
    """Rolled, so compared across enough pens that the dice cannot decide it."""
    who = farmer(conn, make_player, "deeppen", stage=9, essence=50_000_000)
    species = dropping_species(conn)

    def haul(tier):
        total = 0
        for _ in range(6):
            pen, _spent = pen_an_egg(conn, who, species, tier=tier)
            ripen(conn, who, pen)
            total += sum(qty for _code, qty in butcher(conn, who, pen))
        return total

    shallow, deep = haul(1), haul(9)
    assert deep > shallow, (
        f"six tier 9 pens paid {deep} against six tier 1 pens' {shallow}"
    )


def test_a_butchered_pen_is_emptied(conn, make_player):
    who = farmer(conn, make_player, "emptied")
    pen, _spent = pen_an_egg(conn, who, dropping_species(conn))
    ripen(conn, who, pen)
    butcher(conn, who, pen)

    assert conn.execute(
        "SELECT count(*) FROM player_farm WHERE player_id = %s AND pen_no = %s",
        (who, pen),
    ).fetchone()[0] == 0


# ---------------------------------------------------------------------------
# Or taking it alive
# ---------------------------------------------------------------------------

def test_a_raised_beast_walks_out_a_juvenile(conn, make_player):
    """Raised, not cracked. `hatch_egg` still does the hatching - one
    definition - and the pen's hours buy the rung above Baby and no further,
    because `feed_beast` is the whole rest of the ladder.
    """
    who = farmer(conn, make_player, "raiser")
    pen, _spent = pen_an_egg(conn, who, dropping_species(conn))
    ripen(conn, who, pen)

    beast_id, _name, stage = conn.execute(
        "SELECT beast_id, beast_name, stage FROM farm_hatch(%s, %s::smallint)",
        (who, pen),
    ).fetchone()

    assert conn.execute(
        "SELECT stage FROM player_beasts WHERE beast_id = %s", (beast_id,)
    ).fetchone()[0] == "juvenile", f"a raised beast came out {stage}"
    assert conn.execute(
        "SELECT egg_id FROM player_beasts WHERE beast_id = %s", (beast_id,)
    ).fetchone()[0] is not None, "the raised beast points at no egg"
    assert conn.execute(
        "SELECT count(*) FROM player_farm WHERE player_id = %s AND pen_no = %s",
        (who, pen),
    ).fetchone()[0] == 0


def test_a_cracked_egg_still_comes_out_a_baby(conn, make_player):
    """The pen is a benefit, so the thing it is better THAN has to stay put."""
    who = farmer(conn, make_player, "cracker")
    egg = an_egg(conn, who, dropping_species(conn))
    made = conn.execute("SELECT hatch_egg(%s, %s)", (who, egg)).fetchone()[0]

    assert conn.execute(
        "SELECT stage FROM player_beasts WHERE beast_id = %s", (made,)
    ).fetchone()[0] == "baby"


# ---------------------------------------------------------------------------
# Breaking a Gu down
# ---------------------------------------------------------------------------

def a_gu(conn, who):
    gu_type = conn.execute(
        "SELECT gu_type_id FROM gu_recipe_costs "
        "WHERE secondary_material IS NOT NULL LIMIT 1"
    ).fetchone()[0]
    return conn.execute("SELECT grant_gu(%s, %s)", (who, gu_type)).fetchone()[0]


def yield_of(conn, gu):
    """Returns [(material_code, quantity), ...]."""
    return conn.execute(
        "SELECT material_code, quantity FROM gu_breakdown_yield(%s)", (gu,)
    ).fetchall()


def test_a_breakdown_returns_the_recipe_and_nothing_else(conn, make_player):
    who = make_player("breaker")
    gu = a_gu(conn, who)
    rows = yield_of(conn, gu)
    assert rows, "a Gu broke down into nothing"

    recipe = {
        r[0]
        for r in conn.execute(
            "SELECT c.base_material FROM gu_recipe_costs c "
            "JOIN player_gu g ON g.gu_type_id = c.gu_type_id WHERE g.gu_id = %s "
            "UNION ALL "
            "SELECT c.secondary_material FROM gu_recipe_costs c "
            "JOIN player_gu g ON g.gu_type_id = c.gu_type_id WHERE g.gu_id = %s",
            (gu, gu),
        ).fetchall()
    }
    assert {code for code, _qty in rows} <= recipe, (
        "a breakdown offered a material the recipe never used"
    )
    assert all(qty >= 1 for _code, qty in rows), "a breakdown offered nothing back"


def test_a_breakdown_returns_less_than_a_failed_refinement(conn):
    """If smashing paid more than failing, the best play would be to refine,
    succeed, and immediately smash - which is not a sentence that should be
    true of any game.
    """
    back, refund = conn.execute(
        "SELECT game_config_value('gu_breakdown_return'), "
        "       game_config_value('gu_refine_refund')"
    ).fetchone()
    assert back < refund


def test_stars_are_paid_back(conn, make_player):
    """Reaching S stars ate sum(2..S) copies of the same kind, so the Gu in hand
    embodies S*(S+1)/2 of them. Forgetting that would destroy fourteen Gu worth
    of material and hand back one.
    """
    who = make_player("starry")
    one, five = a_gu(conn, who), a_gu(conn, who)
    conn.execute("UPDATE player_gu SET stars = 5 WHERE gu_id = %s", (five,))

    def first(gu):
        return conn.execute(
            "SELECT quantity FROM gu_breakdown_yield(%s) "
            "ORDER BY material_code LIMIT 1",
            (gu,),
        ).fetchone()[0]

    assert first(five) > first(one), "stars paid nothing back"


def test_breaking_down_grants_and_destroys(conn, make_player):
    who = make_player("smasher")
    gu = a_gu(conn, who)
    promised = dict(yield_of(conn, gu))

    conn.execute("SELECT gu_name FROM break_down_gu(%s, %s)", (who, gu))

    assert conn.execute(
        "SELECT count(*) FROM player_gu WHERE gu_id = %s", (gu,)
    ).fetchone()[0] == 0, "the Gu survived being broken down"
    for code, qty in promised.items():
        assert held(conn, who, code) >= qty, f"{code} was promised, not given"


def test_a_worn_gu_refuses_to_be_broken(conn, make_player):
    """The aperture is the number this game is balanced on, and a cascade out of
    `player_gu_equipped` would shrink a build silently.
    """
    who = make_player("wearer")
    gu = a_gu(conn, who)
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id) VALUES (%s, %s)", (gu, who)
    )

    with pytest.raises(psycopg.errors.CheckViolation):
        with conn.transaction():
            conn.execute("SELECT gu_name FROM break_down_gu(%s, %s)", (who, gu))

    assert conn.execute(
        "SELECT count(*) FROM player_gu WHERE gu_id = %s", (gu,)
    ).fetchone()[0] == 1, "a worn Gu was destroyed by a call that refused"


def test_somebody_elses_gu_refuses(conn, make_player):
    mine, yours = make_player("owner"), make_player("thief")
    gu = a_gu(conn, mine)

    with pytest.raises(psycopg.errors.CheckViolation):
        conn.execute("SELECT gu_name FROM break_down_gu(%s, %s)", (yours, gu))


# ---------------------------------------------------------------------------
# The merchant's new shelf
# ---------------------------------------------------------------------------

def stock_some_carts(conn, first, many=40):
    for hour in range(first, first + many):
        stamp = conn.execute(
            "SELECT date_trunc('hour', now()) + make_interval(hours => %s)", (hour,)
        ).fetchone()[0]
        conn.execute("SELECT market_stock_for(%s)", (stamp,))


def test_the_merchant_can_stock_a_beast_material(conn):
    """The bug this closes: his material lane draws `WHERE tier IS NOT NULL` and
    all 62 beast materials have a NULL tier, so every hide and horn in the game
    was invisible to the cart.
    """
    stock_some_carts(conn, 5000, 60)
    seen = conn.execute(
        "SELECT count(*) FROM market_stall WHERE kind = 'beast'"
    ).fetchone()[0]
    assert seen > 0, "sixty carts held no beast material at all"


def test_the_beast_lane_stocks_only_beast_materials(conn):
    stock_some_carts(conn, 6000, 40)
    wrong = conn.execute(
        "SELECT string_agg(DISTINCT s.code, ', ') FROM market_stall s "
        "WHERE s.kind = 'beast' AND NOT EXISTS ("
        "  SELECT 1 FROM materials m WHERE m.code = s.code AND m.category = 'beast')"
    ).fetchone()[0]
    assert wrong is None, f"the beast lane stocked non-beast codes: {wrong}"


def test_a_beast_part_can_be_bought(conn, make_player):
    who = make_player("shopper")
    conn.execute("SELECT grant_material(%s, 'spirit_stone', 10000000)", (who,))
    conn.execute(
        "DELETE FROM market_stall WHERE stocked_for = date_trunc('hour', now())"
    )
    conn.execute(
        "INSERT INTO market_stall (stocked_for, slot_no, kind, code, quantity, price) "
        "SELECT date_trunc('hour', now()), 1, 'beast', m.code, 7, 1000 "
        "FROM materials m WHERE m.category = 'beast' ORDER BY m.code LIMIT 1"
    )

    quantity = conn.execute(
        "SELECT quantity FROM market_buy(%s, 1::smallint)", (who,)
    ).fetchone()[0]
    assert quantity == 7

    got = conn.execute(
        "SELECT pm.quantity FROM player_materials pm "
        "JOIN materials m ON m.code = pm.material_code "
        "WHERE pm.player_id = %s AND m.category = 'beast'",
        (who,),
    ).fetchone()
    assert got is not None and got[0] == 7, "it was reported bought but not granted"


# ---------------------------------------------------------------------------
# Every loot key the dungeon can pay has to be on the card
# ---------------------------------------------------------------------------

def test_the_dungeon_card_renders_every_loot_key(conn):
    """`dungeon_spoils_for` can put eleven keys into a raider's spoils and the
    card rendered ten. The missing one was `notes` - the item the entire
    Venerable ladder runs on - so it was granted silently.

    It had been paid exactly twice in the game's history, both to the same
    cultivator, who then reported getting none in fourteen dungeons. She was
    right about what she saw. A drop nobody is told about is a drop that does
    not exist as far as the player is concerned.

    This is the same failure as a footer naming a command that moved: the
    database learned a new key and the reader did not.
    """
    import pathlib
    import re

    body = conn.execute(
        "SELECT pg_get_functiondef(oid) FROM pg_proc "
        "WHERE proname = 'dungeon_spoils_for' AND pronamespace = 'public'::regnamespace"
    ).fetchone()[0]
    paid = set(re.findall(r"jsonb_build_object\('([a-z_]+)'", body))
    assert len(paid) > 5, f"only found {paid} - the scan stopped matching"

    card = pathlib.Path("bot/cogs/dungeon.py").read_text(encoding="utf-8")
    shown = set(re.findall(r's\.get\("([a-z_]+)"\)', card))

    missing = paid - shown
    assert missing == set(), (
        "dungeon_spoils_for pays these and the card never mentions them: "
        + ", ".join(sorted(missing))
    )


# ---------------------------------------------------------------------------
# And no slot on the cart is nameless
# ---------------------------------------------------------------------------

def test_every_market_kind_has_a_name(conn, make_player):
    """A slot read "None" on a live cart: 0580 added the `beast` kind and
    `market_today`'s label CASE had an ELSE that meant "assume egg", so a beast
    material's code was looked up in `creature_species`, missed, and came back
    NULL.

    0580's own probes bought a part off the cart and confirmed it was granted -
    which is why BUYING worked perfectly and nothing noticed the slot had no
    name. The kinds come off the CHECK constraint here so a sixth one cannot be
    added without being labelled.
    """
    import re

    allowed = set(
        re.findall(
            r"'([a-z_]+)'::text",
            conn.execute(
                "SELECT pg_get_constraintdef(c.oid) FROM pg_constraint c "
                "WHERE c.conrelid = 'market_stall'::regclass "
                "  AND c.conname = 'market_stall_kind_check'"
            ).fetchone()[0],
        )
    )
    assert len(allowed) >= 5, f"only read {allowed} off the constraint"

    samples = {
        "material": "SELECT code FROM materials WHERE tier IS NOT NULL ORDER BY code LIMIT 1",
        "beast": "SELECT code FROM materials WHERE category = 'beast' ORDER BY code LIMIT 1",
        "essence": "SELECT material_code FROM immortal_essences ORDER BY rank LIMIT 1",
        "gu": "SELECT code FROM gu_types ORDER BY code LIMIT 1",
        "egg": "SELECT code FROM creature_species WHERE kind IN ('beast','elite') ORDER BY code LIMIT 1",
    }
    assert allowed <= set(samples), (
        "the cart allows kinds this test has no sample for, so nothing checks "
        f"what they are called: {sorted(allowed - set(samples))}"
    )

    who = make_player("cart-reader")
    conn.execute(
        "DELETE FROM market_stall WHERE stocked_for = date_trunc('hour', now())"
    )
    for slot, kind in enumerate(sorted(allowed), start=1):
        code = conn.execute(samples[kind]).fetchone()[0]
        conn.execute(
            "INSERT INTO market_stall "
            "(stocked_for, slot_no, kind, code, quantity, price) "
            "VALUES (date_trunc('hour', now()), %s, %s, %s, 1, 1000)",
            (slot, kind, code),
        )

    rows = conn.execute(
        "SELECT kind, code, label FROM market_today(%s) ORDER BY slot_no", (who,)
    ).fetchall()
    assert len(rows) == len(allowed)

    for kind, code, label in rows:
        assert label and label.strip(), f"the {kind} slot came back with no name"
        # Not merely non-null: a label of the raw code would pass the line above
        # and still read like a bug on the card.
        assert label != code, f"the {kind} slot is labelled with its raw code"
