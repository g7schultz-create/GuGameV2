"""Every slash command, invoked for real against a real database.

The command bodies are where the SQL actually lives, and a query that does not
parse fails identically to a bot that is offline: Discord shows "the
application did not respond" either way. So these tests call the command
callbacks directly with a stand-in interaction, which exercises the queries,
the embed building and the number formatting without needing a gateway
connection or a token.

Character creation is driven through its actual buttons rather than by writing
`confirmed_at` directly - the reroll accounting and the confirm are the part
worth testing, and reaching past them would test nothing.

What is deliberately *not* stubbed is the database. A fake one would only prove
the commands agree with the fake.

Unlike the schema tests these commit, because the bot's pool owns its own
transactions - so the character is created with a throwaway Discord ID and
deleted at the end.
"""

import asyncio
import os
from decimal import Decimal

import discord
import psycopg
import pytest
from discord import app_commands
from discord.utils import MISSING

from bot import database as db
from bot.__main__ import loop_factory
from bot.client import EXTENSIONS, GuBot
from bot.cogs import auction, trade
from bot.cogs.world import SHELVES, pick_technique
from bot.formatting import thousands
from bot.players import GameError
from db.connection import database_url

TEST_DISCORD_ID = 999_000_000_000_000_001

# Creation rolls at random, so the fixture pins all three traits. Every rate
# assertion below is computed from these: Human is +5% cultivation and +5% all
# Path attainment, Earthen Root is +3% physique training, Mortal Body is flat.
FIXED_RACE = "human"
FIXED_ROOT = "earthen_root"
FIXED_PHYSIQUE = "mortal_body"


# ---------------------------------------------------------------------------
# A stand-in for discord.Interaction
#
# Only the surface the commands actually touch: who ran it, and the ways of
# answering. Every reply is captured so a test can assert on what the player
# would have seen.
# ---------------------------------------------------------------------------


class FakeAvatar:
    url = "https://example.invalid/avatar.png"


class FakeUser:
    def __init__(self, user_id: int, name: str = "Tester") -> None:
        self.id = user_id
        self.name = name
        self.display_name = name
        self.mention = f"<@{user_id}>"
        self.bot = False
        self.display_avatar = FakeAvatar()

    def __str__(self) -> str:
        return f"{self.name}#0001"


class FakeMessage:
    async def edit(self, **kwargs):
        return None


def check_view(view) -> None:
    """Refuse a None view the way discord.py does.

    discord.py treats `view=None` as a view it was handed and calls
    `is_finished()` on it; the sentinel for "no view" is `discord.utils.MISSING`
    and nothing else. A fake that accepted None let /physique ship a crash that
    only fired for characters whose body Path had set - the ones furthest
    along, and the ones least likely to be a test player.
    """
    assert view is not None, (
        "view=None is a crash in discord.py - pass discord.utils.MISSING"
    )


class FakeResponse:
    def __init__(self, interaction: "FakeInteraction") -> None:
        self._interaction = interaction
        self._done = False

    def is_done(self) -> bool:
        return self._done

    async def send_message(
        self, content=None, *, embed=None, view=MISSING, ephemeral=False, **kwargs
    ):
        check_view(view)
        self._done = True
        self._interaction.record(embed if embed is not None else content, view)

    async def edit_message(self, *, embed=None, view=MISSING, **kwargs):
        check_view(view)
        self._done = True
        self._interaction.record(embed, view)

    async def send_modal(self, modal):
        self._done = True
        self._interaction.modal = modal

    async def defer(self, *, ephemeral=False, thinking=False):
        self._done = True


class FakeFollowup:
    def __init__(self, interaction: "FakeInteraction") -> None:
        self._interaction = interaction

    async def send(
        self, content=None, *, embed=None, view=MISSING, ephemeral=False, **kwargs
    ):
        check_view(view)
        self._interaction.record(embed if embed is not None else content, view)


class FakeInteraction:
    def __init__(self, user: FakeUser) -> None:
        self.user = user
        self.replies: list = []
        self.views: list = []
        self.modal = None
        self.response = FakeResponse(self)
        self.followup = FakeFollowup(self)
        self.command = None
        # Components fired from a message carry the message they sit on, and
        # the screens that open a second ephemeral prompt - the insight picker
        # and the pill quantity prompt - edit it afterwards.
        self.message = FakeMessage()

    def record(self, payload, view=MISSING) -> None:
        self.replies.append(payload)
        if view is not MISSING and view is not None:
            self.views.append(view)

    async def original_response(self) -> FakeMessage:
        return FakeMessage()

    @property
    def last(self):
        assert self.replies, "the command answered nothing"
        return self.replies[-1]

    @property
    def view(self):
        assert self.views, "the command attached no view"
        return self.views[-1]


# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------


class Harness:
    """Runs commands on one event loop for the whole test session.

    psycopg's async mode will not run on the Windows default loop, so the loop
    comes from the same factory the bot itself uses - which also means these
    tests would catch it if that factory stopped being right.
    """

    def __init__(self) -> None:
        self.runner = asyncio.Runner(loop_factory=loop_factory)
        self.bot: GuBot | None = None

    def start(self) -> None:
        async def _start():
            await db.open_pool()
            bot = GuBot()
            for extension in EXTENSIONS:
                await bot.load_extension(extension)
            return bot

        self.bot = self.runner.run(_start())

    def stop(self) -> None:
        self.runner.run(db.close_pool())
        self.runner.close()

    def command(self, name: str) -> app_commands.Command:
        """Look a command up the way a player names it: 'dev advance'."""
        parts = name.split()
        node = self.bot.tree.get_command(parts[0])
        for part in parts[1:]:
            node = node.get_command(part)
        assert node is not None, f"no command /{name}"
        return node

    def run(self, name: str, interaction: FakeInteraction, /, **kwargs):
        # Positional-only: commands have parameters called `name` and `path`,
        # and a keyword collision here would look like a bug in the command.
        command = self.command(name)
        interaction.command = command
        self.runner.run(command.callback(command.binding, interaction, **kwargs))
        return interaction.last

    def click(self, item, interaction: FakeInteraction):
        """Press a button or use a select, through its real callback.

        Returns None where the component opens a modal instead of answering
        with an embed - the reply comes on the modal's submit.
        """
        self.runner.run(item.callback(interaction))
        return interaction.replies[-1] if interaction.replies else None

    def pick_path(self, view, code: str, user: FakeUser):
        """Turn to the page holding `code`, then press its button.

        Neither /focus nor /path takes a typed Path any more, so this is the
        only way in - and it is what a player does.
        """
        page = next(
            i for i, (_, members) in enumerate(view.pages)
            if any(p["code"] == code for p in members)
        )
        view.page = page
        view.render()
        button = next(
            b for b in view.children
            if getattr(b, "path", None) and b.path["code"] == code
        )
        return self.click(button, FakeInteraction(user))

    def sql(self, query: str, params=()):
        return self.runner.run(db.fetch_one(query, params))

    def sql_all(self, query: str, params=()):
        return self.runner.run(db.fetch_all(query, params))

    def execute(self, query: str, params=()):
        return self.runner.run(db.execute(query, params))


@pytest.fixture(scope="module")
def harness(migrated_database):
    if not os.getenv("DATABASE_URL"):
        pytest.skip("DATABASE_URL is not set")

    harness = Harness()
    harness.start()
    try:
        yield harness
    finally:
        # battle_combatants RESTRICTs a player delete - battle history involves
        # other people, same reasoning as the audit log. Hunting creates that
        # history, so the battles go first and cascade their combatants away.
        harness.execute(
            """
            DELETE FROM battles WHERE battle_id IN (
                SELECT bc.battle_id FROM battle_combatants bc
                JOIN players p ON p.player_id = bc.player_id
                WHERE p.discord_id = %s
            )
            """,
            (TEST_DISCORD_ID,),
        )
        # The rival exists only to be the other side of a sale, and its
        # listings hold escrowed goods that would otherwise be stranded with
        # the house.
        harness.execute(
            "SELECT auction_cancel(seller_id, listing_id) FROM auction_listings "
            "WHERE status = 'open' AND seller_id IN "
            "(SELECT player_id FROM players WHERE discord_id IN (%s, %s))",
            (TEST_DISCORD_ID, TEST_DISCORD_ID + 7),
        )
        harness.execute(
            "DELETE FROM players WHERE discord_id IN (%s, %s)",
            (TEST_DISCORD_ID, TEST_DISCORD_ID + 7),
        )
        harness.stop()


@pytest.fixture(scope="module")
def user():
    return FakeUser(TEST_DISCORD_ID)


@pytest.fixture
def interaction(user):
    return FakeInteraction(user)


@pytest.fixture(scope="module", autouse=True)
def registered(harness, user):
    """One character for the module, created through the real screen.

    Ordering matters: the commands under test are a progression, and a fresh
    character per test could never reach a state where insight has accrued or
    a weakness has been deduced.
    """
    harness.execute(
        """
        DELETE FROM battles WHERE battle_id IN (
            SELECT bc.battle_id FROM battle_combatants bc
            JOIN players p ON p.player_id = bc.player_id
            WHERE p.discord_id = %s
        )
        """,
        (TEST_DISCORD_ID,),
    )
    harness.execute("DELETE FROM players WHERE discord_id = %s", (TEST_DISCORD_ID,))

    setup = FakeInteraction(user)
    harness.run("register", setup)
    view = setup.view

    # Pin the rolled traits so every rate below is a known number.
    player_id = harness.sql(
        "SELECT player_id FROM players WHERE discord_id = %s", (TEST_DISCORD_ID,)
    )["player_id"]
    harness.execute(
        "UPDATE player_character SET race_code = %s, root_code = %s WHERE player_id = %s",
        (FIXED_RACE, FIXED_ROOT, player_id),
    )
    harness.execute(
        "UPDATE player_physique SET physique_id = "
        "(SELECT physique_id FROM physiques WHERE code = %s) WHERE player_id = %s",
        (FIXED_PHYSIQUE, player_id),
    )
    return {"view": view, "player_id": player_id}


@pytest.fixture(scope="module")
def player_id(registered):
    return registered["player_id"]


# ---------------------------------------------------------------------------
# Character creation
# ---------------------------------------------------------------------------


def test_register_opens_an_unconfirmed_character(harness, registered, player_id):
    row = harness.sql(
        "SELECT confirmed_at, root_rerolls_left, physique_rerolls_left "
        "FROM player_character WHERE player_id = %s",
        (player_id,),
    )
    assert row["confirmed_at"] is None
    assert row["root_rerolls_left"] == 2
    assert row["physique_rerolls_left"] == 2


def test_the_sheet_shows_all_three_traits(harness, registered, user):
    setup = FakeInteraction(user)
    harness.click(registered["view"].children[0], setup)  # Set Name opens a modal
    assert setup.modal is not None

    # The select is the race chooser; using it re-renders the sheet.
    select = next(
        item for item in registered["view"].children if hasattr(item, "options")
    )
    select._values = ["snowman"]
    card = harness.click(select, FakeInteraction(user))
    names = [f.name for f in card.fields]
    assert names[:4] == [
        "\N{DROP OF BLOOD} Race",
        "\N{SEEDLING} Root",
        "\N{FLEXED BICEPS} Physique",
        "\N{GEM STONE} Foundation Stats",
    ]
    race = card.fields[0].value
    assert "Snowman" in race
    assert "Ice Attainment: +15%" in race


def test_race_can_be_changed_back(harness, registered, user, player_id):
    select = next(
        item for item in registered["view"].children if hasattr(item, "options")
    )
    select._values = [FIXED_RACE]
    harness.click(select, FakeInteraction(user))
    assert harness.sql(
        "SELECT race_code FROM player_character WHERE player_id = %s", (player_id,)
    )["race_code"] == FIXED_RACE


def test_rerolling_the_root_spends_a_reroll(harness, registered, user, player_id):
    button = next(
        item for item in registered["view"].children
        if getattr(item, "custom_id", None) == "reroll_root"
    )
    harness.click(button, FakeInteraction(user))
    row = harness.sql(
        "SELECT root_rerolls_left, root_rolls FROM player_character WHERE player_id = %s",
        (player_id,),
    )
    assert row["root_rerolls_left"] == 1
    assert row["root_rolls"] == 2

    harness.click(button, FakeInteraction(user))
    assert harness.sql(
        "SELECT root_rerolls_left FROM player_character WHERE player_id = %s", (player_id,)
    )["root_rerolls_left"] == 0

    with pytest.raises(GameError, match="no rerolls left"):
        harness.click(button, FakeInteraction(user))


def test_rerolling_the_physique_recomputes_stats(harness, registered, user, player_id):
    button = next(
        item for item in registered["view"].children
        if getattr(item, "custom_id", None) == "reroll_physique"
    )
    harness.click(button, FakeInteraction(user))

    # A physique change has to move max HP, because the stat is a function of
    # level and traits rather than an incremented total.
    #
    # This used to spell the formula out as `120 * (hp_multiplier +
    # player_stat('max_hp'))`, which was a second copy of a sum that has since
    # moved twice: manuals, body paths and the foundation bonus all join the
    # multiplier, and 0434 retired `max_hp` into `base_hp`, which is added to
    # the BASE rather than to the multiplier. So the copy drifted, and the
    # test failed roughly one run in eight - whenever the random reroll landed
    # on a body granting base_hp.
    #
    # The property under test is that the stored figure IS the computed one.
    # Asking `apply_physique_xp` to recompute and finding nothing moves says
    # that without owning a second definition of how.
    before = harness.sql(
        "SELECT max_hp, defense, strength FROM player_physique WHERE player_id = %s",
        (player_id,),
    )
    assert before["max_hp"] > 0

    harness.execute("SELECT apply_physique_xp(%s, 0)", (player_id,))

    after = harness.sql(
        "SELECT max_hp, defense, strength FROM player_physique WHERE player_id = %s",
        (player_id,),
    )
    assert (after["max_hp"], after["defense"], after["strength"]) == (
        before["max_hp"], before["defense"], before["strength"]
    ), "the stored physique stats are not what a recompute produces"


def test_confirm_locks_the_character_and_starts_the_clock(harness, registered, user, player_id):
    # Put the pinned traits back after the rerolls above.
    harness.execute(
        "UPDATE player_character SET race_code = %s, root_code = %s WHERE player_id = %s",
        (FIXED_RACE, FIXED_ROOT, player_id),
    )
    harness.execute(
        "UPDATE player_physique SET physique_id = "
        "(SELECT physique_id FROM physiques WHERE code = %s) WHERE player_id = %s",
        (FIXED_PHYSIQUE, player_id),
    )
    harness.execute("SELECT apply_physique_xp(%s, 0)", (player_id,))

    confirm = next(
        item for item in registered["view"].children
        if getattr(item, "label", None) == "Confirm"
    )
    press = FakeInteraction(user)
    harness.click(confirm, press)

    row = harness.sql(
        "SELECT confirmed_at FROM player_character WHERE player_id = %s", (player_id,)
    )
    assert row["confirmed_at"] is not None

    with pytest.raises(GameError, match="already confirmed"):
        harness.click(confirm, FakeInteraction(user))


def test_confirming_hands_over_a_starter_manual(harness, player_id):
    """The point of the whole thing: a character can fight the moment it exists.

    Before this, a new cultivator knew no techniques at all, so pick_technique
    returned nothing and every creature in the world answered /hunt with "you
    cannot fight".
    """
    row = harness.sql(
        """
        SELECT m.manual_id, m.name, m.tier, m.archetype, m.harmony,
               s.slot_index, manual_total_bonus(m.manual_id) AS spent,
               t.base_power, t.category
        FROM player_manuals pm
        JOIN manuals m ON m.manual_id = pm.manual_id
        JOIN player_manual_slots s
            ON s.player_id = pm.player_id AND s.manual_id = m.manual_id
        JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE pm.player_id = %s
        """,
        (player_id,),
    )
    assert row is not None, "confirming a character must hand over a manual"
    assert row["tier"] == 1
    assert row["archetype"] == "offensive"
    assert row["slot_index"] == 0, "an unequipped book teaches nobody anything"
    assert row["category"] == "attack" and row["base_power"] > 0
    # Made for this player, but not refined by them - the distinction 0028
    # loosened the constraint to allow.
    assert row["harmony"] is None
    assert row["spent"] == Decimal("0.0600"), "a Tier 1 manual spends 6%"


def test_the_starter_manual_is_what_you_would_fight_with(harness, player_id):
    """pick_technique is one definition shared by /hunt and every ambush, so
    asserting on it is asserting on both."""
    technique = harness.runner.run(pick_technique(player_id))
    assert technique is not None
    assert technique["source"] == "manual"


def test_a_starter_manual_is_only_ever_granted_once(harness, player_id):
    again = harness.sql("SELECT grant_starter_manual(%s) AS m", (player_id,))
    assert again["m"] is None, "a player who owns a manual is not a beginner"
    owned = harness.sql(
        "SELECT count(*) AS n FROM player_manuals WHERE player_id = %s", (player_id,)
    )
    assert owned["n"] == 1


def test_confirming_hands_over_a_purse(harness, player_id):
    """The other half of the kit.

    A character used to arrive with a book, a technique and nothing to spend,
    while the cheapest thing on the technique shelf costs 25 stones - so the
    first choice the game offers is one a newcomer cannot make for a week.
    """
    purse = harness.sql(
        "SELECT game_config_value('starter_spirit_stones') AS n"
    )["n"]
    held = harness.sql(
        """
        SELECT COALESCE(quantity, 0) AS n FROM player_materials
        WHERE player_id = %s AND material_code = 'spirit_stone'
        """,
        (player_id,),
    )
    assert held is not None, "a confirmed character is holding no stones at all"
    assert held["n"] == purse


def test_the_purse_buys_a_technique_on_the_first_day(harness, player_id):
    """What the stones are FOR, asserted by spending them.

    Sizing the purse against the shelf in the abstract would pass even if
    learning were refused for some other reason, so this actually learns.
    """
    shelf = harness.sql(
        """
        SELECT s.technique_id, s.name, s.stone_cost
        FROM technique_shelf(%s) s
        WHERE NOT s.known AND s.realm_ok AND s.tier_ok
          AND s.grade <> 'advanced' AND s.stone_cost > 0
        ORDER BY s.stone_cost
        LIMIT 1
        """,
        (player_id,),
    )
    assert shelf is not None, "there is nothing a newcomer is allowed to learn"

    learned = harness.sql(
        "SELECT * FROM learn_technique(%s, %s)", (player_id, shelf["technique_id"])
    )
    assert learned["stones_spent"] == shelf["stone_cost"]
    assert learned["stones_left"] >= 0, "the purse did not cover the first choice"

    known = harness.sql(
        "SELECT count(*) AS n FROM player_techniques WHERE player_id = %s",
        (player_id,),
    )
    assert known["n"] == 1


def test_a_purse_is_only_ever_granted_once(harness, player_id):
    again = harness.sql("SELECT grant_starter_stones(%s) AS n", (player_id,))
    assert again["n"] is None, "a cultivator who holds stones is not a beginner"


def test_register_refuses_once_confirmed(harness, interaction):
    with pytest.raises(GameError, match="already registered"):
        harness.run("register", interaction)


def test_traits_publishes_the_roll_odds(harness, interaction):
    card = harness.run(
        "traits", interaction, kind=app_commands.Choice(name="Roots", value="roots")
    )
    headings = [f.name for f in card.fields]
    assert any("Common — 45.0000%" in h for h in headings)
    assert any("Unique — 0.1000%" in h for h in headings)
    assert "Giant Sun's Inheritor" in "\n".join(f.value for f in card.fields)


def test_evolved_roots_are_not_rollable(harness, interaction):
    card = harness.run(
        "traits", interaction, kind=app_commands.Choice(name="Roots", value="roots")
    )
    listed = "\n".join(f.value for f in card.fields)
    assert "Ember Root" in listed
    assert "Blazing Yang Root" not in listed


def test_rename(harness, interaction, player_id):
    harness.run("rename", interaction, name="Frost Nine")
    assert harness.sql(
        "SELECT character_name FROM player_character WHERE player_id = %s", (player_id,)
    )["character_name"] == "Frost Nine"


# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------


def test_ping_reports_the_schema_version(harness, interaction):
    card = harness.run("ping", interaction)
    schema = next(f for f in card.fields if f.name == "Schema")
    assert "migration" in schema.value


def test_profile_shows_the_sheet_and_the_bar(harness, interaction):
    card = harness.run("profile", interaction, user=None)
    names = [f.name for f in card.fields]
    assert "\N{GEM STONE} Foundation Stats" in names
    assert "Cultivation" in names
    assert card.title.endswith("Frost Nine")


# ---------------------------------------------------------------------------
# Passive cultivation
# ---------------------------------------------------------------------------


def test_focus_trades_rate_for_insight(harness, user):
    opened = FakeInteraction(user)
    harness.run("focus", opened)
    card = harness.pick_path(opened.view, "wisdom", user)
    assert "Wisdom Path" in card.title
    assert "85%" in card.description


@pytest.fixture
def headroom(harness, player_id):
    """Room to accrue into.

    Cultivation now stops at the next realm's door, and a test measuring the
    RATE would otherwise be measuring the wall. Standing the character far up
    the ladder puts the door out of reach; the realm goes back afterwards,
    because half this module reads it.
    """
    before = harness.sql(
        "SELECT realm_id FROM player_cultivation WHERE player_id = %s", (player_id,)
    )["realm_id"]
    harness.execute(
        "UPDATE player_cultivation SET realm_id = 20 WHERE player_id = %s", (player_id,)
    )
    try:
        yield
    finally:
        harness.execute(
            "UPDATE player_cultivation SET realm_id = %s WHERE player_id = %s",
            (before, player_id),
        )


def test_idle_time_pays_out_on_the_next_look(harness, user, player_id, headroom):
    harness.run("dev advance", FakeInteraction(user), hours=12)
    card = harness.run("profile", FakeInteraction(user), user=None)

    since = next(f for f in card.fields if f.name == "Since you last looked")

    # 12h * 100/hr * (1.05 Human + 0.02 starter manual) * 0.85 (focused),
    # times the realm's draw. Additive, not multiplicative - 1.05 * 1.02
    # would be 1,092 rather than 1,091.
    #
    # The realm term is read rather than written down: 0183 made the draw
    # scale with rank squared, and a literal here would have to be edited
    # every time that curve is retuned. The point of the test is the
    # additive part, which is what stays fixed.
    scale = float(harness.sql(
        "SELECT realm_cultivation_scale(r.rank) AS s "
        "FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id "
        "WHERE pc.player_id = %s",
        (player_id,),
    )["s"])
    assert f"+{round(12 * 100 * (1.05 + 0.02) * 0.85 * scale):,} cultivation" in since.value
    # 12h * 80/hr * 1.03 (Earthen Root) = 988.8, rounded.
    assert "+989 physique XP" in since.value
    # 12h * 60/hr * 1.05 (Human all-Path) = 756.
    assert "+756 wisdom insight" in since.value


def test_settling_twice_pays_once(harness, user):
    card = harness.run("profile", FakeInteraction(user), user=None)
    assert not any(f.name == "Since you last looked" for f in card.fields)


def test_idle_time_is_capped(harness, user):
    harness.run("dev advance", FakeInteraction(user), hours=200)
    card = harness.run("profile", FakeInteraction(user), user=None)
    since = next(f for f in card.fields if f.name == "Since you last looked")
    assert "Capped" in since.value
    assert "24h away" in since.value


def test_cultivation_shows_the_rate_and_the_estimate(harness, interaction):
    card = harness.run("cultivation", interaction)
    # Matched loosely on purpose: the headings carry emoji now, and a test
    # that pinned the exact glyph would fail on a cosmetic edit.
    names = [f.name for f in card.fields]
    assert "Next realm progress" in names[0]
    assert "Gained each hour" in names[1]
    assert "What is left" in names[2]
    # 100/hr * (1.05 Human + 0.02 starter manual) * 0.85 (focused) = 90.95.
    assert "**91** cultivation" in card.fields[1].value


def test_focus_with_no_argument_opens_the_picker(harness, user):
    """28 Paths against Discord's 25-component limit, so the picker pages."""
    opened = FakeInteraction(user)
    card = harness.run("focus", opened)
    assert card.title == "Choose a focus"

    view = opened.view
    assert len(view.pages) == 3
    assert [title for title, _ in view.pages] == ["Combat I", "Combat II", "Special & Exotic"]
    for _, members in view.pages:
        assert len(members) <= 20, "a page cannot exceed four rows of five"

    # It opens on the page holding the current focus rather than always on
    # page one. Wisdom is the twelfth combat Path, so that is Combat II.
    current = harness.sql(
        "SELECT focus_path FROM player_cultivation WHERE player_id = %s",
        (view.player_id,),
    )["focus_path"]
    assert current is not None
    assert any(p["code"] == current for p in view.pages[view.page][1])


def test_every_path_button_carries_an_emoji(harness, user):
    opened = FakeInteraction(user)
    harness.run("focus", opened)
    view = opened.view

    seen = 0
    for index in range(len(view.pages)):
        view.page = index
        view.render()
        buttons = [i for i in view.children if hasattr(i, "path")]
        assert buttons, "a page with no Paths on it"
        for button in buttons:
            assert button.emoji is not None, f"{button.path['code']} has no emoji"
            seen += 1
    assert seen == 34, f"expected all 34 Paths across the pages, saw {seen}"


def test_pressing_a_path_button_sets_the_focus(harness, user, player_id):
    opened = FakeInteraction(user)
    harness.run("focus", opened)
    view = opened.view

    card = harness.pick_path(view, "fire", user)
    assert "Fire Path" in card.title

    assert harness.sql(
        "SELECT focus_path FROM player_cultivation WHERE player_id = %s", (player_id,)
    )["focus_path"] == "fire"

    # The chosen button is the highlighted one after the re-render.
    highlighted = [
        b.path["code"] for b in view.children
        if getattr(b, "path", None) and b.style == discord.ButtonStyle.success
    ]
    assert highlighted == ["fire"]


def test_paging_wraps(harness, user):
    opened = FakeInteraction(user)
    harness.run("focus", opened)
    view = opened.view
    view.page = 0

    back = [b for b in view.children if getattr(b, "step", None) == -1][0]
    harness.click(back, FakeInteraction(user))
    assert view.page == 2, "paging back from the first page should wrap to the last"

    forward = [b for b in view.children if getattr(b, "step", None) == 1][0]
    harness.click(forward, FakeInteraction(user))
    assert view.page == 0


def test_the_clear_button_clears_the_focus(harness, user, player_id):
    opened = FakeInteraction(user)
    harness.run("focus", opened)
    view = opened.view

    clear = next(b for b in view.children if getattr(b, "label", None) == "No focus")
    assert not clear.disabled, "a focused player must be able to clear it"

    card = harness.click(clear, FakeInteraction(user))
    assert "cleared" in card.title.lower()
    assert harness.sql(
        "SELECT focus_path FROM player_cultivation WHERE player_id = %s", (player_id,)
    )["focus_path"] is None

    # With nothing to clear, the button has nothing to do.
    disabled = next(b for b in view.children if getattr(b, "label", None) == "No focus")
    assert disabled.disabled

    card = harness.run("cultivation", FakeInteraction(user))
    rate = next(f for f in card.fields if "Gained each hour" in f.name)
    # Without the focus penalty: 100 * (1.05 Human + 0.02 starter manual) = 107.
    # The advertised rate has to include what is equipped, or it advertises one
    # number and settle_passive_cultivation pays out another.
    assert "**107** cultivation" in rate.value


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------


def test_paths_groups_by_category(harness, interaction):
    card = harness.run("paths", interaction, category=None)
    names = [f.name for f in card.fields]
    assert any(n.startswith("Combat (27)") for n in names)
    assert any(n.startswith("Exotic (5)") for n in names)


def test_path_reads_both_directions_of_the_chart(harness, user):
    opened = FakeInteraction(user)
    assert harness.run("path", opened).title == "Read a Path"
    card = harness.pick_path(opened.view, "fire", user)
    fields = {f.name: f.value for f in card.fields}
    assert "Wood" in fields["Attacking with it"]
    assert "Water" in fields["Defending against it"]


def test_exotic_path_says_it_is_outside_the_chart(harness, user):
    opened = FakeInteraction(user)
    harness.run("path", opened)
    card = harness.pick_path(opened.view, "dream", user)
    assert any(f.name == "Outside the chart" for f in card.fields)


def test_the_path_picker_stays_attached_for_comparison(harness, user):
    """Picking does not end the view - comparing two Paths is two presses."""
    opened = FakeInteraction(user)
    harness.run("path", opened)
    view = opened.view

    fire = harness.pick_path(view, "fire", user)
    water = harness.pick_path(view, "water", user)
    assert "Fire" in fire.title and "Water" in water.title
    assert not view.is_finished()


def test_tiers_lists_the_whole_ladder(harness, interaction):
    card = harness.run("tiers", interaction)
    assert "Uninitiated" in card.description
    assert "Supreme Grandmaster" in card.description


# ---------------------------------------------------------------------------
# Techniques and the loadout
# ---------------------------------------------------------------------------


@pytest.fixture
def stones(harness, player_id):
    """Enough Spirit Stones to buy a rank 1 technique, and no more.

    Granted rather than earned because /learn is what is under test here, and
    the purse it spends from is filled by half a dozen other screens that have
    their own tests. The exact figure comes from the game so that retuning
    `technique_learn_base` does not quietly make this fixture generous.
    """
    cost = harness.sql("SELECT technique_stone_cost(1::smallint) AS c")["c"]
    harness.execute(
        "SELECT grant_material(%s, 'spirit_stone', %s)", (player_id, cost)
    )
    return cost


def test_the_shelf_is_filtered_by_rank_and_priced(harness, interaction):
    card = harness.run("techniques", interaction, rank=1)
    cost = harness.sql("SELECT technique_stone_cost(1::smallint) AS c")["c"]

    assert "Blood Blade" not in card.description, "the rank filter"
    assert str(cost) in card.description, "every line quotes what it costs"
    assert "rank 1" in card.description


def test_the_shelf_pages_rather_than_dropping_the_rest(harness, interaction):
    """0125 and 0127 took the roster past fifty. A screen that answered with
    one embed would have hit Discord's 4096 characters and lost the tail, which
    is the failure `picking` exists to prevent."""
    names = [
        row["name"]
        for row in harness.sql_all(
            "SELECT name FROM techniques WHERE created_by IS NULL"
        )
    ]

    harness.run("techniques", interaction)
    screen = interaction.view
    assert screen.page_count() > 1, f"{len(names)} techniques should not be one page"

    everything = ""
    for _ in range(screen.page_count()):
        everything += screen.card().description
        screen.page += 1

    missing = [name for name in names if name not in everything]
    assert not missing, f"unreachable by turning pages: {missing}"


def test_a_technique_you_cannot_afford_says_how_short(harness, user, player_id):
    """The refusal a broke cultivator gets has to be a number, not a no."""
    harness.execute(
        "UPDATE player_materials SET quantity = 0 "
        "WHERE player_id = %s AND material_code = 'spirit_stone'",
        (player_id,),
    )
    with pytest.raises(GameError, match="Spirit Stone"):
        harness.run("learn", FakeInteraction(user), technique="ember_lash")


def test_a_refused_learn_costs_nothing(harness, user, player_id):
    """The gates are checked before the stones are taken. A cultivator who is
    told no must be exactly as rich afterwards as before."""
    harness.execute(
        "SELECT grant_material(%s, 'spirit_stone', 100000)", (player_id,)
    )
    before = harness.sql(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (player_id,),
    )["quantity"]

    with pytest.raises(GameError):
        harness.run("learn", FakeInteraction(user), technique="blood_blade")

    after = harness.sql(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (player_id,),
    )["quantity"]
    assert after == before, "a refusal charged for itself"

    harness.execute(
        "UPDATE player_materials SET quantity = 0 "
        "WHERE player_id = %s AND material_code = 'spirit_stone'",
        (player_id,),
    )


def test_technique_shows_dual_path_weights(harness, interaction):
    card = harness.run("technique", interaction, technique="blazing_heaven_sword")
    typing = next(f for f in card.fields if f.name == "Typing")
    assert "Sword Path — 50% of the typing" in typing.value
    assert "Fire Path — 50% of the typing" in typing.value


def test_unknown_code_is_a_player_error(harness, interaction):
    with pytest.raises(GameError, match="no technique"):
        harness.run("technique", interaction, technique="not_a_technique")


def test_learn_is_gated_by_realm(harness, interaction):
    with pytest.raises(GameError, match="rank 6"):
        harness.run("learn", interaction, technique="blood_blade")


def test_learn_then_equip_then_unequip(harness, user, player_id, stones):
    card = harness.run("learn", FakeInteraction(user), technique="crimson_palm")
    assert str(stones) in card.description, "the card says what it cost"

    left = harness.sql(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (player_id,),
    )["quantity"]
    assert left == 0, "the purse actually moved"

    with pytest.raises(GameError, match="already know"):
        harness.run("learn", FakeInteraction(user), technique="crimson_palm")

    card = harness.run("equip", FakeInteraction(user), slot=1, technique="crimson_palm")
    assert "Crimson Palm" in card.description

    card = harness.run("loadout", FakeInteraction(user))
    equipped = next(f for f in card.fields if f.name == "Equipped")
    assert "**Crimson Palm**" in equipped.value

    harness.run("unequip", FakeInteraction(user), slot=1)
    with pytest.raises(GameError, match="already empty"):
        harness.run("unequip", FakeInteraction(user), slot=1)


def test_equipping_something_unknown_is_refused(harness, interaction):
    with pytest.raises(GameError, match="not learned"):
        harness.run("equip", interaction, slot=2, technique="ember_lash")


# ---------------------------------------------------------------------------
# Base stats and creature damage (0015)
# ---------------------------------------------------------------------------


def test_a_fresh_body_is_not_made_of_paper(harness, player_id):
    """Body level 1 used to be 100 HP / 0 defense / 0 strength.

    Defense was structurally unreachable, not merely low: apply_physique_xp
    computed def_rate * (level - 1), and no multiplier can rescue a zero.
    """
    harness.execute(
        "UPDATE player_physique SET physique_xp = 0 WHERE player_id = %s", (player_id,)
    )
    harness.execute("SELECT apply_physique_xp(%s, 0)", (player_id,))
    row = harness.sql(
        "SELECT body_level, max_hp, defense, strength FROM player_physique "
        "WHERE player_id = %s",
        (player_id,),
    )
    assert row["body_level"] == 1
    assert (row["max_hp"], row["defense"], row["strength"]) == (120, 20, 30)


def test_qi_condensation_monsters_hurt_without_destroying(harness, player_id):
    """The actual request: rank 1 is survivable but costs real HP.

    A band rather than two integers. The exact turn count moves whenever
    `defense_scale` or the roster is tuned - 0248 did both - and pinning it
    made this a test of the last balance pass rather than of the thing it is
    named for.
    """
    for code in ("ash_moth", "mire_toad"):
        dmg = harness.sql(
            "SELECT final_damage FROM compute_creature_damage("
            "(SELECT species_id FROM creature_species WHERE code = %s), %s)",
            (code, player_id),
        )["final_damage"]
        assert dmg > 0, f"{code} must be able to hurt you"

        hits = -(-120 // dmg)  # ceil, against a fresh rank 1 body
        assert 4 <= hits <= 20, (
            f"{code} kills a new cultivator in {hits} hits - "
            "that is either a mugging or a nap"
        )


def test_defense_holds_its_value_up_the_ladder(harness, player_id):
    """The premise of this test inverted in 0248.

    It used to assert that defence is worth LESS against a higher rank, which
    was true and was the bug: `creature_defense_scale_per_rank` was 2 while a
    cultivator's defence grew about 1.5x a rank, so the stat decayed from 80%
    of a rank 1 blow to 1.6% of a rank 9 one. The scale is 4 now, matching what
    defence actually grows by, so the stat holds its share instead of
    evaporating - and what is asserted is that the two curves move together.
    """
    step = float(
        harness.sql(
            "SELECT game_config_value('creature_defense_scale_per_rank') AS v"
        )["v"]
    )
    stat = float(
        harness.sql("SELECT game_config_value('stat_step_per_rank') AS v")["v"]
    )

    # A rank of BOTH ladders is what a creature rank is worth, so the scale has
    # to climb by the square of one ladder's step.
    assert step == stat ** 2, (
        f"defence scales {step}x a rank against a cultivator's {stat ** 2}x"
    )

    # Which is to say: a defence stat soaks the same share at every rank.
    soaked = []
    for rank in (1, 5, 9):
        defence = 20 * (stat ** 2) ** (rank - 1)
        dscale = float(
            harness.sql("SELECT game_config_value('defense_scale') AS v")["v"]
        ) * step ** (rank - 1)
        soaked.append(round(defence / (dscale + defence), 3))

    assert len(set(soaked)) == 1, f"the share drifts up the ladder: {soaked}"


def test_creature_damage_mirrors_the_technique_clamps(harness, player_id):
    def dmg(code, defense=None, external=1):
        return harness.sql(
            "SELECT final_damage FROM compute_creature_damage("
            "(SELECT species_id FROM creature_species WHERE code = %s), %s, %s, %s)",
            (code, player_id, external, defense),
        )["final_damage"]

    assert dmg("ash_moth", -500) == dmg("ash_moth", 0), "negative defense cannot amplify"
    assert dmg("ash_moth", 10_000_000) == 1, "a landed hit never rounds below 1"
    assert dmg("ash_moth", 0, 0) == 0, "a zero-power hit deals exactly 0"


def test_hp_regenerates_so_damage_is_not_permanent(harness, player_id):
    """Without this, HP loss would be unrecoverable.

    current_hp had exactly one writer in the whole schema - apply_physique_xp -
    and it only ever added the max_hp delta. `regeneration` sat unused from the
    day it was written. Shipping creature damage without a consumer for it
    would have made four tutorial fights a permanent death sentence.
    """
    harness.execute(
        "UPDATE player_physique SET current_hp = 10 WHERE player_id = %s", (player_id,)
    )
    harness.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '30 minutes' "
        "WHERE player_id = %s",
        (player_id,),
    )
    settled = harness.sql("SELECT * FROM settle_passive_cultivation(%s)", (player_id,))
    assert settled["hp_restored"] == 30, "1 HP/minute for 30 minutes"

    after = harness.sql(
        "SELECT current_hp, max_hp FROM player_physique WHERE player_id = %s",
        (player_id,),
    )
    assert after["current_hp"] == 40

    # And it clamps rather than overshooting the cap.
    harness.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '20 hours' "
        "WHERE player_id = %s",
        (player_id,),
    )
    harness.sql("SELECT * FROM settle_passive_cultivation(%s)", (player_id,))
    full = harness.sql(
        "SELECT current_hp, max_hp FROM player_physique WHERE player_id = %s",
        (player_id,),
    )
    assert full["current_hp"] == full["max_hp"]


# ---------------------------------------------------------------------------
# Bestiary
# ---------------------------------------------------------------------------


def test_study_needs_wisdom_attainment(harness, user, player_id):
    """Deduction is gated behind Wisdom at Expert.

    The attainment is removed and put back rather than relying on the player
    not having reached Expert yet - by this point in the module they have, and
    a gate test that passes only because of test ordering is not a gate test.
    """
    saved = harness.sql(
        "DELETE FROM player_path_attainment "
        "WHERE player_id = %s AND path_code = 'wisdom' "
        "RETURNING insight, tier, dao_marks, seconds_trained",
        (player_id,),
    )
    try:
        with pytest.raises(GameError, match="Expert or better"):
            harness.run(
                "study", FakeInteraction(user), creature="nine_distortion_wolf", path=None
            )
    finally:
        if saved:
            harness.execute(
                "INSERT INTO player_path_attainment "
                "(player_id, path_code, insight, tier, dao_marks, seconds_trained) "
                "VALUES (%s, 'wisdom', %s, %s, %s, %s)",
                (
                    player_id,
                    saved["insight"],
                    saved["tier"],
                    saved["dao_marks"],
                    saved["seconds_trained"],
                ),
            )


def test_study_records_a_deduction(harness, user):
    harness.run("dev insight", FakeInteraction(user), path="wisdom", amount=1000)

    card = harness.run(
        "study", FakeInteraction(user), creature="nine_distortion_wolf", path="sword"
    )
    assert "Sword Path" in card.description
    assert "Resistance" in card.description

    with pytest.raises(GameError, match="already know"):
        harness.run(
            "study", FakeInteraction(user), creature="nine_distortion_wolf", path="sword"
        )


def test_creature_hides_what_has_not_been_discovered(harness, interaction):
    card = harness.run("creature", interaction, creature="nine_distortion_wolf")
    known = next(f for f in card.fields if f.name == "Known reactions")
    assert "Sword" in known.value
    assert "Earth" not in known.value
    assert card.footer.text.startswith("Unknown traits:")


def test_bestiary_counts_unknown_traits(harness, interaction):
    card = harness.run("bestiary", interaction)
    assert "Nine Distortion Wolf" in card.description
    assert "unknown" in card.description


# ---------------------------------------------------------------------------
# The world: travel, gather, hunt
# ---------------------------------------------------------------------------


def test_a_new_character_starts_in_the_central_continent(harness, interaction):
    card = harness.run("where", interaction)
    assert "Central Continent" in card.title


def test_travel_times_grow_with_distance(harness, user):
    """Central is a short hop from anywhere; the opposite corners are the long
    hauls. North to south must cost more than north to central."""
    opened = FakeInteraction(user)
    harness.run("travel", opened)
    view = opened.view
    hours = {d["code"]: float(d["hours"]) for d in view.destinations}

    # The heavens are not on the continent - each is twelve hours from
    # anywhere, because what is being crossed is the gap and not the ground.
    # Read from the schema rather than listed, so a third heaven does not
    # break a test about the continent.
    heavens = {
        r["code"] for r in harness.sql_all(
            "SELECT code FROM regions WHERE min_rank > 1"
        )
    }
    assert heavens, "no gated region to check"
    assert set(hours) == {"northern", "southern", "eastern", "western"} | heavens
    assert all(hours[h] == 12 for h in heavens)
    assert all(
        h == 2 for code, h in hours.items() if code not in heavens
    ), "all four of the continent are adjacent to Central"

    # And from an edge, the far edge costs three times as much.
    assert float(harness.sql("SELECT travel_hours('northern','southern') AS h")["h"]) == 6
    assert float(harness.sql("SELECT travel_hours('northern','central') AS h")["h"]) == 2
    assert float(harness.sql("SELECT travel_hours('eastern','western') AS h")["h"]) == 6
    # Distance is symmetric because the pair is stored once.
    assert (harness.sql("SELECT travel_hours('northern','western') AS h")["h"]
            == harness.sql("SELECT travel_hours('western','northern') AS h")["h"])


def test_you_can_work_the_road_you_are_on(harness, user, player_id):
    """Travelling used to refuse every world command, which made a six-hour
    road six hours of nothing. Only a second journey is refused now - the
    country does not empty because you have somewhere to be.
    """
    opened = FakeInteraction(user)
    harness.run("travel", opened)
    north = next(b for b in opened.view.children if b.region["code"] == "northern")
    card = harness.click(north, FakeInteraction(user))
    assert "Northern Plains" in card.title

    where_from = harness.sql(
        "SELECT region_code FROM player_location WHERE player_id = %s", (player_id,)
    )["region_code"]

    for command in ("gather", "mine", "explore"):
        opened = FakeInteraction(user)
        harness.run(command, opened)
        # The tables are the ones you set out from, and the screen says so
        # rather than leaving somebody to wonder why the Northern Plains are
        # full of the country they just left.
        assert "On the road" in opened.last.description
        assert "Northern Plains" in opened.last.description

    # A second journey is still refused, which is the one thing travel means.
    with pytest.raises(GameError, match="on the road"):
        harness.run("travel", FakeInteraction(user))

    harness.run("dev arrive", FakeInteraction(user))
    assert harness.sql(
        "SELECT region_code FROM player_location WHERE player_id = %s", (player_id,)
    )["region_code"] == "northern" != where_from


def work(harness, user, command: str, times: int = 1):
    """Open a seam and take `times` tries, returning the last card.

    Since 0081 a world command opens FIVE tries behind one cooldown and each is
    a button press, so a test that wants a material has to press for it.
    """
    opened = FakeInteraction(user)
    harness.run(command, opened)
    button = opened.view.children[0]
    card = None
    for _ in range(times):
        card = harness.click(button, FakeInteraction(user))
    return card


def test_gather_yields_only_gathering_materials(harness, user, player_id):
    """The two economies are disjoint: foraging must never produce a fang."""
    harness.run("dev ready", FakeInteraction(user))
    work(harness, user, "gather", times=5)

    rows = harness.sql(
        """
        SELECT count(*) FILTER (WHERE m.category = 'gathering') AS gathering,
               count(*) FILTER (WHERE m.category = 'beast')     AS beast
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        WHERE pm.player_id = %s
        """,
        (player_id,),
    )
    assert rows["gathering"] > 0
    assert rows["beast"] == 0, "gathering must not produce beast materials"


def test_gather_is_on_a_cooldown_once_the_set_is_spent(harness, user):
    """The cooldown now bites at the END of a set, not the start of one -
    running the command again while tries remain RESUMES rather than refuses,
    which is what makes a disconnect free."""
    harness.run("dev ready", FakeInteraction(user))
    work(harness, user, "gather", times=1)

    again = FakeInteraction(user)
    harness.run("gather", again)
    assert "Tries left" in [f.name for f in again.last.fields], "it should resume"

    work(harness, user, "gather", times=4)
    with pytest.raises(GameError, match="Not yet"):
        harness.run("gather", FakeInteraction(user))


def choose(harness, select, value, interaction):
    """Use a select the way Discord does: the values arrive on the component."""
    select._values = [str(value)]
    return harness.click(select, interaction)


def clear_battle(harness, player_id):
    """Leave no fight behind. A live claim would refuse every later /hunt."""
    battle_id = harness.sql(
        "SELECT battle_id FROM player_active_battle WHERE player_id = %s", (player_id,)
    )
    if battle_id:
        harness.execute("SELECT battle_abandon(%s)", (battle_id["battle_id"],))


@pytest.fixture
def no_ambush(harness):
    """Rogues interrupt one hunt in ten. A battle test wants the other nine.

    The chance is a game_config row, so the fixture moves the game's own dial
    rather than monkeypatching anything - and puts it back.
    """
    harness.execute("UPDATE game_config SET value = 0 WHERE key = 'rogue_spawn_chance'")
    try:
        yield
    finally:
        harness.execute(
            "UPDATE game_config SET value = 0.10 WHERE key = 'rogue_spawn_chance'"
        )


def start_hunt(harness, user, player_id, *, sturdy=False):
    """Open a fight. `sturdy` leaves something that survives being hit.

    0248 put every technique on a four-times-a-major-realm ladder, so the
    fixture player can now delete a rank 1 creature in one blow - which ends
    any test that wanted a second round, intermittently, depending on which
    technique happens to be first in the loadout.
    """
    # Whatever the last test left behind. Every caller cleans up in a `finally`,
    # but the harness player is shared by the whole module and one ordering that
    # slips through leaves `/hunt` refusing for the rest of the run - which
    # surfaces as "You are not fighting anything" in some unrelated test.
    clear_battle(harness, player_id)

    # Fight in the Central Continent, where everything is rank 1. The Northern
    # Plains holds a rank 5 wolf that ends a level 1 character in one swing -
    # and ends any test that assumed there would be a second round.
    harness.execute(
        "UPDATE player_location SET region_code = 'central' WHERE player_id = %s",
        (player_id,),
    )
    harness.execute(
        "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s", (player_id,)
    )
    harness.run("dev ready", FakeInteraction(user))
    opened = FakeInteraction(user)
    card = harness.run("hunt", opened)

    if sturdy:
        harness.execute(
            """
            UPDATE battle_combatants SET current_hp = 10000000, max_hp = 10000000
            WHERE battle_id = (SELECT battle_id FROM player_active_battle
                               WHERE player_id = %s)
              AND combatant_no = 1
            """,
            (player_id,),
        )

    return card, opened.view


def test_hunt_opens_a_battle_rather_than_resolving_one(harness, user, player_id, no_ambush):
    """The fight is a row in `battles`, and this is the window onto it.

    0007 built every column this needs - status, turn_number, current_qi, the
    one-fight-at-a-time claim - and 0017's hunt() resolved fifty turns in one
    call before anyone could look at it.
    """
    try:
        card, view = start_hunt(harness, user, player_id)

        assert "Round **1**" in card.description
        body = "\n".join(f.value for f in card.fields)
        assert "HP" in body and "Qi" in body
        assert "Next:" in body, "the creature telegraphs before you choose"

        labels = {getattr(b, "label", None) for b in view.children}
        assert {"Observe", "Guard", "Flee"} <= labels
        assert "Killer Move" in labels
        killer = next(b for b in view.children if getattr(b, "label", None) == "Killer Move")
        assert killer.disabled, "not built yet, and the button says so"

        select = next(i for i in view.children if isinstance(i, discord.ui.Select))
        assert select.options, "your attack moves are what your manuals unlock"

        claimed = harness.sql(
            "SELECT battle_id FROM player_active_battle WHERE player_id = %s", (player_id,)
        )
        assert claimed is not None
    finally:
        clear_battle(harness, player_id)


def test_a_round_costs_qi_and_the_creature_answers(harness, user, player_id, no_ambush):
    try:
        # This test is about what a round costs and what answers, not about
        # how hard anybody hits.
        card, view = start_hunt(harness, user, player_id, sturdy=True)
        before = harness.sql(
            """
            SELECT me.current_qi, me.current_hp,
                   it.current_hp AS creature_hp
            FROM battle_combatants me
            JOIN battle_combatants it
              ON it.battle_id = me.battle_id AND it.combatant_no = 1
            WHERE me.battle_id = (SELECT battle_id FROM player_active_battle
                                  WHERE player_id = %s)
              AND me.combatant_no = 0
            """,
            (player_id,),
        )

        select = next(i for i in view.children if isinstance(i, discord.ui.Select))
        card = choose(harness, select, select.options[0].value, FakeInteraction(user))

        after = harness.sql(
            """
            SELECT me.current_qi, me.current_hp, it.current_hp AS creature_hp, b.turn_number
            FROM battles b
            JOIN battle_combatants me ON me.battle_id = b.battle_id AND me.combatant_no = 0
            JOIN battle_combatants it ON it.battle_id = b.battle_id AND it.combatant_no = 1
            WHERE b.battle_id = (SELECT battle_id FROM player_active_battle WHERE player_id = %s)
            """,
            (player_id,),
        )
        # qi_cost_pct has been on every technique since 0004 with nothing
        # reading it. A battle pool is what finally spends it.
        assert after["current_qi"] < before["current_qi"], "an attack costs qi"
        # Against what it had, not against a number from a past balance pass.
        assert after["creature_hp"] < before["creature_hp"], "the creature took the hit"
        assert after["turn_number"] == 2
        assert after["current_hp"] < before["current_hp"], "it answered"
    finally:
        clear_battle(harness, player_id)


def test_guarding_halves_the_blow_and_returns_qi(harness, user, player_id, no_ambush):
    """Guard is the reason the enemy's move is telegraphed at all."""
    try:
        # Sturdy: this reopens the fight after attacking, so the creature has
        # to still be in it.
        card, view = start_hunt(harness, user, player_id, sturdy=True)
        battle_id = harness.sql(
            "SELECT battle_id FROM player_active_battle WHERE player_id = %s", (player_id,)
        )["battle_id"]

        select = next(i for i in view.children if isinstance(i, discord.ui.Select))
        choose(harness, select, select.options[0].value, FakeInteraction(user))

        spent = harness.sql(
            "SELECT current_qi FROM battle_combatants "
            "WHERE battle_id = %s AND combatant_no = 0",
            (battle_id,),
        )["current_qi"]

        # The view was rebuilt after the attack, so take a fresh one the way a
        # player would - by reopening the fight.
        guard = next(b for b in _live_view(harness, user, player_id).children
                     if getattr(b, "label", None) == "Guard")
        harness.click(guard, FakeInteraction(user))

        restored = harness.sql(
            "SELECT current_qi FROM battle_combatants "
            "WHERE battle_id = %s AND combatant_no = 0",
            (battle_id,),
        )["current_qi"]
        assert restored > spent, "guarding is how qi comes back mid-fight"

        rounds = harness.sql(
            "SELECT damage, detail FROM battle_actions "
            "WHERE battle_id = %s AND actor_no = 1 ORDER BY action_id DESC LIMIT 1",
            (battle_id,),
        )
        assert rounds["detail"]["guarded"] is True
    finally:
        clear_battle(harness, player_id)


def fight_to_the_end(harness, user, view, limit=60):
    """Play the fight out.

    A round is one action, so a kill takes as many rounds as it takes - which
    is the entire point of the screen. Running dry of qi is not a loss: guard
    and it comes back.
    """
    card = None
    for _ in range(limit):
        select = next(
            (i for i in view.children if isinstance(i, discord.ui.Select)), None
        )
        if select is None:
            break
        try:
            card = choose(harness, select, select.options[0].value, FakeInteraction(user))
        except GameError:
            guard = next(
                b for b in view.children if getattr(b, "label", None) == "Guard"
            )
            card = harness.click(guard, FakeInteraction(user))
        if view.is_finished():
            break
    return card


def _live_view(harness, user, player_id):
    """The battle screen as /battle would draw it right now."""
    opened = FakeInteraction(user)
    harness.run("battle", opened)
    return opened.view


def test_observing_reads_one_weakness_and_costs_the_round(harness, user, player_id, no_ambush):
    try:
        card, view = start_hunt(harness, user, player_id)
        species_id = harness.sql(
            "SELECT species_id FROM battle_combatants bc "
            "JOIN player_active_battle pab ON pab.battle_id = bc.battle_id "
            "WHERE pab.player_id = %s AND bc.combatant_no = 1",
            (player_id,),
        )["species_id"]
        known = harness.sql(
            "SELECT count(*) AS n FROM player_bestiary_paths "
            "WHERE player_id = %s AND species_id = %s",
            (player_id, species_id),
        )["n"]
        total = harness.sql(
            "SELECT count(*) AS n FROM creature_incoming_paths WHERE species_id = %s",
            (species_id,),
        )["n"]

        observe = next(b for b in view.children if getattr(b, "label", None) == "Observe")
        harness.click(observe, FakeInteraction(user))

        after = harness.sql(
            "SELECT count(*) AS n FROM player_bestiary_paths "
            "WHERE player_id = %s AND species_id = %s",
            (player_id, species_id),
        )["n"]
        if total > known:
            assert after == known + 1, "observing learns exactly one thing"

        # It still swung: information is not free.
        swung = harness.sql(
            "SELECT count(*) AS n FROM battle_actions ba "
            "JOIN player_active_battle pab ON pab.battle_id = ba.battle_id "
            "WHERE pab.player_id = %s AND ba.actor_no = 1",
            (player_id,),
        )["n"]
        assert swung >= 1
    finally:
        clear_battle(harness, player_id)


def test_fleeing_ends_the_fight(harness, user, player_id, no_ambush):
    """The roll is realm difference; the test pins it so the outcome is not.

    All three dials, not just the base: the rank term still applies underneath.
    Pinning only the base left a 28% escape against the rank 5 wolf the region
    can produce - 1 + 0.18 x (1 - 5) - and the test failed the moment the draw
    turned one up.
    """
    for key in ("flee_base_chance", "flee_min_chance", "flee_max_chance"):
        harness.execute("UPDATE game_config SET value = 1 WHERE key = %s", (key,))
    try:
        card, view = start_hunt(harness, user, player_id)
        flee = next(b for b in view.children if getattr(b, "label", None) == "Flee")
        card = harness.click(flee, FakeInteraction(user))

        assert "got away" in card.title
        assert harness.sql(
            "SELECT battle_id FROM player_active_battle WHERE player_id = %s", (player_id,)
        ) is None, "fleeing releases the claim"
    finally:
        for key, value in (
            ("flee_base_chance", "0.45"),
            ("flee_min_chance", "0.05"),
            ("flee_max_chance", "0.95"),
        ):
            harness.execute(
                "UPDATE game_config SET value = %s WHERE key = %s", (value, key)
            )
        clear_battle(harness, player_id)


def test_a_battle_outlives_its_view(harness, user, player_id, no_ambush):
    """A timed-out view, a restarted bot and a lost message are all the same
    thing to a fight that lives in the database."""
    try:
        card, view = start_hunt(harness, user, player_id)
        opened = harness.sql(
            "SELECT battle_id FROM player_active_battle WHERE player_id = %s", (player_id,)
        )["battle_id"]

        resumed = FakeInteraction(user)
        again = harness.run("battle", resumed)
        assert "Round" in again.description
        assert resumed.view is not None

        still = harness.sql(
            "SELECT battle_id FROM player_active_battle WHERE player_id = %s", (player_id,)
        )["battle_id"]
        assert still == opened, "resuming does not start a second fight"
    finally:
        clear_battle(harness, player_id)


def test_only_one_fight_at_a_time(harness, user, player_id, no_ambush):
    try:
        start_hunt(harness, user, player_id)
        harness.run("dev ready", FakeInteraction(user))
        with pytest.raises(GameError, match="already in a fight"):
            harness.run("hunt", FakeInteraction(user))
    finally:
        clear_battle(harness, player_id)


def test_winning_pays_out_and_releases_the_claim(harness, user, player_id, no_ambush):
    """The kill is where the drops, the bestiary and the claim all land."""
    before = harness.sql(
        "SELECT physique_xp FROM player_physique WHERE player_id = %s", (player_id,)
    )["physique_xp"]
    try:
        harness.execute(
            "UPDATE player_physique SET physique_xp = 2000000 WHERE player_id = %s",
            (player_id,),
        )
        harness.execute("SELECT apply_physique_xp(%s, 0)", (player_id,))

        card, view = start_hunt(harness, user, player_id)
        card = fight_to_the_end(harness, user, view)

        assert "You killed the " in card.title
        assert any("Taken from the body" in f.name for f in card.fields)
        assert harness.sql(
            "SELECT battle_id FROM player_active_battle WHERE player_id = %s", (player_id,)
        ) is None

        killed = harness.sql(
            "SELECT sum(times_defeated) AS n FROM player_bestiary WHERE player_id = %s",
            (player_id,),
        )
        assert killed["n"] >= 1
    finally:
        harness.execute(
            "UPDATE player_physique SET physique_xp = %s WHERE player_id = %s",
            (before, player_id),
        )
        harness.execute("SELECT apply_physique_xp(%s, 0)", (player_id,))
        clear_battle(harness, player_id)


def test_hunting_has_a_cooldown(harness, user, player_id, no_ambush):
    """hunt_cooldown_minutes sat in game_config since 0017 with nothing reading
    it. A menu you could reopen forever had no use for one; a command that
    starts a fight the moment you type it does."""
    try:
        start_hunt(harness, user, player_id)
        with pytest.raises(GameError, match="Not yet"):
            harness.run("hunt", FakeInteraction(user))
    finally:
        clear_battle(harness, player_id)


def test_an_ambush_opens_the_same_battle_screen(harness, user, player_id):
    """A rogue cultivator is a creature_species row, so the fight they start is
    the fight a hunt starts. Only what falls off the body differs."""
    harness.execute("UPDATE game_config SET value = 1 WHERE key = 'rogue_spawn_chance'")
    try:
        harness.execute(
            "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s",
            (player_id,),
        )
        harness.run("dev ready", FakeInteraction(user))
        opened = FakeInteraction(user)
        card = harness.run("hunt", opened)
        assert "steps out of the treeline" in card.description

        fight = next(
            b for b in opened.view.children if getattr(b, "label", None) == "Fight"
        )
        pressed = FakeInteraction(user)
        card = harness.click(fight, pressed)
        assert "Round **1**" in card.description
        assert "Rogue cultivator" in card.description

        kind = harness.sql(
            """
            SELECT s.kind FROM player_active_battle pab
            JOIN battle_combatants bc
                ON bc.battle_id = pab.battle_id AND bc.combatant_no = 1
            JOIN creature_species s ON s.species_id = bc.species_id
            WHERE pab.player_id = %s
            """,
            (player_id,),
        )
        assert kind["kind"] == "rogue"
    finally:
        harness.execute(
            "UPDATE game_config SET value = 0.10 WHERE key = 'rogue_spawn_chance'"
        )
        clear_battle(harness, player_id)


def test_hunting_at_zero_hp_is_refused(harness, user, player_id):
    harness.execute(
        "UPDATE player_physique SET current_hp = 0 WHERE player_id = %s", (player_id,)
    )
    harness.run("dev ready", FakeInteraction(user))
    with pytest.raises(GameError, match="nothing left to fight"):
        harness.run("hunt", FakeInteraction(user))
    harness.execute(
        "UPDATE player_physique SET current_hp = max_hp WHERE player_id = %s", (player_id,)
    )


def satchel_shelf(view, code: str) -> str:
    """Everything on one shelf of an open /inventory, pages and all.

    The satchel shows one shelf at a time now, so a test that read embed
    fields was reading the shape rather than the contents. Turning the pages
    is also the only way to assert the thing that matters most about this
    screen: that nothing on a shelf is unreachable.
    """
    view.shelf = code
    view.page = 0
    view.build()
    text = ""
    for _ in range(view.page_count()):
        text += view.card().description or ""
        view.page += 1
    return text


def test_inventory_separates_the_two_economies(harness, user):
    opened = FakeInteraction(user)
    harness.run("inventory", opened, category=None)
    labels = [b.label for b in opened.view.children if hasattr(b, "code")]
    assert any("Gathering" in (label or "") for label in labels)


# ---------------------------------------------------------------------------
# Manuals and equipment (0021)
# ---------------------------------------------------------------------------


def test_equipment_page_opens_with_empty_slots(harness, user, player_id):
    harness.execute("DELETE FROM player_manual_slots WHERE player_id = %s", (player_id,))
    harness.execute("DELETE FROM player_manuals WHERE player_id = %s", (player_id,))
    card = harness.run("equipment", FakeInteraction(user))
    manual = next(f for f in card.fields if "Manual" in f.name)
    assert manual.value.count("*empty*") == 2


def test_the_equipment_page_lists_every_real_slot(harness, user, player_id):
    """It used to carry seven hardcoded names under "Not implemented yet",
    three of which were shipped features - so a player wearing armour was told
    armour did not exist. The slots are read from the table now, and this
    fails if the two ever disagree again."""
    card = harness.run("equipment", FakeInteraction(user))
    forged = next(f for f in card.fields if "Forged" in f.name)

    for row in harness.sql_all("SELECT name FROM equipment_slots"):
        assert row["name"] in forged.value, row["name"]

    assert "Not implemented" not in str(card.to_dict())
    assert any("Aperture" in f.name for f in card.fields), "Gu shipped in 0036"


def test_a_bare_slot_says_what_to_do_about_it(harness, user, player_id):
    card = harness.run("equipment", FakeInteraction(user))
    forged = next(f for f in card.fields if "Forged" in f.name)
    assert "*bare*" in forged.value and "/forge" in forged.value


def test_worn_armour_shows_up_on_the_equipment_page(harness, user, player_id):
    """The screen the report came in about: forge a piece of armour, wear it,
    and the page must name it rather than calling the slot unbuilt."""
    ore = harness.sql("SELECT material_code FROM ores ORDER BY tier LIMIT 1")
    part = harness.sql("SELECT material_code FROM beast_parts LIMIT 1")
    harness.execute(
        "SELECT grant_material(%s, %s, 100)", (player_id, ore["material_code"])
    )
    harness.execute(
        "SELECT grant_material(%s, %s, 100)", (player_id, part["material_code"])
    )

    made = harness.sql(
        "SELECT * FROM forge(%s, 'armour', ARRAY[%s], ARRAY[40], ARRAY[%s], ARRAY[30])",
        (player_id, ore["material_code"], part["material_code"]),
    )
    assert made["succeeded"], "the anvil refused, so the test proves nothing"
    harness.execute("SELECT equip(%s, %s)", (player_id, made["equipment_id"]))
    try:
        card = harness.run("equipment", FakeInteraction(user))
        forged = next(f for f in card.fields if "Forged" in f.name)
        armour = next(l for l in forged.value.splitlines() if "Armour" in l)
        assert made["item_name"] in armour
        assert "bare" not in armour
    finally:
        harness.execute(
            "DELETE FROM player_equipped WHERE player_id = %s AND slot = 'armour'",
            (player_id,),
        )
        harness.execute(
            "DELETE FROM player_equipment WHERE equipment_id = %s",
            (made["equipment_id"],),
        )


def test_the_binder_lists_only_what_can_be_unbound(harness, user, player_id):
    """Equipped manuals are left off the screen as well as refused by the SQL,
    so that "All tier 1" can never mean "and the one you are reading"."""
    card = harness.run("unbind", FakeInteraction(user))

    equipped = {
        r["manual_id"]
        for r in harness.sql_all(
            "SELECT manual_id FROM player_manual_slots WHERE player_id = %s",
            (player_id,),
        )
    }
    from bot.cogs.manuals import fetch_unbindable

    listed = {r["manual_id"] for r in harness.runner.run(fetch_unbindable(player_id))}
    assert not (listed & equipped)
    assert "Binder" in card.title


def test_the_band_button_takes_the_whole_tier(harness, user, player_id):
    """The bulk half. Picking eleven Tier 1 manuals out of a select one at a
    time is the same chore with more presses."""
    # Made here rather than borrowed from the shared shelf, which may hold
    # nothing unbindable depending on what ran before.
    made = []
    for _ in range(3):
        row = harness.sql(
            "INSERT INTO manuals (name, tier, created_by, refined_at, harmony) "
            "VALUES ('Binder Test', 1, %s, now(), 60) RETURNING manual_id",
            (player_id,),
        )
        harness.execute(
            "INSERT INTO manual_paths (manual_id, path_code) VALUES (%s, 'fire')",
            (row["manual_id"],),
        )
        harness.execute(
            "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
            (player_id, row["manual_id"]),
        )
        made.append(row["manual_id"])

    try:
        opened = FakeInteraction(user)
        harness.run("unbind", opened)
        view = opened.view

        expected = {r["manual_id"] for r in view.rows if r["tier"] == 1}
        assert set(made) <= expected, "the new books are on the shelf"

        button = next(
            b for b in view.children
            if getattr(b, "label", "").startswith("All tier 1")
        )
        pressed = FakeInteraction(user)
        card = harness.click(button, pressed)

        # The press confirms rather than destroys: nothing is spent until the
        # second screen says so.
        assert "Unbind" in card.title
        assert str(len(expected)) in card.title
        assert harness.sql(
            "SELECT count(*) AS n FROM player_manuals WHERE manual_id = ANY(%s)",
            (made,),
        )["n"] == 3, "still on the shelf until confirmed"
    finally:
        harness.execute(
            "DELETE FROM player_manuals WHERE manual_id = ANY(%s)", (made,)
        )


def test_manuals_refuses_when_you_have_none(harness, user):
    with pytest.raises(GameError, match="no manuals"):
        harness.run("manuals", FakeInteraction(user))


def test_equipping_manuals_speeds_cultivation_additively(harness, user, player_id, headroom):
    """Two manuals at +3% and +12% must make +15%, not +15.36%.

    Every bonus in this game is an additive fraction for exactly this reason -
    multiplying independent percentages is how a build ends up accidentally
    several times stronger than intended.
    """
    for slot, code in ((0, "crimson_palm_canon"), (1, "thousand_thought_soul_canon")):
        harness.execute(
            "INSERT INTO player_manuals (player_id, manual_id) "
            "SELECT %s, manual_id FROM manuals WHERE code = %s",
            (player_id, code),
        )
        harness.execute(
            "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
            "SELECT %s, %s, manual_id FROM manuals WHERE code = %s",
            (player_id, slot, code),
        )

    bonus = harness.sql(
        "SELECT cultivation_rate_bonus FROM player_manual_bonuses WHERE player_id = %s",
        (player_id,),
    )
    # Crimson Palm Canon is T1 (2% of its 6% budget on cultivation), Thousand
    # Thought is T4 (13% of 21%). Additive: 15%.
    assert float(bonus["cultivation_rate_bonus"]) == 0.15

    # Settle a known span and check the payout moved by exactly the bonus.
    harness.execute("SELECT settle_passive_cultivation(%s)", (player_id,))
    harness.execute(
        "UPDATE player_cultivation SET last_tick_at = now() - interval '10 hours' "
        "WHERE player_id = %s",
        (player_id,),
    )
    settled = harness.sql("SELECT * FROM settle_passive_cultivation(%s)", (player_id,))

    # 10h * 100/hr * (1.05 Human + 0.15 manuals), times the realm's draw.
    # The 1.20 is the claim; the realm term is read rather than frozen.
    scale = float(harness.sql(
        "SELECT realm_cultivation_scale(r.rank) AS s "
        "FROM player_cultivation pc JOIN realms r ON r.realm_id = pc.realm_id "
        "WHERE pc.player_id = %s",
        (player_id,),
    )["s"])
    assert settled["cultivation_gained"] == round(10 * 100 * 1.20 * scale)


def test_every_seeded_manual_spends_its_tier_budget(harness):
    """Higher tier must mean higher total percentage, and the split across
    stats is the manual's business - the total is the tier's.

    Seeded content is the content with a stable `code`. It used to be selected
    by `created_by IS NULL`, which stopped meaning that in 0033: a refined
    manual whose maker closed their account has a NULL maker and a harmony,
    and is allowed to spend more than its budget.
    """
    rows = harness.runner.run(db.fetch_all(
        """
        SELECT m.tier, m.name, m.archetype, mt.bonus_budget,
               manual_total_bonus(m.manual_id) AS spent
        FROM manuals m JOIN manual_tiers mt ON mt.tier = m.tier
        WHERE m.code IS NOT NULL
        ORDER BY m.tier
        """
    ))
    assert rows, "no seeded manuals"
    for row in rows:
        # Every seeded manual spends its tier in full, technique books
        # included. 0130 wrote them at half - the other half notionally paid
        # for the move - and 0187 undid that: it made the rarest drop in the
        # game the weakest thing of its tier, a tier 6 Canon paying 0.18
        # against a stat manual's 0.36. What keeps a technique manual honest
        # is the move's own realm gate, not a thinner book.
        #
        # Exactly the budget, not "at most", so a typo in one of the eighteen
        # is still caught rather than waved through as deliberate restraint.
        assert row["spent"] == row["bonus_budget"], (
            f"{row['name']} (T{row['tier']}, {row['archetype']}) spends "
            f"{row['spent']} of a {row['bonus_budget']} budget"
        )


def test_the_tier_curve_only_goes_up(harness):
    budgets = harness.runner.run(db.fetch_all(
        "SELECT tier, bonus_budget FROM manual_tiers ORDER BY tier"
    ))
    values = [float(r["bonus_budget"]) for r in budgets]
    # Fifteen since 0379 took the ladder past the Pinnacle Mortal World rung.
    # Counted rather than listed, because what matters is that every rung
    # beats the one below it, and a count that has to be edited is the cheap
    # half of that.
    assert len(values) == 15
    assert values == sorted(values)
    assert all(b > a for a, b in zip(values, values[1:])), "a tier must beat the one below"


def test_attack_bonus_reaches_the_damage_pipeline(harness, player_id):
    """A manual's attack percentage arrives through the same external hook
    0008 left for equipment, unweighted by Path - it is a fact about how hard
    you hit, not about a Path."""
    def multiplier():
        return float(harness.sql(
            "SELECT player_external_multiplier(%s, "
            "(SELECT technique_id FROM techniques WHERE code='crimson_palm')) AS m",
            (player_id,),
        )["m"])

    before = multiplier()
    restore = harness.sql(
        "SELECT manual_id FROM player_manual_slots "
        "WHERE player_id = %s AND slot_index = 0",
        (player_id,),
    )

    harness.execute(
        "INSERT INTO player_manuals (player_id, manual_id) "
        "SELECT %s, manual_id FROM manuals WHERE code = 'blood_blade_scripture' "
        "ON CONFLICT DO NOTHING",
        (player_id,),
    )
    try:
        harness.execute(
            "UPDATE player_manual_slots SET manual_id = "
            "(SELECT manual_id FROM manuals WHERE code = 'blood_blade_scripture') "
            "WHERE player_id = %s AND slot_index = 0",
            (player_id,),
        )
        # Blood Blade Scripture is T6 and spends 24% of its 36% budget on
        # attack. Slot 0 previously held the T1 Crimson Palm Canon at +4%, so
        # this is a swap - assert the absolute multiplier rather than a delta,
        # which would be measuring the difference between two manuals.
        assert before == 1.04
        assert multiplier() == 1.24
    finally:
        # This module's tests share one character, so anything borrowed has to
        # go back - four later tests read the damage pipeline.
        if restore:
            harness.execute(
                "UPDATE player_manual_slots SET manual_id = %s "
                "WHERE player_id = %s AND slot_index = 0",
                (restore["manual_id"], player_id),
            )
        else:
            harness.execute(
                "DELETE FROM player_manual_slots "
                "WHERE player_id = %s AND slot_index = 0",
                (player_id,),
            )


def test_an_equipped_manual_unlocks_its_technique(harness, player_id):
    """Unlocking is a view over the slots, not a copy into player_techniques -
    so unequipping withdraws access with no bookkeeping to get wrong.

    The subject has to be a technique this character has NOT learned. It used
    to be `crimson_palm`, which an earlier test in this progression buys - and
    once 0143 stopped listing a technique twice for somebody who both owns and
    borrows it, the row correctly came back as `learned` and this read zero.
    That was the fix working, not the unlock breaking.
    """
    borrowed = harness.sql(
        """
        SELECT m.manual_id, t.technique_id, t.name
        FROM manuals m
        JOIN manual_techniques mt ON mt.manual_id = m.manual_id
        JOIN techniques t ON t.technique_id = mt.technique_id
        WHERE m.code IS NOT NULL AND t.rank = 1
          AND NOT EXISTS (
              SELECT 1 FROM player_techniques pt
              WHERE pt.player_id = %s AND pt.technique_id = t.technique_id
          )
        LIMIT 1
        """,
        (player_id,),
    )
    assert borrowed is not None, "no manual teaches something this character lacks"

    already = harness.sql(
        "SELECT 1 AS owned FROM player_manuals WHERE player_id = %s AND manual_id = %s",
        (player_id, borrowed["manual_id"]),
    )
    harness.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s) "
        "ON CONFLICT DO NOTHING",
        (player_id, borrowed["manual_id"]),
    )
    was = harness.sql(
        "SELECT manual_id FROM player_manual_slots "
        "WHERE player_id = %s AND slot_index = 1",
        (player_id,),
    )
    harness.execute(
        """
        INSERT INTO player_manual_slots (player_id, slot_index, manual_id)
        VALUES (%s, 1, %s)
        ON CONFLICT (player_id, slot_index)
        DO UPDATE SET manual_id = EXCLUDED.manual_id
        """,
        (player_id, borrowed["manual_id"]),
    )
    try:
        lent = harness.sql(
            "SELECT source FROM player_usable_techniques "
            "WHERE player_id = %s AND technique_id = %s",
            (player_id, borrowed["technique_id"]),
        )
        assert lent is not None and lent["source"] == "manual", (
            f"{borrowed['name']} should be on loan from the equipped book"
        )

        harness.execute(
            "DELETE FROM player_manual_slots WHERE player_id = %s AND slot_index = 1",
            (player_id,),
        )
        gone = harness.sql(
            "SELECT source FROM player_usable_techniques "
            "WHERE player_id = %s AND technique_id = %s",
            (player_id, borrowed["technique_id"]),
        )
        assert gone is None, "unequipping did not withdraw the loan"
    finally:
        # This module shares one character and later tests read the pipeline.
        if was:
            harness.execute(
                """
                INSERT INTO player_manual_slots (player_id, slot_index, manual_id)
                VALUES (%s, 1, %s)
                ON CONFLICT (player_id, slot_index)
                DO UPDATE SET manual_id = EXCLUDED.manual_id
                """,
                (player_id, was["manual_id"]),
            )
        # And the book goes back on the shelf. Leaving it owned made
        # test_only_two_manuals_can_be_equipped collide on its own INSERT
        # further down the file - a borrowed fixture that was never returned.
        if not already:
            harness.execute(
                "DELETE FROM player_manuals WHERE player_id = %s AND manual_id = %s",
                (player_id, borrowed["manual_id"]),
            )


def test_a_technique_both_owned_and_borrowed_is_listed_once(harness, player_id):
    """pashu0 spent a morning stuck against a live creature because of this.

    `player_usable_techniques` was a UNION whose halves differ in `source`, so
    a technique you had learned AND had an equipped manual for came back twice.
    The battle screen builds its move select from that list, and Discord
    refuses the whole message for two options with the same value:

        400 Bad Request (50035): The specified option value is already used

    So the fight could not be drawn at all, and /battle - the command the bot
    told them to resume with - failed every time they ran it.
    """
    doubled = harness.sql_all(
        """
        SELECT u.player_id, u.technique_id, count(*) AS n
        FROM player_usable_techniques u
        GROUP BY u.player_id, u.technique_id
        HAVING count(*) > 1
        """
    )
    assert doubled == [], f"a technique is listed twice: {doubled}"


def test_the_equipment_page_shows_what_is_carried(harness, user, player_id):
    card = harness.run("equipment", FakeInteraction(user))
    manual = next(f for f in card.fields if "Manual" in f.name)
    assert "Thousand Thought Soul Canon" in manual.value

    worth = next(f for f in card.fields if f.name == "What they are worth")
    # Both slots are filled by now: Crimson Palm Canon is T1 and spends 2 of a
    # 6% budget on cultivation, Thousand Thought is T4 and spends 13 of 21.
    # Additive, so 15.
    #
    # This read 13 until the unlock test above stopped emptying slot 0 as a
    # side effect of testing something else. The figure was only ever right
    # because of that, which is the kind of agreement between two tests that
    # holds until one of them is rewritten for its own reasons.
    assert "Cultivation Speed: +15%" in worth.value

    # And each equipped manual says what IT gives, not only the pair's total -
    # a sum is no help in deciding which of the two to swap out.
    assert "Cultivation Speed" in manual.value or "%" in manual.value


def test_manual_reading(harness, user):
    card = harness.run("manual", FakeInteraction(user), manual="blood_blade_scripture")
    assert card.title == "Blood Blade Scripture"
    unlocks = next(f for f in card.fields if f.name == "Unlocks")
    assert "Blood Blade" in unlocks.value


def test_only_two_manuals_can_be_equipped(harness, player_id):
    """The limit is a CHECK, not something the caller counts first."""
    harness.execute(
        "INSERT INTO player_manuals (player_id, manual_id) "
        "SELECT %s, manual_id FROM manuals WHERE code = 'rooted_mountain_method'",
        (player_id,),
    )
    with pytest.raises(Exception, match="slot_index"):
        harness.execute(
            "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
            "SELECT %s, 2, manual_id FROM manuals WHERE code = 'rooted_mountain_method'",
            (player_id,),
        )


# ---------------------------------------------------------------------------
# Manual pages (0023)
# ---------------------------------------------------------------------------


def test_pages_is_empty_before_any_rogue_is_beaten(harness, user):
    with pytest.raises(GameError, match="rogue cultivators"):
        harness.run("pages", FakeInteraction(user), path=None)


def test_minting_a_page_never_reaches_tier_8(harness, player_id):
    """Tiers 8-10 exist and must be refined into being, never dropped.

    Expressed as roll_weight 0 in page_tiers rather than a range check in the
    roller, so the rule is visible in the data - and this asserts the roller
    actually honours it.
    """
    for _ in range(200):
        harness.execute("SELECT mint_page(%s)", (player_id,))

    spread = harness.sql(
        """
        SELECT min(tier) AS lo, max(tier) AS hi, count(*) AS n,
               count(DISTINCT path_code) AS paths,
               count(*) FILTER (WHERE trait IS NOT NULL) AS traited
        FROM manual_pages WHERE owner_id = %s
        """,
        (player_id,),
    )
    assert spread["n"] == 200
    assert spread["lo"] >= 1 and spread["hi"] <= 7, "tier 8+ must never drop"
    assert spread["paths"] > 10, "the roll should reach across the Path list"
    assert 10 < spread["traited"] < 80, "traits should be occasional, not always"


def test_page_power_tracks_the_manual_tier_budget(harness):
    """A Tier 3 page averages 15 power and a Tier 3 manual distributes 15%.

    Keeping the two scales identical is what makes "these pages are worth
    about a Tier 5 manual" arithmetic rather than a curve to trust.
    """
    rows = harness.runner.run(db.fetch_all(
        """
        SELECT pt.tier, (pt.power_min + pt.power_max) / 2.0 AS mid,
               mt.bonus_budget * 100 AS budget
        FROM page_tiers pt JOIN manual_tiers mt ON mt.tier = pt.tier
        ORDER BY pt.tier
        """
    ))
    for row in rows:
        assert abs(float(row["mid"]) - float(row["budget"])) <= 2, (
            f"tier {row['tier']}: page power midpoint {row['mid']} "
            f"vs manual budget {row['budget']}"
        )


def test_only_rogues_carry_pages(harness, player_id):
    """A page is written by a person, so it comes off a person.

    0025 dropped the creature and region page-drop tables outright rather than
    leaving them empty: they encoded a rule that is no longer the rule.
    """
    beast = harness.sql(
        "SELECT count(*) AS n FROM rogue_pages(%s, "
        "(SELECT species_id FROM creature_species WHERE code = 'ash_moth'), 'central')",
        (player_id,),
    )
    assert beast["n"] == 0, "wildlife must not carry manual pages"

    # Cleared first: an earlier test in this module mints 200 pages, and this
    # assertion is about what THIS rogue was carrying.
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))

    rogue = harness.sql(
        "SELECT count(*) AS n FROM rogue_pages(%s, "
        "(SELECT species_id FROM creature_species WHERE code = 'rogue_wanderer'), 'central')",
        (player_id,),
    )
    assert rogue["n"] >= 1, "a beaten rogue must yield pages"

    # And what they carried is bounded by what they could read: a rank 1 rogue
    # carries tier 1 to 1 + rogue_page_tier_spread.
    tiers = harness.sql(
        "SELECT min(tier) AS lo, max(tier) AS hi FROM manual_pages WHERE owner_id = %s",
        (player_id,),
    )
    assert tiers["lo"] >= 1 and tiers["hi"] <= 3, (
        f"a rank 1 rogue carried tier {tiers['lo']}-{tiers['hi']}"
    )
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))


def test_rogues_are_not_listed_as_local_wildlife(harness, user):
    """Rogues sit in creature_regions so a spawn can draw from them, but they
    are passing through - /where lists what lives here."""
    card = harness.run("where", FakeInteraction(user))
    lives = next(f for f in card.fields if f.name == "What lives here")
    assert "Rogue" not in lives.value and "Drifter" not in lives.value


def test_exploring_finds_something_or_honestly_nothing(harness, user, player_id):
    harness.run("dev ready", FakeInteraction(user))
    card = work(harness, user, "explore")
    # Either a find, an honest nothing, or an ambush - all three are outcomes.
    assert card.title is not None


def test_pages_lists_what_is_held(harness, user, player_id):
    # Mints its own rather than leaning on what another test left behind.
    for _ in range(3):
        harness.execute("SELECT mint_page(%s)", (player_id,))
    card = harness.run("pages", FakeInteraction(user), path=None)
    assert "total power" in card.footer.text
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))


def test_pages_points_at_rogues_when_you_have_none(harness, user, player_id):
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))
    with pytest.raises(GameError, match="rogue cultivators"):
        harness.run("pages", FakeInteraction(user), path=None)


# ---------------------------------------------------------------------------
# Refinement (0026)
# ---------------------------------------------------------------------------


def test_refine_needs_pages(harness, user, player_id):
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))
    with pytest.raises(GameError, match="at least two pages"):
        harness.run("refine", FakeInteraction(user))


def make_page(harness, player_id, tier, path, ptype, quality):
    return harness.sql(
        """
        INSERT INTO manual_pages (owner_id, tier, path_code, page_type, power, quality)
        SELECT %s, %s, %s, %s,
               round(t.power_min + (t.power_max - t.power_min) * %s / 100.0), %s
        FROM page_tiers t WHERE t.tier = %s
        RETURNING page_id
        """,
        (player_id, tier, path, ptype, quality, quality, tier),
    )["page_id"]


def test_matching_paths_refine_and_conflicting_ones_suffer(harness, player_id):
    """The whole design in one comparison: better pages, worse manual.

    Fire and Water are opposed in the matchup chart, and refinement reads that
    chart - so a novice handed higher-tier conflicting pages produces a manual
    worth less than one made from humble matching ones.
    """
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))
    harness.execute("DELETE FROM player_refinement WHERE player_id = %s", (player_id,))

    matched = [make_page(harness, player_id, 3, "fire", "attack", 84),
               make_page(harness, player_id, 3, "fire", "attack", 80),
               make_page(harness, player_id, 2, "fire", "cultivation", 75)]
    good = harness.sql("SELECT * FROM refine(%s, %s)", (player_id, matched))
    assert good["succeeded"]

    clashing = [make_page(harness, player_id, 5, "fire", "attack", 82),
                make_page(harness, player_id, 5, "water", "attack", 80),
                make_page(harness, player_id, 4, "water", "defense", 75)]
    bad = harness.sql("SELECT * FROM refine(%s, %s)", (player_id, clashing))

    assert good["harmony"] > bad["harmony"], (
        "matching Paths must out-harmonise opposed ones"
    )
    if bad["succeeded"]:
        # Retention is a band, not a curve: two refinements whose harmony
        # differs by a few points can land on the same rung of the ladder and
        # keep exactly the same fraction. The strict claim is the harmony one
        # above; this only has to not contradict it.
        assert float(bad["retained"]) <= float(good["retained"])


def test_an_affinity_override_beats_the_chart(harness, player_id):
    """Soul and Wisdom are opposed in combat and compatible on paper.

    The chart is the default source of refinement harmony; path_affinities is
    where the exceptions live, the same way creature_path_modifiers beats the
    derived weakness.
    """
    derived = harness.sql("SELECT pair_harmony('soul', 'wisdom') AS h")["h"]
    assert derived == 12, "the override should win over chart opposition"

    unopposed = harness.sql("SELECT pair_harmony('fire', 'human') AS h")["h"]
    assert unopposed == 4, "two Paths the chart is silent about have no quarrel"

    opposed = harness.sql("SELECT pair_harmony('fire', 'water') AS h")["h"]
    assert opposed == -22, "rows in both directions is the worst case"


def test_refinement_skill_caps_how_many_pages(harness, player_id):
    harness.execute("DELETE FROM player_refinement WHERE player_id = %s", (player_id,))
    cap = harness.sql("SELECT refinement_max_pages(1::smallint) AS c")["c"]
    assert cap == 3, "a novice combines three"

    pages = [make_page(harness, player_id, 1, "fire", "attack", 60) for _ in range(4)]
    with pytest.raises(Exception, match="allows 3 pages"):
        harness.sql("SELECT * FROM refine(%s, %s)", (player_id, pages))

    top = harness.sql(
        "SELECT max(level_required) AS n FROM profession_steps "
        "WHERE ladder = 'refinement_pages'"
    )["n"]
    assert harness.sql(
        "SELECT refinement_max_pages(%s::smallint) AS c", (top,)
    )["c"] == 8, "a finished refiner combines eight"


def test_high_tier_pages_refine_past_the_drop_table(harness, player_id):
    """Tier 8 does not drop and must be made. Five high-tier pages should
    reach it, which is the entire reason tiers above 7 exist."""
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))
    harness.execute(
        "INSERT INTO player_refinement (player_id, exp, level) VALUES (%s, 4200, 36) "
        "ON CONFLICT (player_id) DO UPDATE SET exp = 4200, level = 36",
        (player_id,),
    )
    pages = [make_page(harness, player_id, 7, "sword", "attack", 96),
             make_page(harness, player_id, 7, "lightning", "attack", 94),
             make_page(harness, player_id, 7, "sword", "speed", 92),
             make_page(harness, player_id, 6, "sword", "attack", 95),
             make_page(harness, player_id, 6, "wind", "speed", 90)]
    result = harness.sql("SELECT * FROM refine(%s, %s)", (player_id, pages))

    assert result["succeeded"]
    assert result["tier"] >= 8, f"reached only tier {result['tier']}"

    # Harmony above 90 retains more than 100%, so the manual exceeds its tier
    # budget - which is why manual_total_bonus is a function, not a CHECK.
    if result["harmony"] >= 90:
        spend = harness.sql(
            "SELECT manual_total_bonus(%s) AS spent, "
            "(SELECT bonus_budget FROM manual_tiers WHERE tier = %s) AS budget",
            (result["manual_id"], result["tier"]),
        )
        assert float(spend["spent"]) > float(spend["budget"])

    consumed = harness.sql(
        "SELECT count(*) AS n FROM manual_pages WHERE consumed_by = %s",
        (result["manual_id"],),
    )
    assert consumed["n"] == 5, "the pages are kept, marked as consumed, not deleted"
    harness.execute("DELETE FROM player_refinement WHERE player_id = %s", (player_id,))


# ---------------------------------------------------------------------------
# The damage pipeline, through the command that reads it
# ---------------------------------------------------------------------------


@pytest.fixture
def bare_slots(harness, player_id):
    """No manuals equipped, so a pipeline figure is the pipeline's.

    These tests assert exact damage. An equipped manual with an attack bonus
    lands in the external multiplier and moves that figure - Crimson Palm Canon
    is +4%, which turns 12,500 into 13,000.

    They passed for months on an accident: the unlock test above used to empty
    slot 0 as a side effect of testing something unrelated, and when that test
    was rewritten these two started measuring the manual as well. Owning the
    state is the fix; agreeing with a neighbour by luck is what broke.
    """
    was = harness.sql_all(
        "SELECT slot_index, manual_id FROM player_manual_slots WHERE player_id = %s",
        (player_id,),
    )
    harness.execute(
        "DELETE FROM player_manual_slots WHERE player_id = %s", (player_id,)
    )
    try:
        yield
    finally:
        for row in was:
            harness.execute(
                "INSERT INTO player_manual_slots (player_id, slot_index, manual_id) "
                "VALUES (%s, %s, %s) ON CONFLICT DO NOTHING",
                (player_id, row["slot_index"], row["manual_id"]),
            )


def test_damage_shows_every_stage(harness, interaction, bare_slots):
    card = harness.run(
        "damage",
        interaction,
        technique="blood_blade",
        creature="frost_maned_ape",
        defense=0,
    )
    pipeline = next(f for f in card.fields if f.name == "Pipeline")
    # Read the technique rather than pinning its power: 0248 rescaled every
    # seeded technique onto a four-times-a-rank ladder, and blood_blade is a
    # seeded technique.
    printed = harness.sql(
        "SELECT base_power FROM techniques WHERE code = 'blood_blade'"
    )["base_power"]
    assert f"Base power **{thousands(printed)}**" in pipeline.value
    assert "Matchup **+25%**" in pipeline.value

    # 0244 put the body behind the technique and 0245 gave it its own
    # stage. The total is the technique plus whatever this cultivator has
    # tempered, so it is read off the screen rather than hard-coded - the
    # old 12,500 only held while Strength did nothing at all.
    body = 0
    for line in pipeline.value.splitlines():
        if line.startswith("Body **+"):
            body = int(
                line[len("Body **+") : -len("**")].replace(",", "")
            )

    damage = next(f for f in card.fields if f.name == "Damage")
    assert damage.value == f"# {thousands(round((printed + body) * 1.25))}"


def test_damage_reports_immunity(harness, interaction):
    card = harness.run(
        "damage",
        interaction,
        technique="blood_blade",
        creature="void_ash_revenant",
        defense=0,
    )
    assert card.colour == discord.Colour(0xED4245)
    damage = next(f for f in card.fields if f.name == "Damage")
    assert damage.value == "# 0"


def test_damage_applies_a_species_override(harness, interaction):
    """The wolf resists Sword by species trait, not by its Path.

    Matchup components sum rather than averaging - unlike attainment, which is
    weighted - so a Sword/Fire technique carries the Sword resistance at its
    full -20% while the neutral Fire half contributes nothing.
    """
    card = harness.run(
        "damage",
        interaction,
        technique="blazing_heaven_sword",
        creature="nine_distortion_wolf",
        defense=0,
    )
    matchup = next(f for f in card.fields if f.name == "Matchup")
    assert "species override" in matchup.value

    pipeline = next(f for f in card.fields if f.name == "Pipeline")
    assert "Matchup **-20%**" in pipeline.value


def test_trait_damage_bonuses_reach_the_pipeline(
    harness, user, player_id, bare_slots
):
    """The external hook 0008 left at 1 is now carrying Race/Root/Physique.

    A Snowman throwing Ice gets +15% from the race alone, weighted by the
    technique's typing - which for a single-Path move is the whole of it.
    """
    harness.execute(
        "UPDATE player_character SET race_code = 'snowman' WHERE player_id = %s",
        (player_id,),
    )
    card = harness.run(
        "damage",
        FakeInteraction(user),
        technique="frost_lotus_seal",
        creature="stone_hide_boar",
        defense=0,
    )
    pipeline = next(f for f in card.fields if f.name == "Pipeline")
    assert "Traits **+15%**" in pipeline.value

    harness.execute(
        "UPDATE player_character SET race_code = %s WHERE player_id = %s",
        (FIXED_RACE, player_id),
    )


# ---------------------------------------------------------------------------
# Trading (0033)
# ---------------------------------------------------------------------------

PARTNER_DISCORD_ID = 999_000_000_000_000_002


@pytest.fixture
def partner(harness):
    """A second cultivator, made directly - /register is exercised elsewhere and
    this test is about the trade screen."""
    harness.execute(
        "DELETE FROM trades WHERE proposer_id IN "
        "(SELECT player_id FROM players WHERE discord_id = %s) "
        "OR partner_id IN (SELECT player_id FROM players WHERE discord_id = %s)",
        (PARTNER_DISCORD_ID, PARTNER_DISCORD_ID),
    )
    harness.execute("DELETE FROM players WHERE discord_id = %s", (PARTNER_DISCORD_ID,))
    row = harness.sql(
        "INSERT INTO players (discord_id, discord_name) VALUES (%s, 'Partner') "
        "RETURNING player_id",
        (PARTNER_DISCORD_ID,),
    )
    other = row["player_id"]
    harness.execute("INSERT INTO player_cultivation (player_id) VALUES (%s)", (other,))
    harness.execute(
        "INSERT INTO player_physique (player_id, physique_id) VALUES (%s, roll_physique())",
        (other,),
    )
    harness.execute(
        "INSERT INTO player_character (player_id, race_code, root_code) "
        "VALUES (%s, 'human', roll_root())",
        (other,),
    )
    harness.execute(
        "UPDATE player_character SET confirmed_at = now() WHERE player_id = %s", (other,)
    )
    try:
        yield {"player_id": other, "user": FakeUser(PARTNER_DISCORD_ID, "Partner")}
    finally:
        harness.execute(
            "DELETE FROM trades WHERE proposer_id = %s OR partner_id = %s", (other, other)
        )
        harness.execute("DELETE FROM players WHERE player_id = %s", (other,))


def test_trade_opens_a_shared_table(harness, user, player_id, partner):
    opened = FakeInteraction(user)
    card = harness.run("trade", opened, partner=partner["user"])

    assert "Partner" in card.title
    assert len(card.fields) == 2, "one pile each"
    assert all("nothing yet" in f.value for f in card.fields)

    # Both parties may press; nobody else may.
    view = opened.view
    assert view.sides == {TEST_DISCORD_ID: player_id, PARTNER_DISCORD_ID: partner["player_id"]}
    harness.execute(
        "SELECT trade_cancel(%s, %s)",
        (view.trade_id, player_id),
    )


def test_a_material_offer_goes_through_the_picker_and_the_modal(
    harness, user, player_id, partner
):
    """The pickers are ephemeral so each side only ever sees their own things,
    and a quantity is typed rather than guessed."""
    held = harness.sql(
        "SELECT material_code, quantity FROM player_materials "
        "WHERE player_id = %s AND quantity > 1 LIMIT 1",
        (player_id,),
    )
    if held is None:
        harness.execute("SELECT grant_material(%s, 'spirit_rice', 5)", (player_id,))
        held = harness.sql(
            "SELECT material_code, quantity FROM player_materials "
            "WHERE player_id = %s AND material_code = 'spirit_rice'",
            (player_id,),
        )

    opened = FakeInteraction(user)
    harness.run("trade", opened, partner=partner["user"])
    view = opened.view

    button = next(b for b in view.children if getattr(b, "label", None) == "Materials")
    picking = FakeInteraction(user)
    harness.click(button, picking)

    select = picking.view.children[0]
    select._values = [held["material_code"]]
    chosen = FakeInteraction(user)
    harness.click(select, chosen)

    modal = chosen.modal
    assert modal is not None, "a quantity is typed, not assumed"
    modal.amount._value = "1"
    harness.runner.run(modal.on_submit(FakeInteraction(user)))

    offered = harness.sql(
        "SELECT quantity FROM trade_offer_materials WHERE trade_id = %s AND side = 0",
        (view.trade_id,),
    )
    assert offered["quantity"] == 1
    harness.execute("SELECT trade_cancel(%s, %s)", (view.trade_id, player_id))


def test_trading_with_an_unregistered_account_is_refused(harness, user):
    stranger = FakeUser(999_000_000_000_000_009, "Stranger")
    with pytest.raises(GameError, match="not begun cultivating"):
        harness.run("trade", FakeInteraction(user), partner=stranger)


# ---------------------------------------------------------------------------
# Gu refining
# ---------------------------------------------------------------------------


def test_refinegu_opens_the_recipe_book(harness, interaction, player_id):
    card = harness.run("refinegu", interaction)

    assert card.fields[0].name == "Gu Refiner"
    assert "Level **1**" in card.fields[0].value
    assert "**2** auxiliary" in card.fields[0].value, "a novice bench is two wide"
    assert "Showing" in card.fields[1].name
    assert interaction.view.children, "a recipe to open"


def test_the_book_never_hides_a_recipe_behind_the_25_limit(harness, user, player_id):
    """Discord allows 25 options in a select and there are more recipes than
    that. The old screen took the first 25 and said nothing about the rest."""
    total = harness.sql("SELECT count(*) AS n FROM gu_recipe_costs")["n"]
    assert total > 25, "otherwise this test proves nothing"

    opened = FakeInteraction(user)
    harness.run("refinegu", opened)
    book = opened.view

    book.mode = "all"
    book.page = 0
    book.build()
    reachable = set()
    for _ in range(book.pages()):
        select = next(c for c in book.children if hasattr(c, "options"))
        assert len(select.options) <= 25, "Discord would refuse this"
        reachable.update(o.value for o in select.options)
        book.page += 1
        book.build()

    assert len(reachable) == total, "every recipe is reachable by paging"


def test_the_filters_are_a_ladder(harness, user, player_id):
    """Ready is a subset of in-reach is a subset of everything, so pressing
    along the row always shows MORE - the direction somebody hunting for a
    particular Gu is travelling."""
    opened = FakeInteraction(user)
    harness.run("refinegu", opened)
    book = opened.view

    counts = {}
    for mode in ("ready", "reach", "all"):
        book.mode = mode
        counts[mode] = {r["gu_code"] for r in book.visible()}

    assert counts["ready"] <= counts["reach"] <= counts["all"]
    assert counts["all"] == {r["gu_code"] for r in book.rows}


def test_the_book_opens_on_something_rather_than_on_nothing(harness, user, player_id):
    """A screen that opens on an empty list has answered "what can I make"
    with "nothing", when the true answer was "nothing yet, and here is what to
    go and get"."""
    opened = FakeInteraction(user)
    harness.run("refinegu", opened)
    assert opened.view.visible(), "the opening filter has something in it"


def _pick_rank(harness, book, user, tier):
    """Choose a rank on the book, the way a player does.

    The ranks were ten buttons until they became one select - two rows of the
    view's five spent on a single axis, which is why there was no room for
    quality or a search. These tests drive the menu instead.
    """
    import discord as _d

    menu = next(
        c for c in book.children
        if isinstance(c, _d.ui.Select) and c.placeholder == "Which rank?"
    )
    menu._values = ["any" if tier is None else str(tier)]
    harness.click(menu, FakeInteraction(user))


def test_the_book_can_be_narrowed_to_one_rank(harness, user, player_id):
    """2,869 recipes at 25 to a page is 115 pages of names. The rank is the
    axis that makes it browsable, so there is a button for each and one for
    the whole ladder."""
    opened = FakeInteraction(user)
    harness.run("refinegu", opened)
    book = opened.view

    import discord as _d

    menu = next(
        c for c in book.children
        if isinstance(c, _d.ui.Select) and c.placeholder == "Which rank?"
    )
    assert {o.value for o in menu.options} == {
        "any", "1", "2", "3", "4", "5", "6", "7", "8", "9"}
    assert book.tier is None, "the book opens on the whole ladder"

    # Every rank the catalogue has, reachable and narrowing to itself.
    for tier in (1, 4, 6):
        _pick_rank(harness, book, user, tier)
        assert book.tier == tier
        assert book.visible(), f"rank {tier} came back empty"
        assert {r["rank"] for r in book.visible()} == {tier}

    _pick_rank(harness, book, user, None)
    assert book.tier is None
    assert len({r["rank"] for r in book.visible()}) > 1


def test_the_book_says_what_each_recipe_makes(harness, user, player_id):
    """A price with no idea what it buys is not something anybody can choose
    between two and a half thousand of. Until 0212 the book said what a recipe
    cost and what was in the way, and never what you got."""
    opened = FakeInteraction(user)
    card = harness.run("refinegu", opened)
    book = opened.view

    assert all(r["effects"] for r in book.rows), "a recipe makes nothing"

    listing = next(f for f in card.fields if f.name.startswith("Showing"))
    # The effect emoji of the first drawn recipe is on the screen.
    first = book.visible()[0]
    assert first["effects"].split()[0] in listing.value


def test_no_page_of_the_book_can_burst_the_field(harness, user, player_id):
    """Two lines per recipe and names up to fifty characters: a fixed count of
    eight can overrun Discord's 1024, and an overrun field costs the whole
    embed rather than the tail of a list. So the list is measured."""
    opened = FakeInteraction(user)
    harness.run("refinegu", opened)
    book = opened.view

    for tier in (None, 1, 2, 3, 4, 5, 6):
        _pick_rank(harness, book, user, tier)
        for page in range(min(book.pages(), 4)):
            book.page = page
            book.build()
            card = book.card()
            for field in card.fields:
                assert len(field.value) <= 1024, (
                    f"rank {tier} page {page}: {len(field.value)} characters"
                )
            assert sum(len(f.name) + len(f.value) for f in card.fields) <= 6000


def test_a_selected_button_is_never_dead(harness, user, player_id):
    """Two filters compose, so a rank can empty under the state you are
    standing in. A green button that cannot be pressed is a dead end."""
    opened = FakeInteraction(user)
    harness.run("refinegu", opened)
    book = opened.view

    for tier in (None, 1, 5, 9):
        _pick_rank(harness, book, user, tier)
        assert book.visible(), f"rank {tier} answered with an empty screen"
        for child in book.children:
            if not isinstance(child, discord.ui.Button):
                continue
            selected = child.style == discord.ButtonStyle.success
            assert not (selected and child.disabled), (
                f"{child.label} is both chosen and unpressable"
            )


def test_a_locked_recipe_opens_and_says_what_it_wants(harness, user, player_id):
    """It used to refuse outright. "What do I need to be able to make this" is
    the question a crafting screen exists to answer."""
    locked = harness.sql(
        """
        SELECT gu_code, gu_name, required_level FROM gu_recipe_book(%s)
        WHERE NOT level_ok ORDER BY required_level LIMIT 1
        """,
        (player_id,),
    )
    assert locked is not None, "the fixture player is not maxed out"

    opened = FakeInteraction(user)
    card = harness.run("refinegu", opened, gu=locked["gu_code"])

    assert locked["gu_name"] in card.title
    not_yet = next(f for f in card.fields if "Not yet" in f.name)
    assert f"level {locked['required_level']}" in not_yet.value
    # Browsable, not usable.
    assert all(c.disabled for c in opened.view.children), "nothing on it can be pressed"


def test_a_recipe_you_can_make_is_not_locked(harness, user, player_id):
    ready = harness.sql(
        "SELECT gu_code FROM gu_recipe_book(%s) WHERE level_ok LIMIT 1", (player_id,)
    )
    opened = FakeInteraction(user)
    harness.run("refinegu", opened, gu=ready["gu_code"])
    assert any(not c.disabled for c in opened.view.children)


def test_the_book_says_what_is_in_the_way(harness, user, player_id):
    """The blocker phrase is the whole reason a recipe you cannot make is
    worth drawing at all."""
    opened = FakeInteraction(user)
    card = harness.run("refinegu", opened)
    book = opened.view

    for row in book.rows:
        if row["ready"]:
            assert row["blocker"] is None
        else:
            assert row["blocker"], f"{row['gu_name']} is blocked by nothing"

    select = next(c for c in book.children if hasattr(c, "options"))
    assert all(o.description for o in select.options), "every option says something"


def test_the_bench_says_what_every_auxiliary_is_doing(harness, user, player_id):
    """A player must not have to lose thirty jade leaves to learn that Wood
    fights Poison. The screen says so before the button is pressed."""
    from bot.cogs import gurefine

    for code, amount in (
        ("poison_herb", 50),
        ("scorpion_stinger", 50),
        ("shame_plum", 50),
        ("jade_leaf", 50),
    ):
        harness.execute("SELECT grant_material(%s, %s, %s)", (player_id, code, amount))

    opened = FakeInteraction(user)
    harness.run("refinegu", opened, gu="poison_needle_gu")
    view = opened.view

    button = next(
        b for b in view.children if getattr(b, "label", None) == "Add material"
    )
    picking = FakeInteraction(user)
    harness.click(button, picking)

    select = picking.view.children[0]
    select._values = ["shame_plum"]
    chosen = FakeInteraction(user)
    harness.click(select, chosen)

    modal = chosen.modal
    assert modal is not None, "a quantity is typed, not assumed"
    modal.amount._value = "9"
    harness.runner.run(modal.on_submit(FakeInteraction(user)))
    assert view.aux == {"shame_plum": 9}

    # And one the Gu's Path fights, to prove both readings show.
    view.aux["jade_leaf"] = 30
    card = harness.runner.run(gurefine.render_bench(view.recipe, view.skill, view.aux))

    bench = next(f for f in card.fields if f.name.startswith("Auxiliary"))
    assert "belongs" in bench.value, "Poison in a Poison Gu"
    assert "ruins it" in bench.value, "Wood and Poison fight both ways: the worst band"

    worth = next(f for f in card.fields if f.name == "What the pile is worth")
    assert "Potency" in worth.value


def test_a_bench_wider_than_the_profession_is_refused(harness, user, player_id):
    """Raised inside a modal, which discord.py would otherwise log and leave
    the player staring at "did not respond"."""
    from bot.cogs import gurefine

    opened = FakeInteraction(user)
    harness.run("refinegu", opened, gu="poison_needle_gu")
    view = opened.view
    view.aux = {"shame_plum": 3, "tree_bark": 3}

    modal = gurefine.AuxQuantityModal(view, "spirit_rice", "Spirit Rice", 10)
    modal.amount._value = "3"
    refused = FakeInteraction(user)

    # discord.py catches what a modal raises and hands it to on_error, which
    # is the whole point of the handler: without it the player is told the
    # application did not respond.
    try:
        harness.runner.run(modal.on_submit(refused))
    except GameError as exc:
        harness.runner.run(modal.on_error(refused, exc))

    assert "bench holds 2" in refused.last.description


def test_refining_makes_a_gu_you_can_then_equip(harness, user, player_id):
    held_before = harness.sql(
        "SELECT count(*) AS n FROM player_gu WHERE owner_id = %s", (player_id,)
    )["n"]

    harness.execute("SELECT grant_material(%s, 'poison_herb', 50)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'scorpion_stinger', 50)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("refinegu", opened, gu="poison_needle_gu")
    view = opened.view

    button = next(b for b in view.children if getattr(b, "label", None) == "Refine")
    pressed = FakeInteraction(user)
    card = harness.click(button, pressed)

    assert "Poison Needle Gu" in card.title
    assert card.fields[0].name == "Stars"
    assert "/gu to take it into your aperture" in card.footer.text

    held_after = harness.sql(
        "SELECT count(*) AS n FROM player_gu WHERE owner_id = %s", (player_id,)
    )["n"]
    assert held_after == held_before + 1


def test_a_rank_you_have_not_earned_cannot_be_refined(harness, user, player_id):
    """The bench for it opens now - browsing a recipe you cannot make is the
    point of the book. What must not move is the rule itself, and a disabled
    button is not a rule: `refine_gu` refuses on its own, which is what would
    still stand if the screen were bypassed entirely.
    """
    opened = FakeInteraction(user)
    card = harness.run("refinegu", opened, gu="jade_skin_gu")
    assert "Jade Skin Gu" in card.title
    assert any("Not yet" in f.name for f in card.fields)
    assert all(c.disabled for c in opened.view.children)

    with pytest.raises(psycopg.errors.CheckViolation, match="level 4"):
        harness.execute(
            "SELECT refine_gu(%s, (SELECT gu_type_id FROM gu_types "
            "WHERE code = 'jade_skin_gu'))",
            (player_id,),
        )


def test_gu_renders_what_you_hold(harness, user, player_id):
    """A literal percent inside a query that also takes parameters is a
    psycopg placeholder, and this screen builds three of them. Nothing but
    running the command catches that.
    """
    harness.execute(
        "SELECT grant_gu(%s, (SELECT gu_type_id FROM gu_types WHERE code = %s), NULL)",
        (player_id, "big_strength_gu"),
    )
    card = harness.run("gu look", FakeInteraction(user))

    assert "aperture" in card.description
    assert any(f.name == "In the jar" for f in card.fields)


def test_an_insight_batch_asks_how_many_and_then_where(harness, user, player_id):
    """0399 gave the shelf a quantity prompt and insight pills never saw it -
    the select branched to the Path picker first, so an insight batch was the
    one thing left that had to be taken a pill at a time.

    Both questions now, in the order somebody would say them: five, into Fire.
    """
    path = harness.sql("SELECT code FROM paths ORDER BY code LIMIT 1")["code"]
    harness.execute(
        "INSERT INTO player_pills "
        "(owner_id, name, tier, kind, path_code, magnitude, quantity, harmony) "
        "VALUES (%s, 'Batch of Insight', 3, 'insight', %s, 400, 5, 80)",
        (player_id, path),
    )
    pill_id = harness.sql(
        "SELECT pill_id FROM player_pills WHERE owner_id = %s AND kind = 'insight' "
        "ORDER BY pill_id DESC LIMIT 1",
        (player_id,),
    )["pill_id"]

    shelf = FakeInteraction(user)
    harness.run("pills", shelf)
    select = next(
        c for c in shelf.view.children if hasattr(c, "options")
    )
    select._values = [str(pill_id)]

    # First question: how many.
    asked = FakeInteraction(user)
    harness.click(select, asked)
    how_many = asked.views[-1]
    counts = [b for b in how_many.children if hasattr(b, "count")]
    assert counts, "an insight batch went straight past the quantity prompt"

    three = next((b for b in counts if b.count == 5), counts[-1])
    wanted = three.count

    # Second question: which Path.
    pointed = FakeInteraction(user)
    harness.click(three, pointed)
    picker = pointed.views[-1]
    assert hasattr(picker, "on_pick"), "it did not go on to ask for a Path"
    assert picker.count == wanted, (
        f"the Path picker was handed {picker.count} rather than {wanted}"
    )

    before = harness.sql(
        "SELECT COALESCE(insight, 0) AS insight FROM player_path_attainment "
        "WHERE player_id = %s AND path_code = %s",
        (player_id, path),
    )
    was = before["insight"] if before else 0

    button = next(
        b for b in picker.children
        if getattr(b, "path", None) and b.path["code"] == path
    )
    card = harness.click(button, FakeInteraction(user))

    assert "+" in card.description
    after = harness.sql(
        "SELECT insight FROM player_path_attainment "
        "WHERE player_id = %s AND path_code = %s",
        (player_id, path),
    )["insight"]
    assert after > was, "the batch landed no insight at all"

    left = harness.sql(
        "SELECT COALESCE(sum(quantity), 0) AS n FROM player_pills "
        "WHERE pill_id = %s",
        (pill_id,),
    )["n"]
    assert left == 5 - wanted, f"{5 - left} pills left the bag, not {wanted}"


def test_find_reaches_every_source_rather_than_naming_a_remainder(harness):
    """/find cut each way of getting a thing at eight and said "and 41 more".
    Beast Blood has forty-nine sources; the screen knew all of them and would
    not say them.

    Paged over the whole list now, and this walks every page of the worst
    material in the game to prove nothing is stranded past the last one.
    """
    from bot.cogs.index import SOURCES_PER_PAGE, fetch_sources, render_material

    worst = harness.sql(
        """
        SELECT m.code, (SELECT count(*) FROM material_sources(m.code)) AS n
        FROM materials m
        ORDER BY (SELECT count(*) FROM material_sources(m.code)) DESC
        LIMIT 1
        """
    )
    assert worst["n"] > SOURCES_PER_PAGE, (
        "no material is long enough to test paging with"
    )

    rows = harness.runner.run(fetch_sources(worst["code"]))
    pages = max(1, -(-len(rows) // SOURCES_PER_PAGE))

    seen = 0
    for page in range(pages):
        card = harness.runner.run(render_material(worst["code"], 0, page))
        for field in card.fields:
            if field.name == "You are carrying":
                continue
            # Two lines a source: the place, then what it yields.
            seen += len(field.value.split("\n")) // 2
            assert len(field.value) <= 1024, (
                f"page {page + 1} builds a field Discord would refuse"
            )
        assert "more*" not in "".join(f.value for f in card.fields), (
            "a page still trails off into a remainder"
        )

    assert seen == len(rows), f"paging showed {seen} of {len(rows)} sources"

    # And a material that fits on one page is not given buttons to press.
    short = harness.sql(
        """
        SELECT m.code FROM materials m
        WHERE (SELECT count(*) FROM material_sources(m.code)) BETWEEN 1 AND %s
        LIMIT 1
        """,
        (SOURCES_PER_PAGE,),
    )
    if short:
        card = harness.runner.run(render_material(short["code"], 0, 0))
        assert "Page " not in (card.footer.text or ""), (
            "a one-page material claims to have pages"
        )


def test_a_support_technique_can_be_chosen_in_a_fight(harness, user, player_id):
    """clearwest read a manual for The Table That Seats the Line and could not
    find it anywhere in a fight.

    `usable_techniques` filtered on `base_power > 0`, which hid every defence,
    support and utility technique in the game - 37 of them, including all nine
    healing moves. `battle_act` had always handled them; they were simply never
    offered. A technique you can learn, see on /loadout and never once cast is
    worse than one that does not exist.
    """
    from bot.battle import usable_techniques

    # Within their realm, or `player_usable_techniques` gates it out for a
    # reason that has nothing to do with the bug being tested. Any non-attack
    # kind proves it - all three were hidden by the same filter.
    support = harness.sql(
        """
        SELECT t.technique_id, t.name FROM techniques t
        JOIN player_cultivation pc ON pc.player_id = %s
        JOIN realms r ON r.realm_id = pc.realm_id
        WHERE t.created_by IS NULL AND t.category <> 'attack'
          AND t.base_power = 0 AND t.rank <= r.rank
        ORDER BY t.rank LIMIT 1
        """,
        (player_id,),
    )
    assert support, "the roster has no non-attack technique this character could hold"
    harness.execute(
        "INSERT INTO player_techniques (player_id, technique_id) VALUES (%s, %s) "
        "ON CONFLICT DO NOTHING",
        (player_id, support["technique_id"]),
    )

    max_qi = harness.sql("SELECT player_max_qi(%s) AS q", (player_id,))["q"]
    rows = harness.runner.run(usable_techniques(player_id, max_qi))
    names = [r["name"] for r in rows]
    assert support["name"] in names, (
        f"{support['name']} is learned and still not offered in a fight"
    )

    # And it describes itself by what it does, because its power is zero and
    # printing that tells nobody anything.
    row = next(r for r in rows if r["name"] == support["name"])
    assert row["effect_text"], f"{row['name']} says nothing about what it does"

    # An attack still leads, because that is what most rounds are for.
    if any(r["category"] == "attack" for r in rows):
        assert rows[0]["category"] == "attack", [r["category"] for r in rows]


def test_the_auto_swing_never_comes_up_a_healing_move(harness, player_id):
    """`pick_technique` chooses what you swing on a hunt. It filtered on
    `base_power > 0`, which happened to mean "an attack" and stopped meaning it
    the moment anything else was asked of that column."""
    import pathlib as _p

    source = (_p.Path(__file__).resolve().parent.parent
              / "bot" / "cogs" / "world.py").read_text(encoding="utf-8")
    assert "t.category = 'attack'" in source, (
        "the hunt's auto-swing no longer asks for an attack outright"
    )


def test_a_flat_stat_is_never_printed_as_a_percentage(harness, user, player_id):
    """Iron Bone Immortal Gu read "Body 1500%" on /gu. It grants fifteen POINTS
    of Body - 0355 added three effects that are counts rather than fractions,
    and every screen listing effects multiplied by a hundred and stapled a per
    cent sign on regardless.

    Driven through the screens rather than through `effect_amount` alone,
    because the bug was never in the arithmetic - it was in four separate
    copies of the formatting, and a fifth copy is the thing to catch.
    """
    base_gu = harness.sql(
        """
        SELECT t.code FROM gu_types t
        JOIN gu_type_effects te ON te.gu_type_id = t.gu_type_id
        JOIN gu_effects f ON f.code = te.effect_code
        WHERE f.is_base AND t.size = 1
        LIMIT 1
        """
    )["code"]
    harness.execute(
        "SELECT grant_gu(%s, (SELECT gu_type_id FROM gu_types WHERE code = %s), NULL)",
        (player_id, base_gu),
    )
    harness.execute(
        """
        INSERT INTO player_gu_equipped (gu_id, player_id)
        SELECT g.gu_id, %s FROM player_gu g
        JOIN gu_types t ON t.gu_type_id = g.gu_type_id
        WHERE g.owner_id = %s AND t.code = %s
        ON CONFLICT DO NOTHING
        """,
        (player_id, player_id, base_gu),
    )

    from bot.cogs.gu import fetch_gu

    held = harness.runner.run(fetch_gu(player_id))
    worn = [g for g in held if g["code"] == base_gu]
    assert worn, "the base-stat Gu was not equipped, so this proves nothing"

    names = [
        r["name"] for r in harness.sql_all(
            "SELECT name FROM gu_effects WHERE is_base"
        )
    ]
    for g in worn:
        for part in (g["effects"] or "").split(", "):
            for flat in names:
                if flat in part:
                    assert "%" not in part, (
                        f"{g['name']} prints a flat stat as a percentage: {part!r}"
                    )
                    assert "+" in part, (
                        f"{g['name']} prints a flat stat without a sign: {part!r}"
                    )

    # The catalogue entry is a separate copy of the same formatting.
    card = harness.run("gu book", FakeInteraction(user), name=base_gu)
    shown = next(f.value for f in card.fields if "star" in f.name.lower())
    for flat in names:
        for line in shown.splitlines():
            if flat in line:
                assert "%" not in line, (
                    f"/gu book prints a flat stat as a percentage: {line!r}"
                )

    # And the TOTALS on /gu, which is the fifth copy this docstring warned
    # about and the one that got away. It read `percent(total)` against a
    # number that was already a count, so sixteen points of Sinew came out as
    # "+1600%" - the right value in the wrong quantity.
    card = harness.run("gu look", FakeInteraction(user))
    worth = next((f.value for f in card.fields if f.name == "What they are worth"), None)
    assert worth, "the /gu screen stopped saying what the Gu are worth"
    for flat in names:
        for line in worth.splitlines():
            if flat in line:
                assert "%" not in line, (
                    f"/gu totals print a flat stat as a percentage: {line!r}"
                )
                assert "+" in line, (
                    f"/gu totals print a flat stat without a sign: {line!r}"
                )


def test_gupedia_reads_a_gu_out_of_the_catalog(harness, interaction):
    card = harness.run("gu book", interaction, name="big_strength_gu")

    assert card.title.endswith("Big Strength Gu")
    assert any(f.name == "At one star" for f in card.fields)


def test_a_gu_offer_goes_through_the_picker(harness, user, player_id, partner):
    """The fourth pile. A Gu is an instance, so it takes no quantity modal —
    one press puts it on the table."""
    gu_id = harness.sql(
        "SELECT grant_gu(%s, (SELECT gu_type_id FROM gu_types WHERE code = %s), NULL) AS gu_id",
        (player_id, "moonlight_gu"),
    )["gu_id"]

    opened = FakeInteraction(user)
    harness.run("trade", opened, partner=partner["user"])
    view = opened.view

    button = next(b for b in view.children if getattr(b, "label", None) == "Gu")
    picking = FakeInteraction(user)
    harness.click(button, picking)

    select = picking.view.children[0]
    select._values = [str(gu_id)]
    chosen = FakeInteraction(user)
    harness.click(select, chosen)

    offered = harness.sql(
        "SELECT side, label FROM trade_contents WHERE trade_id = %s AND kind = 'gu'",
        (view.trade_id,),
    )
    assert offered["side"] == 0
    assert offered["label"] == "1* Moonlight Gu"

    # And the card draws the stars rather than the count the view stores.
    contents = harness.runner.run(trade.fetch_contents(view.trade_id))
    assert "Moonlight Gu \N{BLACK STAR}" in trade.pile(contents, 0)

    harness.execute("SELECT trade_cancel(%s, %s)", (view.trade_id, player_id))


# ---------------------------------------------------------------------------
# What a find looks like (0042)
# ---------------------------------------------------------------------------


@pytest.fixture
def always_finds_stones(harness):
    """Explore's outcomes are weighted rows, so a test can move the game's own
    dial to make a find certain - and put it back."""
    harness.execute("UPDATE explore_outcomes SET weight = 0 WHERE code <> 'spirit_stones'")
    try:
        yield
    finally:
        harness.execute(
            """
            UPDATE explore_outcomes SET weight = v.weight
            FROM (VALUES ('gathering', 34), ('beast', 18), ('nothing', 18))
                 AS v (code, weight)
            WHERE explore_outcomes.code = v.code
            """
        )


def test_explore_shows_what_you_found_and_what_it_looks_like(
    harness, user, player_id, no_ambush, always_finds_stones
):
    """A rarity dot says how lucky you were, not what you are holding.

    The region is the constant and the find is the news, so the region titles
    the card and the find reads underneath it.
    """
    harness.run("dev ready", FakeInteraction(user))
    card = work(harness, user, "explore")

    where = harness.sql(
        """
        SELECT r.name, r.emoji FROM player_location pl
        JOIN regions r ON r.code = pl.region_code
        WHERE pl.player_id = %s
        """,
        (player_id,),
    )
    assert card.title == f"{where['emoji']} {where['name']}"

    emoji = harness.sql(
        "SELECT emoji FROM materials WHERE code = 'spirit_stone'"
    )["emoji"]
    outcome = harness.sql(
        "SELECT name FROM explore_outcomes WHERE code = 'spirit_stones'"
    )["name"]
    line = next(f for f in card.fields if f.name.startswith("Collected")).value
    assert f"{emoji} **Spirit Stone**" in line
    assert outcome in line, "the outcome still names itself beside the find"

    # The rarity dot leads the line it was always describing.
    assert line.split()[0] not in {emoji, "**Spirit"}, "a rarity mark leads it"


def collected(card):
    """The tally lines off a seam card, as (emoji, material name) pairs.

    Each line is `<rarity mark> <emoji> **Name** xN`, so the emoji is the last
    token before the name.
    """
    field = next(f for f in card.fields if f.name.startswith("Collected"))
    pairs = []
    for line in field.value.splitlines():
        head, sep, rest = line.partition(" **")
        if not sep:
            continue
        pairs.append((head.split()[-1], rest.split("**")[0]))
    return pairs


def test_gather_shows_the_same_picture(harness, user, player_id, no_ambush):
    """Same card shape as /explore, so the two do not teach a player to read
    two different screens."""
    # A rogue can interrupt a forage, and an ambush card names a person.
    harness.run("dev ready", FakeInteraction(user))
    card = work(harness, user, "gather")

    where = harness.sql(
        """
        SELECT r.name, r.emoji FROM player_location pl
        JOIN regions r ON r.code = pl.region_code
        WHERE pl.player_id = %s
        """,
        (player_id,),
    )
    assert card.title == f"{where['emoji']} {where['name']}"

    emoji, material = collected(card)[0]
    stored = harness.sql("SELECT emoji FROM materials WHERE name = %s", (material,))
    assert stored is not None, f"should name a real material, got {material!r}"
    assert emoji == stored["emoji"]


def test_the_inventory_lists_pictures_too(harness, user, player_id):
    harness.execute("SELECT grant_material(%s, 'spirit_rice', 3)", (player_id,))
    opened = FakeInteraction(user)
    harness.run("inventory", opened, category=None)

    gathering = satchel_shelf(opened.view, "gathering")
    assert "\N{COOKED RICE} **Spirit Rice**" in gathering


# ---------------------------------------------------------------------------
# The bottleneck (0044)
# ---------------------------------------------------------------------------


def test_cultivation_fills_to_the_door_and_stops(harness, user, player_id):
    """Idle time against a full bar buys nothing. That is what makes the
    command worth pressing, and it is what a tribulation will interrupt."""
    ceiling = harness.sql(
        "SELECT cultivation_ceiling(%s) AS c", (player_id,)
    )["c"]
    harness.execute(
        "UPDATE player_cultivation SET cultivation = %s WHERE player_id = %s",
        (ceiling, player_id),
    )

    harness.run("dev advance", FakeInteraction(user), hours=12)
    harness.run("profile", FakeInteraction(user), user=None)

    after = harness.sql(
        "SELECT cultivation, realm_id FROM player_cultivation WHERE player_id = %s",
        (player_id,),
    )
    assert after["cultivation"] == ceiling, "not one point past the door"
    assert harness.sql(
        "SELECT ready_to_break_through(%s) AS ready", (player_id,)
    )["ready"] is True
    # The twelve hours were not thrown away for being late: they are
    # behind the door rather than past it.
    assert harness.sql(
        "SELECT reserve FROM player_cultivation WHERE player_id = %s",
        (player_id,),
    )["reserve"] > 0, "the wait was banked"


def test_the_profile_says_the_door_is_open(harness, user, player_id):
    card = harness.run("profile", FakeInteraction(user), user=None)
    field = next(f for f in card.fields if "Breakthrough" in f.name)
    assert "within reach" in field.value
    assert "/breakthrough" in field.value


def test_breakthrough_takes_the_realm_and_says_what_it_bought(harness, user, player_id):
    before = harness.sql(
        "SELECT realm_id FROM player_cultivation WHERE player_id = %s", (player_id,)
    )["realm_id"]

    card = harness.run("breakthrough", FakeInteraction(user))

    after = harness.sql(
        "SELECT realm_id FROM player_cultivation WHERE player_id = %s", (player_id,)
    )["realm_id"]
    assert after == before + 1, "one realm, taken on purpose"

    worth = next(f for f in card.fields if f.name == "What it is worth")
    assert "Qi capacity" in worth.value
    # The card has to say the reserve came back. A promise the player
    # cannot see on the screen where it pays out is not a promise.
    assert "reserve" in worth.value
    assert "tribulation" in card.footer.text


def test_a_realm_you_have_not_earned_is_refused(harness, user, player_id):
    """The breakthrough above poured the reserve into the new realm, which
    can leave the next door open too - that is the reserve working, not a
    bug. So this empties both before asking, because what is under test is
    the refusal and not how far the last crossing carried."""
    harness.execute(
        "UPDATE player_cultivation pc SET reserve = 0, cultivation = r.cultivation_required "
        "FROM realms r WHERE r.realm_id = pc.realm_id AND pc.player_id = %s",
        (player_id,),
    )
    with pytest.raises(GameError, match="needed to break into"):
        harness.run("breakthrough", FakeInteraction(user))


# ---------------------------------------------------------------------------
# `I hunt` (the prefix adapter)
# ---------------------------------------------------------------------------


class FakeChannel:
    def __init__(self) -> None:
        self.sent = []

    async def send(self, content=None, *, embed=None, view=None, **kwargs):
        self.sent.append(embed if embed is not None else content)
        return FakeMessage()

    async def typing(self):
        return None


class FakeChatMessage:
    """A message someone typed, with only what the adapter reads off it."""

    def __init__(self, user, content: str) -> None:
        self.author = user
        self.content = content
        self.channel = FakeChannel()
        self.guild = None
        self.replies = []

    async def reply(self, content=None, *, embed=None, view=None, **kwargs):
        self.replies.append(embed if embed is not None else content)
        self.view = view
        return FakeMessage()

    @property
    def answer(self):
        assert self.replies, "the line went unanswered"
        return self.replies[-1]


def say(harness, user, text: str) -> FakeChatMessage:
    message = FakeChatMessage(user, text)
    cog = harness.bot.get_cog("Prefix")
    harness.runner.run(cog.on_message(message))
    return message


def test_i_hunt_runs_the_same_command_slash_hunt_does(harness, user, player_id, no_ambush):
    """One adapter, not a second copy of thirty-nine commands."""
    try:
        harness.run("dev ready", FakeInteraction(user))
        said = say(harness, user, "I hunt")

        assert said.answer is not None, "a hunt card"
        assert "Round **1**" in said.answer.description
        assert said.view is not None, "and the buttons come with it"
    finally:
        clear_battle(harness, player_id)


def test_the_prefix_reaches_into_groups(harness, user, player_id):
    said = say(harness, user, "I dev ready")
    assert said.answer is not None
    assert harness.sql(
        "SELECT count(*) AS n FROM player_cooldowns WHERE player_id = %s", (player_id,)
    )["n"] == 0


def test_a_sentence_that_starts_with_i_is_left_alone(harness, user, player_id):
    """The prefix is an English pronoun. A command that takes no arguments runs
    only when nothing follows it, which is what keeps the bot out of the
    conversation."""
    for sentence in (
        "I travel a lot these days",
        "I gather that you are busy",
        "I explore ideas for a living",
        "I think this is fine",
        "I",
    ):
        said = say(harness, user, sentence)
        assert said.replies == [], f"{sentence!r} should have been left alone"
        assert said.channel.sent == []


def test_an_argument_that_will_not_convert_is_read_as_prose(harness, user, player_id):
    said = say(harness, user, "I techniques whatever")
    assert said.replies == []


def test_arguments_do_come_through(harness, user, player_id):
    said = say(harness, user, "I techniques 1")
    assert said.answer.title == "Techniques — rank 1", (
        "the integer arrived as an integer"
    )


def test_the_command_own_refusals_are_answered(harness, user, player_id):
    """Once it is running, the player meant it - so this one does talk back."""
    said = say(harness, user, "I gu book not_a_real_gu")
    assert "no Gu called" in said.answer.description


def test_the_prefix_is_case_insensitive(harness, user, player_id):
    said = say(harness, user, "i dev ready")
    assert said.answer is not None


def test_the_bot_does_not_answer_itself(harness, user):
    message = FakeChatMessage(user, "I hunt")
    message.author = FakeUser(user.id, "Tester")
    message.author.bot = True
    cog = harness.bot.get_cog("Prefix")
    harness.runner.run(cog.on_message(message))
    assert message.replies == []


# ---------------------------------------------------------------------------
# /physique
# ---------------------------------------------------------------------------


def test_physique_shows_the_body_and_offers_the_three(harness, user, player_id):
    card = harness.run("physique", FakeInteraction(user))
    assert "The body" in [f.name for f in card.fields]

    tempering = next(f for f in card.fields if f.name == "Tempering")
    assert "toward" in tempering.value


def test_choosing_a_body_moves_the_numbers(harness, user, player_id):
    before = harness.sql(
        "SELECT strength FROM player_physique WHERE player_id = %s", (player_id,)
    )["strength"]

    opened = FakeInteraction(user)
    harness.run("physique", opened)
    view = opened.view

    demonic = next(b for b in view.children if "Demonic" in b.label)
    harness.click(demonic, FakeInteraction(user))

    after = harness.sql(
        "SELECT strength, body_path FROM player_physique WHERE player_id = %s",
        (player_id,),
    )
    assert after["body_path"] == "demonic"
    assert after["strength"] > before, "the path reaches the stats immediately"


def test_the_physique_screen_never_shows_a_bar_past_full(harness, user, player_id):
    """Since 0108 the training carries on while the rank waits, so a body can
    sit at 209% of its own door. A bar past full reads as a bug rather than as
    "you have been ready for a while"."""
    harness.execute(
        "UPDATE player_physique SET physique_xp = 99999, body_rank = 1 "
        "WHERE player_id = %s", (player_id,)
    )
    try:
        card = harness.run("physique", FakeInteraction(user))
        field = next(f for f in card.fields if f.name == "Tempering")
        assert "100%" in field.value
        assert not any(
            int(word.rstrip("%")) > 100
            for word in field.value.split()
            if word.rstrip("%").isdigit()
        ), field.value
    finally:
        harness.execute(
            "UPDATE player_physique SET physique_xp = 3000, body_rank = 2 "
            "WHERE player_id = %s", (player_id,)
        )


def test_the_physique_screen_names_the_way_through(harness, user, player_id):
    """A door nobody is told about is a wall. The crossing costs beast
    material now, and /physique is where somebody looks for it."""
    harness.execute(
        "UPDATE player_physique SET physique_xp = 99999, body_rank = 1 "
        "WHERE player_id = %s", (player_id,)
    )
    try:
        card = harness.run("physique", FakeInteraction(user))
        field = next(f for f in card.fields if f.name == "Tempering")
        assert "/temper" in field.value
        assert "beast material" in field.value
    finally:
        harness.execute(
            "UPDATE player_physique SET physique_xp = 3000, body_rank = 2 "
            "WHERE player_id = %s", (player_id,)
        )


def test_a_set_body_offers_no_buttons(harness, user, player_id):
    """The character is past Rank 1 and has now chosen, so the screen must
    stop offering a choice the database would refuse.

    This also covers HOW the screen declines to attach one. `view=None` is a
    crash inside discord.py, not an empty view, and it only fires for a
    character whose Path has set - so it reached a real player before any test
    caught it. `check_view` on the fake is what makes this test see it.
    """
    # Since 0108 the path locks on the CROSSING rather than on the training,
    # so this character has to have actually left Rank 1.
    harness.execute(
        "UPDATE player_physique SET body_rank = 2 WHERE player_id = %s", (player_id,)
    )
    assert harness.sql(
        "SELECT path_still_open FROM player_body WHERE player_id = %s", (player_id,)
    )["path_still_open"] is False

    opened = FakeInteraction(user)
    card = harness.run("physique", opened)
    assert opened.views == [] or not opened.views[-1].children
    assert "set" in card.footer.text


def test_the_profile_names_the_rank(harness, user, player_id):
    card = harness.run("profile", FakeInteraction(user), user=None)
    stats = next(f for f in card.fields if "Foundation Stats" in f.name)
    named = harness.sql(
        "SELECT rank_name FROM player_body WHERE player_id = %s", (player_id,)
    )["rank_name"]
    assert named in stats.value


def test_the_top_of_the_ladder_still_says_tempering_pays(harness, user, player_id):
    """The branch nobody has reached yet.

    Before 0383 the last rung was a wall, and the screen said so: "there is no
    further body to build". The wall is gone - past the end of the last band
    every doubling is worth another `body_overflow_weight` of a rank - so a
    screen still saying that would be telling the four people who got furthest
    that the only thing left to do is worth nothing. No live character is at
    rank 18 yet, which is exactly why this has to be driven here.
    """
    top = harness.sql("SELECT max(rank) AS top FROM body_rank_requirements")["top"]
    before = harness.sql(
        "SELECT physique_xp, body_rank FROM player_physique WHERE player_id = %s",
        (player_id,),
    )
    try:
        # Well past the end of the last band, so the soft cap is engaged rather
        # than merely reachable: the percentage has to read over 100.
        harness.execute(
            "UPDATE player_physique SET physique_xp = 4000000, body_rank = %s "
            "WHERE player_id = %s", (top, player_id)
        )
        harness.execute("SELECT apply_physique_xp(%s, 0)", (player_id,))

        card = harness.run("physique", FakeInteraction(user))
        field = next(f for f in card.fields if f.name == "Tempering")
        assert "pays" in field.value or "counting" in field.value, field.value
        assert "no further body" not in field.value
        over = [
            int(word.rstrip("%")) for word in field.value.split()
            if word.rstrip("%").isdigit() and word.endswith("%")
        ]
        assert any(n > 100 for n in over), (
            f"tempering past the last rung read as {over}, not as overflow"
        )

        # And /temper, which is where somebody goes to find out what is left.
        crossing = harness.run("temper", FakeInteraction(user))
        assert "nothing above it" in crossing.description
        assert "still pays" in crossing.description
    finally:
        harness.execute(
            "UPDATE player_physique SET physique_xp = %s, body_rank = %s "
            "WHERE player_id = %s",
            (before["physique_xp"], before["body_rank"], player_id),
        )
        harness.execute("SELECT apply_physique_xp(%s, 0)", (player_id,))


def test_bodies_lists_all_three_ladders(harness, interaction):
    card = harness.run("bodies", interaction)
    assert len(card.fields) == 3
    assert "Dao Origin Immortal King" in card.fields[0].value
    assert "Myriad Abyss Demon Venerable" in card.fields[1].value
    assert "Supreme Nirvana Buddha Sovereignty" in card.fields[2].value


def test_every_rarity_a_player_can_meet_has_a_mark(harness):
    """The screen colours a rarity by looking it up in a dict. A band added to
    the database without an entry there renders as nothing at all, which is
    how a Divine root would have arrived looking Common."""
    from bot.character import RARITY_MARK

    bands = harness.sql_all("SELECT code FROM rarities ORDER BY sort_order")
    missing = [b["code"] for b in bands if b["code"] not in RARITY_MARK]
    assert missing == []


def test_traits_publishes_the_divine_odds(harness, interaction):
    """The odds screen reads the ladder out of the database, so a new band
    reaches players without a line of Python moving."""
    card = harness.run(
        "traits", interaction, kind=app_commands.Choice(name="Roots", value="roots")
    )
    headings = [f.name for f in card.fields]
    assert any("Divine \N{EM DASH} 0.5000%" in h for h in headings)
    assert "Dao Ancestor Root" in "\n".join(f.value for f in card.fields)


# ---------------------------------------------------------------------------
# Alchemy
# ---------------------------------------------------------------------------


def test_the_cauldron_reads_what_is_in_it(harness, user, player_id):
    """No recipe list, so the screen has to say what the pot would become."""
    from bot.cogs import alchemy

    for code in ("blue_kelp_grass", "pearl_dew_lily"):
        harness.execute("SELECT grant_material(%s, %s, 40)", (player_id, code))

    opened = FakeInteraction(user)
    harness.run("alchemy", opened)
    view = opened.view

    button = next(b for b in view.children if getattr(b, "label", None) == "Add herb")
    picking = FakeInteraction(user)
    harness.click(button, picking)

    select = picking.view.children[0]
    select._values = ["blue_kelp_grass"]
    chosen = FakeInteraction(user)
    harness.click(select, chosen)
    modal = chosen.modal
    assert modal is not None
    modal.amount._value = "6"
    harness.runner.run(modal.on_submit(FakeInteraction(user)))

    view.pot["pearl_dew_lily"] = 6
    card = harness.runner.run(alchemy.render_cauldron(view.skill, view.pot))

    becomes = next(f for f in card.fields if f.name == "Becomes")
    assert "potency" in becomes.value
    assert "Healing" in becomes.value, "two Water herbs make a healing pill"

    agreement = next(f for f in card.fields if "Agreement" in f.name or "winning" in f.name)
    assert "Nothing in the pot argues" in agreement.value


def test_brewing_and_then_taking_one(harness, user, player_id):
    for code in ("blue_kelp_grass", "pearl_dew_lily"):
        harness.execute("SELECT grant_material(%s, %s, 40)", (player_id, code))

    opened = FakeInteraction(user)
    harness.run("alchemy", opened)
    view = opened.view
    view.pot = {"blue_kelp_grass": 8, "pearl_dew_lily": 8}

    brew = next(b for b in view.children if getattr(b, "label", None) == "Brew")
    card = harness.click(brew, FakeInteraction(user))
    assert "Pill" in card.title or "Elixir" in card.title

    harness.execute(
        "UPDATE player_physique SET current_hp = 1 WHERE player_id = %s", (player_id,)
    )
    shelf = FakeInteraction(user)
    harness.run("pills", shelf)
    select = shelf.view.children[0]
    select._values = [str(harness.sql(
        "SELECT pill_id FROM player_pills WHERE owner_id = %s ORDER BY pill_id DESC LIMIT 1",
        (player_id,),
    )["pill_id"])]

    # 0399: a batch of more than one asks how many first. A single pill still
    # goes straight down, so which of the two happens depends on what the brew
    # produced - and a test that assumed either would be testing the brew size.
    # Detected structurally rather than off the wording: the prompt's title is
    # the pill's own name, so looking for "Pill" in it matched both screens and
    # this test skipped the prompt it was meant to walk.
    opened = FakeInteraction(user)
    taken = harness.click(select, opened)
    picker = opened.views[-1] if opened.views else None
    if picker is not None and any(
        hasattr(b, "count") for b in getattr(picker, "children", [])
    ):
        one = next(b for b in picker.children if b.label == "1")
        taken = harness.click(one, FakeInteraction(user))

    assert "+" in taken.description
    healed = harness.sql(
        "SELECT current_hp FROM player_physique WHERE player_id = %s", (player_id,)
    )["current_hp"]
    assert healed > 1


def test_gather_can_turn_up_a_herb(harness, user, player_id, no_ambush):
    """Herbs are gathering materials, so `gather()` carries them with no edit."""
    found = set()
    for _ in range(25):
        harness.run("dev ready", FakeInteraction(user))
        harness.run("gather", FakeInteraction(user))
    held = harness.sql_all(
        "SELECT m.tier FROM player_materials pm JOIN materials m ON m.code = pm.material_code "
        "WHERE pm.player_id = %s AND m.tier IS NOT NULL AND pm.quantity > 0",
        (player_id,),
    )
    assert held, "twenty-five gathers and not one herb"


def test_professions_lists_every_craft_including_the_unstarted(harness, user, player_id):
    """Three crafts across two tables — manual refinement predates the
    professions table. A screen showing two of three would lie by omission."""
    card = harness.run("professions", FakeInteraction(user))

    names = " ".join(f.name for f in card.fields)
    for craft in ("Refiner", "Gu Refiner", "Alchemist"):
        assert craft in names, f"{craft} is missing"

    assert len(card.fields) == harness.sql("SELECT count(*) AS n FROM skills")["n"]


def test_professions_says_how_far_the_next_level_is(harness, user, player_id):
    harness.execute(
        "SELECT grant_profession_exp(%s, 'alchemy', 250, TRUE)", (player_id,)
    )
    card = harness.run("professions", FakeInteraction(user))

    # Asserted against the database rather than against a constant: other
    # tests in this module brew, so the EXP here is whatever the session has
    # earned. What must hold is the arithmetic - every level formula in this
    # game is `1 + floor(exp / per_level)`, so the distance left is
    # `level * per_level - exp`.
    truth = harness.sql(
        "SELECT level, exp, to_next FROM player_skills "
        "WHERE player_id = %s AND skill = 'alchemy'",
        (player_id,),
    )
    assert truth["to_next"] == truth["level"] * 200 - truth["exp"]

    alchemy = next(f for f in card.fields if "Alchemist" in f.name)
    assert f"level {truth['level']}" in alchemy.name
    assert f"**{truth['to_next']:,}** EXP to level {truth['level'] + 1}" in alchemy.value
    assert "herbs in the cauldron" in alchemy.value


def test_a_craft_you_have_not_begun_still_says_what_it_is_for(harness, user, player_id):
    """The `buys` line came back NULL for anybody with no row, which is exactly
    the player who needs it."""
    harness.execute(
        "DELETE FROM player_professions WHERE player_id = %s AND profession = 'gu_refining'",
        (player_id,),
    )
    card = harness.run("professions", FakeInteraction(user))

    gu = next(f for f in card.fields if "Gu Refiner" in f.name)
    assert "level 1" in gu.name
    assert "auxiliary materials on the bench" in gu.value


# ---------------------------------------------------------------------------
# Mining and the forge
# ---------------------------------------------------------------------------


def test_mine_brings_up_ore_and_nothing_else(harness, user, player_id, no_ambush):
    """The economies stay disjoint one more way: a shaft is not a meadow and
    must never hand back a herb or a fang.

    Measured as a difference rather than as a total. This player is shared by
    the whole module and has been gathering and hunting for two thousand lines;
    asserting it holds no herbs would be asserting something about the other
    tests.
    """
    def held() -> dict[str, int]:
        return {
            r["material_code"]: r["quantity"]
            for r in harness.sql_all(
                "SELECT material_code, quantity FROM player_materials "
                "WHERE player_id = %s",
                (player_id,),
            )
        }

    before = held()
    harness.run("dev ready", FakeInteraction(user))
    work(harness, user, "mine", times=5)
    after = held()

    gained = [c for c, q in after.items() if q > before.get(c, 0)]
    assert gained, "five swings and nothing came up"

    wrong = harness.sql_all(
        """
        SELECT m.code FROM unnest(%s::text[]) AS u (code)
        JOIN materials m ON m.code = u.code
        WHERE NOT EXISTS (SELECT 1 FROM ores o WHERE o.material_code = m.code)
        """,
        (gained,),
    )
    assert [r["code"] for r in wrong] == [], "mining produced something that is not ore"


def test_mine_shows_the_same_picture_as_gather(harness, user, player_id, no_ambush):
    """Region first, find second. Two world commands teaching two ways to read
    a card is the failure /explore was already shaped to avoid."""
    harness.run("dev ready", FakeInteraction(user))
    card = work(harness, user, "mine")

    where = harness.sql(
        """
        SELECT r.name, r.emoji FROM player_location pl
        JOIN regions r ON r.code = pl.region_code
        WHERE pl.player_id = %s
        """,
        (player_id,),
    )
    assert card.title == f"{where['emoji']} {where['name']}"

    emoji, material = collected(card)[0]
    stored = harness.sql(
        "SELECT m.emoji FROM materials m JOIN ores o ON o.material_code = m.code "
        "WHERE m.name = %s",
        (material,),
    )
    assert stored is not None, f"should name a real ore, got {material!r}"
    assert emoji == stored["emoji"]
    assert any(f.name == "Tries left" for f in card.fields)


def test_mine_is_on_a_cooldown_once_the_set_is_spent(harness, user, no_ambush):
    harness.run("dev ready", FakeInteraction(user))
    work(harness, user, "mine", times=5)
    with pytest.raises(GameError, match="Not yet"):
        harness.run("mine", FakeInteraction(user))


def test_where_says_how_deep_the_stone_goes(harness, user):
    card = harness.run("where", FakeInteraction(user))
    veins = next(f for f in card.fields if f.name == "Veins")
    assert "down to tier 8" in veins.value
    assert "you reach tier" in veins.value


def make_smith(harness, player_id, level: int = 30) -> None:
    """A smith with an anvil deep enough to be worth testing."""
    exp = level * 220
    harness.execute(
        """
        INSERT INTO player_professions (player_id, profession, exp, level)
        VALUES (%s, 'blacksmithing', %s, profession_level_for_exp('blacksmithing', %s))
        ON CONFLICT (player_id, profession) DO UPDATE
            SET exp = EXCLUDED.exp, level = EXCLUDED.level
        """,
        (player_id, exp, exp),
    )


def test_the_anvil_reads_what_is_on_it(harness, user, player_id):
    """No recipe list, so the screen has to say what the anvil would become."""
    from bot.cogs import forge as forge_cog

    make_smith(harness, player_id)
    harness.execute("SELECT grant_material(%s, 'gold_ore', 200)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'wolf_fang', 60)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("forge", opened)
    view = opened.view

    metal = next(b for b in view.children if getattr(b, "label", None) == "Metal")
    picking = FakeInteraction(user)
    harness.click(metal, picking)
    select = picking.view.children[0]
    select._values = ["gold_ore"]
    chosen = FakeInteraction(user)
    harness.click(select, chosen)
    modal = chosen.modal
    assert modal is not None, "picking a metal should ask how much"
    modal.amount._value = "40"
    harness.runner.run(modal.on_submit(FakeInteraction(user)))

    view.parts["wolf_fang"] = 10
    card = harness.runner.run(
        forge_cog.render_anvil(view.skill, view.slot, view.ores, view.parts)
    )

    becomes = next(f for f in card.fields if f.name == "Becomes")
    assert "potency" in becomes.value
    metal_field = next(f for f in card.fields if f.name.startswith("Metal"))
    assert "Gold Ore" in metal_field.value
    assert "leads" in metal_field.value, (
        "the metal that sets the ceiling has to be marked as the one that does"
    )

    # Metal against Strength: the chart is silent, so neither agrees nor fights.
    agreement = next(
        f for f in card.fields
        if "Agreement" in f.name or "which the leading metal" in f.name
    )
    assert "Strength" in agreement.value


def test_the_ore_ceiling_is_explained_rather_than_just_applied(harness, user, player_id):
    """A player who piles in three thousand iron and gets a tier 1 sword needs
    to be told why on the screen, not by inference from the result."""
    from bot.cogs import forge as forge_cog

    make_smith(harness, player_id)
    harness.execute("SELECT grant_material(%s, 'iron_ore', 4000)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'dragon_scale', 60)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("forge", opened)
    view = opened.view
    view.ores["iron_ore"] = 3000
    view.parts["dragon_scale"] = 20

    card = harness.runner.run(
        forge_cog.render_anvil(view.skill, view.slot, view.ores, view.parts)
    )
    becomes = next(f for f in card.fields if f.name == "Becomes")
    assert "**tier 1** piece" in becomes.value

    # Which tier the weight is worth is read off the table, not written down:
    # 0506 added a ninth band and 3,180 potency stopped being "worth tier 8"
    # the moment it did. What this test is for is that the screen SAYS it.
    weighs = harness.sql(
        "SELECT max(tier) AS tier FROM equipment_tiers WHERE potency_required <= 3180"
    )["tier"]
    assert f"worth tier {weighs}" in becomes.value, (
        f"what is on the anvil is worth saying - {becomes.value!r}"
    )
    assert "best metal is tier 1" in becomes.value, "and so is what holds it back"


def test_the_summit_lists_what_it_wants(harness, user, player_id):
    """Three thousand iron is heavy enough for tier 8, so the anvil names the
    other three conditions - as a list, not as one run-on sentence. The first
    version of this concatenated its clauses with no separator and read as
    'wants:a Blacksmith of 85 3 more kind(s) of tier 8 metal 3 of each'."""
    from bot.cogs import forge as forge_cog

    make_smith(harness, player_id)
    harness.execute("SELECT grant_material(%s, 'iron_ore', 4000)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'dragon_scale', 60)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("forge", opened)
    view = opened.view
    view.ores["iron_ore"] = 3000
    # Ore alone is an ingot - the anvil needs something off a beast before it
    # reads as a piece at all.
    view.parts["dragon_scale"] = 20

    card = harness.runner.run(
        forge_cog.render_anvil(view.skill, view.slot, view.ores, view.parts)
    )
    becomes = next(f for f in card.fields if f.name == "Becomes").value
    summit = becomes.split("Pseudo-Immortal", 1)[1]
    assert "wants a Blacksmith" in summit, "a colon is not a space"
    # The level comes from the ladder, so the screen cannot quote a stale one.
    gate = harness.sql(
        "SELECT max(level_required) AS gate FROM profession_steps"
        " WHERE ladder = 'forge_tier'"
    )["gate"]
    # Three thousand iron is already fodder enough, and there is no tier 8
    # metal here to be thin on, so two conditions stand - and they are
    # separated rather than run together, which is the whole point.
    assert f"of {gate}, 3 more kinds of tier 8 metal" in summit, summit


def test_a_first_sword_is_not_lectured_about_the_summit(harness, user, player_id):
    """Every anvil in the game is short of Pseudo-Immortal. Saying so on one
    holding five lumps of iron would put the last tier of the game on the
    screen of somebody making their first weapon."""
    from bot.cogs import forge as forge_cog

    make_smith(harness, player_id)
    harness.execute("SELECT grant_material(%s, 'iron_ore', 20)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'wolf_fang', 10)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("forge", opened)
    view = opened.view
    view.ores["iron_ore"] = 5
    view.parts["wolf_fang"] = 2

    card = harness.runner.run(
        forge_cog.render_anvil(view.skill, view.slot, view.ores, view.parts)
    )
    becomes = next(f for f in card.fields if f.name == "Becomes").value
    assert "Pseudo-Immortal" not in becomes, becomes


def test_forging_and_then_wearing_it(harness, user, player_id):
    make_smith(harness, player_id)
    harness.execute("SELECT grant_material(%s, 'gold_ore', 300)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'wolf_fang', 80)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("forge", opened)
    view = opened.view
    view.ores["gold_ore"] = 60
    view.parts["wolf_fang"] = 20

    strike = next(b for b in view.children if getattr(b, "label", None) == "Forge")
    card = harness.click(strike, FakeInteraction(user))
    assert "%" in next(f for f in card.fields if "worth" in f.name).value

    rack = FakeInteraction(user)
    harness.run("gear", rack)

    # Two steps since the picker started showing a piece rather than wearing
    # it blind: choose it, read what it gives, then put it on.
    from bot.cogs.forge import GearSelect, WearButton

    picker = next(i for i in rack.view.children if isinstance(i, GearSelect))
    picker._values = [str(harness.sql(
        "SELECT equipment_id FROM player_equipment WHERE owner_id = %s "
        "ORDER BY equipment_id DESC LIMIT 1",
        (player_id,),
    )["equipment_id"])]

    looked = harness.click(picker, FakeInteraction(user))
    # The whole point of the step: every stat, not the two a rack line fits.
    shown = next(f for f in looked.fields
                 if rack.view.chosen["name"] in f.name)
    assert shown.value.count(chr(10)) >= 2, (
        f"a piece was looked at and showed almost nothing: {shown.value!r}"
    )

    wear = next(i for i in rack.view.children if isinstance(i, WearButton))
    worn = harness.click(wear, FakeInteraction(user))
    assert "is on" in worn.description
    assert any("Worn, in total" in f.name for f in worn.fields)

    assert harness.sql(
        "SELECT count(*) FROM player_equipped WHERE player_id = %s", (player_id,)
    )["count"] == 1


def test_the_gear_screen_names_the_bare_slots(harness, user, player_id):
    card = harness.run("gear", FakeInteraction(user))
    bare = next(f for f in card.fields if f.name == "Bare")
    assert "Helm" in bare.value and "Boots" in bare.value


def test_stats_reads_the_same_numbers_a_fight_does(harness, user, player_id):
    """The sheet is not a second opinion. Whatever it prints has to be what
    `player_stat` returns, because that is the number every swing is settled
    by - a screen that rounded differently, or summed the seven sources its
    own way, would be a second source of truth about the same thing."""
    card = harness.run("stats", FakeInteraction(user))
    assert "aperture" in card.description

    rows = harness.sql_all(
        "SELECT effect_code, total, cap, capped FROM player_stat_sheet(%s) "
        "WHERE total > 0",
        (player_id,),
    )
    for row in rows:
        live = harness.sql(
            "SELECT player_stat(%s, %s) AS v", (player_id, row["effect_code"])
        )["v"]
        assert row["total"] == live, f"{row['effect_code']} disagrees with player_stat"


def test_stats_separates_the_abilities_from_the_numbers(harness, user, player_id):
    """0353 made abilities a fifth as common as ordinary stats, so which of
    them a cultivator has IS their build. The screen splits them for the same
    reason the drop tables do, and reads `gu_effects.is_ability` rather than
    keeping its own list - a second list is a list that drifts."""
    # Give them one of each kind, so the test does not depend on what earlier
    # tests happened to leave on the fixture. A destiny is the cheapest real
    # source of a stat there is.
    harness.execute(
        "INSERT INTO player_destinies (player_id, rank, code, offered, chosen_at) "
        "SELECT %s, 2, de.code, ARRAY[de.code], now() FROM destiny_effects de "
        "WHERE de.effect_code = 'resource_find' LIMIT 1 "
        "ON CONFLICT (player_id, rank) DO NOTHING",
        (player_id,),
    )
    try:
        card = harness.run("stats", FakeInteraction(user))
        titles = [f.name for f in card.fields]
        assert any("Stats" in t for t in titles), f"the flat half was not drawn: {titles}"
        assert "Fortune" in " ".join(f.value for f in card.fields)
    finally:
        harness.execute(
            "DELETE FROM player_destinies WHERE player_id = %s AND rank = 2",
            (player_id,),
        )

    # Whatever the screen calls an ability, the schema agrees.
    abilities = {
        r["name"] for r in harness.sql_all(
            "SELECT name FROM gu_effects WHERE is_ability"
        )
    }
    assert "Critical Rate" in abilities and "Life on Hit" in abilities
    assert "Attack Power" not in abilities, "a flat number is not an ability"


def test_a_capped_stat_says_so_rather_than_lying(harness, user, player_id):
    """Sitting on a ceiling is the one thing a build screen has to shout: the
    next worm of that kind is worth exactly nothing, and the sheet is where a
    player finds that out instead of wondering why their damage stopped."""
    card = harness.run("stats", FakeInteraction(user))
    capped = harness.sql_all(
        "SELECT name FROM player_stat_sheet(%s) WHERE capped", (player_id,)
    )
    body = " ".join(f.value for f in card.fields)
    for row in capped:
        assert "at the ceiling" in body, f"{row['name']} is capped and unmarked"


def test_a_base_stat_is_not_printed_as_a_percentage(harness, user, player_id):
    """0355 put three effects in the table that are points on a body rather
    than a fraction of one. Three points of Body rendered through `percent`
    reads as +300%, which is not a rounding error - it is a different
    quantity, and a player acting on it would be acting on nonsense.

    The screen also has to say what the points are WORTH, because that is the
    entire reason a base stat is interesting: the same three points are three
    health at Qi Condensation and half a million at Dewberry Immortal."""
    base = harness.sql_all(
        "SELECT code, name, cap FROM gu_effects WHERE is_base ORDER BY code"
    )
    assert base, "no base stats exist to render"
    assert {r["name"] for r in base} == {"Body", "Hide", "Sinew"}

    # Their caps are absolute points, not fractions - the old numeric(6,4)
    # could not have held them.
    assert any(float(r["cap"]) > 1 for r in base), (
        "a base cap that fits in a fraction is a percentage wearing a new name"
    )

    sheet = harness.sql_all(
        "SELECT name, is_base, total, worth FROM player_stat_sheet(%s)",
        (player_id,),
    )
    for row in sheet:
        if row["is_base"]:
            # Worth is the points times the realm multiple; never negative,
            # and zero only when the player holds none.
            assert row["worth"] >= 0
            if row["total"] > 0:
                assert row["worth"] >= row["total"], (
                    f"{row['name']} is worth less than its own points"
                )
        else:
            assert row["worth"] == 0, f"{row['name']} is not a base stat"


def test_professions_lists_the_two_new_crafts(harness, user, player_id):
    card = harness.run("professions", FakeInteraction(user))
    names = " ".join(f.name for f in card.fields)
    assert "Miner" in names and "Blacksmith" in names

    smith = next(f for f in card.fields if "Blacksmith" in f.name)
    assert "beast materials on the anvil" in smith.value
    miner = next(f for f in card.fields if "Miner" in f.name)
    assert "veins down to tier" in miner.value


def test_the_inventory_shelves_ore_apart_from_herbs(harness, user, player_id):
    """Both are `gathering` in the schema and belong to different crafts. A
    smith with forty ores would otherwise bury the herbs under them."""
    harness.execute("SELECT grant_material(%s, 'blazing_sunsteel', 5)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'blue_kelp_grass', 5)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'spirit_rice', 5)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("inventory", opened, category=None)

    ore = satchel_shelf(opened.view, "ore")
    herbs = satchel_shelf(opened.view, "herb")
    plain = satchel_shelf(opened.view, "gathering")

    assert "Blazing Sunsteel" in ore
    assert "Blue Kelp Grass" in herbs
    assert "Spirit Rice" in plain
    assert "Blazing Sunsteel" not in herbs and "Blazing Sunsteel" not in plain


def test_the_physique_screen_says_what_the_body_grants(harness, user, player_id):
    """Thirty-six bodies started granting something in 0070. A screen that
    still showed three multipliers would leave the player to find out by
    fighting."""
    original = harness.sql(
        "SELECT physique_id FROM player_physique WHERE player_id = %s", (player_id,)
    )["physique_id"]
    harness.execute(
        "UPDATE player_physique SET physique_id = "
        "(SELECT physique_id FROM physiques WHERE code = 'flameblood_physique') "
        "WHERE player_id = %s",
        (player_id,),
    )
    try:
        card = harness.run("physique", FakeInteraction(user))
        born = next(f for f in card.fields if f.name == "Born with")
        assert "Flameblood" in born.value
        assert "Blood Runs Hot" in born.value, "the body should say what it is"
        assert "less from Fire" in born.value, "and what it turns aside"
    finally:
        harness.execute(
            "UPDATE player_physique SET physique_id = %s WHERE player_id = %s",
            (original, player_id),
        )


def test_every_short_form_points_at_a_real_command(harness):
    """The table is hand-written, so it is exactly the kind of thing that rots
    when a command is renamed. Asking the tree is the only way it stays true."""
    from bot.cogs.prefix import ALIASES

    names = {c.name for c in harness.bot.tree.get_commands()}
    broken = {short: full for short, full in ALIASES.items() if full not in names}
    assert broken == {}


def test_no_short_form_shadows_a_real_command(harness):
    """A real name always wins, so an alias that IS a name would be dead text
    pretending to do something."""
    from bot.cogs.prefix import ALIASES

    names = {c.name for c in harness.bot.tree.get_commands()}
    assert [s for s in ALIASES if s in names] == []


def test_i_m_mines_and_i_h_hunts(harness, user, player_id, no_ambush):
    from bot.cogs.prefix import ALIASES

    assert (ALIASES["m"], ALIASES["h"], ALIASES["f"]) == ("mine", "hunt", "forge")

    harness.run("dev ready", FakeInteraction(user))
    said = say(harness, user, "I m")
    assert said.answer is not None, "a mining card"
    assert any(f.name == "Tries left" for f in said.answer.fields), "which is a seam"
    assert said.view is not None, "and it comes with the button"


def test_a_short_form_still_will_not_start_a_sentence(harness, user, player_id):
    """`I m going out` is a typo for I'm, not a mining trip. The no-arguments
    rule already covers it, and this is the test that says so."""
    for sentence in ("I m going out", "I h no", "I f it", "I c you"):
        said = say(harness, user, sentence)
        assert said.replies == [], f"{sentence!r} should have been left alone"


def test_a_short_form_cannot_smuggle_a_command_into_a_group(harness, user, player_id):
    """`I dev r` must not reach /refine: the table is consulted against the
    pool the walk has reached, not against the top level."""
    from bot.cogs.prefix import resolve

    assert resolve(harness.bot.tree, ["dev", "r"]) is None
    assert resolve(harness.bot.tree, ["r"])[0].name == "refine"


def test_choosing_pages_asks_before_it_spends_them(harness, user, player_id):
    """Six pages is a real cost. The select used to consume them on the spot."""
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))
    pages = [make_page(harness, player_id, 2, "fire", "attack", 80) for _ in range(2)]

    opened = FakeInteraction(user)
    harness.run("refine", opened)
    select = opened.view.children[0]
    select._values = [str(p) for p in pages]
    harness.click(select, FakeInteraction(user))

    # Ticking stages the batch; the Refine button is what asks.
    go = next(b for b in opened.view.children
              if str(getattr(b, "label", "")).startswith("Refine "))
    shown = FakeInteraction(user)
    card = harness.click(go, shown)

    assert card.title.startswith("Refine 2 page"), card.title
    assert any(f.name == "Becomes" for f in card.fields)
    assert any(f.name == "The last roll" for f in card.fields)

    # Nothing spent yet: that is the whole point of the screen.
    assert harness.sql(
        "SELECT count(*) AS n FROM manual_pages "
        "WHERE page_id = ANY(%s) AND consumed_at IS NULL", (pages,)
    )["n"] == 2


def test_backing_off_leaves_the_pages_alone(harness, user, player_id):
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))
    pages = [make_page(harness, player_id, 2, "fire", "attack", 80) for _ in range(2)]

    opened = FakeInteraction(user)
    harness.run("refine", opened)
    select = opened.view.children[0]
    select._values = [str(p) for p in pages]
    harness.click(select, FakeInteraction(user))

    go = next(b for b in opened.view.children
              if str(getattr(b, "label", "")).startswith("Refine "))
    shown = FakeInteraction(user)
    harness.click(go, shown)

    back = next(b for b in shown.view.children if getattr(b, "label", "") == "Back off")
    harness.click(back, FakeInteraction(user))

    assert harness.sql(
        "SELECT count(*) AS n FROM manual_pages "
        "WHERE page_id = ANY(%s) AND consumed_at IS NULL", (pages,)
    )["n"] == 2


def test_confirming_refines_and_names_the_band(harness, user, player_id):
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))
    pages = [make_page(harness, player_id, 3, "fire", "attack", 90) for _ in range(3)]

    opened = FakeInteraction(user)
    harness.run("refine", opened)
    select = opened.view.children[0]
    select._values = [str(p) for p in pages]
    harness.click(select, FakeInteraction(user))

    ask = next(b for b in opened.view.children
               if str(getattr(b, "label", "")).startswith("Refine "))
    shown = FakeInteraction(user)
    harness.click(ask, shown)

    go = next(b for b in shown.view.children if getattr(b, "label", "") == "Refine")
    card = harness.click(go, FakeInteraction(user))

    assert any(f.name == "The last roll" for f in card.fields), card.fields
    band = harness.sql(
        "SELECT quality FROM manuals WHERE created_by = %s ORDER BY manual_id DESC LIMIT 1",
        (player_id,),
    )
    assert band["quality"] in {
        r["code"] for r in harness.sql_all("SELECT rarity AS code FROM manual_qualities")
    }
    assert harness.sql(
        "SELECT count(*) AS n FROM manual_pages "
        "WHERE page_id = ANY(%s) AND consumed_at IS NULL", (pages,)
    )["n"] == 0, "confirming does spend them"


def test_the_forecast_agrees_with_what_refining_produces(harness, player_id):
    """The reason the preview calls `refine_forecast` rather than reimplementing
    it. Tier and archetype are decided before the dice, so they must match."""
    harness.execute("DELETE FROM manual_pages WHERE owner_id = %s", (player_id,))
    pages = [make_page(harness, player_id, 4, "wood", "cultivation", 85) for _ in range(3)]

    look = harness.sql(
        "SELECT forecast_tier, archetype, base_harmony FROM refine_forecast(%s, %s)",
        (player_id, pages),
    )
    got = harness.sql("SELECT * FROM refine(%s, %s)", (player_id, pages))

    assert got["tier"] == look["forecast_tier"]
    assert got["archetype"] == look["archetype"]
    # The roll is worth four points either way and nothing more.
    assert abs(got["harmony"] - float(look["base_harmony"])) <= 4.5


def test_a_set_survives_the_screen_it_was_opened_on(harness, user, player_id, no_ambush):
    """The whole reason the count is a row. A view times out, a bot restarts,
    a phone scrolls away — and none of that may cost the four tries left."""
    harness.run("dev ready", FakeInteraction(user))

    opened = FakeInteraction(user)
    harness.run("gather", opened)
    harness.click(opened.view.children[0], FakeInteraction(user))

    # Throw the screen away entirely, the way a timeout would.
    del opened

    resumed = FakeInteraction(user)
    harness.run("gather", resumed)
    left = next(f for f in resumed.last.fields if f.name == "Tries left")
    assert "4" in left.value
    assert "Picking up where you left off" in resumed.last.description

    assert harness.sql(
        "SELECT tries_left FROM player_action_tries "
        "WHERE player_id = %s AND action = 'gather'", (player_id,)
    )["tries_left"] == 4


def test_a_spent_set_takes_the_row_with_it(harness, user, player_id, no_ambush):
    """`tries_left > 0` is a CHECK, so the last try deletes rather than zeroes.
    0060 is why that is written down."""
    harness.run("dev ready", FakeInteraction(user))
    work(harness, user, "gather", times=5)

    assert harness.sql(
        "SELECT count(*) AS n FROM player_action_tries "
        "WHERE player_id = %s AND action = 'gather'", (player_id,)
    )["n"] == 0


def test_a_sixth_press_is_refused_rather_than_granted(harness, user, player_id, no_ambush):
    """Two fast clicks are two interactions, and only the row can tell them
    apart — so the button asks the database before it draws anything."""
    harness.run("dev ready", FakeInteraction(user))
    opened = FakeInteraction(user)
    harness.run("gather", opened)
    button = opened.view.children[0]
    for _ in range(5):
        harness.click(button, FakeInteraction(user))

    with pytest.raises(GameError, match="finished"):
        harness.click(button, FakeInteraction(user))


def test_one_cooldown_covers_the_whole_set(harness, user, player_id, no_ambush):
    """Five tries, one claim. If each try claimed, the second would refuse."""
    harness.run("dev ready", FakeInteraction(user))
    card = work(harness, user, "gather", times=5)
    assert len(collected(card)) == 5


def test_the_three_seams_keep_separate_sets(harness, user, player_id, no_ambush):
    """Sparse rows keyed by action, like the cooldowns beside them."""
    harness.run("dev ready", FakeInteraction(user))
    work(harness, user, "gather", times=2)
    work(harness, user, "mine", times=1)

    rows = {
        r["action"]: r["tries_left"]
        for r in harness.sql_all(
            "SELECT action, tries_left FROM player_action_tries WHERE player_id = %s",
            (player_id,),
        )
    }
    assert rows == {"gather": 3, "mine": 4}


def test_the_sheet_says_what_a_craft_root_grants(harness, user, player_id):
    """A root whose whole identity is the forge has to say so on the sheet,
    or the only way to learn it is to forge twice and compare."""
    original = harness.sql(
        "SELECT root_code FROM player_character WHERE player_id = %s", (player_id,)
    )["root_code"]
    harness.execute(
        "UPDATE player_character SET root_code = 'heavens_forge_root' WHERE player_id = %s",
        (player_id,),
    )
    try:
        card = harness.run("profile", FakeInteraction(user), user=None)
        root = next(
            (f for f in card.fields if "Root" in f.name),
            None,
        )
        assert root is not None, [f.name for f in card.fields]
        assert "Heaven's Forge Root" in root.value
        assert "Smith's Hand" in root.value, "the effect, not just the flavour"
        assert "%" in root.value
    finally:
        harness.execute(
            "UPDATE player_character SET root_code = %s WHERE player_id = %s",
            (original, player_id),
        )


def test_the_inventory_leads_with_the_purse(harness, user, player_id):
    """Money is the one line a player checks before deciding anything else."""
    # Read as a delta: this player is shared by the whole module and has been
    # breaking through realms and killing first-of-species for three thousand
    # lines, so it already has a balance.
    before = harness.sql("SELECT jade_held(%s) AS n", (player_id,))["n"]
    harness.execute("SELECT grant_jade(%s, 7, 'test_faucet')", (player_id,))
    card = harness.run("inventory", FakeInteraction(user), category=None)

    purse = next(f for f in card.fields if "Spirit Jade" in f.name)
    assert card.fields[0].name == purse.name, "and it leads"
    assert f"**{before + 7:,}**" in purse.value

    # Listed once, not twice: no shelf repeats what the purse already says.
    assert sum("Spirit Jade" in f.value for f in card.fields) == 0


def test_jade_can_be_put_into_a_trade(harness, user, player_id):
    """The reason it is a material rather than a wallet: `/trade` already had
    a pile for it, so this needed no trade code at all."""
    from bot.cogs import trade as trade_cog

    harness.execute("SELECT grant_jade(%s, 40, 'test_faucet')", (player_id,))
    held = harness.sql_all(
        """
        SELECT pm.material_code AS code, m.name, m.category
        FROM player_materials pm JOIN materials m ON m.code = pm.material_code
        WHERE pm.player_id = %s AND pm.quantity > 0 AND m.category = 'currency'
        """,
        (player_id,),
    )
    assert [r["name"] for r in held] == ["Spirit Jade"], (
        "jade has to be visible to the same query the trade picker uses"
    )
    assert trade_cog is not None


# ---------------------------------------------------------------------------
# The auction house
# ---------------------------------------------------------------------------


def a_rival(harness) -> int:
    """A second player, to buy from. The board needs two sides."""
    return harness.sql(
        """
        INSERT INTO players (discord_id, discord_name) VALUES (%s, 'Rival')
        ON CONFLICT (discord_id) DO UPDATE SET discord_name = 'Rival'
        RETURNING player_id
        """,
        (TEST_DISCORD_ID + 7,),
    )["player_id"]


def test_selling_needs_the_fee_and_says_so(harness, user, player_id):
    harness.execute(
        "UPDATE player_materials SET quantity = 0 "
        "WHERE player_id = %s AND material_code = 'spirit_jade'", (player_id,)
    )
    with pytest.raises(GameError, match="costs"):
        harness.run("sell", FakeInteraction(user))


def test_a_listing_takes_the_goods_out_of_your_hands(harness, user, player_id):
    """Escrow is the whole design. If the seller still holds it, they can sell
    it twice."""
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (player_id,))
    harness.execute("SELECT grant_material(%s, 'iron_ore', 40)", (player_id,))

    def ore(who: str) -> int:
        return harness.sql(
            "SELECT COALESCE(sum(quantity), 0) AS n FROM player_materials "
            f"WHERE player_id = {who} AND material_code = 'iron_ore'",
            (player_id,) if who == "%s" else (),
        )["n"]

    # Deltas, not totals: this player is shared by the whole module and has
    # been mining for a thousand lines.
    mine_before, house_before = ore("%s"), ore("auction_house()")
    listing = harness.sql(
        "SELECT auction_list_material(%s, 'iron_ore', 30, 12) AS id", (player_id,)
    )["id"]

    assert ore("%s") == mine_before - 30, "thirty left the seller"
    assert ore("auction_house()") == house_before + 30, "and arrived at the house"

    harness.execute("SELECT auction_cancel(%s, %s)", (player_id, listing))
    assert ore("%s") == mine_before, "and comes back on a cancellation"
    assert ore("auction_house()") == house_before, "leaving the house holding none"


def test_the_board_shows_what_is_up_and_sells_it(harness, user, player_id):
    rival = a_rival(harness)
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (player_id,))
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (rival,))
    harness.execute("SELECT grant_material(%s, 'iron_ore', 40)", (rival,))
    listing = harness.sql(
        "SELECT auction_list_material(%s, 'iron_ore', 5, 9) AS id", (rival,)
    )["id"]

    try:
        opened = FakeInteraction(user)
        harness.run("auction", opened)
        card = opened.last
        assert any("purse" in f.name.lower() for f in card.fields)
        board = next(f for f in card.fields if "board" in f.name.lower())
        assert "Iron Ore" in board.value

        buy = next(
            item for item in opened.view.children
            if getattr(item, "placeholder", "") == "Buy…"
        )
        bought = choose(harness, buy, listing, FakeInteraction(user))
        assert "Bought for" in bought.description

        assert harness.sql(
            "SELECT status, buyer_id FROM auction_listings WHERE listing_id = %s",
            (listing,),
        )["status"] == "sold"
    finally:
        harness.execute(
            "UPDATE auction_listings SET status = 'cancelled', ended_at = now() "
            "WHERE seller_id = %s AND status = 'open'", (rival,)
        )


def test_you_cannot_buy_your_own_listing(harness, user, player_id):
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (player_id,))
    harness.execute("SELECT grant_material(%s, 'iron_ore', 40)", (player_id,))
    listing = harness.sql(
        "SELECT auction_list_material(%s, 'iron_ore', 5, 9) AS id", (player_id,)
    )["id"]
    try:
        with pytest.raises(psycopg.errors.CheckViolation):
            harness.execute("SELECT auction_buy(%s, %s)", (player_id, listing))
    finally:
        harness.execute("SELECT auction_cancel(%s, %s)", (player_id, listing))


def test_your_own_listings_are_not_offered_back_to_you(harness, user, player_id):
    """`auction_buy` refuses it anyway, so a select that only ever errors
    would be a trap rather than an option."""
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (player_id,))
    harness.execute("SELECT grant_material(%s, 'iron_ore', 40)", (player_id,))
    listing = harness.sql(
        "SELECT auction_list_material(%s, 'iron_ore', 5, 9) AS id", (player_id,)
    )["id"]
    try:
        opened = FakeInteraction(user)
        harness.run("auction", opened)
        buys = [
            item for item in opened.view.children
            if getattr(item, "placeholder", "") == "Buy…"
        ]
        offered = {o.value for sel in buys for o in sel.options}
        assert str(listing) not in offered

        takeback = next(
            item for item in opened.view.children
            if getattr(item, "placeholder", "") == "Take one back…"
        )
        assert str(listing) in {o.value for o in takeback.options}
    finally:
        harness.execute(
            "SELECT auction_cancel(%s, %s)", (player_id, listing)
        )


def test_money_cannot_be_listed_for_money(harness, user, player_id):
    """What the house pays in is the one thing it will not take.

    Not "money" in general: a listing is bought with jade, so Spirit Stones on
    the board are stones for jade, which is an exchange and the point of a
    market. Only jade for jade means nothing.
    """
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (player_id,))
    with pytest.raises(psycopg.errors.CheckViolation, match="money for money"):
        harness.execute(
            "SELECT auction_list_material(%s, auction_currency(), 5, 9)",
            (player_id,),
        )


def test_a_dungeon_key_is_stock_on_the_board(harness, user, player_id):
    """0204 built the key as a material so it could change hands, then put it
    in the purse so it would not clutter a shelf. The picker read that display
    choice as a rule and hid it from the auction, which nobody decided."""
    rival = a_rival(harness)
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (player_id,))
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (rival,))
    harness.execute("SELECT grant_material(%s, 'dungeon_key', 1)", (rival,))

    listing = harness.sql(
        "SELECT auction_list_material(%s, 'dungeon_key', 1, 9) AS id", (rival,)
    )["id"]
    try:
        opened = FakeInteraction(user)
        harness.run("auction", opened)
        board = next(f for f in opened.last.fields if "board" in f.name.lower())
        assert "Dungeon Key" in board.value, "a listed key is not on the board"
    finally:
        harness.execute("SELECT auction_cancel(%s, %s)", (rival, listing))


def test_the_seller_is_offered_a_key_but_never_the_house_currency(
    harness, user, player_id
):
    """The picker and the function have to agree on what may be listed - the
    screen hiding one set while the function refuses another is how the key
    became unsellable without a decision."""
    harness.execute("SELECT grant_material(%s, 'dungeon_key', 1)", (player_id,))
    harness.execute("SELECT grant_jade(%s, 50, 'test_faucet')", (player_id,))

    stock = harness.sql_all(auction.STOCK["material"]["sql"], (player_id,))
    codes = {row["ref"] for row in stock}
    assert "dungeon_key" in codes, "a key is stock and the picker should offer it"
    assert harness.sql("SELECT auction_currency() AS c")["c"] not in codes


def test_reroll_shows_the_real_odds_before_you_spend(harness, user, player_id):
    """The screen quotes `reroll_odds`, which is a view over the same weights
    the roll uses — so what it promises and what it does cannot drift."""
    opened = FakeInteraction(user)
    harness.run("reroll", opened)
    card = opened.last

    ladder = next(f for f in card.fields if "ladder" in f.name.lower())
    assert "Legendary or rarer" in ladder.value
    assert "%" in ladder.value and "Jade" not in ladder.name

    published = harness.sql(
        "SELECT round(or_better * 100, 1) AS pct FROM reroll_odds "
        "WHERE trait = 'root' AND rarity = 'legendary'"
    )["pct"]
    assert f"{float(published):.0f}%" in ladder.value or "5%" in ladder.value


def test_reroll_refuses_before_the_character_is_finished(harness, user, player_id):
    """/register still has free rerolls in it. Charging for what is already
    free would be a trap."""
    harness.execute(
        "UPDATE player_character SET confirmed_at = NULL WHERE player_id = %s",
        (player_id,),
    )
    try:
        with pytest.raises(GameError, match="Finish creating"):
            harness.run("reroll", FakeInteraction(user))
    finally:
        harness.execute(
            "UPDATE player_character SET confirmed_at = now() WHERE player_id = %s",
            (player_id,),
        )


def test_a_roll_you_cannot_pay_for_says_so(harness, user, player_id):
    from bot.cogs import reroll as reroll_cog

    harness.execute(
        "UPDATE player_materials SET quantity = 0 "
        "WHERE player_id = %s AND material_code = 'spirit_jade'", (player_id,)
    )
    opened = FakeInteraction(user)
    harness.run("reroll", opened)
    button = next(
        b for b in opened.view.children
        if isinstance(b, reroll_cog.RollButton) and b.count == 1
    )
    with pytest.raises(GameError, match="Not enough Spirit Jade"):
        harness.click(button, FakeInteraction(user))


def test_daily_pays_and_then_reports_the_wait(harness, user, player_id):
    harness.execute("DELETE FROM player_daily WHERE player_id = %s", (player_id,))

    card = harness.run("daily", FakeInteraction(user))
    assert "Spirit Jade" in card.title
    run = next(f for f in card.fields if f.name == "Run")
    assert "1** day" in run.value

    again = harness.run("daily", FakeInteraction(user))
    assert again.title.endswith("Not yet")
    assert "ready" in again.description


def test_i_d_takes_the_daily(harness, user, player_id):
    from bot.cogs.prefix import ALIASES

    assert ALIASES["d"] == "daily"
    harness.execute("DELETE FROM player_daily WHERE player_id = %s", (player_id,))
    said = say(harness, user, "I d")
    assert said.answer is not None
    assert "Spirit Jade" in said.answer.title


def test_cooldowns_carries_the_two_world_clocks(harness, user):
    """The world beast and the ring are the only two timers in the game that
    are not cooldowns, and they were the only two /cooldowns did not show -
    which left "what you are waiting on" answering the smaller half of it.

    Neither can be derived the way the rows above them are: `cooldown_status`
    reads `player_cooldowns`, and these live one to a server rather than one
    to a cultivator.

    Whichever way each currently stands, it has to say which. A line that
    names the thing and then trails off is worse than no line at all, and
    both branches are reachable depending on what the world is doing when
    this runs - so both are accepted and silence is not.
    """
    card = harness.run("cooldowns", FakeInteraction(user))

    world = next((f for f in card.fields if f.name == "The world"), None)
    assert world is not None, [f.name for f in card.fields]

    assert "World boss" in world.value
    assert ("nothing standing" in world.value
            or "% left" in world.value), world.value

    assert "Tournament" in world.value
    assert ("no ring open" in world.value
            or "sign-ups close" in world.value), world.value


def test_rest_closes_what_it_can_and_is_on_a_cooldown(harness, user, player_id):
    harness.run("dev ready", FakeInteraction(user))
    harness.execute(
        "UPDATE player_physique SET current_hp = 1 WHERE player_id = %s", (player_id,)
    )
    card = harness.run("rest", FakeInteraction(user))
    assert "HP" in card.title
    body = next(f for f in card.fields if f.name == "Body")
    assert "/" in body.value

    with pytest.raises(GameError, match="Not yet"):
        harness.run("rest", FakeInteraction(user))


def test_meditate_offers_both_axes_and_spends_one_hour(harness, user, player_id):
    """A second cooldown would let a player take both every time, and then
    there is no choice in it at all."""
    harness.run("dev ready", FakeInteraction(user))
    harness.execute(
        "UPDATE player_cultivation SET focus_path = 'fire' WHERE player_id = %s",
        (player_id,),
    )
    opened = FakeInteraction(user)
    harness.run("meditate", opened)
    labels = {b.label for b in opened.view.children}
    assert "Cultivation" in labels
    assert "Fire Path" in labels, "the focus Path is the other half"

    button = next(b for b in opened.view.children if b.label == "Cultivation")
    card = harness.click(button, FakeInteraction(user))
    assert "cultivation" in card.title

    # The hour is spent, so the other axis is not also free.
    again = FakeInteraction(user)
    harness.run("meditate", again)
    other = next(b for b in again.view.children if b.label == "Fire Path")
    with pytest.raises(GameError, match="Not yet"):
        harness.click(other, FakeInteraction(user))


def test_meditate_offers_no_path_button_without_a_path(harness, user, player_id):
    """A button that always refuses is worse than a button that is not there."""
    harness.run("dev ready", FakeInteraction(user))
    harness.execute(
        "UPDATE player_cultivation SET focus_path = NULL WHERE player_id = %s",
        (player_id,),
    )
    try:
        opened = FakeInteraction(user)
        harness.run("meditate", opened)
        assert {b.label for b in opened.view.children} == {"Cultivation"}
        toward = next(f for f in opened.last.fields if f.name == "Toward")
        assert "/focus" in toward.value
    finally:
        harness.execute(
            "UPDATE player_cultivation SET focus_path = 'fire' WHERE player_id = %s",
            (player_id,),
        )


def test_cooldowns_groups_every_timer_under_a_heading(harness, user, player_id):
    harness.run("dev ready", FakeInteraction(user))
    card = harness.run("cooldowns", FakeInteraction(user))
    assert "ready" in card.description

    headings = [f.name for f in card.fields]
    assert headings[:1] == ["Gathering"], "sections come in sort_order"
    for section in ("Gathering", "Combat", "Recovery", "Purse", "Active boosts"):
        assert section in headings, section

    # Every label the display table carries is drawn somewhere, under the
    # section it was given rather than one this file decided on.
    written = "\n".join(f"{f.name}: {f.value}" for f in card.fields)
    for row in harness.sql_all("SELECT label, section FROM cooldown_display"):
        assert row["label"] in written, row["label"]
        block = next(f for f in card.fields if f.name == row["section"])
        assert row["label"] in block.value, f"{row['label']} under the wrong heading"

    assert "Ready" in next(f for f in card.fields if f.name == "Combat").value


def test_a_spent_action_shows_the_wait_rather_than_leaving_the_list(
    harness, user, player_id
):
    harness.run("dev ready", FakeInteraction(user))
    harness.execute(
        "UPDATE player_physique SET current_hp = 1 WHERE player_id = %s", (player_id,)
    )
    harness.run("rest", FakeInteraction(user))

    card = harness.run("cooldowns", FakeInteraction(user))
    recovery = next(f for f in card.fields if f.name == "Recovery")
    rest = next(line for line in recovery.value.splitlines() if "Rest" in line)
    assert "Ready" not in rest, "it was just spent"
    assert any(c.isdigit() for c in rest), f"no wait shown: {rest}"
    # The one beside it is untouched, which is the whole point of a per-action
    # clock rather than a global one.
    assert "Ready" in next(
        line for line in recovery.value.splitlines() if "Meditate" in line
    )


def test_cooldowns_names_a_boost_that_is_running(harness, user, player_id):
    harness.execute(
        """
        INSERT INTO player_boosts (player_id, kind, magnitude, hours_left)
        VALUES (%s, 'cultivation_rate', 0.25, 6)
        ON CONFLICT (player_id, kind, magnitude) DO UPDATE
            SET hours_left = 6
        """,
        (player_id,),
    )
    try:
        card = harness.run("cooldowns", FakeInteraction(user))
        boosts = next(f for f in card.fields if f.name == "Active boosts")
        assert "Quickened Cultivation" in boosts.value
        assert "+25%" in boosts.value
        # Hours of settled time, not a countdown - a boost sitting unspent
        # while nobody cultivates is still worth six hours.
        assert "cultivation left" in boosts.value
    finally:
        harness.execute(
            "DELETE FROM player_boosts WHERE player_id = %s", (player_id,)
        )

    card = harness.run("cooldowns", FakeInteraction(user))
    boosts = next(f for f in card.fields if f.name == "Active boosts")
    # /alchemy, not /brew. The card said /brew and no such command has ever
    # existed - the command is /alchemy, described as "Brew herbs into a
    # pill". This assertion was pinning the typo in place.
    assert "/alchemy" in boosts.value, (
        "an empty section still says where they come from"
    )



def test_insight_lists_a_path_and_what_it_pays(harness, user, player_id):
    harness.execute(
        """
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (%s, 'fire', 50000, 6)
        ON CONFLICT (player_id, path_code) DO UPDATE SET insight = 50000, tier = 6
        """,
        (player_id,),
    )
    try:
        card = harness.run("insight", FakeInteraction(user))
        # What a tier pays is said once, in the heading of its group - it is a
        # function of the tier, so repeating it on every Path in the group was
        # the same sentence with the name changed.
        field = next(f for f in card.fields if "Grandmaster" in f.name)
        assert "damage" in field.name
        assert "resistance" in field.name, (
            "Grandmaster is the first tier that pays resistance"
        )
        assert "Fire" in field.value, "the Path itself is a line in the group"
    finally:
        harness.execute(
            "DELETE FROM player_path_attainment WHERE player_id = %s "
            "AND path_code = 'fire'",
            (player_id,),
        )


def test_insight_does_not_list_thirty_four_paths(harness, user, player_id):
    """Discord allows 25 fields. The untouched Paths are summarised instead,
    which is also the more useful half for somebody just starting."""
    card = harness.run("insight", FakeInteraction(user))
    assert len(card.fields) <= 25

    # Grouping by tier means the fields are tiers, not Paths - so 34 Paths fit
    # in at most eleven of them and none of the begun ones has to be dropped.
    assert any("quickest to start" in f.name or "The rest" in f.name
               for f in card.fields)
    for field in card.fields:
        assert len(field.value) <= 1024, f"{field.name} is over the field limit"
    assert sum(len(f.name) + len(f.value) for f in card.fields) <= 6000


def test_insight_says_nothing_it_is_not_paying(harness, user, player_id):
    """A +0% beside a real bonus reads as a bonus that has stopped working."""
    harness.execute(
        """
        INSERT INTO player_path_attainment (player_id, path_code, insight, tier)
        VALUES (%s, 'water', 10, 1)
        ON CONFLICT (player_id, path_code) DO UPDATE SET insight = 10, tier = 1
        """,
        (player_id,),
    )
    try:
        card = harness.run("insight", FakeInteraction(user))
        field = next(f for f in card.fields if "Ordinary" in f.name)
        assert "Water" in field.value

        # Ordinary pays neither of the two, so the heading says so outright
        # rather than drawing a +0% that reads as a bonus which has stopped
        # working.
        assert "pays nothing yet" in field.name
        assert "+0%" not in field.name and "+0%" not in field.value
        assert "damage" not in field.value
        assert "resistance" not in field.value
    finally:
        harness.execute(
            "DELETE FROM player_path_attainment WHERE player_id = %s "
            "AND path_code = 'water'",
            (player_id,),
        )

def test_the_tutorial_opens_and_turns_pages(harness, user):
    opened = FakeInteraction(user)
    harness.run("tutorial", opened)
    card = opened.last
    assert "Getting Started" in card.title
    assert "1 of" in card.footer.text

    buttons = opened.view.children
    assert len(buttons) >= 10, "one button per system"

    jade = next(b for b in buttons if b.label == "Spirit Jade")
    turned = harness.click(jade, FakeInteraction(user))
    assert "Spirit Jade" in turned.title
    assert "Daily" in turned.description or "/daily" in turned.description


def test_the_tutorial_needs_no_character(harness):
    """Somebody deciding whether to register should be able to read what they
    would be registering for."""
    stranger = FakeUser(TEST_DISCORD_ID + 99, "Stranger")
    opened = FakeInteraction(stranger)
    harness.run("tutorial", opened)
    assert opened.last is not None


def test_the_satchel_can_reach_every_material_it_holds(harness, user, player_id):
    """The screen this replaced cut each shelf at twenty and printed a bare
    ellipsis, so the twenty-first ore was neither shown nor counted. Nothing a
    player carries may be unreachable by turning pages."""
    held = harness.sql_all(
        """
        SELECT m.name,
               CASE WHEN o.material_code IS NOT NULL THEN 'ore'
                    WHEN m.tier IS NOT NULL          THEN 'herb'
                    ELSE m.category END AS shelf
        FROM player_materials pm
        JOIN materials m ON m.code = pm.material_code
        LEFT JOIN ores o ON o.material_code = pm.material_code
        WHERE pm.player_id = %s AND pm.quantity > 0 AND m.category <> 'currency'
        """,
        (player_id,),
    )
    assert held, "this test needs a satchel with something in it"

    opened = FakeInteraction(user)
    harness.run("inventory", opened, category=None)

    everything = "".join(
        satchel_shelf(opened.view, code)
        for code in ("ore", "herb", "gathering", "beast")
    )
    missing = [row["name"] for row in held if row["name"] not in everything]
    assert not missing, f"carried but unreachable: {missing}"


def test_the_satchel_opens_on_a_shelf_with_something_on_it(harness, user, player_id):
    """Opening on an empty Ore shelf when the satchel is full of herbs makes
    the player press a button to be told what could have been shown."""
    harness.execute(
        "DELETE FROM player_materials WHERE player_id = %s AND material_code IN "
        "(SELECT material_code FROM ores)",
        (player_id,),
    )
    harness.execute("SELECT grant_material(%s, 'spirit_rice', 4)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("inventory", opened, category=None)
    assert opened.view.shelf != "ore", "opened on an empty shelf"
    assert opened.view.card().description.strip(), "opened on an empty page"


def test_a_manual_that_is_not_a_cultivation_manual_still_shows_its_worth(
    harness, user, player_id
):
    """Both screens quoted `cultivation_rate_bonus` and nothing else, which
    describes about one manual in five. An offensive book spends its whole
    budget on attack and was listed as "+0% cultivation" - indistinguishable
    on the page from a manual with nothing in it at all."""
    manual_id = harness.sql(
        """
        INSERT INTO manuals (name, tier, required_rank, archetype,
                             attack_bonus, defense_bonus)
        VALUES ('Test Fist Canon', 2, 1, 'offensive', 0.0800, 0.0300)
        RETURNING manual_id
        """
    )["manual_id"]
    harness.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (player_id, manual_id),
    )

    try:
        opened = FakeInteraction(user)
        harness.run("manuals", opened)

        pages = ""
        for _ in range(opened.view.page_count()):
            pages += opened.view.card().description
            opened.view.page += 1

        assert "Test Fist Canon" in pages
        line = next(
            block for block in pages.split("`T")
            if "Test Fist Canon" in block
        )
        assert "8%" in line, f"the attack bonus is not on the line: {line!r}"
        assert "0% cultivation" not in line, "still quoting the empty stat"
    finally:
        harness.execute("DELETE FROM player_manuals WHERE manual_id = %s", (manual_id,))
        harness.execute("DELETE FROM manuals WHERE manual_id = %s", (manual_id,))


def test_the_equipment_screen_lists_the_manuals_it_is_offering(harness, user, player_id):
    """A select option carries a hundred characters and a manual has twelve
    bonuses, so the dropdown can never be where a player compares books. The
    card lists the same page the dropdown is offering, with the numbers."""
    manual_id = harness.sql(
        """
        INSERT INTO manuals (name, tier, required_rank, archetype,
                             cultivation_rate_bonus)
        VALUES ('Test Breathing Sutra', 3, 1, 'cultivation', 0.0600)
        RETURNING manual_id
        """
    )["manual_id"]
    harness.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (player_id, manual_id),
    )

    try:
        opened = FakeInteraction(user)
        harness.run("equipment", opened)
        card = opened.last

        shelf = next(
            (f for f in card.fields if "On the shelf" in f.name), None
        )
        assert shelf is not None, "the equipment card offers a dropdown and no list"
        assert "Test Breathing Sutra" in shelf.value
        assert "6%" in shelf.value, "listed without the number that decides it"

        # And the list has to be the page the dropdown is on, or the screen is
        # describing manuals the player cannot currently pick.
        offered = {
            option.value
            for item in opened.view.children
            if isinstance(item, discord.ui.Select)
            for option in item.options
            if option.value != "clear"
        }
        listed = {str(row["manual_id"]) for row in opened.view.page_rows()}
        assert listed <= offered, "the card lists manuals the dropdown does not"
    finally:
        harness.execute("DELETE FROM player_manual_slots WHERE manual_id = %s", (manual_id,))
        harness.execute("DELETE FROM player_manuals WHERE manual_id = %s", (manual_id,))
        harness.execute("DELETE FROM manuals WHERE manual_id = %s", (manual_id,))


def test_the_summary_shows_the_strongest_bonuses_a_manual_pays(
    harness, user, player_id
):
    """A three-item summary must spend its slots on the largest bonuses, and
    never on one with no system behind it.

    This used to assert the opposite of what it asserts now, and was right
    both times: 90% speed and 90% essence WERE inert, so a 1% cultivation
    bonus was the only real thing on the book. 0193 wired those columns to
    `dodge` and `max_qi`, so they are the two biggest real bonuses on it and
    the 1% is what should be crowded out.

    The rule that survives is the one that was always meant: strongest first,
    inert never - so this reads BONUS_LABELS rather than naming columns, and a
    future column added without a system behind it fails here."""
    manual_id = harness.sql(
        """
        INSERT INTO manuals (name, tier, required_rank, archetype,
                             speed_bonus, essence_bonus, defense_bonus,
                             attack_bonus, cultivation_rate_bonus)
        VALUES ('Test Hollow Record', 2, 1, 'hybrid', 0.9000, 0.9000, 0.0300,
                0.0200, 0.0100)
        RETURNING manual_id
        """
    )["manual_id"]
    harness.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s)",
        (player_id, manual_id),
    )

    try:
        opened = FakeInteraction(user)
        harness.run("manuals", opened)
        pages = ""
        for _ in range(opened.view.page_count()):
            pages += opened.view.card().description
            opened.view.page += 1

        line = next(
            block for block in pages.split("`T") if "Test Hollow Record" in block
        )
        # Five bonuses, four slots: the smallest is the one that goes.
        assert "90%" in line, f"the largest bonuses are missing: {line!r}"
        assert "+3%" in line and "+2%" in line, (
            f"the middle bonuses are missing: {line!r}"
        )
        assert "+1%" not in line, (
            f"the smallest bonus took a slot from a larger one: {line!r}"
        )

        # And nothing inert is ever summarised. There is nothing inert left,
        # which is the point - if that changes, this catches it.
        from bot.cogs.manuals import BONUS_LABELS

        for column, _icon, label, live in BONUS_LABELS:
            if not live:
                assert label not in line, (
                    f"{label} has no system behind it and took a slot"
                )
    finally:
        harness.execute("DELETE FROM player_manuals WHERE manual_id = %s", (manual_id,))
        harness.execute("DELETE FROM manuals WHERE manual_id = %s", (manual_id,))


def test_the_reroll_card_says_what_each_trait_gives(harness, user, player_id):
    """The screenshot that prompted this showed "Void Spirit Root (Epic)" over
    "Grave Lily Root (Rare)" with nothing but rarity to choose between them.
    Rarity is not the question: an Epic root full of Space is a downgrade for a
    Poison cultivator, and the band alone would never say so.
    """
    card = harness.run("reroll", FakeInteraction(user))
    current = next(f for f in card.fields if "Current" in f.name)
    assert "%" in current.value, (
        f"the root you hold is described without a single number: {current.value!r}"
    )


def test_the_reroll_card_compares_the_offer_against_what_you_hold(
    harness, user, player_id
):
    from bot.cogs.reroll import compare

    held = harness.sql_all(
        "SELECT * FROM root_grants((SELECT root_code FROM player_character "
        "WHERE player_id = %s))",
        (player_id,),
    )
    other = harness.sql_all(
        """
        SELECT * FROM root_grants(
            (SELECT r.code FROM roots r
             WHERE r.code <> (SELECT root_code FROM player_character
                              WHERE player_id = %s)
             LIMIT 1))
        """,
        (player_id,),
    )
    said = compare(held, other)

    assert "Gains" in said or "Loses" in said, (
        f"two different roots compared to nothing at all: {said!r}"
    )
    # An arrow per moved figure, so the swap is legible rather than implied.
    assert "\N{RIGHTWARDS ARROW}" in said or "Tempers" in said

    same = compare(held, held)
    assert "same" in same.lower(), f"a trait against itself should be flat: {same!r}"


def test_the_kill_announcement_says_what_each_person_got():
    """The post the channel reads. A claimed share lists the haul; one nobody
    has taken says so rather than showing zeroes."""
    from bot.cogs.boss import haul_line

    taken = haul_line({
        "discord_name": "grafv",
        "damage": 8500,
        "share": 0.39,
        "claimed": True,
        "stones": 170,
        "jade": 14,
        "spoils": [
            {"code": "dragon_whale_bone", "name": "Dragon Whale Bone",
             "emoji": "🐋", "quantity": 9},
        ],
        "manual": None,
    })
    assert "grafv" in taken
    assert "8,500 damage" in taken and "39%" in taken
    assert "170" in taken and "14" in taken
    assert "Dragon Whale Bone" in taken and "9" in taken

    waiting = haul_line({
        "discord_name": "m_i_y_u_k_i.",
        "damage": 2500,
        "share": 0.11,
        "claimed": False,
        "stones": 0,
        "jade": 0,
        "spoils": [],
        "manual": None,
    })
    assert "not taken yet" in waiting
    assert "0" not in waiting.split("\n")[1], (
        "an unclaimed share showed zeroes instead of saying it is waiting"
    )


def test_the_announcement_names_a_manual_that_dropped():
    """A technique manual is the rarest thing a beast pays and cannot be bought
    at any price, so the channel has to see it."""
    from bot.cogs.boss import haul_line

    said = haul_line({
        "discord_name": "clearwest",
        "damage": 4000,
        "share": 0.25,
        "claimed": True,
        "stones": 80,
        "jade": 22,
        "spoils": [],
        "manual": "Heaven-Defying Edge Canon",
    })
    assert "Heaven-Defying Edge Canon" in said


def test_a_haul_line_can_number_itself_and_point_at_you():
    """The /boss card lists the same hauls the channel post does, but for one
    reader - so it numbers them and marks which one is theirs. The channel
    post has no reader to point at and passes neither."""
    from bot.cogs.boss import haul_line

    row = {
        "discord_name": "clearwest",
        "damage": 5424,
        "share": 0.22,
        "claimed": True,
        "stones": 108,
        "jade": 21,
        "spoils": [{"code": "soul_crystal", "name": "Soul Crystal",
                    "emoji": "\N{SMALL BLUE DIAMOND}", "quantity": 4}],
        "manual": None,
    }

    plain = haul_line(row)
    assert "`3`" not in plain and "you" not in plain

    marked = haul_line(row, place=3, mine=True)
    assert marked.startswith("`3` ")
    assert "you" in marked
    assert "Soul Crystal" in marked and "4" in marked


def test_a_haul_reads_the_same_wherever_it_is_shown():
    """Three screens say what a beast paid: the channel post, the /boss card
    and the killing blow. They were one screen and two silences - /boss ended
    on "your share has been paid" without naming any of it, and the kill card
    sent you to /boss to claim something 0153 had already put in your satchel.

    All three call `spoils_text` now, and this is what stops that becoming
    three copies that drift the first time a new kind of spoil is added."""
    from bot.cogs.boss import haul_line, spoils_text

    row = {
        "discord_name": "._.visha._.",
        "damage": 10482,
        "share": 0.43,
        "claimed": True,
        "stones": 210,
        "jade": 17,
        "spoils": [{"code": "tormented_soul", "name": "Tormented Soul",
                    "emoji": "\N{CONFOUNDED FACE}", "quantity": 1}],
        "manual": "Crimson Moth Requiem",
    }

    paid = spoils_text(row)
    assert "210" in paid and "17" in paid
    assert "Tormented Soul" in paid
    assert "Crimson Moth Requiem" in paid, "the rarest drop went unnamed"

    assert paid in haul_line(row), (
        "the list and the single line no longer write a haul the same way"
    )


def test_a_finished_tournament_still_offers_the_next_ring(harness, user):
    """The bug this is about: `open_tournament` had one caller and it sat
    behind `if meet is None`. Once the first ring had been fought, /tournament
    showed the result and attached nothing - while /cooldowns said anyone
    could start one and the result card's own footer promised that entering
    again would open one. Three screens describing a button that did not
    exist.

    Deliberately does not press it. Opening a ring is a real thing the whole
    server can see, and a test suite should not start one.
    """
    interaction = FakeInteraction(user)
    harness.run("tournament", interaction)
    view = interaction.view

    labels = [getattr(item, "label", None) for item in view.children]
    standing = harness.sql(
        "SELECT count(*) AS n FROM tournaments WHERE status = 'signup'"
    )["n"]

    if standing:
        assert "Enter" in labels, labels
    else:
        assert "Open a ring" in labels, (
            f"nothing on the screen starts a tournament: {labels}"
        )


def test_equipment_names_the_manuals_it_is_holding_back(harness, user, player_id):
    """`EquipmentView` offers only manuals whose `required_rank` the cultivator
    has reached, which is right - offering one that cannot be equipped is
    offering a choice that does nothing. Leaving it out SILENTLY is not:
    clearwest won a Heaven-Defying Edge Canon off a world beast, opened
    /equipment, could not see it, and asked where it had gone.

    It was in /manuals the whole time, labelled "needs rank 6". The screen
    that dropped it just never said so."""
    deep = harness.sql(
        "SELECT manual_id, name, required_rank FROM manuals "
        "WHERE required_rank >= 6 AND code IS NOT NULL "
        "ORDER BY required_rank DESC LIMIT 1"
    )
    harness.execute(
        "INSERT INTO player_manuals (player_id, manual_id) VALUES (%s, %s) "
        "ON CONFLICT DO NOTHING",
        (player_id, deep["manual_id"]),
    )

    card = harness.run("equipment", FakeInteraction(user))
    held = next(
        (f for f in card.fields if f.name.startswith("Not yet yours to carry")),
        None,
    )
    assert held is not None, [f.name for f in card.fields]
    assert deep["name"] in held.value
    assert f"needs realm {deep['required_rank']}" in held.value
    assert "/manuals" in held.value, "it does not say where the book actually is"

    harness.execute(
        "DELETE FROM player_manuals WHERE player_id = %s AND manual_id = %s",
        (player_id, deep["manual_id"]),
    )


def test_the_boss_channel_is_optional_and_validated():
    """A bot with no channel configured must still run the fight - a beast
    dying unannounced is a missing post, not a broken command."""
    import os

    from bot import config

    was = os.environ.get("BOSS_CHANNEL_ID")
    try:
        os.environ["BOSS_CHANNEL_ID"] = ""
        assert config.boss_channel_id() is None

        os.environ["BOSS_CHANNEL_ID"] = "1544766647145988206"
        assert config.boss_channel_id() == 1544766647145988206

        os.environ["BOSS_CHANNEL_ID"] = "not-a-snowflake"
        with pytest.raises(RuntimeError, match="snowflake"):
            config.boss_channel_id()
    finally:
        if was is None:
            os.environ.pop("BOSS_CHANNEL_ID", None)
        else:
            os.environ["BOSS_CHANNEL_ID"] = was


def test_pages_are_grouped_by_type_and_ordered_by_power(harness, user, player_id):
    """A refiner picks a column to fill and then wants the strongest thing that
    fills it. Tier is a consequence of power, not something to sort on."""
    harness.execute(
        """
        INSERT INTO manual_pages (owner_id, tier, path_code, page_type, power, quality)
        VALUES (%s, 2, 'fire', 'attack', 12, 80),
               (%s, 6, 'ice',  'attack', 44, 90),
               (%s, 3, 'wood', 'cultivation', 30, 70),
               (%s, 1, 'water','cultivation',  8, 60)
        """,
        (player_id, player_id, player_id, player_id),
    )
    try:
        opened = FakeInteraction(user)
        harness.run("pages", opened, path=None)
        view = opened.view

        kinds = [code for code, _, _ in view.kinds]
        assert kinds == sorted(
            kinds,
            key=lambda c: [
                row["sort_order"] for row in view.rows if row["type_code"] == c
            ][0],
        ), "the types are not in the order the table declares"

        for code in kinds:
            powers = [
                row["power"] for row in view.rows if row["type_code"] == code
            ]
            assert powers == sorted(powers, reverse=True), (
                f"{code} pages are not strongest first: {powers}"
            )
    finally:
        harness.execute(
            "DELETE FROM manual_pages WHERE owner_id = %s AND consumed_at IS NULL",
            (player_id,),
        )


def test_the_binder_can_reach_every_page_held(harness, user, player_id):
    """It sorted by tier and cut at forty. clearwest holds nine hundred and
    thirty-four, so eight hundred and ninety-four were invisible - and the
    footer read "40 page(s)", stating the truncation as though it were the
    total."""
    harness.execute(
        """
        INSERT INTO manual_pages (owner_id, tier, path_code, page_type, power, quality)
        SELECT %s, 1 + (i %% 6), 'fire', 'attack', 5 + i, 70
        FROM generate_series(1, 60) AS i
        """,
        (player_id,),
    )
    try:
        held = harness.sql(
            "SELECT count(*) AS n FROM manual_pages WHERE owner_id = %s "
            "AND consumed_at IS NULL",
            (player_id,),
        )["n"]
        assert held > 40, "this test needs more pages than the old cut"

        opened = FakeInteraction(user)
        harness.run("pages", opened, path=None)
        view = opened.view

        assert len(view.rows) == held, (
            f"the binder loaded {len(view.rows)} of {held} pages"
        )

        seen = 0
        for code, _, _ in view.kinds:
            view.kind = code
            view.page = 0
            view.build()
            for _ in range(view.page_count()):
                seen += len(
                    [
                        line
                        for line in (view.card().description or "").splitlines()
                        if line.startswith("`T")
                    ]
                )
                view.page += 1
        assert seen == held, f"{seen} of {held} pages reachable by turning pages"

        assert str(held) in view.card().footer.text, (
            "the footer does not say how many are actually held"
        )
    finally:
        harness.execute(
            "DELETE FROM manual_pages WHERE owner_id = %s AND consumed_at IS NULL",
            (player_id,),
        )


def test_balance_shows_both_currencies_and_counts_the_rest(harness, user, player_id):
    """The one-line answer to "can I afford this"."""
    harness.execute("SELECT grant_material(%s, 'spirit_stone', 77)", (player_id,))
    harness.execute("SELECT grant_jade(%s, 13, 'test')", (player_id,))

    card = harness.run("balance", FakeInteraction(user))

    stones = harness.sql(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'spirit_stone'",
        (player_id,),
    )["quantity"]
    jade = harness.sql("SELECT jade_held(%s) AS n", (player_id,))["n"]

    assert thousands(stones) in card.description
    assert thousands(jade) in card.description

    shelves = next(f for f in card.fields if f.name == "Materials")
    for label in ("Ore", "Herbs", "Gathering", "Beast"):
        assert label in shelves.value, f"{label} is missing from the balance"


def test_eggs_points_at_what_hatching_gets_you(harness, user, player_id):
    """This screen used to say plainly that nothing hatched them, which was
    the honest thing while pets did not exist. They do, so it points at where
    the beast ends up instead."""
    harness.execute("SELECT roll_beast_egg(%s, 4::smallint, NULL)", (player_id,))

    opened = FakeInteraction(user)
    card = harness.run("eggs", opened)
    assert "/pet" in (card.footer.text or "").lower()

    # And the button that does it is on the screen.
    picker = next(
        c for c in opened.view.children if isinstance(c, discord.ui.Select)
    )
    assert picker.options, "the shelf offers nothing to hatch"

    shelf = next(f for f in card.fields if f.name == "Shelf")
    egg = harness.sql(
        "SELECT name, tier FROM player_egg_shelf WHERE owner_id = %s LIMIT 1",
        (player_id,),
    )
    assert egg["name"] in shelf.value
    assert f"T{egg['tier']}" in shelf.value


def test_an_empty_shelf_says_where_eggs_come_from(harness, user, player_id):
    """"You have none" answers half a question. The other half is what to go
    and do about it."""
    harness.execute("DELETE FROM player_beast_eggs WHERE owner_id = %s", (player_id,))
    card = harness.run("eggs", FakeInteraction(user))
    assert card.fields == [] or all(f.name != "Shelf" for f in card.fields)
    assert "tier" in card.description.lower()


def test_balance_counts_the_keys_too(harness, user, player_id):
    """A key is a currency, so it never appeared on a material shelf, and no
    screen but /daily and the dungeon door ever counted it. "Can I afford
    this" now includes "can I get in"."""
    harness.execute("SELECT grant_material(%s, 'dungeon_key', 3)", (player_id,))

    card = harness.run("balance", FakeInteraction(user))
    keys = harness.sql(
        "SELECT quantity FROM player_materials WHERE player_id = %s "
        "AND material_code = 'dungeon_key'",
        (player_id,),
    )["quantity"]

    assert "Dungeon Key" in card.description
    assert thousands(keys) in card.description
    # And where the next ones come from, which is the half a bare count leaves out.
    assert "/daily" in card.description


def test_balance_says_none_rather_than_nothing_about_keys(harness, user, player_id):
    """A zero is the answer to "why can I not open a door", and a missing line
    is not - the same rule the material shelves already follow."""
    harness.execute(
        "DELETE FROM player_materials WHERE player_id = %s "
        "AND material_code = 'dungeon_key'",
        (player_id,),
    )
    card = harness.run("balance", FakeInteraction(user))
    assert "0** Dungeon Key" in card.description


def test_balance_names_every_shelf_even_an_empty_one(harness, user, player_id):
    """"No herbs at all" is the answer to a question somebody is asking, and a
    missing line is not."""
    harness.execute(
        "DELETE FROM player_materials WHERE player_id = %s AND material_code IN "
        "(SELECT code FROM materials WHERE tier IS NOT NULL)",
        (player_id,),
    )
    card = harness.run("balance", FakeInteraction(user))
    shelves = next(f for f in card.fields if f.name == "Materials")

    assert "Herbs" in shelves.value
    assert "*none*" in shelves.value, (
        f"an empty shelf was dropped rather than reported: {shelves.value!r}"
    )


def test_balance_counts_the_same_shelves_the_satchel_does(harness, user, player_id):
    """Two screens disagreeing about what counts as ore is the sort of thing
    nobody notices until they are arguing with a recipe."""
    harness.execute("SELECT grant_material(%s, 'blazing_sunsteel', 4)", (player_id,))
    harness.execute("SELECT grant_material(%s, 'blue_kelp_grass', 3)", (player_id,))

    opened = FakeInteraction(user)
    harness.run("inventory", opened, category=None)
    satchel = {code: opened.view.held(code) for code, *_ in SHELVES}

    card = harness.run("balance", FakeInteraction(user))
    shelves = next(f for f in card.fields if f.name == "Materials")

    for code, _, label, _ in SHELVES:
        if satchel[code]:
            assert f"{satchel[code]} kind(s)" in shelves.value or (
                thousands(satchel[code]) in shelves.value
            ), f"{label} reads differently on the two screens"


def test_balance_answers_to_the_i_prefix(harness, user, player_id):
    """`resolve` matches against the command tree, so a new command is reachable
    as "I balance" without anybody registering a phrase for it."""
    said = say(harness, user, "I balance")
    assert said.answer is not None
    assert "Balance" in (said.answer.title or "")


def test_no_field_on_any_card_can_be_refused(harness, user, player_id):
    """Discord rejects the WHOLE message for one oversized field:

        400 Bad Request (50035): In embeds.0.fields.2.value:
        Must be 1024 or fewer in length

    So a screen that overflows does not look untidy, it looks broken - which is
    what /equipment did for anybody carrying enough manuals to fill the shelf
    listing under the dropdown.

    This walks the screens that list one line per thing, with the field limit
    asserted rather than the page size, because the page size is a guess about
    a typical entry and the limit is the rule.
    """
    from bot.formatting import FIELD_LIMIT

    # Enough manuals to fill several pages of the shelf.
    harness.execute(
        """
        INSERT INTO player_manuals (player_id, manual_id)
        SELECT %s, manual_id FROM manuals
        WHERE code IS NOT NULL AND required_rank <= 2
        ON CONFLICT DO NOTHING
        """,
        (player_id,),
    )
    try:
        opened = FakeInteraction(user)
        harness.run("equipment", opened)

        for _ in range(opened.view.page_count()):
            card = harness.runner.run(opened.view.card())
            for field in card.fields:
                assert len(field.value) <= FIELD_LIMIT, (
                    f"{field.name!r} is {len(field.value)} characters, and "
                    f"Discord takes {FIELD_LIMIT}"
                )
            assert len(card.description or "") <= 4096
            opened.view.page += 1
            opened.view.build()
    finally:
        harness.execute(
            "DELETE FROM player_manual_slots WHERE player_id = %s", (player_id,)
        )
        harness.execute(
            """
            DELETE FROM player_manuals WHERE player_id = %s AND manual_id IN (
                SELECT manual_id FROM manuals
                WHERE code IS NOT NULL AND required_rank <= 2
            )
            """,
            (player_id,),
        )


def test_a_full_aperture_does_not_break_the_gu_screen(harness, user, player_id):
    """`I gu` returned "Something broke on our side" for an immortal:

        400 Bad Request (50035): In embeds.0.fields.0.value:
        Must be 1024 or fewer in length

    Field 0 is "Held in the aperture", and it was built with a bare join while
    the jar directly beneath it had been using `fit_field` for exactly this
    reason. It never mattered while an aperture held a handful of worms. 0352
    made capacity `rank * 3`, so an immortal wears thirty-odd, each printing a
    name, rank, stars, size AND an effects line under it.

    `render_gu` also took a `page` it never used: the view paged its dropdowns
    while the card under them printed everything, so the arrows moved the menu
    and not the list. Both are asserted here - every field fits, and the pages
    actually differ.
    """
    from bot.formatting import FIELD_LIMIT

    # An immortal aperture, which is the only place this bug lives.
    harness.execute(
        "UPDATE player_cultivation SET realm_id = "
        "(SELECT min(realm_id) FROM realms WHERE rank = 10) WHERE player_id = %s",
        (player_id,),
    )
    # Every Gu that carries effects, so the lines are the real length.
    harness.execute(
        """
        SELECT grant_gu(%s, t.gu_type_id, NULL)
        FROM gu_types t
        WHERE EXISTS (SELECT 1 FROM gu_type_effects e
                      WHERE e.gu_type_id = t.gu_type_id)
          AND t.size = 1
        LIMIT 40
        """,
        (player_id,),
    )
    # Worn, not merely owned - the field that broke is the worn one.
    harness.execute(
        """
        INSERT INTO player_gu_equipped (gu_id, player_id)
        SELECT g.gu_id, %s FROM player_gu g
        WHERE g.owner_id = %s
        LIMIT (SELECT gu_capacity_of(%s))
        ON CONFLICT DO NOTHING
        """,
        (player_id, player_id, player_id),
    )

    from bot.cogs.gu import render_gu, sorted_equipped, fetch_gu

    held = harness.runner.run(fetch_gu(player_id))
    worn = sorted_equipped(held)
    assert len(worn) >= 10, (
        f"only {len(worn)} Gu are worn - this fixture is not reproducing "
        "the aperture that broke"
    )

    # The test is not vacuous: unpaged and unguarded, this really is over the
    # limit, which is what the old code handed to Discord.
    raw = "\n".join(
        f"{g['emoji']} **{g['name']} - rank {g['rank']}** "
        f"{'*' * g['stars']} - size {g['size']}\n     {g['effects'] or 'nothing'}"
        for g in worn
    )
    assert len(raw) > FIELD_LIMIT, (
        f"the whole worn list is only {len(raw)} characters, so this would "
        "have passed before the fix too"
    )

    seen = []
    for page in range(3):
        card = harness.runner.run(render_gu(player_id, "Tester", page=page))
        for field in card.fields:
            assert len(field.value) <= FIELD_LIMIT, (
                f"{field.name!r} is {len(field.value)} characters, and "
                f"Discord takes {FIELD_LIMIT}"
            )
        seen.append(next(f.value for f in card.fields
                         if f.name == "Held in the aperture"))

    # And the page argument reaches the card rather than being accepted and
    # dropped, which is the other half of the bug.
    assert len(set(seen)) > 1, "every page of the aperture showed the same thing"


def test_fit_field_trims_honestly():
    """The backstop under the paging. A page size is chosen from a typical
    entry; one unusually long name must not take the message down."""
    from bot.formatting import FIELD_LIMIT, fit_field

    assert fit_field([]) == "*Nothing.*"
    assert fit_field(["one", "two"]) == "one\ntwo"

    long_ones = [f"{i}: " + "x" * 200 for i in range(20)]
    fitted = fit_field(long_ones, noun="not listed")
    assert len(fitted) <= FIELD_LIMIT
    assert "not listed" in fitted, "it trimmed without saying how many it dropped"

    # And what it kept is a prefix of what it was given, in order.
    kept = fitted.split("\n")[0]
    assert kept == long_ones[0]


# ---------------------------------------------------------------------------
# A bad second at Discord is not the game breaking
# ---------------------------------------------------------------------------


def test_a_transient_discord_failure_is_retried_rather_than_surfaced():
    """`I alchemy` died at 14:14 with a 503 whose body was an upstream connect
    error. The cauldron behind it had rendered perfectly - 2 fields, 4
    components - and the player was told "Something broke on our side", which
    is both alarming and untrue.

    The send is retried; only a failure that survives every try is real."""
    import asyncio

    import discord

    from bot.cogs.prefix import SEND_TRIES, reply_through_a_hiccup

    class Flaky:
        def __init__(self, fail_times):
            self.left = fail_times
            self.calls = 0

        async def reply(self, **kwargs):
            self.calls += 1
            if self.left > 0:
                self.left -= 1
                raise discord.DiscordServerError(
                    type("R", (), {"status": 503, "reason": "flaky"})(),
                    "upstream connect error",
                )
            return "sent"

    # Recovers from anything short of the whole budget.
    flaky = Flaky(SEND_TRIES - 1)
    assert asyncio.run(reply_through_a_hiccup(flaky, content="hi")) == "sent"
    assert flaky.calls == SEND_TRIES

    # And a real outage still raises, rather than being swallowed into silence.
    dead = Flaky(SEND_TRIES)
    with pytest.raises(discord.DiscordServerError):
        asyncio.run(reply_through_a_hiccup(dead, content="hi"))
    assert dead.calls == SEND_TRIES


# ---------------------------------------------------------------------------
# The rack is read one slot at a time
# ---------------------------------------------------------------------------


def stock_the_rack(harness, player_id, how_many: int) -> None:
    """Enough pieces that one select cannot hold them.

    Forging them would be the honest route and is far too slow; what is being
    tested is the drawing, and the drawing reads `player_equipment`.
    """
    harness.execute(
        """
        INSERT INTO player_equipment
            (owner_id, name, slot, tier, rarity, harmony, ore_code)
        SELECT %s, 'Filler ' || g, 'weapon', 1, 'common', g %% 150, 'iron_ore'
        FROM generate_series(1, %s) g
        """,
        (player_id, how_many),
    )


def listed_on(card) -> list[str]:
    """The pieces a rendered rack actually names, in order."""
    import re

    out: list[str] = []
    for field in card.fields:
        if field.name and ("by " in field.name or field.name == "…"):
            out += re.findall(r"\*\*(.+?)\*\*", field.value)
    return out


def offered_on(view) -> list[str]:
    """What the rack's piece picker is offering.

    Found by class rather than by placeholder text: it read "Wear one" until
    the picker started SHOWING a piece instead of equipping it on the spot,
    and matching on the word broke three tests that care about neither the
    word nor the wearing.
    """
    from bot.cogs.forge import GearSelect

    return [
        option.label
        for item in view.children
        if isinstance(item, GearSelect)
        for option in item.options
    ]


def test_the_rack_shows_every_piece_it_offers(harness, user, player_id):
    """The old rack drew eight pieces as eight full-width fields and then
    offered all twenty in the select underneath, so its own footer had to say
    "12 more on this page, in the list below" - a player could equip a piece
    the screen had never shown them.

    What the card lists and what the select offers are one list now."""
    harness.run("gear", (opened := FakeInteraction(user)))
    view = opened.view

    for slot in (None, "weapon", "armour"):
        view.slot = slot
        view.build()
        listed = [r["name"] for r in view.matching() if not r["worn"]]
        assert listed == offered_on(view), f"slot {slot}"


def test_a_rack_too_big_for_one_select_still_shows_what_it_offers(
    harness, user, player_id
):
    """A select holds twenty-five options and no more. The card used to draw
    every piece regardless, so a rack of seventy-nine listed all seventy-nine
    and handed over a menu of twenty-five with nothing to say which twenty-five
    - the missing pieces were not missing, they were on a page nobody was told
    about. pashu0 has seventy-nine.

    The test above cannot catch this: the fixture holds a handful of pieces, so
    it agrees with the bug as readily as with the fix.
    """
    from bot.picking import PER_PAGE

    # The harness is module-scoped and its writes commit, so a rack stuffed
    # here would still be stuffed for every test after this one.
    try:
        stock_the_rack(harness, player_id, PER_PAGE * 2 + 5)

        harness.run("gear", (opened := FakeInteraction(user)))
        view = opened.view
        view.slot = "weapon"
        view.build()

        spare = [r for r in view.matching() if not r["worn"]]
        assert len(spare) > PER_PAGE, "the rack is not big enough to page"
        assert view.page_count() > 1, "a rack past one select offered no second page"

        seen: list[str] = []
        for page in range(view.page_count()):
            view.page = page
            view.build()
            card = harness.runner.run(view.card())

            listed = listed_on(card)
            offered = offered_on(view)
            worn = [r["name"] for r in view.matching() if r["worn"]]

            # Every piece drawn is either worn or on the menu underneath it.
            assert listed == worn + offered, (
                f"page {page}: card drew {listed}, select offered {worn + offered}"
            )
            assert len(offered) <= PER_PAGE, f"page {page} offered {len(offered)}"
            seen += offered

        # And walking the pages reaches every last one of them.
        assert sorted(seen) == sorted(r["name"] for r in spare), (
            "some pieces are on no page at all"
        )
    finally:
        harness.execute(
            "DELETE FROM player_equipment "
            "WHERE owner_id = %s AND name LIKE 'Filler %%'",
            (player_id,),
        )


def test_the_slot_buttons_are_the_slots_the_schema_has(harness):
    """A button row cannot await a query, so the four are written out - and
    would silently rot if a fifth slot were ever added."""
    from bot.cogs.forge import SLOT_BUTTONS

    rows = harness.sql_all("SELECT code FROM equipment_slots ORDER BY sort_order")
    assert [c for c, _l, _e in SLOT_BUTTONS] == [r["code"] for r in rows]


def test_filtering_to_a_slot_shows_only_that_slot(harness, user, player_id):
    harness.run("gear", (opened := FakeInteraction(user)))
    view = opened.view

    view.slot = "weapon"
    view.build()
    assert all(r["slot"] == "weapon" for r in view.matching())
    assert view.matching(), "the fixture holds no weapon to look at"


def test_the_worn_piece_leads_whatever_the_sort(harness, user, player_id):
    """It is the thing every other piece in the slot is being compared
    against, so it goes first even when it is not the best."""
    from bot.cogs.forge import GEAR_SORTS

    harness.run("gear", (opened := FakeInteraction(user)))
    view = opened.view

    for code, _label, _key in GEAR_SORTS:
        view.sort = code
        rows = view.matching()
        worn = [i for i, r in enumerate(rows) if r["worn"]]
        if worn:
            assert worn == list(range(len(worn))), (
                f"sorted by {code}, the worn pieces are not first"
            )


def test_a_rack_is_never_wider_than_discord_allows(harness, user, player_id):
    """Five rows, five buttons to a row, and 1024 characters to a field. The
    slot row is exactly full - All plus four slots - so a fifth slot would
    break it, which is what the schema test above is for."""
    harness.run("gear", (opened := FakeInteraction(user)))
    view = opened.view

    rows: dict = {}
    for item in view.children:
        rows.setdefault(item.row, []).append(item)
    assert len(rows) <= 5, f"{len(rows)} component rows"
    for index, items in rows.items():
        assert len(items) <= 5, f"row {index} holds {len(items)}"

    card = opened.last
    for field in card.fields:
        assert len(field.value) <= 1024, f"{field.name} is over the field limit"
    assert sum(len(f.name) + len(f.value) for f in card.fields) <= 6000


def test_a_pooled_read_survives_a_migration_landing_under_it(harness):
    """Migrations here are forward-only and get applied while the bot is up.

    psycopg prepares a statement after a few runs and the server remembers the
    shape it returned, so a view gaining a column - 0224 adding `seconds_left`
    to `horde_board` - made every later run of that plan fail with "cached plan
    must not change result type". Pooled connections are long-lived, so it kept
    failing: the horde tick died mid-tide and only a restart brought it back.

    The DDL comes from a separate connection on purpose. That is how migrations
    actually arrive, and a same-session change does not reproduce it.
    """

    def migrate(sql: str) -> None:
        with psycopg.connect(database_url(), autocommit=True) as other:
            other.execute(sql)

    async def read_across_a_shape_change(ddl: str):
        await db.execute("DROP VIEW IF EXISTS zz_replan_probe")
        await db.execute("CREATE VIEW zz_replan_probe AS SELECT 1 AS a")
        try:
            # Past psycopg's prepare threshold, so the server holds a plan.
            for _ in range(8):
                await db.fetch_one("SELECT * FROM zz_replan_probe")
            migrate(ddl)
            return await db.fetch_one("SELECT * FROM zz_replan_probe")
        finally:
            await db.execute("DROP VIEW IF EXISTS zz_replan_probe")

    for ddl in (
        "DROP VIEW zz_replan_probe; "
        "CREATE VIEW zz_replan_probe AS SELECT 1 AS a, 2 AS b",
        "CREATE OR REPLACE VIEW zz_replan_probe AS SELECT 1 AS a, 2 AS b",
    ):
        assert harness.runner.run(read_across_a_shape_change(ddl)) == {
            "a": 1,
            "b": 2,
        }, f"a pooled read did not survive: {ddl}"


def test_destiny_opens_and_takes_one(harness, user, player_id):
    """/destiny shipped broken because nothing had ever run its queries.

    A literal `%` in a parameterised statement is a placeholder to psycopg, so
    every query in the cog raised the moment it was called - and the schema
    tests, which exercise `destiny_offer` and `destiny_take` directly, could
    not see it. This runs the command.
    """
    harness.execute("DELETE FROM player_destinies WHERE player_id = %s", (player_id,))
    harness.execute("SELECT destiny_offer(%s, 3::smallint)", (player_id,))

    opened = FakeInteraction(user)
    card = harness.run("destiny", opened)

    assert "fate" in card.title.lower()
    assert len(card.fields) >= 3, "three fates were not put in front of them"

    select = next(
        i for i in opened.view.children if isinstance(i, discord.ui.Select)
    )
    assert len(select.options) == 3

    # Taking one writes it, and the screen comes back with it listed.
    taken = select.options[0].value
    choose(harness, select, taken, FakeInteraction(user))

    assert harness.sql(
        "SELECT code FROM player_destinies WHERE player_id = %s AND rank = 3",
        (player_id,),
    )["code"] == taken

    # And a cultivator with nothing waiting gets a screen that says so.
    again = FakeInteraction(user)
    card = harness.run("destiny", again)
    assert "Written (1)" in [f.name for f in card.fields]

    harness.execute("DELETE FROM player_destinies WHERE player_id = %s", (player_id,))


def test_no_command_hides_a_bare_percent_in_its_sql():
    """The bug in /destiny, as a rule rather than one fix.

    psycopg treats `%` as a placeholder marker, so a literal one in a
    parameterised query raises the moment it is called. Testing the SQL
    functions directly cannot catch it, because those never go through the
    driver's parameter handling - only running the command does.
    """
    import pathlib

    offenders = []
    for path in sorted(pathlib.Path("bot").rglob("*.py")):
        for n, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            # What the bug looked like: a percent concatenated into SQL as a
            # literal, undoubled.
            if "|| '%'" in line and "|| '%%'" not in line:
                offenders.append(f"{path}:{n}")

    assert offenders == [], f"bare percent in parameterised SQL: {offenders}"


def test_no_command_clears_a_view_with_none():
    """The other thing /destiny shipped with.

    `view=None` is a crash in discord.py and the codebase settled on
    `discord.utils.MISSING` long ago - but nothing checked, so every cog
    written today got it wrong the same way.
    """
    import pathlib

    offenders = []
    for path in sorted(pathlib.Path("bot").rglob("*.py")):
        for n, line in enumerate(
            path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            stripped = line.strip()
            if stripped.startswith("view=") and stripped.rstrip(",").endswith("None"):
                offenders.append(f"{path}:{n}")

    assert offenders == [], f"view=None crashes discord.py: {offenders}"


def test_no_paged_menu_is_capped_at_a_select_full():
    """What the trade screen shipped with, as a rule.

    Discord shows 25 options in a select, so every list query was written
    `LIMIT 25` and that was honest. Then the pickers learned to page, and the
    limits stayed - so /trade offered grafv 25 of his 119 materials, and the
    Dungeon Key, which sorts 28th, was simply not among them. Paging past the
    end of the rows you were handed finds nothing.

    The cap is still real wherever the widget really does stop at 25 - an
    autocomplete, a plain unpaged select - so the rule is narrow: a query that
    fills a PAGED menu may not be cut to one page.
    """
    import ast
    import importlib
    import pathlib
    import pkgutil

    import bot
    from bot.picking import PagedPicker

    offenders = []
    for info in pkgutil.walk_packages(bot.__path__, prefix="bot."):
        module = importlib.import_module(info.name)
        paged = {
            name
            for name, obj in vars(module).items()
            if isinstance(obj, type) and issubclass(obj, PagedPicker)
        }
        if not paged:
            continue

        path = pathlib.Path(module.__file__)
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source)

        for node in ast.walk(tree):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            body = ast.dump(node)
            builds_paged = any(
                isinstance(c, ast.Call)
                and isinstance(c.func, ast.Name)
                and c.func.id in paged
                for c in ast.walk(node)
            )
            if not builds_paged:
                continue
            for text in (
                c.value
                for c in ast.walk(node)
                if isinstance(c, ast.Constant) and isinstance(c.value, str)
            ):
                if "LIMIT" in text.upper():
                    offenders.append(f"{path.name}:{node.lineno} {node.name}")
                    break

    assert offenders == [], (
        "a paged menu was handed only one page of rows to page through: "
        f"{offenders}"
    )


def test_a_trade_survives_the_screen_it_was_opened_on(harness, user, player_id, partner):
    """pashu0 and clearwest were locked out for half an hour by a restart.

    The table lives in the database and the view lives in Discord, so a
    restart or a timeout kills the screen while the trade stays open - and
    /trade then refused both of them until the thirty minute expiry ran out.
    Re-running it hands the same table back with the offers still on it.
    """
    opened = FakeInteraction(user)
    harness.run("trade", opened, partner=partner["user"])
    first = opened.view.trade_id

    page = make_page(harness, player_id, 3, "fire", "attack", 70)
    harness.execute(
        "SELECT trade_add_page(%s, %s, %s)", (first, player_id, page)
    )

    # The screen dies; the trade does not. This is what a restart leaves.
    opened.view.stop()

    again = FakeInteraction(user)
    card = harness.run("trade", again, partner=partner["user"])

    assert again.view.trade_id == first, (
        "re-running /trade started a second table instead of handing back the "
        "one they were already at"
    )
    told = "\n".join(f.value for f in card.fields)
    assert "Fire" in told, f"the offer was not still on the table: {told}"

    assert harness.sql(
        "SELECT count(*) AS n FROM trades WHERE status = 'open' "
        "AND ((proposer_id = %s AND partner_id = %s) "
        "  OR (proposer_id = %s AND partner_id = %s))",
        (player_id, partner["player_id"], partner["player_id"], player_id),
    )["n"] == 1, "resuming left two open trades between the same pair"

    harness.execute("SELECT trade_cancel(%s, %s)", (first, player_id))


def test_a_trade_with_somebody_else_is_still_refused(harness, user, player_id, partner):
    """Resuming must only ever hand back the table you are actually at."""
    opened = FakeInteraction(user)
    harness.run("trade", opened, partner=partner["user"])
    trade_id = opened.view.trade_id

    third = harness.sql(
        "SELECT p.player_id, p.discord_id FROM players p "
        "WHERE p.deleted_at IS NULL AND p.discord_id NOT IN (%s, %s) LIMIT 1",
        (TEST_DISCORD_ID, PARTNER_DISCORD_ID),
    )
    if third is not None:
        with pytest.raises(GameError, match="already"):
            harness.run(
                "trade",
                FakeInteraction(user),
                partner=FakeUser(third["discord_id"]),
            )

    harness.execute("SELECT trade_cancel(%s, %s)", (trade_id, player_id))


def test_a_ring_is_never_resolved_without_being_announced():
    """The tournament pays out wherever it happens to be settled.

    `run_tournament` pays the whole field, and the only place those numbers
    are ever printed is the result card. So the settle and the announcement
    have to be the same act. They were not: /cd called `settle_due` through
    `ring_line` to draw one status line, which silently resolved the ring and
    paid everybody, and then /tournament found nothing left to announce
    because the transition had already happened. A whole tournament's purse
    was handed out with no message anywhere.

    So: `settle_due` belongs to `settle_and_announce` and to nobody else.
    """
    import pathlib

    root = pathlib.Path(__file__).resolve().parent.parent / "bot"
    offenders = []
    for path in sorted(root.rglob("*.py")):
        source = path.read_text(encoding="utf-8")
        for n, line in enumerate(source.splitlines(), start=1):
            code = line.split("#", 1)[0]
            if "settle_due()" not in code and "run_tournament()" not in code:
                continue
            # The helper itself, and its own definition, are the exception.
            if path.name == "tournament.py":
                continue
            offenders.append(f"{path.name}:{n}: {line.strip()}")

    assert offenders == [], (
        "a ring is resolved outside settle_and_announce, so it pays out "
        f"without printing what it paid: {offenders}"
    )


def test_the_result_card_names_what_everybody_was_paid():
    """The card is the only receipt, so it has to carry the numbers.

    Guarding the columns rather than the layout: if `stones_paid` or
    `jade_paid` stop being read, the card still renders and still looks
    right, and nobody finds out the ring went quiet until somebody asks
    where their stones went.
    """
    import pathlib

    source = (
        pathlib.Path(__file__).resolve().parent.parent
        / "bot" / "cogs" / "tournament.py"
    ).read_text(encoding="utf-8")

    for column in ("stones_paid", "jade_paid"):
        assert f"row['{column}']" in source or f'row["{column}"]' in source, (
            f"the result card stopped printing {column}"
        )


def test_the_recipe_book_narrows_on_four_axes_independently():
    """Quality and a name search, beside the state and rank that were there.

    3,035 recipes over nine ranks still leaves hundreds on a rank, and what
    people ask for is "the good ones" or one Gu by name. The four axes must
    narrow INDEPENDENTLY - picking Legendary must not clear the rank, and
    searching must not clear either - because a filter that silently resets
    another is one you have to set again every time you use it.
    """
    from bot.cogs.gurefine import matches

    book = [
        {"gu_name": "Moonlight Gu", "rank": 3, "rarity": "legendary",
         "ready": True, "level_ok": True},
        {"gu_name": "Grand Moonlight Gu", "rank": 6, "rarity": "mythic",
         "ready": False, "level_ok": True},
        {"gu_name": "Stone Skin Gu", "rank": 3, "rarity": "common",
         "ready": False, "level_ok": False},
    ]

    def names(**kw):
        return sorted(r["gu_name"] for r in book if matches(r, **kw))

    # Each axis alone.
    assert names(mode="all") == [
        "Grand Moonlight Gu", "Moonlight Gu", "Stone Skin Gu"]
    assert names(mode="all", rarity="legendary") == ["Moonlight Gu"]
    assert names(mode="all", tier=3) == ["Moonlight Gu", "Stone Skin Gu"]
    assert names(mode="ready") == ["Moonlight Gu"]

    # Together, and in either order - neither clears the other.
    assert names(mode="all", tier=3, rarity="common") == ["Stone Skin Gu"]
    assert names(mode="all", tier=6, rarity="legendary") == []

    # Search is by name, folded, and composes with the rest.
    assert names(mode="all", query="moonlight") == [
        "Grand Moonlight Gu", "Moonlight Gu"]
    assert names(mode="all", query="MOONLIGHT") == [
        "Grand Moonlight Gu", "Moonlight Gu"]
    assert names(mode="all", query="moonlight", tier=6) == [
        "Grand Moonlight Gu"]
    assert names(mode="all", query="nothing called this") == []


def test_the_rarity_menu_is_ordered_the_way_the_database_orders_rarities(conn):
    """The quality menu reuses `RARITY_MARK`'s key order rather than a list.

    That is only safe while the mapping agrees with `rarities.sort_order` -
    if a rarity is added to the database and not to the mapping, it silently
    disappears from the menu rather than appearing in the wrong place, which
    is the harder failure to notice.
    """
    from bot.character import RARITY_MARK

    in_db = [
        r[0] for r in conn.execute(
            "SELECT code FROM rarities ORDER BY sort_order"
        ).fetchall()
    ]
    mapped = [q for q in RARITY_MARK]

    assert mapped == [q for q in in_db if q in RARITY_MARK], (mapped, in_db)
    missing = [q for q in in_db if q not in RARITY_MARK]
    assert missing == [], f"rarities the menu would drop: {missing}"


def test_the_anvil_never_promises_a_tier_it_will_not_make(harness, user, player_id):
    """clea's anvil said "1,204 potency -> a tier 8 piece" and made a tier 7.

    The screen mirrored the forge's LEAST(potency, metal, smith) and stopped
    there - but `forge` drops a short attempt to tier 7 on the very next line,
    when `pseudo_immortal_shortfall` finds anything missing. So the forecast
    announced a tier the anvil had already decided not to make, with the
    reason printed underneath it as a footnote to the wrong number.
    """
    from bot.cogs.forge import fetch_skill, render_anvil

    make_smith(harness, player_id)
    # Deep enough that the smith's own cap is not what holds the tier back -
    # otherwise this would pass for the wrong reason.
    harness.execute(
        "SELECT grant_profession_exp(%s, 'blacksmithing', 900000, FALSE)", (player_id,)
    )
    slot = harness.sql(
        "SELECT code, name, emoji, description FROM equipment_slots WHERE code = 'armour'"
    )
    skill = harness.runner.run(fetch_skill(player_id))
    assert skill["tier_cap"] >= 8, skill["tier_cap"]

    def becomes(ores, parts):
        card = harness.runner.run(render_anvil(skill, slot, ores, parts))
        return next(f for f in card.fields if f.name == "Becomes").value

    # Exactly what clea had: two kinds of tier 8 metal and 500 fodder potency.
    said = becomes(
        {"glacier_heart_adamant": 6, "eight_sided_diamond_star_fragment": 5},
        {"primordial_blood": 15, "immortal_soul_ember": 5},
    )
    assert "tier 7" in said, said
    assert "tier 8** piece" not in said, "the anvil still promises a tier 8"
    assert "Pseudo-Immortal" in said, "it dropped the tier without saying why"

    # And the promise is kept when the conditions actually are met.
    ok = becomes(
        {"glacier_heart_adamant": 3, "heavenly_origin_adamant": 3,
         "leviathan_spine_ore": 3},
        {"dragon_scale": 80},
    )
    assert "tier 8" in ok, ok
    assert "still wants" not in ok, ok


def test_a_deep_collection_is_reachable_by_rank_name_and_paging():
    """95 of pashu0's 140 servants could not be chosen at all.

    The picker took `self.rows[:25]` from a tier-ordered list, so a deep
    collection showed its top and said nothing about the rest - not hard to
    reach, absent. Three things fix it and this pins all three: a rank filter,
    a name filter, and pages.
    """
    import discord

    from bot.cogs.servants import RARITIES, ServantView, read_rank

    RARITIES.clear()
    RARITIES.update({1: "common", 2: "uncommon", 3: "rare", 4: "epic",
                     5: "legendary", 6: "mythic", 7: "unique"})

    class _User:
        id = 1
        display_name = "Tester"

    # A collection shaped like the deepest one in the game.
    spread = {5: 2, 4: 14, 3: 29, 2: 32, 1: 63}
    rows = []
    for tier, n in spread.items():
        for i in range(n):
            rows.append({
                "player_servant_id": len(rows) + 1,
                "name": f"Bai Ning Bing {i}" if tier == 5 else f"Servant T{tier} #{i}",
                "tier": tier, "stars": 1, "rarity": RARITIES[tier],
                "farming": False, "attending": False,
                "bonus_kind": "strength", "bonus_name": "Sinew",
                "is_flat": True, "is_strike": False, "grants": 1,
                "spares": 0, "copies_needed": 1, "next_stars": 2,
            })
    assert len(rows) == 140

    view = ServantView(_User(), 1)
    view.rows = rows

    # Every servant is reachable by paging - the whole point.
    assert view.page_count() == 6, view.page_count()
    from bot.picking import page_of
    reached = {
        r["player_servant_id"]
        for page in range(view.page_count())
        for r in page_of(view.visible(), page)
    }
    assert len(reached) == 140, f"only {len(reached)} of 140 can be chosen"

    # Rank narrows, and it takes the number, the T-form or the rarity word -
    # a search box that refuses the notation printed on the card is one people
    # stop using.
    assert read_rank("4") == 4
    assert read_rank("T4") == 4
    assert read_rank("epic") == 4
    assert read_rank("") is None
    assert read_rank("nonsense") is None

    view.tier = 4
    assert len(view.visible()) == 14
    assert view.page_count() == 1

    # Name narrows too, and the two narrow TOGETHER rather than replacing
    # each other: "a mythic called Bai" is one question, not two.
    view.tier = 5
    view.term = "bai"
    assert len(view.visible()) == 2
    view.term = "nobody"
    assert view.visible() == []

    # A search matching nobody must not build a select with no options, which
    # Discord refuses outright - the screen would simply fail to render.
    view.build()
    assert not any(isinstance(c, discord.ui.Select) for c in view.children)

    # And clearing gets the whole collection back.
    view.tier, view.term, view.page = None, "", 0
    view.build()
    assert len(view.visible()) == 140

    # The layout still fits: 5 rows, 5 items each, and discord.py accepts it.
    used: dict[int, int] = {}
    for child in view.children:
        used[child.row] = used.get(child.row, 0) + 1
    assert all(n <= 5 for n in used.values()), used
    assert max(used) <= 4, used


def test_the_refinery_filters_on_path_and_kind_independently():
    """Two questions, two filters, and neither clears the other.

    Path was the only axis. It is the wrong one on its own: somebody after a
    Refinement manual holds Refinement pages scattered over a dozen Paths, and
    somebody aiming at one Path still has to pick the Attack pages out of the
    Cultivation ones by eye.

    The kind counts are deliberately taken AFTER the Path filter, so "Attack
    x2" while Lightning is chosen means two Lightning Attack pages - the
    question somebody narrowing twice is actually asking.
    """
    from bot.cogs.refine import RefineView

    class _User:
        id = 1

    shelf = [
        {"page_id": 1, "tier": 5, "power": 40, "quality": 80,
         "path_code": "wood", "path_name": "Wood Path",
         "type_code": "attack", "type_name": "Attack", "trait_name": None},
        {"page_id": 2, "tier": 5, "power": 40, "quality": 80,
         "path_code": "wood", "path_name": "Wood Path",
         "type_code": "refinement", "type_name": "Refinement", "trait_name": None},
        {"page_id": 3, "tier": 5, "power": 40, "quality": 80,
         "path_code": "fire", "path_name": "Fire Path",
         "type_code": "refinement", "type_name": "Refinement", "trait_name": None},
    ]
    view = RefineView(1, _User(), shelf, cap=8)

    def ids():
        return sorted(p["page_id"] for p in view.visible_pages())

    assert ids() == [1, 2, 3], "the shelf opens unfiltered"

    view.chosen_types = {"refinement"}
    assert ids() == [2, 3]

    # Adding a Path narrows further and does not clear the kind.
    view.chosen_paths = {"wood"}
    assert ids() == [2]
    assert view.chosen_types == {"refinement"}

    # The kind menu counts what is on the CURRENT shelf, not the whole bag.
    view.chosen_types = set()
    kinds = {code: n for code, _, n in view.held_types()}
    assert kinds == {"attack": 1, "refinement": 1}, kinds

    # And clearing takes both off.
    view.chosen_paths.clear()
    view.chosen_types.clear()
    assert ids() == [1, 2, 3]


def test_no_ui_item_shadows_the_row_property():
    """`self.row` on a Button is not a field, it is discord.py's layout row.

    `discord.ui.Item` exposes `row` as a property validated with
    `5 > value >= 0`, so `self.row = some_dict` raises TypeError inside the
    setter. That happens while a view is being rebuilt - before the
    interaction has been answered - so Discord reports it as the bot never
    responding, and the traceback is nowhere near the thing anybody typed.

    The servants cog did exactly this and took `/servants` down with it. A
    Modal or a View may hold `self.row` quite safely, which is why this looks
    at what a class inherits from rather than at the name alone.
    """
    import ast
    import pathlib

    ui_items = {"Button", "Select", "Item", "TextInput", "ChannelSelect",
                "RoleSelect", "UserSelect", "MentionableSelect"}
    guilty: list[str] = []

    for path in sorted(
        (pathlib.Path(__file__).resolve().parent.parent / "bot").rglob("*.py")
    ):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if not isinstance(node, ast.ClassDef):
                continue
            # discord.ui.Button, ui.Select, and so on - the last name is what
            # decides, so an aliased import is caught too.
            if not any(
                isinstance(base, ast.Attribute) and base.attr in ui_items
                for base in node.bases
            ):
                continue
            for inner in ast.walk(node):
                if not isinstance(inner, ast.Assign):
                    continue
                for target in inner.targets:
                    if (
                        isinstance(target, ast.Attribute)
                        and target.attr == "row"
                        and isinstance(target.value, ast.Name)
                        and target.value.id == "self"
                    ):
                        guilty.append(f"{path.name}:{inner.lineno} {node.name}")

    assert guilty == [], (
        "these UI items assign self.row, which is discord.py's layout row: "
        + ", ".join(guilty)
    )


def test_the_pet_card_only_reads_columns_the_shelf_query_selects():
    """How /pet broke the moment beasts got bodies.

    `player_beast_shelf` grew `hp`, `max_hp` and `is_down` in 0286, the card
    was taught to draw a health bar from them, and `fetch_beasts` was left
    selecting its old explicit column list. The view had the data, the query
    did not ask for it, and every /pet in the server answered KeyError: 'hp'.

    A `SELECT *` would have hidden it. The explicit list is the right call for
    a hot query - so this checks the list instead.
    """
    import pathlib
    import re

    source = (
        pathlib.Path(__file__).resolve().parent.parent
        / "bot" / "cogs" / "eggs.py"
    ).read_text(encoding="utf-8")

    # The SELECT list inside fetch_beasts, up to its FROM.
    block = source[source.index("async def fetch_beasts"):]
    selected = block[: block.index("FROM player_beast_shelf")]
    columns = set(re.findall(r"\bs\.(\w+)", selected))
    assert columns, "could not find the shelf query's column list"

    # Every shelf key the card and its pickers read. `row[...]` off a single
    # fetched beast is a SELECT * elsewhere, so only the two names that carry
    # a fetch_beasts row are checked.
    card = source[source.index("class PetView"):]
    read = set(re.findall(r"""(?<!\w)(?:at_heel|r)\[["'](\w+)["']\]""", card))

    missing = sorted(read - columns)
    assert missing == [], (
        f"the /pet screen reads {missing} off a row fetch_beasts never selected"
    )


def test_no_screen_reaches_for_a_name_that_does_not_exist():
    """`/read` raised NameError: StudyPicker for every cultivator who had a
    manual ready to read.

    The class was referenced once and defined nowhere, and the whole suite
    stayed green, because the line that reaches for it is guarded:

        view = StudyPicker(...) if ready else None

    With an empty shelf the name is never evaluated, so nothing ran it. That
    is the shape of the bug worth catching generally - a name that only some
    players' data reaches - and it is exactly what an undefined-name check
    finds without needing to construct those players.

    Only UndefinedName is asserted on. pyflakes also reports unused imports and
    f-strings without placeholders across this codebase; those are tidiness and
    are deliberately not failures here, because a check that cries about style
    is a check somebody turns off.
    """
    import ast
    import pathlib

    from pyflakes import checker
    from pyflakes.messages import UndefinedExport, UndefinedLocal, UndefinedName

    root = pathlib.Path(__file__).resolve().parent.parent
    wanted = (UndefinedName, UndefinedLocal, UndefinedExport)

    found = []
    for path in sorted((root / "bot").rglob("*.py")):
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=str(path))
        for message in checker.Checker(tree, filename=str(path)).messages:
            if isinstance(message, wanted):
                found.append(
                    f"{path.relative_to(root)}:{message.lineno}: {message}"
                )

    assert found == [], "a screen reaches for something that is not there:\n" + "\n".join(
        found
    )
