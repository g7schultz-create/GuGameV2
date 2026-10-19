"""A refusal raised inside a button has to reach the player.

`tree.on_error` catches command bodies. Components are dispatched separately,
and discord.py's default handler logs a traceback and answers nothing - so a
view that does not override `on_error` turns "your aperture holds 4 and this
needs 2 more" into a red box and a log line the player cannot read.

That is not a hypothetical: it is what `/gu` did. The message was built
correctly, raised as a `GameError`, and dropped, because `GuView` was a plain
`discord.ui.View` while five other cogs had each written their own answer.

The first test below is the one that would have caught it, and it needs no
database: it walks the package and asks every view the same question.
"""

import importlib
import inspect
import pkgutil

import discord

import bot
from bot.players import GameError
from bot.views import AnsweringModal, AnsweringView, answer_error


def every_class(base):
    """Every subclass of `base` defined anywhere in the bot package."""
    found = {}
    for info in pkgutil.walk_packages(bot.__path__, prefix="bot."):
        module = importlib.import_module(info.name)
        for name, obj in vars(module).items():
            if (
                inspect.isclass(obj)
                and issubclass(obj, base)
                and obj is not base
                and obj.__module__ == info.name
            ):
                found[f"{info.name}.{name}"] = obj
    return found


def test_every_view_answers_its_own_refusals():
    views = every_class(discord.ui.View)
    assert views, "the walk found nothing, which means it is not walking"

    silent = sorted(
        name
        for name, cls in views.items()
        if not issubclass(cls, AnsweringView) and "on_error" not in vars(cls)
    )
    assert not silent, (
        "these views drop a GameError into the log instead of telling the "
        f"player: {silent}. Inherit AnsweringView."
    )


def test_every_modal_answers_too():
    """A modal has its own handler and its own silent default."""
    modals = every_class(discord.ui.Modal)
    silent = sorted(
        name
        for name, cls in modals.items()
        if not issubclass(cls, AnsweringModal) and "on_error" not in vars(cls)
    )
    assert not silent, f"these modals answer nothing: {silent}"


# ---------------------------------------------------------------------------
# What the shared handler actually does
# ---------------------------------------------------------------------------


class Response:
    def __init__(self) -> None:
        self.sent = []
        self.done = False

    def is_done(self) -> bool:
        return self.done

    async def send_message(self, *, embed=None, ephemeral=False, **kw):
        self.done = True
        self.sent.append(embed)


class Followup:
    def __init__(self, response: Response) -> None:
        self.response = response

    async def send(self, *, embed=None, ephemeral=False, **kw):
        self.response.sent.append(embed)


class Interaction:
    def __init__(self) -> None:
        self.response = Response()
        self.followup = Followup(self.response)


def test_a_refusal_is_shown_to_the_player():
    import asyncio

    interaction = Interaction()
    handled = asyncio.run(
        answer_error(interaction, GameError("your aperture holds 4 and this needs 2 more"))
    )
    assert handled is True
    assert "aperture" in interaction.response.sent[0].description


def test_a_bug_is_not_swallowed():
    """Anything that is not a GameError goes back to discord.py with its
    traceback, because a screen that ate those would be worse than one that
    said nothing."""
    import asyncio

    interaction = Interaction()
    handled = asyncio.run(answer_error(interaction, ValueError("a real bug")))
    assert handled is False
    assert interaction.response.sent == []


def test_an_already_answered_interaction_uses_the_followup():
    """Half the refusals on these screens arrive after the view has already
    replied once - a quantity typed into a modal opened off an ephemeral
    picker is three messages deep."""
    import asyncio

    interaction = Interaction()
    interaction.response.done = True
    asyncio.run(answer_error(interaction, GameError("too much")))
    assert len(interaction.response.sent) == 1


def test_fuse_can_reach_every_tier_it_lists():
    """The select showed the first 25 of a tier-descending shelf. With 190
    stacks that put tier 2 at position 88 and tier 1 at 183 - so fusion looked
    broken on low tiers when the database was fine and the screen could not
    reach them."""
    import discord

    from bot.cogs.fusion import FuseView

    stacks = [
        {
            "tier": tier,
            "path_code": f"path{n}",
            "page_type": "attack",
            "path_name": f"Path {n}",
            "type_name": "Attack",
            "held": 3,
            "fusions": 1,
            "avg_quality": 70,
        }
        for tier in (5, 4, 3, 2, 1)
        for n in range(40)
    ]

    user = type("U", (), {"id": 1})()
    view = FuseView(1, user, stacks)

    # Discord's own limit, which is what the bug was about.
    for item in view.children:
        if isinstance(item, discord.ui.Select):
            assert len(item.options) <= 25

    # Every tier on the shelf is one press away.
    offered = {
        int(b.label.split()[0][1:])
        for b in view.children
        if isinstance(b, discord.ui.Button) and b.label.startswith("T")
    }
    assert offered == {1, 2, 3, 4, 5}, offered

    # And picking the lowest one actually lists it.
    view.tier = 1
    view.page = 0
    view.build()
    shown = next(
        i for i in view.children if isinstance(i, discord.ui.Select)
    ).options
    assert shown, "tier 1 is offered but lists nothing"
    assert all(o.label.startswith("T1 ") for o in shown), (
        "the tier filter listed something else"
    )


def test_big_numbers_are_read_not_counted():
    """0248 put stats on a four-times-a-major-realm ladder, so an Ancient Realm
    cultivator carries eight figures and a rank 9 dungeon boss nine. Below a
    hundred million a player is still comparing digits; above it nobody is."""
    from bot.formatting import SHORTHAND_FROM, thousands

    # Under the line, nothing changes.
    assert thousands(999) == "999"
    assert thousands(12_480) == "12,480"
    assert thousands(SHORTHAND_FROM - 1) == "99,999,999"

    # On and over it, shorthand.
    assert thousands(SHORTHAND_FROM) == "100M"
    assert thousands(150_994_944) == "151M"
    assert thousands(1_234_000_000) == "1.23B"
    assert thousands(1_500_000_000) == "1.5B"
    assert thousands(2_400_000_000_000) == "2.4T"

    # The unit is picked against the rounded value, so this is not "1000M".
    assert thousands(999_600_000) == "1B"
    assert thousands(999_499_999) == "999M"

    # And the old contract holds.
    assert thousands(None) == "-"
    assert thousands(-150_994_944) == "-151M"


def test_a_long_picker_can_be_searched_not_only_paged():
    """Paging made everything reachable and nothing findable.

    A cultivator with eighty-one kinds of material looking for their Dungeon
    Keys was four pages of guessing away from them - reachable, in the sense
    that a haystack contains a needle.
    """
    import discord

    from bot.picking import PER_PAGE, PagedPicker

    rows = [{"name": f"Material {n}", "ref": str(n)} for n in range(80)]
    rows.append({"name": "Dungeon Key", "ref": "dungeon_key"})

    def make_select(page):
        return discord.ui.Select(
            placeholder="Which one?",
            options=[
                discord.SelectOption(label=r["name"], value=r["ref"]) for r in page
            ],
        )

    view = PagedPicker(make_select, rows, noun="materials")

    # The keys are not on the first page, which is the whole complaint.
    first = next(i for i in view.children if isinstance(i, discord.ui.Select))
    assert "dungeon_key" not in [o.value for o in first.options]

    # A search finds them.
    view.term = "key"
    view.page = 0
    view.build()
    found = next(i for i in view.children if isinstance(i, discord.ui.Select))
    assert [o.value for o in found.options] == ["dungeon_key"]

    # And the paging follows the filter rather than the whole list.
    assert view.page_count() == 1


def test_a_search_that_finds_nothing_shows_everything():
    """discord.py refuses to render a select with no options, so an empty
    result would be a crash rather than a shrug."""
    import discord

    from bot.picking import PagedPicker

    rows = [{"name": f"Thing {n}"} for n in range(40)]

    def make_select(page):
        return discord.ui.Select(
            options=[discord.SelectOption(label=r["name"]) for r in page]
        )

    view = PagedPicker(make_select, rows)
    view.term = "nothing here matches this"
    view.build()

    shown = next(i for i in view.children if isinstance(i, discord.ui.Select))
    assert len(shown.options) > 0


def test_a_short_picker_is_not_given_a_search_it_does_not_need():
    import discord

    from bot.picking import PER_PAGE, PagedPicker

    rows = [{"name": f"Thing {n}"} for n in range(3)]

    def make_select(page):
        return discord.ui.Select(
            options=[discord.SelectOption(label=r["name"]) for r in page]
        )

    view = PagedPicker(make_select, rows)
    labels = [getattr(i, "label", "") for i in view.children]
    assert not any("Find" in str(x) for x in labels), (
        "a menu that already shows everything was given a search box"
    )


def test_a_boss_stand_off_always_leaves_something_to_press():
    """The stand-off disabled the only button on the screen.

    Spend the fifth strike and the strike button became 'Ready in 7m' and
    disabled - and it was the only component there, so nothing could be
    pressed to redraw it. The count froze at whatever it said when the burst
    ran out and the button never came back; re-running /boss was the only way
    out. A timer that cannot reach zero is a broken timer.
    """
    from bot.cogs.boss import BossView, LookAgainButton, StrikeButton

    class Someone:
        id = 1

    standing = BossView(
        1, Someone(), {"status": "open", "strikes_left": 3, "ready_in": 420.0}
    )

    struck = next(c for c in standing.children if isinstance(c, StrikeButton))
    assert struck.disabled, "the fixture no longer represents a stand-off"

    live = [c for c in standing.children if not c.disabled]
    assert live, "a standing-off boss screen has nothing left to press"
    assert any(isinstance(c, LookAgainButton) for c in live)


def test_the_boss_screen_outlasts_its_own_stand_off():
    """At 300 seconds against a 420 second wait the screen died before the
    wait did, so the countdown could never be watched to its end."""
    from bot.cogs.boss import STAND_OFF_SECONDS, BossView

    class Someone:
        id = 1

    view = BossView(1, Someone(), {"status": "open", "strikes_left": 5, "ready_in": None})
    assert view.timeout > STAND_OFF_SECONDS, (
        f"the screen times out after {view.timeout}s and the stand-off lasts "
        f"{STAND_OFF_SECONDS}s"
    )


def test_the_stand_off_the_screen_assumes_is_the_one_the_game_enforces(conn):
    """A view's timeout is chosen before any query runs, so the wait is
    mirrored in Python. This is what stops the two drifting apart."""
    from bot.cogs.boss import STAND_OFF_SECONDS

    minutes = conn.execute(
        "SELECT game_config_value('boss_strike_cooldown_minutes')"
    ).fetchone()[0]
    assert STAND_OFF_SECONDS == int(minutes) * 60, (
        f"the screen expects a {STAND_OFF_SECONDS}s stand-off and the game "
        f"enforces {int(minutes) * 60}s"
    )


def test_a_prefix_command_can_still_name_a_user():
    """`I trade @someone` raised AttributeError rather than running.

    The converter reached for `commands.Context.from_message`, which is not a
    discord.py API and never has been, so every prefix command taking a user
    was dead while its slash twin worked. Nothing here needs a Context: a
    mention is already parsed onto the message.
    """
    import asyncio

    from bot.cogs import prefix as prefix_cog

    class Someone:
        id = 4242

    class Msg:
        mentions = [Someone()]

    class Shim:
        message = Msg()
        guild = None
        client = None

    found = asyncio.run(prefix_cog.resolve_user(Shim(), "<@4242>"))
    assert found.id == 4242, "a mention did not resolve to the person mentioned"

    # And the API that never existed is not reached for again.
    import inspect

    # The call, not the word - the docstring explaining the bug says its name.
    assert "commands.Context.from_message(" not in inspect.getsource(prefix_cog), (
        "the converter is back on an API discord.py does not have"
    )


def test_the_dungeon_sweeper_does_not_wait_to_be_looked_at():
    """`sweep` was called only from the two screens, so a forming run sat
    forty minutes past its ten minute limit holding its party out, because
    nobody typed /dungeon in the meantime."""
    import inspect

    from bot.cogs import dungeon as dungeon_cog

    assert hasattr(dungeon_cog.Dungeon, "keep_time"), (
        "nothing sweeps the dungeon on a clock"
    )
    assert "sweep" in inspect.getsource(dungeon_cog.Dungeon.keep_time.coro)
