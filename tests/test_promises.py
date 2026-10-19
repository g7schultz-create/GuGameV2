"""Every command a screen tells a player to type has to exist.

`test_every_command_the_tutorial_names_exists` guards the guide, which lives in
the database. Nothing guarded the CARDS, which is where most of the pointing
actually happens - and they had drifted four times:

    garden.py    /plant      -> /garden plant
    garden.py    /harvest    -> /garden harvest
    bestiary.py  /cultivate  -> /cultivation
    core.py      /brew       -> /alchemy       (it is described as "Brew herbs")

The first two are what folding the garden into a Group cost: the commands moved
and the footer under them did not. That is this repo's oldest recurring bug - a
guard moved and a reader did not - and a footer is a reader.

THE TREE, NOT A REGEX, and that was learned twice over. Scanning source for
`async def` names reports /yield as missing forever, because duel.py declares

    @app_commands.command(
        name="yield", description="Give up a duel you cannot win."
    )
    async def yield_duel(self, interaction): ...

since `yield` is a Python keyword - the command is /yield and the function is
not. Patching the regex to read name= then still missed /duel, /study and
/techniques, whose decorators span lines in ways the pattern did not expect.

So this asks discord.py what the commands are. `walk_commands` returns every
leaf with its real name, group paths included, which is the same list Discord
itself is handed. Loading the extensions needs no database - nothing opens a
pool until the bot is actually started.
"""

import asyncio
import pathlib
import re

import discord
import pytest

from bot.client import EXTENSIONS, GuBot

COGS = pathlib.Path("bot/cogs")

# What a card looks like when it points somewhere: **/thing** or **/thing sub**.
MENTION = re.compile(r"\*\*/([a-z_]+(?: [a-z_]+)?)\*\*")


@pytest.fixture(scope="module")
def shipped() -> set[str]:
    """Every name a player can type, straight out of the command tree."""

    async def build() -> set[str]:
        bot = GuBot()
        for ext in EXTENSIONS:
            await bot.load_extension(ext)

        names: set[str] = set()
        for command in bot.tree.walk_commands():
            if isinstance(command, discord.app_commands.Group):
                names.add(command.name)
                continue
            parent = command.parent
            names.add(
                f"{parent.name} {command.name}" if parent else command.name
            )
        return names

    return asyncio.run(build())


def test_the_tree_is_actually_loaded(shipped):
    """The check is only worth having if it can see the tree it checks against.

    A probe that cannot fail is worse than no probe, and a `shipped` that came
    back empty would make the test below pass by being blind.
    """
    for expected in (
        "hunt",
        "gu look",
        "gu dissolve",
        "farm place",
        "garden plant",
        "yield",          # the name= override that defeated two regexes
        "duel",
        "techniques",
    ):
        assert expected in shipped, f"the tree does not contain /{expected}"


def test_no_card_names_a_command_that_does_not_exist(shipped):
    broken: dict[str, set[str]] = {}

    for path in sorted(COGS.glob("*.py")):
        for named in MENTION.findall(path.read_text(encoding="utf-8")):
            if named in shipped:
                continue
            # "**/pet** to see it" style mentions can swallow a following word,
            # so a two-word miss whose first word is real is prose, not a bug.
            if " " in named and named.split()[0] in shipped:
                continue
            broken.setdefault(path.name, set()).add(named)

    assert broken == {}, (
        "these cards tell a player to type a command that does not exist: "
        + "; ".join(f"{f}: {sorted(n)}" for f, n in sorted(broken.items()))
    )


# ---------------------------------------------------------------------------
# And the tree has to fit in Discord
# ---------------------------------------------------------------------------
# Discord allows 100 slash commands and a cog that pushes past the line does not
# degrade - it raises CommandLimitReached and takes all of its own commands with
# it. The garden hit this the day it landed. A Group costs ONE slot however many
# subcommands hang off it, which is the only lever there is.


def live_extensions(dev: bool) -> list[str]:
    """What `setup_hook` would load, so this measures what really syncs.

    `bot.cogs.prefix` is NOT filtered here: setup_hook drops it only when
    MESSAGE CONTENT is unavailable, and it registers no slash command either
    way, so it cannot affect the count this file is about.
    """
    return [e for e in EXTENSIONS if dev or e != "bot.cogs.dev"]


def tree_size(dev: bool) -> tuple[int, bool]:
    async def build():
        bot = GuBot(dev_commands=dev, sync_on_start=False)
        for ext in live_extensions(dev):
            await bot.load_extension(ext)
        top = bot.tree.get_commands()
        return len(top), any(c.name == "dev" for c in top)

    return asyncio.run(build())


def test_the_live_tree_fits_in_discords_ceiling():
    count, has_dev = tree_size(dev=False)
    assert not has_dev, (
        "/dev is registered by default; it is thirteen subcommands on one slot "
        "and the slot is worth more than the convenience"
    )
    assert count <= 100, (
        f"the live tree is {count} commands and Discord allows 100 - fold two "
        f"related commands into an app_commands.Group to buy a slot back"
    )


def test_dev_comes_back_when_asked_for():
    """Gated, not deleted. 33 tests use /dev as setup machinery and the cog is
    the only admin tooling there is, so the switch has to work in both
    directions - a one-way removal would have been a deletion with extra steps.
    """
    count, has_dev = tree_size(dev=True)
    assert has_dev, "DEV_COMMANDS could not bring /dev back"
    assert count <= 100, f"the tree with /dev is {count} commands, over the 100 cap"
