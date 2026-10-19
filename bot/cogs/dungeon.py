"""Dungeons: /dungeons and /dungeon.

Nine doors, one per realm, four difficulties, and a party of one to five who
were invited by name. A key opens it, and a key arrives every twelve hours.

NOTHING TICKS HERE, because nothing ticks anywhere in this game. A round
resolves the moment the last raider chooses, or the next time anybody looks at
the room after its sixty seconds are up - the same rule the passive cultivation
settle and the world boss spawn already follow. A raider who says nothing
swings with their first attack technique, so a silent friend costs the party a
choice and never the round.

The damage is the database's. `dungeon_resolve_round` calls the same
`compute_technique_damage` a duel does, so a dungeon is not a second opinion
about how hard anybody hits.
"""

import logging

import discord
import psycopg
from discord import app_commands
from discord.ext import commands, tasks

from bot import database as db
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    COLOUR_INFO,
    bar,
    embed,
    humanise_duration,
    thousands,
)
from bot.players import GameError, require_player, settle_passive
from bot.views import AnsweringView

KEY = "\N{OLD KEY}"
STONE = "\N{LARGE BLUE DIAMOND}"
JADE = "\N{GEM STONE}"
DOOR = "\N{DOOR}"
SKULL = "\N{SKULL}"


def refuse(exc: psycopg.errors.CheckViolation) -> GameError:
    said = str(exc).splitlines()[0]
    return GameError(said[:1].upper() + said[1:])


async def sweep() -> None:
    """Resolve whatever the clock has finished with.

    Called from both screens AND from a loop, because a sweeper that only runs
    when somebody opens a screen is not a sweeper. A forming run sat forty
    minutes past its ten minute limit once, holding its whole party out of
    the dungeon, simply because nobody typed /dungeon in the meantime.

    A round whose sixty seconds are up resolves whether or not everybody
    spoke; a party that never went through the door stops holding it after
    `dungeon_forming_minutes`.
    """
    for due in await db.fetch_all("SELECT * FROM dungeon_runs_due()"):
        if due["why"] == "round":
            await db.execute(
                "SELECT * FROM dungeon_resolve_round(%s)", (due["run_id"],)
            )
        else:
            await db.execute("SELECT dungeon_abandon(%s)", (due["run_id"],))


async def my_run(player_id: int) -> dict | None:
    return await db.fetch_one(
        """
        SELECT s.* FROM dungeon_run_state s
        JOIN dungeon_raiders x ON x.run_id = s.run_id
        WHERE x.player_id = %s AND s.status IN ('forming', 'fighting')
        """,
        (player_id,),
    )


async def party_of(run_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT x.*, p.discord_name,
               (x.player_id = r.leader_id) AS is_leader,
               -- The beast at their heel swings in this lane and takes
               -- `pet_cover_share` of every blow meant for them, and the room
               -- showed neither its health nor that it was there at all.
               -- `pet_at_heel` rather than `pet_standing`: a downed beast is
               -- still your beast, and the raider most needs to see the bar
               -- on the round it empties.
               b.name AS pet_name,
               pet_hp(b.beast_id) AS pet_hp,
               pet_max_hp(b.beast_id) AS pet_max_hp
        FROM dungeon_raiders x
        JOIN players p ON p.player_id = x.player_id
        JOIN dungeon_runs r ON r.run_id = x.run_id
        LEFT JOIN player_beasts b ON b.beast_id = pet_at_heel(x.player_id)
        WHERE x.run_id = %s
        ORDER BY x.joined_at, x.player_id
        """,
        (run_id,),
    )


async def foes_of(run_id: int) -> list[dict]:
    """Everything standing in the room, in the order it is numbered.

    A room held one creature until 0540. `dungeon_runs.boss_hp` is kept as
    the SUM of these so the old readers still work, which means the single
    bar this screen used to draw was the whole room under one of their
    names.
    """
    return await db.fetch_all(
        """
        SELECT f.foe_no, f.current_hp, f.max_hp,
               cs.name, cs.description
        FROM dungeon_foes f
        JOIN creature_species cs ON cs.species_id = f.species_id
        WHERE f.run_id = %s
        ORDER BY f.foe_no
        """,
        (run_id,),
    )


# The circled digits a foe is named by, so the bar, the menu and the round
# log all call it the same thing.
FOE_MARKS = (
    "\N{CIRCLED DIGIT ONE}\N{CIRCLED DIGIT TWO}\N{CIRCLED DIGIT THREE}"
    "\N{CIRCLED DIGIT FOUR}\N{CIRCLED DIGIT FIVE}\N{CIRCLED DIGIT SIX}"
)


def foe_mark(foe_no: int) -> str:
    return FOE_MARKS[foe_no] if 0 <= foe_no < len(FOE_MARKS) else "?"


# ---------------------------------------------------------------------------
# The catalogue
# ---------------------------------------------------------------------------


async def fetch_doors(player_id: int) -> list[dict]:
    return await db.fetch_all(
        """
        SELECT d.*, s.name AS boss_name, s.rank AS boss_rank,
               r.name AS realm_name,
               COALESCE((SELECT pm.quantity FROM player_materials pm
                         WHERE pm.player_id = %(me)s
                           AND pm.material_code = 'dungeon_key'), 0) AS keys_held,
               -- STANDING. `reach()` compares this against the door's
               -- rank to say how bad an idea it is, and a Venerable
               -- read 18 - so the rooms they outrank came back
               -- "a stretch", "lethal" and "hopeless".
               player_standing(%(me)s) AS my_rank
        FROM dungeons d
        JOIN creature_species s ON s.species_id = d.species_id
        -- LEFT, and the Venerable ladder as the second half. This was an
        -- INNER join onto `realms` by the door's own rank, and no realm
        -- has rank 19 - so The Vault of Unclaimed Dao was dropped from
        -- the catalogue entirely. Nineteen rows in `dungeons`, eighteen
        -- on the screen, no error anywhere: the headline room of the
        -- update could not be seen or opened by the only cultivator who
        -- was allowed in it.
        LEFT JOIN LATERAL (
            SELECT COALESCE(
                (SELECT rr.name FROM realms rr WHERE rr.rank = d.realm_rank
                 ORDER BY rr.realm_id LIMIT 1),
                (SELECT v.name FROM venerable_ranks v
                 WHERE v.rank = d.realm_rank)
            ) AS name
        ) r ON TRUE
        ORDER BY d.realm_rank
        """,
        {"me": player_id},
    )


def reach(door: dict) -> str:
    """How far above the reader this door is. Any of them may be entered."""
    mine = door["my_rank"] or 1
    over = door["realm_rank"] - mine
    if over <= -2:
        return "trivial"
    if over <= 0:
        return "even"
    if over == 1:
        return "a stretch"
    if over == 2:
        return "lethal"
    return "hopeless"


def door_line(door: dict) -> str:
    cost = f"{thousands(door['stone_cost'])} {STONE}"
    if door["jade_cost"]:
        cost += f" \N{BULLET} {door['jade_cost']} {JADE}"
    return (
        f"`{door['realm_rank']}` **{door['name']}** \N{BULLET} *{reach(door)}*\n"
        f"\N{IDEOGRAPHIC SPACE}{SKULL} {door['boss_name']} \N{BULLET} "
        f"{door['realm_name'].split(' — ')[0]}\n"
        f"\N{IDEOGRAPHIC SPACE}{KEY} 1 \N{BULLET} {cost} \N{EM DASH} each"
    )


async def render_doors(doors: list[dict], display_name: str) -> discord.Embed:
    held = doors[0]["keys_held"] if doors else 0
    card = embed(
        f"{DOOR} The {len(doors)} doors",
        "One for every realm, and any of them will open for anybody. What is "
        "behind them does not check whether you were ready.\n\n"
        f"*Everyone in the party pays their own way in.*",
        colour=COLOUR_INFO,
    )
    # Six to a field, and the range is read off the doors rather than written
    # down. An embed field holds 1024 characters and a door line runs to about
    # 120 of them, so the old half-and-half split sat one realm short of the
    # limit and went over it the moment the immortal rooms doubled the list.
    for start in range(0, len(doors), 6):
        run = doors[start:start + 6]
        card.add_field(
            name=f"Realms {run[0]['realm_rank']} to {run[-1]['realm_rank']}",
            value="\n\n".join(door_line(d) for d in run),
            inline=False,
        )

    steps = await db.fetch_all(
        "SELECT name, hp_scale, reward_scale FROM dungeon_difficulties "
        "ORDER BY sort_order"
    )
    card.add_field(
        name="Difficulty",
        value="\n".join(
            f"**{s['name']}** \N{BULLET} {float(s['hp_scale']):g}\N{MULTIPLICATION SIGN} health "
            f"\N{BULLET} {float(s['reward_scale']):g}\N{MULTIPLICATION SIGN} spoils"
            for s in steps
        ),
        inline=False,
    )
    card.set_footer(
        text=f"You hold {held} key(s) \N{BULLET} one arrives every 12 hours "
        "\N{BULLET} keys can be traded"
    )
    return card


class DoorSelect(discord.ui.Select):
    def __init__(self, screen: "Catalogue", doors: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="Which door\N{HORIZONTAL ELLIPSIS}",
            row=0,
            options=[
                discord.SelectOption(
                    label=d["name"][:100],
                    value=str(d["dungeon_id"]),
                    description=f"Realm {d['realm_rank']} \N{BULLET} "
                    f"{d['boss_name']} \N{BULLET} {reach(d)}"[:100],
                    default=d["dungeon_id"] == screen.dungeon_id,
                )
                for d in doors
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.dungeon_id = int(self.values[0])
        await self.screen.redraw(interaction)


class DifficultySelect(discord.ui.Select):
    def __init__(self, screen: "Catalogue", steps: list[dict]) -> None:
        self.screen = screen
        super().__init__(
            placeholder="How hard\N{HORIZONTAL ELLIPSIS}",
            row=1,
            options=[
                discord.SelectOption(
                    label=s["name"],
                    value=s["code"],
                    description=f"{float(s['hp_scale']):g}\N{MULTIPLICATION SIGN} health, "
                    f"{float(s['reward_scale']):g}\N{MULTIPLICATION SIGN} spoils",
                    default=s["code"] == screen.difficulty,
                )
                for s in steps
            ],
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        self.screen.difficulty = self.values[0]
        await self.screen.redraw(interaction)


class Catalogue(AnsweringView):
    def __init__(self, player_id, user, doors, steps) -> None:
        super().__init__(timeout=300)
        self.player_id = player_id
        self.user = user
        self.doors = doors
        self.steps = steps
        self.dungeon_id = None
        self.difficulty = "normal"
        self.build()

    def build(self) -> None:
        self.clear_items()
        self.add_item(DoorSelect(self, self.doors))
        self.add_item(DifficultySelect(self, self.steps))
        self.add_item(OpenButton(self))

    async def card(self) -> discord.Embed:
        return await render_doors(self.doors, self.user.display_name)

    async def redraw(self, interaction: discord.Interaction) -> None:
        self.build()
        await interaction.response.edit_message(embed=await self.card(), view=self)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Open your own with **/dungeons**.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class OpenButton(discord.ui.Button):
    def __init__(self, screen: Catalogue) -> None:
        self.screen = screen
        super().__init__(
            label="Gather a party",
            emoji=DOOR,
            row=2,
            style=discord.ButtonStyle.success,
            disabled=screen.dungeon_id is None,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            run_id = await db.fetch_value(
                "SELECT dungeon_open(%s, %s::smallint, %s)",
                (self.screen.player_id, self.screen.dungeon_id,
                 self.screen.difficulty),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        run = await db.fetch_one(
            "SELECT * FROM dungeon_run_state WHERE run_id = %s", (run_id,)
        )
        view = Lobby(self.screen.player_id, self.screen.user, run)
        await interaction.response.edit_message(
            embed=await view.card(), view=view
        )


# ---------------------------------------------------------------------------
# The doorway
# ---------------------------------------------------------------------------


async def render_lobby(run: dict, party: list[dict]) -> discord.Embed:
    card = embed(
        f"{DOOR} {run['dungeon_name']} \N{BULLET} {run['difficulty_name']}",
        f"{SKULL} **{run['boss_name']}** waits inside.\n\n"
        "Invite who you want. Everybody pays their own key and stones at the "
        "door, and the party goes in together.",
        colour=COLOUR_DEFAULT,
    )
    card.add_field(
        name=f"The party ({len(party)}/5)",
        value="\n".join(
            ("\N{CROWN} " if r["is_leader"] else "\N{IDEOGRAPHIC SPACE}")
            + f"**{r['discord_name']}**"
            for r in party
        ),
        inline=False,
    )
    waiting = await db.fetch_all(
        """
        SELECT p.discord_name FROM dungeon_invites i
        JOIN players p ON p.player_id = i.player_id
        WHERE i.run_id = %s
          AND NOT EXISTS (SELECT 1 FROM dungeon_raiders x
                          WHERE x.run_id = i.run_id AND x.player_id = i.player_id)
        ORDER BY i.invited_at
        """,
        (run["run_id"],),
    )
    if waiting:
        card.add_field(
            name="Asked, not yet come",
            value=", ".join(w["discord_name"] for w in waiting)
            + "\n*They join with **/dungeon**.*",
            inline=False,
        )
    cost = f"{KEY} 1 \N{BULLET} {thousands(run['stone_cost'])} {STONE}"
    if run["jade_cost"]:
        cost += f" \N{BULLET} {run['jade_cost']} {JADE}"
    card.set_footer(text=f"Each pays {cost} \N{BULLET} the door closes in 10 minutes")
    return card


class InviteSelect(discord.ui.UserSelect):
    def __init__(self, screen: "Lobby") -> None:
        self.screen = screen
        super().__init__(
            placeholder="Invite someone\N{HORIZONTAL ELLIPSIS}",
            row=0, max_values=4,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        asked = []
        for user in self.values:
            row = await db.fetch_one(
                "SELECT player_id FROM players WHERE discord_id = %s "
                "AND deleted_at IS NULL",
                (user.id,),
            )
            if not row:
                continue
            try:
                asked.append(await db.fetch_value(
                    "SELECT dungeon_invite(%s, %s, %s)",
                    (self.screen.run["run_id"], self.screen.player_id,
                     row["player_id"]),
                ))
            except psycopg.errors.CheckViolation as exc:
                raise refuse(exc) from exc
        await self.screen.redraw(interaction)


class CancelButton(discord.ui.Button):
    """The leader closing a door nobody went through.

    A party that gathers and changes its mind used to wait out
    `dungeon_forming_minutes` before any of them could open another, because
    every screen finds the forming run and refuses.
    """

    def __init__(self, screen: "Lobby") -> None:
        self.screen = screen
        super().__init__(
            label="Call it off", row=1, style=discord.ButtonStyle.secondary
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.execute(
                "SELECT dungeon_cancel(%s, %s)",
                (self.screen.run["run_id"], self.screen.player_id),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        for item in self.screen.children:
            item.disabled = True
        await interaction.response.edit_message(
            embed=embed(
                "The door closes",
                "Nobody went through, so nothing was spent. **/dungeon** when "
                "you are ready again.",
                colour=COLOUR_INFO,
            ),
            view=self.screen,
        )
        self.screen.stop()


class BeginButton(discord.ui.Button):
    def __init__(self, screen: "Lobby") -> None:
        self.screen = screen
        super().__init__(
            label="Go in", emoji="\N{CROSSED SWORDS}", row=1,
            style=discord.ButtonStyle.danger,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        try:
            await db.fetch_one(
                "SELECT * FROM dungeon_begin(%s, %s)",
                (self.screen.run["run_id"], self.screen.player_id),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        run = await db.fetch_one(
            "SELECT * FROM dungeon_run_state WHERE run_id = %s",
            (self.screen.run["run_id"],),
        )
        view = await Room.build_for(
            self.screen.player_id, self.screen.user, run
        )
        await interaction.response.edit_message(
            embed=await view.card(), view=view
        )


class Lobby(AnsweringView):
    def __init__(self, player_id, user, run) -> None:
        super().__init__(timeout=600)
        self.player_id = player_id
        self.user = user
        self.run = run
        self.build()

    def build(self) -> None:
        self.clear_items()
        if self.player_id == self.run["leader_id"]:
            self.add_item(InviteSelect(self))
            self.add_item(BeginButton(self))
            self.add_item(CancelButton(self))

    async def card(self) -> discord.Embed:
        return await render_lobby(self.run, await party_of(self.run["run_id"]))

    async def redraw(self, interaction: discord.Interaction) -> None:
        self.run = await db.fetch_one(
            "SELECT * FROM dungeon_run_state WHERE run_id = %s",
            (self.run["run_id"],),
        )
        self.build()
        await interaction.response.edit_message(embed=await self.card(), view=self)

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


# ---------------------------------------------------------------------------
# The room
# ---------------------------------------------------------------------------


def _haul(raider: dict, won: bool) -> str:
    """One raider's line out of the room.

    The stake and the bonus are named apart. "12,400 stones" after a run
    that cost 14,000 reads as a loss until you know 14,000 of it was your
    own money coming back, and the whole point of the refund is that it is
    legible.
    """
    s = raider["spoils"]
    head = f"**{raider['discord_name']}** \N{BULLET} {s['share']}% of the damage"

    if not won:
        return head + f"\n     {KEY} key returned"

    money = []
    if s.get("stones_back"):
        money.append(f"{thousands(s['stones_back'])} {STONE} stake back")
    if s.get("stones"):
        money.append(f"**+{thousands(s['stones'])}** {STONE}")
    if s.get("jade_back"):
        money.append(f"{s['jade_back']} {JADE} back")
    if s.get("jade"):
        money.append(f"**+{s['jade']}** {JADE}")

    haul = []
    if s.get("herbs"):
        haul.append("\N{HERB} " + ", ".join(s["herbs"]))
    if s.get("pages"):
        n = s["pages"]
        haul.append(f"\N{SCROLL} {n} page" + ("s" if n != 1 else ""))
    if s.get("equipment"):
        haul.append(f"\N{HAMMER AND PICK} {s['equipment']}")
    if s.get("pill"):
        haul.append(f"\N{PILL} {s['pill']}")
    if s.get("egg"):
        haul.append(
            f"\N{HATCHING CHICK} {s['egg']} \N{EM DASH} /eggs"
        )
    if s.get("gu"):
        haul.append(f"\N{BUG} **{s['gu']}**")
    if s.get("jackpot"):
        # The one thing in the game that comes from nowhere else. It gets
        # its own line and its own word.
        haul.append(
            f"\N{GLOWING STAR} **{s['jackpot']}** \N{EM DASH} an Immortal Gu"
        )
    if s.get("essence"):
        haul.append(f"\N{SPARKLES} {s['essence']}")
    if s.get("notes"):
        # THE ONE KEY THIS CARD USED TO DROP ON THE FLOOR. Eleven loot keys
        # come out of `dungeon_spoils_for` and ten of them were rendered;
        # notes were granted silently, so the item the whole Venerable
        # ladder runs on looked like it never dropped. It had been paid
        # twice ever, and the raider it went to reported getting none.
        #
        # MEMO, not SCROLL: pages are SCROLL two lines up, and two
        # identical icons side by side is part of why nobody noticed.
        haul.append(
            f"\N{MEMO} **{s['notes']}** \N{EM DASH} **/notes** to read them"
        )
    if s.get("venerable_gear"):
        # Tier 10. No anvil in the game reaches it - the deepest ore is
        # tier 9 and `smith_tier_cap` is a hard nine - so it is worth
        # saying so rather than letting it look like another drop.
        haul.append(
            f"\N{CROSSED SWORDS} **{s['venerable_gear']}**"
            " \N{EM DASH} *no smith can make this*"
        )
    if s.get("venerable_egg"):
        haul.append(
            f"\N{DRAGON} **{s['venerable_egg']}** \N{EM DASH} out of the"
            " Heavenly Court itself \N{BULLET} /eggs"
        )

    lines = [head]
    # Who walked out, when it was not everybody. The pot and the spoils go
    # entirely to the last one standing, so somebody paid nothing deserves
    # to be told why rather than left to work it out.
    if s.get("took_it_all"):
        lines.append(
            "     \N{CROWN} **walked out alone** \N{EM DASH} took the whole room"
        )
    elif s.get("upright") == 0:
        lines.append(
            "     \N{SKULL} nobody walked out \N{EM DASH} the room keeps its own"
        )
    if s.get("betrayals"):
        n = s["betrayals"]
        lines.append(
            f"     \N{HOCHO} turned on a companion {n} time"
            + ("s" if n != 1 else "")
        )
    if money:
        lines.append("     " + " \N{BULLET} ".join(money))
    for got in haul:
        lines.append("     " + got)
    return "\n".join(lines)


def _raider_line(r: dict) -> str:
    """One raider, and under them the beast standing in front of them.

    The pet gets its own line rather than a tail on the raider's, because
    it has its own health and its own way of going down: `pet_cover_share`
    of every blow meant for the raider lands on the beast first. That makes
    it the thing quietly dying while the raider's own bar barely moves -
    which a room printing no pet health gave nobody a way to see.
    """
    said = (
        ("\N{SKULL}" if r["current_hp"] <= 0 else
         "\N{WHITE HEAVY CHECK MARK}" if r["intent_id"] else
         "\N{HOURGLASS WITH FLOWING SAND}")
        + f" **{r['discord_name']}** "
        + (f"{bar(r['current_hp'], r['max_hp'], width=8)} "
           f"{thousands(r['current_hp'])}"
           if r["current_hp"] > 0 else "*down*")
        + (f" \N{BULLET} {thousands(r['damage_dealt'])} dealt"
           if r["damage_dealt"] else "")
    )
    if r.get("pet_name"):
        said += (
            f"\n\N{PAW PRINTS} {r['pet_name']} "
            + (f"{bar(r['pet_hp'], r['pet_max_hp'], width=8)} "
               f"{thousands(r['pet_hp'])}"
               if (r["pet_hp"] or 0) > 0 else "*down*")
        )
    return said


async def render_room(
    run: dict,
    party: list[dict],
    log: list | None,
    foes: list[dict] | None = None,
) -> discord.Embed:
    done = run["status"] in ("won", "lost")
    card = embed(
        f"{SKULL} {run['dungeon_name']} \N{BULLET} {run['difficulty_name']}",
        f"**Round {run['round_no']}**",
        colour=COLOUR_GOOD if run["status"] == "won"
        else COLOUR_BAD if run["status"] == "lost" else COLOUR_INFO,
    )
    # ONE BAR EACH, once there is more than one thing in here. A room held
    # a single creature until 0540 and `boss_hp` is still kept as the SUM
    # of them, so the one bar below was the whole room drawn under one of
    # their names - a party fighting three Daos could not see which of them
    # was nearly down, which is the only question the room asks them.
    #
    # A single-foe room renders exactly as it did: rooms 1-18 all hold one
    # creature and did not ask for a new screen.
    if foes and len(foes) > 1:
        standing = []
        for f in foes:
            if f["current_hp"] <= 0:
                standing.append(
                    f"{foe_mark(f['foe_no'])} ~~{f['name']}~~ \N{SKULL}"
                )
                continue
            standing.append(
                f"{foe_mark(f['foe_no'])} **{f['name']}**\n"
                f"{bar(f['current_hp'], f['max_hp'], width=14)}  "
                f"{thousands(f['current_hp'])} / {thousands(f['max_hp'])}"
            )
        card.add_field(
            name="The room", value="\n".join(standing), inline=False
        )
    else:
        card.add_field(
            name=f"{run['boss_name']}",
            value=f"{bar(run['boss_hp'], run['boss_max_hp'], width=16)}  "
            f"{thousands(run['boss_hp'])} / {thousands(run['boss_max_hp'])}",
            inline=False,
        )
    card.add_field(
        name="Raiders",
        value="\n".join(_raider_line(r) for r in party),
        inline=False,
    )

    if log:
        told = []
        for entry in log:
            if entry["kind"] == "strike":
                mark = "" if entry["chosen"] else " *(waited)*"
                # 0242 put the strike and crit counts on the round log.
                # Without them a raider whose whole build is extra strikes
                # sees one number and cannot tell it did anything.
                if (entry.get("strikes") or 1) > 1:
                    mark = f" ({entry['strikes']}×)" + mark
                if entry.get("crits"):
                    mark = " \N{COLLISION SYMBOL}" + mark
                # WHICH ONE. The resolver has carried `foe_no` since 0541
                # and the log printed none of it, so in a three-foe room
                # nobody could tell whether the party was concentrating or
                # scattering - and concentrating is the whole teamwork ask.
                at = ""
                if len(foes or []) > 1 and entry.get("foe_no") is not None:
                    at = f" on {foe_mark(entry['foe_no'])}"
                told.append(
                    f"\N{BLACK RIGHTWARDS ARROW} **{entry['who']}** used "
                    f"{entry['move']}{at} \N{EM DASH} "
                    f"{thousands(entry['damage'])}{mark}"
                )
                # The beast at their heel swings in this lane too. The round
                # log has carried the number since 0287 and printed none of it.
                if entry.get("pet_damage"):
                    told.append(
                        f"\N{PAW PRINTS} {entry['pet']} adds "
                        f"{thousands(entry['pet_damage'])}"
                    )
            elif entry["kind"] == "boss":
                # Named by its number too, so "who is hitting me" and "who
                # am I hitting" are the same word.
                hit_by = (
                    foe_mark(entry["foe_no"])
                    if len(foes or []) > 1 and entry.get("foe_no") is not None
                    else "\N{LARGE RED CIRCLE}"
                )
                told.append(
                    f"{hit_by} **{entry['who']}** struck "
                    f"{entry['target']} for {thousands(entry['damage'])}"
                    + (" \N{SKULL} **down**" if entry["downed"] else "")
                )
                if entry.get("pet_covered"):
                    told.append(
                        f"\N{PAW PRINTS} {entry['pet']} took "
                        f"{thousands(entry['pet_covered'])} of it"
                    )
            elif entry["kind"] == "betrayal":
                # EVERYONE SEES IT - the log is the round's public record
                # and this is the line that makes it one. The strike and
                # crit counts come along for the same reason the ordinary
                # strike line carries them: the build is most of the blow.
                turn = ""
                if (entry.get("strikes") or 1) > 1:
                    turn = f" ({entry['strikes']}×)"
                if entry.get("crits"):
                    turn = " \N{COLLISION SYMBOL}" + turn
                told.append(
                    f"\N{HOCHO} **{entry['who']}** turns on "
                    f"**{entry['target']}** with {entry['move']} "
                    f"\N{EM DASH} {thousands(entry['damage'])}{turn}"
                )
            elif entry["kind"] == "suppressed":
                # 0562 made Suppression work outside a hunt and 0563 made
                # the room say so. Without this the blow simply never
                # arrives and a raider cannot tell their own worms from
                # the room having an off round.
                mark = ""
                if len(foes or []) > 1 and entry.get("foe_no") is not None:
                    mark = f" {foe_mark(entry['foe_no'])}"
                told.append(
                    f"\N{SPEAKER WITH CANCELLATION STROKE}{mark} **{entry['who']}** was "
                    f"suppressed by **{entry['target']}** \N{EM DASH} its move "
                    "never came out"
                )
            elif entry["kind"] == "felled":
                # `who` is the FOE here and there is no `text`, which is
                # why this cannot fall through to the branch below.
                told.append(f"\N{SKULL} **{entry['who']}** falls")
            else:
                # `.get`, because this branch used to read entry["text"]
                # outright: neither kind above carries one, so the card
                # raised KeyError the moment a foe went down. A kind added
                # later should cost a line, not the whole screen.
                told.append(
                    f"\N{BLACK RIGHTWARDS ARROW} {entry.get('who', '')} "
                    f"{entry.get('text', '')}".strip()
                )
        card.add_field(name="Last round", value="\n".join(told)[:1024], inline=False)

    if done:
        spoils = [r for r in party if r["spoils"]]
        card.add_field(
            name="Spoils" if run["status"] == "won" else "Wiped",
            value="\n".join(_haul(r, run["status"] == "won") for r in spoils)
            or "*nothing*",
            inline=False,
        )
        card.set_footer(text="**/dungeons** to go again.")
    else:
        card.set_footer(
            text=f"{run['still_choosing']} still choosing \N{BULLET} "
            "the round resolves when everyone has, or after 60 seconds "
            "\N{EM DASH} silence swings your strongest attack."
        )
    return card


class TargetSelect(discord.ui.Select):
    """Who the next blow is for.

    `dungeon_choose` has taken a foe number or a victim since 0541, and the
    three-argument call below left both NULL - so every raider auto-aimed
    at whatever was standing first, and the knife had no button at all.

    Row 2: the moves take rows 0 and 1, ten of them at five a row. The
    Vault holds three foes and up to four companions, so seven options at
    the widest against a limit of twenty-five.

    The choice is held PER PLAYER and answered ephemerally. This message is
    public, so a `default=` here would show the room who you are aiming at
    before you swing, and editing it would redraw somebody else's screen.
    """

    def __init__(
        self, screen: "Room", foes: list[dict], party: list[dict]
    ) -> None:
        self.screen = screen
        options = []

        for f in foes:
            if f["current_hp"] <= 0:
                continue
            options.append(
                discord.SelectOption(
                    # The mark goes in the LABEL, not `emoji`: a circled
                    # digit is not one of Discord's emoji and the option
                    # would come back rejected.
                    label=f"{foe_mark(f['foe_no'])} {f['name']}"[:100],
                    value=f"foe:{f['foe_no']}",
                    description=f"{thousands(f['current_hp'])} left"[:100],
                )
            )

        # THE KNIFE, on the same control - choosing a companion IS choosing
        # a target, which is exactly what the mechanic is. The option says
        # what it costs, because nobody should turn on a friend by
        # misreading a menu.
        for r in party:
            if r["player_id"] == screen.player_id or r["current_hp"] <= 0:
                continue
            options.append(
                discord.SelectOption(
                    label=f"Turn on {r['discord_name']}"[:100],
                    value=f"ally:{r['player_id']}",
                    emoji="\N{HOCHO}",
                    description="the room sees it, and still swings at you",
                )
            )

        super().__init__(
            placeholder="Who are you aiming at?",
            options=options[:25],
            row=2,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        me = await require_player(interaction.user)
        aim = self.values[0]
        self.screen.aims[me["player_id"]] = aim

        said = next((o.label for o in self.options if o.value == aim), "them")
        # Nothing reaches the database yet: a target is not a turn. The move
        # button is what speaks, and this only says it was heard.
        await interaction.response.send_message(
            f"\N{HOCHO} **{said}** \N{EM DASH} pick your move, and the "
            "room will find out."
            if aim.startswith("ally:")
            else f"\N{DIRECT HIT} Aiming at **{said}**.",
            ephemeral=True,
        )


class MoveButton(discord.ui.Button):
    def __init__(self, screen: "Room", move: dict, index: int) -> None:
        self.screen = screen
        self.move = move
        super().__init__(
            label=f"{index}. {move['name']}"[:80],
            row=(index - 1) // 5,
            # Attacks lead in blue; anything that mends, guards or hinders is
            # grey, so a raider can tell at a glance which button spends the
            # round hitting and which one does not.
            style=discord.ButtonStyle.primary
            if move.get("category", "attack") == "attack"
            else discord.ButtonStyle.secondary,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        me = await require_player(interaction.user)
        try:
            # Whatever they picked on the menu, or neither - and neither
            # still means "the first thing standing", which is what the
            # room did for everybody before there was a menu.
            aim = self.screen.aims.get(me["player_id"]) or ""
            foe_no = int(aim[4:]) if aim.startswith("foe:") else None
            victim = int(aim[5:]) if aim.startswith("ally:") else None
            left = await db.fetch_value(
                "SELECT dungeon_choose(%s, %s, %s, %s::smallint, %s)",
                (self.screen.run["run_id"], me["player_id"],
                 self.move["technique_id"], foe_no, victim),
            )
        except psycopg.errors.CheckViolation as exc:
            raise refuse(exc) from exc

        # The round resolves the moment the last raider speaks. Nothing ticks
        # in this game, so this is the tick.
        log = None
        if left == 0:
            done = await db.fetch_one(
                "SELECT * FROM dungeon_resolve_round(%s)",
                (self.screen.run["run_id"],),
            )
            log = done["log"]

        await self.screen.redraw(interaction, log)


class Room(AnsweringView):
    def __init__(
        self, player_id, user, run, moves, log=None, foes=None, party=None
    ) -> None:
        super().__init__(timeout=900)
        self.player_id = player_id
        self.user = user
        self.run = run
        self.moves = moves
        self.log = log
        self.foes = foes or []
        self.party = party or []
        # Keyed by player, because this message is public and the button
        # already acts as whoever pressed it rather than whoever opened the
        # screen. One shared `aim` would let a raider aim for somebody else
        # - and with a knife on the menu that is not a small bug.
        self.aims: dict[int, str] = {}
        self.build()

    @classmethod
    async def build_for(cls, player_id, user, run, log=None):
        moves = await db.fetch_all(
            """
            SELECT t.technique_id, t.name, t.rank, t.category,
                   -- Live, not filed. See 0395.
                   technique_power_for(u.player_id, t.technique_id)
                       AS base_power
            FROM player_usable_techniques u
            JOIN techniques t ON t.technique_id = u.technique_id
            LEFT JOIN player_loadout l
                ON l.player_id = u.player_id AND l.technique_id = u.technique_id
            -- Everything they can throw. This used to end `AND t.category =
            -- 'attack'`, which is right for `dungeon_default_move` - the move
            -- a SILENT raider makes should never be a heal - and wrong here,
            -- where the raider is the one choosing. It hid every support,
            -- defence and utility technique from the room, so a cultivator
            -- whose only learned move mends the party could find it on every
            -- screen except the one place a party stands together.
            -- `player_swing` calls `technique_cast_effects` in a dungeon
            -- exactly as it does in a duel, so the effect always would have
            -- landed. Only the button to ask for it was missing.
            WHERE u.player_id = %s
            -- Loadout first, then attacks, the way `usable_techniques` orders
            -- them, so the move the room would swing for you on silence is
            -- still the one at the front.
            ORDER BY l.slot_index NULLS LAST,
                     (t.category = 'attack') DESC,
                     technique_power_for(u.player_id, t.technique_id) DESC
            LIMIT 10
            """,
            (player_id,),
        )
        return cls(
            player_id, user, run, moves, log,
            await foes_of(run["run_id"]), await party_of(run["run_id"]),
        )

    def build(self) -> None:
        self.clear_items()
        if self.run["status"] != "fighting":
            return
        for index, move in enumerate(self.moves, start=1):
            self.add_item(MoveButton(self, move, index))
        # Only when there is something to decide. A room holding one thing
        # with nobody else in it has one target and does not need a menu.
        if self._worth_asking():
            menu = TargetSelect(self, self.foes, self.party)
            # Discord refuses a Select with no options, so an empty one is
            # not a disabled menu - it is a room that fails to draw.
            if menu.options:
                self.add_item(menu)

    def _worth_asking(self) -> bool:
        if len([f for f in self.foes if f["current_hp"] > 0]) > 1:
            return True
        return any(
            r["player_id"] != self.player_id and r["current_hp"] > 0
            for r in self.party
        )

    async def card(self) -> discord.Embed:
        return await render_room(
            self.run, await party_of(self.run["run_id"]), self.log, self.foes
        )

    async def redraw(self, interaction: discord.Interaction, log=None) -> None:
        self.run = await db.fetch_one(
            "SELECT * FROM dungeon_run_state WHERE run_id = %s",
            (self.run["run_id"],),
        )
        if log is not None:
            self.log = log
        # Re-read both, because a round just went by. A menu offering a
        # corpse is a menu whose choice `dungeon_choose` refuses - and it
        # would refuse it sixty seconds later, with no time left to pick
        # again.
        self.foes = await foes_of(self.run["run_id"])
        self.party = await party_of(self.run["run_id"])
        self.aims = {
            who: aim for who, aim in self.aims.items()
            if self._still_standing(aim)
        }
        self.build()
        await interaction.response.edit_message(embed=await self.card(), view=self)

    def _still_standing(self, aim: str) -> bool:
        if aim.startswith("foe:"):
            return any(
                f["foe_no"] == int(aim[4:]) and f["current_hp"] > 0
                for f in self.foes
            )
        return any(
            r["player_id"] == int(aim[5:]) and r["current_hp"] > 0
            for r in self.party
        )

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


# ---------------------------------------------------------------------------


# A round is sixty seconds and the forming window is ten minutes, so twenty
# seconds is fine enough for both and cheap enough to run forever: the query
# behind `sweep` returns nothing at all when nothing is due.
SWEEP_SECONDS = 20

log = logging.getLogger("gu.dungeon")


class Dungeon(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot
        self.keep_time.start()

    async def cog_unload(self) -> None:
        self.keep_time.cancel()

    @tasks.loop(seconds=SWEEP_SECONDS)
    async def keep_time(self) -> None:
        """The clock, running whether or not anybody is looking at it.

        `sweep` was called only from the two screens, so a run whose round had
        ended - or a party that never went in - waited for somebody to type
        /dungeon before anything happened to it. One sat forty minutes past a
        ten minute limit holding its whole party out.
        """
        try:
            await sweep()
        except Exception:
            log.warning("the dungeon sweep failed", exc_info=True)

    @keep_time.before_loop
    async def before_keep_time(self) -> None:
        # Under the test harness `bot` is a stand-in with no gateway, so
        # this raises and discord.py reports it as an unretrieved task
        # exception - three of them, every test, drowning the output that
        # says which assertion actually failed. A loop that cannot wait
        # for a client it does not have simply does not run.
        try:
            await self.bot.wait_until_ready()
        except RuntimeError:
            self.keep_time.cancel()
            return

    @app_commands.command(
        description="Every door on the ladder, and what waits behind them."
    )
    async def dungeons(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        await sweep()

        running = await my_run(player["player_id"])
        if running:
            raise GameError(
                f"You are already in **{running['dungeon_name']}**. "
                "**/dungeon** is the room you are standing in."
            )

        doors = await fetch_doors(player["player_id"])
        steps = await db.fetch_all(
            "SELECT * FROM dungeon_difficulties ORDER BY sort_order"
        )
        view = Catalogue(player["player_id"], interaction.user, doors, steps)
        await interaction.response.send_message(embed=await view.card(), view=view)

    @app_commands.command(
        description="The dungeon you are in, or one you were invited to."
    )
    async def dungeon(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await sweep()

        run = await my_run(player["player_id"])

        if run is None:
            # Not in one - but somebody may be holding a door open for them.
            asked = await db.fetch_one(
                """
                SELECT s.* FROM dungeon_invites i
                JOIN dungeon_run_state s ON s.run_id = i.run_id
                WHERE i.player_id = %s AND s.status = 'forming'
                ORDER BY i.invited_at DESC LIMIT 1
                """,
                (player["player_id"],),
            )
            if asked is None:
                raise GameError(
                    "You are not in a dungeon and nobody has invited you to "
                    "one. **/dungeons** opens a door."
                )
            try:
                await db.fetch_value(
                    "SELECT dungeon_join(%s, %s)",
                    (asked["run_id"], player["player_id"]),
                )
            except psycopg.errors.CheckViolation as exc:
                raise refuse(exc) from exc
            run = await db.fetch_one(
                "SELECT * FROM dungeon_run_state WHERE run_id = %s",
                (asked["run_id"],),
            )

        if run["status"] == "forming":
            view = Lobby(player["player_id"], interaction.user, run)
        else:
            view = await Room.build_for(player["player_id"], interaction.user, run)

        await interaction.response.send_message(embed=await view.card(), view=view)


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Dungeon(bot))
