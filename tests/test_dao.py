"""Reading a Dao off a cultivator (0482-0486).

Phase 2 of the Venerable realm: given a character, derive the aspects their
history produced and compose a name from them. Nothing is stored and no player
can see any of it - `/dev dao` is owner-gated until the realm that spends a Dao
exists.

Four faults got through the probes in the migrations that introduced this, and
every one of them was found by reading the output rather than by asserting a
property. These tests are mostly those four turned into assertions:

    0483  five titles restated one path twice - Lawful Rule, Empyrean Heaven
    0484  stem test caught Decree/Decreed and missed Empyrean/Heaven entirely
    0485  one adjective, Untracked, named three different cultivators
    0486  a bare one-word title beat shapes with four sources to work with
"""

import psycopg
import pytest


PLACEHOLDERS = ("{adj1}", "{adj2}", "{noun1}", "{noun2}", "{body_adj}", "{craft_noun}")


def name_of(conn, player_id):
    return conn.execute("SELECT dao_name_of(%s)", (player_id,)).fetchone()[0]


def aspects(conn, player_id):
    return conn.execute(
        "SELECT ordinal, source_kind, source_code, label, weight, feeds "
        "FROM dao_aspects(%s) ORDER BY ordinal",
        (player_id,),
    ).fetchall()


def words_in(conn, name):
    """The vocabulary words a finished title contains.

    A word sitting inside a longer matched word is that word, not a second
    one - Edge inside Keen Steel's neighbour would otherwise count twice.
    """
    return conn.execute(
        """
        SELECT DISTINCT w.word FROM dao_words w
        WHERE strpos(%s, w.word) > 0
          AND NOT EXISTS (
              SELECT 1 FROM dao_words w2
              WHERE strpos(%s, w2.word) > 0 AND w2.word <> w.word
                AND strpos(w2.word, w.word) > 0)
        """,
        (name, name),
    ).fetchall()


@pytest.fixture
def walker(conn, make_player):
    """A cultivator the test can give a history to, one axis at a time."""

    def _make(paths=(), body=None, craft=None, root=None):
        pid = make_player("DaoWalker")
        for code, insight in paths:
            conn.execute(
                "INSERT INTO player_path_attainment (player_id, path_code, insight, tier) "
                "VALUES (%s, %s, %s, 1)",
                (pid, code, insight),
            )
        if body is not None:
            conn.execute(
                "INSERT INTO player_physique (player_id, physique_id, body_path) "
                "VALUES (%s, (SELECT min(physique_id) FROM physiques), %s)",
                (pid, body),
            )
        if craft is not None:
            conn.execute(
                "INSERT INTO player_professions (player_id, profession, level) "
                "VALUES (%s, %s, 40)",
                (pid, craft),
            )
        if root is not None:
            conn.execute(
                "INSERT INTO player_character (player_id, race_code, root_code) "
                "VALUES (%s, (SELECT min(code) FROM races), %s)",
                (pid, root),
            )
        return pid

    return _make


# ---------------------------------------------------------------------------
# The vocabulary
# ---------------------------------------------------------------------------


def test_every_path_carries_a_full_set(conn):
    thin = conn.execute(
        """
        SELECT p.code, w.role, COALESCE(count(w.word), 0) AS n
        FROM paths p
        CROSS JOIN (VALUES ('adjective'), ('noun')) AS r(role)
        LEFT JOIN dao_words w
               ON w.source_kind = 'path' AND w.source_code = p.code
              AND w.role = r.role
        GROUP BY p.code, w.role
        HAVING COALESCE(count(w.word), 0) < 6
        """
    ).fetchall()
    assert thin == [], thin


def test_the_earned_axes_are_as_deep_as_the_paths(conn):
    """0486. They were two deep while being the only adjective source."""
    thin = conn.execute(
        """
        SELECT source_kind, source_code, role, count(*) AS n
        FROM dao_words
        WHERE source_kind IN ('body', 'craft')
        GROUP BY 1, 2, 3
        HAVING count(*) < 6
        """
    ).fetchall()
    assert thin == [], thin


def test_the_seventh_craft_has_words_too(conn):
    """`player_skills` unions six professions with a synthetic refinement row.

    Reading `player_professions` instead of the view would drop refinement
    from every refiner's Dao without anything failing.
    """
    missing = conn.execute(
        """
        SELECT DISTINCT ps.skill FROM player_skills ps
        WHERE NOT EXISTS (
            SELECT 1 FROM dao_words w
            WHERE w.source_kind = 'craft' AND w.source_code = ps.skill)
        """
    ).fetchall()
    assert missing == []
    assert conn.execute(
        "SELECT count(*) FROM dao_words WHERE source_kind = 'craft' "
        "AND source_code = 'refinement'"
    ).fetchone()[0] >= 12


def test_nothing_is_keyed_to_something_that_does_not_exist(conn):
    assert conn.execute(
        """
        SELECT count(*) FROM dao_words w
        WHERE (w.source_kind = 'path'
               AND NOT EXISTS (SELECT 1 FROM paths WHERE code = w.source_code))
           OR (w.source_kind = 'body'
               AND NOT EXISTS (SELECT 1 FROM body_paths WHERE code = w.source_code))
        """
    ).fetchone()[0] == 0


def test_the_register_the_old_words_set_survived(conn):
    """`path_words` is where the voice of this vocabulary came from.

    Nine Palace, Ten Thousand Folk, Inch of Time, Vajra. Replacing rather than
    extending them would have lost the register, so most of the original 102
    are still reachable.
    """
    kept = conn.execute(
        """
        SELECT count(*) FROM path_words pw
        WHERE EXISTS (SELECT 1 FROM dao_words w
                      WHERE w.source_kind = 'path' AND w.source_code = pw.path_code
                        AND w.word = pw.word)
        """
    ).fetchone()[0]
    assert kept >= 90, f"only {kept} of 102 survived"


def test_every_template_names_only_slots_the_composer_fills(conn):
    for code, shape in conn.execute("SELECT code, shape FROM dao_templates").fetchall():
        rest = shape
        for slot in PLACEHOLDERS:
            rest = rest.replace(slot, "")
        assert "{" not in rest and "}" not in rest, (code, shape)


# ---------------------------------------------------------------------------
# The aspects
# ---------------------------------------------------------------------------


def test_a_character_with_no_history_has_no_dao(conn, make_player):
    pid = make_player("Blank")
    assert aspects(conn, pid) == []
    assert name_of(conn, pid) is None


def test_the_strongest_path_leads_and_leads_at_full_weight(conn, walker):
    pid = walker(paths=[("sword", 500), ("shadow", 90_000), ("ice", 20_000)])
    rows = aspects(conn, pid)
    assert rows[0][1:3] == ("path", "shadow")
    assert rows[0][4] == 1


def test_a_path_you_dabbled_in_is_not_an_aspect(conn, walker):
    """Player 5365 holds all thirty-four paths. A tenth of the leader is the floor."""
    pid = walker(paths=[("sword", 100_000), ("ice", 30_000), ("poison", 500)])
    held = [r[2] for r in aspects(conn, pid) if r[1] == "path"]
    assert held == ["sword", "ice"]


def test_at_most_three_paths_however_many_you_walked(conn, walker):
    pid = walker(paths=[(c, 100_000) for c in ("sword", "ice", "poison", "shadow", "fire")])
    assert len([r for r in aspects(conn, pid) if r[1] == "path"]) == 3


def test_insight_orders_the_paths_not_tier(conn, walker):
    """Tier caps at 10 and four of player 5365's paths are tied there.

    `dao_marks` is the other obvious-looking measure and is zero in all 192
    rows - nothing writes it.
    """
    pid = walker(paths=[("sword", 50_000), ("ice", 90_000)])
    conn.execute(
        "UPDATE player_path_attainment SET tier = 10 WHERE player_id = %s AND path_code = 'sword'",
        (pid,),
    )
    conn.execute(
        "UPDATE player_path_attainment SET tier = 1 WHERE player_id = %s AND path_code = 'ice'",
        (pid,),
    )
    assert [r[2] for r in aspects(conn, pid) if r[1] == "path"] == ["ice", "sword"]


def test_a_specialist_craft_weighs_more_than_a_generalist_one(conn, walker):
    focused = walker(paths=[("sword", 1000)], craft="mining")
    spread = walker(paths=[("sword", 1000)], craft="mining")
    for other in ("foraging", "exploring", "alchemy"):
        conn.execute(
            "INSERT INTO player_professions (player_id, profession, level) VALUES (%s, %s, 40)",
            (spread, other),
        )
    one = [r[4] for r in aspects(conn, focused) if r[1] == "craft"][0]
    many = [r[4] for r in aspects(conn, spread) if r[1] == "craft"][0]
    assert one == 1 and many < one


def test_a_rarer_root_is_more_defining(conn, walker):
    common = walker(paths=[("sword", 1000)], root="earthen_root")
    divine = walker(paths=[("sword", 1000)], root="infinite_dao_root")
    assert (
        [r[4] for r in aspects(conn, common) if r[1] == "root"][0]
        < [r[4] for r in aspects(conn, divine) if r[1] == "root"][0]
    )


def test_every_weight_is_on_the_one_scale(conn, walker):
    pid = walker(
        paths=[("sword", 90_000), ("ice", 40_000)],
        body="buddhist",
        craft="mining",
        root="iron_root",
    )
    for row in aspects(conn, pid):
        assert 0 < row[4] <= 1, row


def test_every_aspect_says_what_feeds_it(conn, walker):
    """Understanding accrues by acting in accordance, so each aspect names a deed."""
    pid = walker(paths=[("sword", 1000)], body="taoist", craft="mining", root="iron_root")
    for row in aspects(conn, pid):
        assert row[5] and row[5].strip()


# ---------------------------------------------------------------------------
# The name
# ---------------------------------------------------------------------------


def test_a_name_is_never_left_half_composed(conn, walker):
    pid = walker(paths=[("sword", 90_000), ("ice", 40_000)], body="taoist", craft="mining")
    name = name_of(conn, pid)
    assert name and "{" not in name and "}" not in name
    assert name == name.strip() and "  " not in name


def test_reading_a_dao_twice_reads_the_same_dao(conn, walker):
    """The premise. A title a player quotes cannot be re-rolled on every read."""
    pid = walker(paths=[("shadow", 90_000), ("ice", 40_000)], body="demonic", craft="mining")
    assert len({name_of(conn, pid) for _ in range(6)}) == 1


def test_two_cultivators_with_different_histories_get_different_daos(conn, walker):
    a = walker(paths=[("sword", 90_000), ("ice", 40_000)], craft="mining")
    b = walker(paths=[("shadow", 90_000), ("poison", 40_000)], craft="alchemy")
    assert name_of(conn, a) != name_of(conn, b)


def test_no_source_lends_two_words_to_one_title(conn, walker):
    """0485's guarantee, and the reason it is structural rather than a word list.

    Empyrean IS heaven and Lawful IS rule, so no stem test catches them. An
    adjective drawn from a different source than the noun beside it cannot
    restate it, whatever the vocabulary happens to hold.
    """
    for paths, body, craft in (
        ([("heaven", 90_000)], None, "mining"),
        ([("rule", 90_000)], "taoist", "alchemy"),
        ([("blood", 90_000)], None, "foraging"),
        ([("time", 90_000)], "buddhist", None),
        ([("heaven", 90_000), ("rule", 40_000)], "demonic", "exploring"),
    ):
        pid = walker(paths=paths, body=body, craft=craft)
        name = name_of(conn, pid)
        worst = conn.execute(
            """
            SELECT COALESCE(max(c), 0) FROM (
                SELECT count(DISTINCT w.word) AS c
                FROM dao_words w
                JOIN dao_aspects(%s) a
                  ON a.source_kind = w.source_kind AND a.source_code = w.source_code
                WHERE strpos(%s, w.word) > 0
                  AND NOT EXISTS (
                      SELECT 1 FROM dao_words w2
                      WHERE strpos(%s, w2.word) > 0 AND w2.word <> w.word
                        AND strpos(w2.word, w.word) > 0)
                  -- only words this cultivator could have got from one place;
                  -- 0482 shares Decreed between heaven and rule on purpose
                  AND 1 = (SELECT count(DISTINCT w3.source_kind || w3.source_code)
                           FROM dao_words w3
                           JOIN dao_aspects(%s) a3
                             ON a3.source_kind = w3.source_kind
                            AND a3.source_code = w3.source_code
                           WHERE w3.word = w.word)
                GROUP BY w.source_kind, w.source_code
            ) s
            """,
            (pid, name, name, pid),
        ).fetchone()[0]
        assert worst <= 1, f"{name!r} draws {worst} words from one source"


def test_a_cultivator_with_much_to_say_is_not_given_a_bare_title(conn, walker):
    """0486. luckymate0_0 had three paths, a body and a craft, and got The Hoar Dao."""
    pid = walker(
        paths=[("shadow", 90_000), ("ice", 40_000), ("poison", 20_000)],
        body="demonic",
        craft="mining",
    )
    assert len(words_in(conn, name_of(conn, pid))) >= 2


def test_one_path_and_nothing_else_still_gets_a_title(conn, walker):
    """Eleven of the twenty living cultivators have exactly one path.

    The majority case, not an edge case - and 0484's templates all wanted two
    voices, which is how both halves came from one path for eleven people.
    """
    pid = walker(paths=[("qi", 90_000)])
    name = name_of(conn, pid)
    assert name and "{" not in name
    assert len(words_in(conn, name)) == 1, name


def test_one_path_plus_a_craft_is_named_for_both(conn, walker):
    pid = walker(paths=[("qi", 90_000)], craft="mining")
    assert len(words_in(conn, name_of(conn, pid))) >= 2


def test_the_leading_noun_is_your_strongest_path(conn, walker):
    """A Dao is named for the path you are deepest in, not for your trade."""
    pid = walker(paths=[("shadow", 90_000)], craft="mining")
    name = name_of(conn, pid)
    assert conn.execute(
        """
        SELECT count(*) FROM dao_words
        WHERE source_kind = 'path' AND source_code = 'shadow' AND strpos(%s, word) > 0
        """,
        (name,),
    ).fetchone()[0] >= 1, name


# ---------------------------------------------------------------------------
# The two primitives
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "a,b",
    [
        ("Decree", "Decreed"),
        ("Lifeblood", "Heartsblood"),
        ("Sanguine", "Sanguine Tide"),
        ("Frost", "Hoarfrost"),
        ("Refined", "Refinement"),
        ("Shadow", "Shadowed"),
    ],
)
def test_words_that_stutter_are_refused(conn, a, b):
    assert conn.execute("SELECT dao_clashes(%s, %s)", (a, b)).fetchone()[0]


@pytest.mark.parametrize(
    "a,b",
    [
        ("Celestial Vault", "Leash"),
        ("Governing", "Heaven"),
        ("Keen", "Edge"),
        ("Immovable", "Severance"),
        ("Waning", "Aeon"),
    ],
)
def test_a_good_pairing_is_not_refused(conn, a, b):
    assert not conn.execute("SELECT dao_clashes(%s, %s)", (a, b)).fetchone()[0]


def test_a_clash_reads_the_same_both_ways_round(conn):
    pairs = conn.execute(
        """
        SELECT a.word, b.word FROM dao_words a JOIN dao_words b ON a.word < b.word
        WHERE a.source_kind = 'path' AND b.source_kind = 'path'
        LIMIT 400
        """
    ).fetchall()
    for a, b in pairs:
        forward = conn.execute("SELECT dao_clashes(%s, %s)", (a, b)).fetchone()[0]
        back = conn.execute("SELECT dao_clashes(%s, %s)", (b, a)).fetchone()[0]
        assert forward == back, (a, b)


def test_a_pick_is_stable_and_ignores_the_order_it_was_handed(conn):
    one = conn.execute(
        "SELECT dao_pick_clear(ARRAY['Ember','Pyre','Cinder','Blaze'], 'seed', NULL)"
    ).fetchone()[0]
    two = conn.execute(
        "SELECT dao_pick_clear(ARRAY['Blaze','Cinder','Pyre','Ember'], 'seed', NULL)"
    ).fetchone()[0]
    assert one == two


def test_a_pick_stays_clear_of_what_it_is_told_to_avoid(conn):
    got = conn.execute(
        "SELECT dao_pick_clear(ARRAY['Frost','Glacier','Rime','Winter'], 's', ARRAY['Hoarfrost'])"
    ).fetchone()[0]
    assert got != "Frost"


def test_a_pick_returns_something_even_when_everything_clashes(conn):
    """A stutter beats a hole in the title. Asserted unreachable for real players."""
    got = conn.execute(
        "SELECT dao_pick_clear(ARRAY['Frost','Frosted'], 's', ARRAY['Frost'])"
    ).fetchone()[0]
    assert got is not None


def test_a_rarity_ladder_only_climbs(conn):
    weights = conn.execute(
        """
        SELECT weight FROM dao_rarity_weight
        ORDER BY array_position(
            ARRAY['common','uncommon','rare','epic','legendary','mythic','unique','divine'],
            rarity)
        """
    ).fetchall()
    flat = [w[0] for w in weights]
    assert flat == sorted(flat)
    assert len(flat) == 8


# ---------------------------------------------------------------------------
# The worm axis, which shipped on the wrong measure (0487)
# ---------------------------------------------------------------------------


@pytest.fixture
def carrier(conn, make_player):
    """A cultivator who wears a worm, optionally starting in the past."""

    def _make(hours=0.0, stars=1, gu_type_id=None, player_id=None):
        pid = player_id if player_id is not None else make_player("Carrier")
        if gu_type_id is None:
            gu_type_id = conn.execute(
                "SELECT min(gu_type_id) FROM gu_types"
            ).fetchone()[0]
        gid = conn.execute(
            "INSERT INTO player_gu (owner_id, gu_type_id, stars) VALUES (%s, %s, %s) "
            "RETURNING gu_id",
            (pid, gu_type_id, stars),
        ).fetchone()[0]
        conn.execute(
            "INSERT INTO player_gu_equipped (gu_id, player_id, equipped_at) "
            "VALUES (%s, %s, now() - make_interval(secs => %s))",
            (gid, pid, hours * 3600),
        )
        return pid, gid, gu_type_id

    return _make


def test_equipping_opens_a_tally(conn, carrier):
    """The delete side can only UPDATE, so the row has to exist by then."""
    pid, _, type_id = carrier(hours=1)
    assert conn.execute(
        "SELECT count(*) FROM player_gu_carried WHERE player_id = %s AND gu_type_id = %s",
        (pid, type_id),
    ).fetchone()[0] == 1


def test_an_open_stint_counts_before_it_is_banked(conn, carrier):
    pid, _, type_id = carrier(hours=10)
    secs = conn.execute(
        "SELECT gu_carried_seconds(%s, %s)", (pid, type_id)
    ).fetchone()[0]
    assert 35_000 <= secs <= 37_000, secs


def test_unequipping_banks_the_stint(conn, carrier):
    """Before 0487 this time was simply deleted with the row."""
    pid, gid, type_id = carrier(hours=10)
    conn.execute("DELETE FROM player_gu_equipped WHERE gu_id = %s", (gid,))
    banked = conn.execute(
        "SELECT seconds_carried FROM player_gu_carried "
        "WHERE player_id = %s AND gu_type_id = %s",
        (pid, type_id),
    ).fetchone()[0]
    assert 35_000 <= banked <= 37_000, banked


def test_a_second_stint_adds_to_the_first(conn, carrier):
    pid, gid, type_id = carrier(hours=10)
    conn.execute("DELETE FROM player_gu_equipped WHERE gu_id = %s", (gid,))
    conn.execute(
        "INSERT INTO player_gu_equipped (gu_id, player_id, equipped_at) "
        "VALUES (%s, %s, now() - INTERVAL '5 hours')",
        (gid, pid),
    )
    conn.execute("DELETE FROM player_gu_equipped WHERE gu_id = %s", (gid,))
    banked = conn.execute(
        "SELECT seconds_carried FROM player_gu_carried "
        "WHERE player_id = %s AND gu_type_id = %s",
        (pid, type_id),
    ).fetchone()[0]
    assert 53_000 <= banked <= 55_000, banked


def test_the_tally_outlives_the_worm(conn, carrier):
    """Keyed by kind, not instance, so a trade or a refinement cannot erase it.

    The worm is destroyed here; the month somebody spent wearing it was still
    their month.
    """
    pid, gid, type_id = carrier(hours=10)
    conn.execute("DELETE FROM player_gu WHERE gu_id = %s", (gid,))
    assert conn.execute(
        "SELECT gu_carried_seconds(%s, %s)", (pid, type_id)
    ).fetchone()[0] >= 35_000


def test_deleting_a_cultivator_still_works(conn, carrier):
    """The shape the trigger was written around.

    Both foreign keys on player_gu_equipped are ON DELETE CASCADE, so a hard
    delete fires the banking trigger mid-teardown. A trigger that INSERTED
    there would hand the half-deleted player a fresh referencing row after the
    cascade had passed, and this DELETE would fail. `/dev wipe` and real
    account removal both do exactly this.
    """
    pid, _, _ = carrier(hours=3)
    conn.execute("DELETE FROM players WHERE player_id = %s", (pid,))
    assert conn.execute(
        "SELECT count(*) FROM player_gu_carried WHERE player_id = %s", (pid,)
    ).fetchone()[0] == 0


def test_two_worms_of_one_kind_count_twice(conn, carrier):
    """Two of a kind in the aperture is twice the aperture spent on it."""
    pid, _, type_id = carrier(hours=10)
    carrier(hours=10, gu_type_id=type_id, player_id=pid)
    assert conn.execute(
        "SELECT gu_carried_seconds(%s, %s)", (pid, type_id)
    ).fetchone()[0] >= 70_000


def test_a_worm_tried_for_an_hour_is_not_an_aspect(conn, walker, carrier):
    """A day is the floor. Slotting something to see what it did is not a Dao."""
    pid = walker(paths=[("sword", 1000)])
    carrier(hours=1, player_id=pid)
    assert [r for r in aspects(conn, pid) if r[1] == "gu"] == []


def test_a_worm_worn_for_weeks_is_an_aspect(conn, walker, carrier):
    pid = walker(paths=[("sword", 1000)])
    carrier(hours=24 * 20, player_id=pid)
    rows = [r for r in aspects(conn, pid) if r[1] == "gu"]
    assert len(rows) == 1
    assert rows[0][4] == 1, rows


def test_the_worm_worn_longest_wins_not_the_one_with_most_stars(conn, walker, carrier):
    """0483 shipped this axis on stars and said so in its own header.

    The spec calls it "fed by using them rather than hoarding them" and
    nothing counted a use, so it named the most-starred worm - a statement
    about hoarding. Across the live roster stars and carry-time now disagree
    for nine cultivators of eleven.
    """
    pid = walker(paths=[("sword", 1000)])
    types = conn.execute(
        "SELECT gu_type_id FROM gu_types ORDER BY gu_type_id LIMIT 2"
    ).fetchall()
    worn, hoarded = types[0][0], types[1][0]
    carrier(hours=24 * 30, stars=1, gu_type_id=worn, player_id=pid)
    carrier(hours=24 * 2, stars=5, gu_type_id=hoarded, player_id=pid)
    got = [r[2] for r in aspects(conn, pid) if r[1] == "gu"]
    worn_code = conn.execute(
        "SELECT code FROM gu_types WHERE gu_type_id = %s", (worn,)
    ).fetchone()[0]
    assert got == [worn_code], got


def test_the_worm_weight_is_a_share_like_the_craft_weight(conn, walker, carrier):
    """One scale for all six axes: dominance within the aspect's own axis."""
    pid = walker(paths=[("sword", 1000)])
    types = [
        r[0] for r in conn.execute(
            "SELECT gu_type_id FROM gu_types ORDER BY gu_type_id LIMIT 2"
        ).fetchall()
    ]
    carrier(hours=24 * 10, gu_type_id=types[0], player_id=pid)
    carrier(hours=24 * 10, gu_type_id=types[1], player_id=pid)
    weight = [r[4] for r in aspects(conn, pid) if r[1] == "gu"][0]
    assert 0.4 <= float(weight) <= 0.6, weight


def test_a_hoarder_who_wears_nothing_has_no_worm_aspect(conn, walker, make_player):
    pid = walker(paths=[("sword", 1000)])
    type_id = conn.execute("SELECT min(gu_type_id) FROM gu_types").fetchone()[0]
    conn.execute(
        "INSERT INTO player_gu (owner_id, gu_type_id, stars) VALUES (%s, %s, 5)",
        (pid, type_id),
    )
    assert [r for r in aspects(conn, pid) if r[1] == "gu"] == []


# ---------------------------------------------------------------------------
# Nothing is written, and everybody alive survives being read
# ---------------------------------------------------------------------------


def test_reading_a_dao_writes_nothing(conn):
    """A Dao is derived until ascension exists to stamp it.

    Asserted on the declarations rather than by watching for writes: Postgres
    refuses an INSERT inside a STABLE or IMMUTABLE function, so this is the
    guarantee itself and not a symptom of it.
    """
    declared = dict(
        conn.execute(
            """
            SELECT p.proname, p.provolatile
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname IN ('dao_aspects', 'dao_name_of', 'dao_pick',
                                'dao_pick_clear', 'dao_clashes')
            """
        ).fetchall()
    )
    assert declared, "the dao functions are missing"
    # s = stable, i = immutable; v would mean it is allowed to write
    assert set(declared.values()) <= {"s", "i"}, declared


def test_every_living_cultivator_can_be_read(conn):
    """The only test that would have caught any of the four faults on its own."""
    rows = conn.execute(
        """
        SELECT p.player_id, dao_name_of(p.player_id) AS dao,
               (SELECT count(*) FROM dao_aspects(p.player_id)) AS n
        FROM players p WHERE p.deleted_at IS NULL
        """
    ).fetchall()
    for player_id, dao, n in rows:
        assert n <= 9, (player_id, n)
        if dao is not None:
            assert "{" not in dao and "}" not in dao, (player_id, dao)
            assert dao == dao.strip() and "  " not in dao, (player_id, dao)


def test_a_dao_cannot_be_read_for_somebody_who_is_not_there(conn):
    assert name_of(conn, -1) is None
    assert aspects(conn, -1) == []
