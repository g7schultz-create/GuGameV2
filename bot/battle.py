"""The battle screen: one round at a time.

A fight is a row in `battles` with status 'active', not a Python object. The
view here is a window onto that row - it can time out, the bot can restart,
Discord can lose the message, and the fight is still there for **/battle** to
pick up. Nothing about a battle lives in this process.

Every action goes through `battle_act`, which resolves the player's half, the
creature's answer and the next telegraph in one transaction. The view never
computes damage, decides an outcome, or writes HP.
"""

import discord
import psycopg

from bot import database as db
from bot.character import RARITY_MARK
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_DEFAULT,
    COLOUR_GOOD,
    bar,
    embed,
    thousands,
)
from bot.views import AnsweringView
from bot.players import GameError

# The creature's turn is telegraphed before you choose, so guarding is a read
# rather than a coin flip. Everything below exists to show that clearly.
BAR_WIDTH = 18


async def fetch_state(battle_id: int) -> dict | None:
    """Everything the card needs, plus the two things the view decides on.

    `kind` says whether the loser drops a manual or manual pages; `emoji` is
    the region marker. Both are joined here rather than added to
    battle_overview, which is about the fight itself.

    The beast at heel is joined for the same reason: it has a body of its own
    since 0285 and the card draws a bar for it, but it belongs to the
    cultivator rather than to this fight. LEFT, because most people walk
    nothing.
    """
    return await db.fetch_one(
        """
        SELECT o.*, s.kind, s.code AS creature_code,
               b.name AS pet_name, b.hp AS pet_hp, b.max_hp AS pet_max_hp
        FROM battle_overview o
        -- LEFT, because the far side of a duel is a person and has no
        -- species. 0533 loosened the same join inside the view and this
        -- one sat on top of it, so a duel still came back as no row at
        -- all - the fight existing in `battles` and being impossible to
        -- look at.
        LEFT JOIN creature_species s ON s.species_id = o.species_id
        LEFT JOIN player_beast_shelf b
               ON b.owner_id = o.player_id AND b.at_heel
        WHERE o.battle_id = %s
        """,
        (battle_id,),
    )


async def active_battle(player_id: int) -> int | None:
    return await db.fetch_value(
        "SELECT battle_id FROM player_active_battle WHERE player_id = %s",
        (player_id,),
    )


async def usable_techniques(player_id: int, max_qi: int) -> list[dict]:
    """What this player can throw, and what each costs.

    Ordered by loadout slot then power, the same order `pick_technique` uses,
    so the move the game would have picked for you is the first one listed.
    """
    return await db.fetch_all(
        """
        SELECT t.technique_id, t.name, t.code, t.qi_cost_pct,
               u.source, t.category,
               -- What it does, for the ones that do not simply hit: the same
               -- sentence `/techniques` prints.
               technique_effect_summary(t.technique_id) AS effect_text,
               -- What it is worth to THIS cultivator today, not the
               -- figure it was filed under. A forged or fated technique
               -- stores a grade and is recomputed every swing, so the
               -- written number has been wrong by up to 128x.
               technique_power_for(u.player_id, t.technique_id) AS base_power,
               ceil(t.qi_cost_pct * %s)::bigint AS qi_cost,
               string_agg(p.name, ' / ' ORDER BY tp.weight DESC) AS paths,
               string_agg(p.emoji, '' ORDER BY tp.weight DESC) AS emoji
        FROM player_usable_techniques u
        JOIN techniques t ON t.technique_id = u.technique_id
        LEFT JOIN player_loadout l
            ON l.player_id = u.player_id AND l.technique_id = u.technique_id
        LEFT JOIN technique_paths tp ON tp.technique_id = t.technique_id
        LEFT JOIN paths p ON p.code = tp.path_code
        -- Everything they can throw, not just the things that hurt. Filtering
        -- on `base_power > 0` hid every defence, support and utility
        -- technique in the game - 37 of them, including all nine healing
        -- moves - so a cultivator could learn The Table That Seats the Line
        -- and never once find it in a fight. `battle_act` has always handled
        -- them: a technique with no power of its own deals what the arm
        -- behind it deals and then applies what it was written for.
        WHERE u.player_id = %s
        GROUP BY t.technique_id, u.player_id, u.source, l.slot_index
        -- Attacks first, because that is what most rounds are for, then by
        -- what each is worth.
        ORDER BY l.slot_index NULLS LAST,
                 (t.category = 'attack') DESC,
                 technique_power_for(u.player_id, t.technique_id) DESC
        LIMIT 25
        """,
        (max_qi, player_id),
    )


def health_block(name: str, icon: str, hp: int, max_hp: int) -> str:
    pct = round(100 * hp / max_hp) if max_hp else 0
    return (
        f"{icon} **{name}**\n"
        f"\N{HEAVY BLACK HEART} HP `{thousands(hp)} / {thousands(max_hp)}` \N{BULLET} {pct}%\n"
        f"{bar(hp, max_hp, width=BAR_WIDTH)}"
    )


def render_battle(
    state: dict, display_name: str, round_log: list[str] | None = None
) -> discord.Embed:
    """The fight as it stands, with the last round underneath it."""
    living = state["status"] == "active"
    colour = COLOUR_DEFAULT
    if not living:
        colour = COLOUR_GOOD if state["winner_side"] == 0 else COLOUR_BAD

    title = f"\N{CROSSED SWORDS} {state['creature_name']}"
    if living:
        title += " \N{BULLET} Fighting"

    card = embed(
        title,
        f"\N{CROSSED SWORDS} Round **{state['turn_number']}** \N{BULLET} "
        f"{'Rogue cultivator' if state['kind'] == 'rogue' else 'Beast'}",
        colour=colour,
    )

    them = health_block(
        state["creature_name"],
        "\N{BOAR}" if state["kind"] != "rogue" else "\N{BUST IN SILHOUETTE}",
        state["creature_hp"],
        state["creature_max_hp"],
    )
    them += (
        f"\n\N{SNOW CAPPED MOUNTAIN} Realm **{state['creature_realm']}** \N{BULLET} "
        f"Rank {state['creature_rank']}"
    )
    if living and state["intent_name"]:
        them += (
            f"\n\N{DIRECT HIT} Next: **{state['intent_name']}** — "
            f"*{state['intent_text']}*"
        )
    card.add_field(name="​", value=them, inline=False)

    mine = health_block(
        display_name, "\N{STANDING PERSON}", state["player_hp"], state["player_max_hp"]
    )
    qi_pct = (
        round(100 * state["player_qi"] / state["player_max_qi"])
        if state["player_max_qi"]
        else 0
    )
    mine += (
        f"\n\N{DROPLET} Qi `{thousands(state['player_qi'])} / "
        f"{thousands(state['player_max_qi'])}` \N{BULLET} {qi_pct}%\n"
        f"{bar(state['player_qi'], state['player_max_qi'], width=BAR_WIDTH)}"
    )
    card.add_field(name="​", value=mine, inline=False)

    # The beast standing with you. It has had a body of its own since 0285,
    # and a body nobody can see is the same as no body at all - which is
    # exactly how this got reported.
    if state.get("pet_max_hp"):
        beast = health_block(
            state.get("pet_name") or "Your beast",
            "\N{PAW PRINTS}",
            state.get("pet_hp") or 0,
            state["pet_max_hp"],
        )
        if not (state.get("pet_hp") or 0):
            beast += (
                "\n\N{SKULL} **Down** \N{EM DASH} it neither swings nor "
                "covers until you **/rest**."
            )
        card.add_field(name="​", value=beast, inline=False)

    if round_log:
        card.add_field(name="Last round", value="\n".join(round_log), inline=False)

    if living:
        card.set_footer(
            text="Guard halves the telegraphed blow and returns qi. Observe reads "
            "one weakness and costs you the round."
        )
    return card


def round_log(result: dict, state: dict, display_name: str) -> list[str]:
    """What just happened, in the order it happened."""
    lines = []

    # SUPPRESSION, at last. `battle_act` has recorded this on every turn
    # since the effect existed and nothing has ever printed it, so a
    # cultivator who had spent aperture on it watched creatures skip turns
    # with no idea they were the cause.
    if result.get("suppressed"):
        lines.append(
            f"\N{SPEAKER WITH CANCELLATION STROKE} You suppress it \N{EM DASH} its move never comes out."
        )

    if result["move_name"] == "Guard":
        lines.append(f"\N{SHIELD} You brace.")
    elif result["move_name"] == "Observe":
        lines.append(f"\N{LEFT-POINTING MAGNIFYING GLASS} You watch instead of swinging.")
    elif result["move_name"] == "Flee":
        lines.append(f"\N{RUNNER} You break for it.")
    else:
        spent = (
            f" (−{thousands(result['qi_spent'])} qi)" if result["qi_spent"] else ""
        )
        # How many times it landed, and how many of those bit. `battle_act`
        # has returned both since 0225 and this log rendered neither, so a
        # build assembled around Extra Strikes read exactly like one without
        # - which is how a working effect gets reported as broken.
        blows = []
        if (result.get("strikes") or 1) > 1:
            blows.append(f"{result['strikes']} strikes")
        if result.get("crits"):
            blows.append(
                f"{result['crits']} critical"
                + ("s" if result["crits"] > 1 else "")
            )
        lines.append(
            f"\N{CROSSED SWORDS} **{result['move_name']}**{spent} — "
            f"**{thousands(result['dealt'])}** damage"
            + (" • " + " • ".join(blows) if blows else "")
            + "."
        )

    if result.get("pet_dealt"):
        lines.append(
            f"\N{PAW PRINTS} **{result['pet_name']}** adds "
            f"**{thousands(result['pet_dealt'])}**."
        )

    if result["note"]:
        lines.append(f"*{result['note']}*")

    if result["revealed_path"]:
        lines.append(
            f"\N{OPEN BOOK} It takes **{result['revealed_path']}** as "
            f"**{result['revealed_effect']}**."
        )

    if result["enemy_move"]:
        lines.append(
            f"\N{COLLISION SYMBOL} **{result['enemy_move']}** — "
            f"**{thousands(result['taken'])}** to you."
        )

    if result.get("pet_covered"):
        lines.append(
            f"\N{PAW PRINTS} **{result['pet_name']}** takes "
            f"**{thousands(result['pet_covered'])}** of it."
        )
    if result.get("pet_down"):
        lines.append(f"\N{SKULL} **{result['pet_name']}** goes down.")

    return lines


def ending_card(
    result: dict, state: dict, display_name: str, extra: list[str]
) -> discord.Embed:
    """The last screen of a fight, which is a different thing from a round."""
    verdicts = {
        "won": "\N{SKULL} "
        + ("You killed the " if state["kind"] != "rogue" else "You put down the ")
        + state["creature_name"],
        "lost": "\N{DROP OF BLOOD} You were beaten by the " + state["creature_name"],
        "fled": "\N{DASH SYMBOL} You got away from the " + state["creature_name"],
        "drawn": "\N{HOURGLASS} Neither of you could finish it",
    }
    colour = COLOUR_GOOD if result["outcome"] in ("won", "fled") else COLOUR_BAD

    card = embed(
        verdicts.get(result["outcome"], "The fight ends"),
        f"{state['turn_number']} rounds.",
        colour=colour,
    )
    card.add_field(
        name="\N{CROSSED SWORDS} Last round",
        value="\n".join(round_log(result, state, display_name)),
        inline=False,
    )
    card.add_field(
        name="\N{HEAVY BLACK HEART} You",
        value=(
            f"{bar(result['player_hp'], state['player_max_hp'], width=BAR_WIDTH)} "
            f"{thousands(result['player_hp'])} / {thousands(state['player_max_hp'])} HP"
        ),
        inline=False,
    )

    # A fang and a dragon scale used to arrive looking identical. The dot is
    # how rare it was, the face is what it is - the same pair /explore shows.
    drops = result["drops"] or []
    if drops:
        card.add_field(
            name="\N{SCHOOL SATCHEL} Taken from the body",
            value="\n".join(
                f"{RARITY_MARK.get(d['rarity'], '')} {d['emoji']} **{d['name']}** "
                f"\N{MULTIPLICATION SIGN}{d['quantity']}"
                for d in drops
            ),
            inline=False,
        )
    elif result["outcome"] == "won":
        card.add_field(
            name="\N{SCHOOL SATCHEL} Taken from the body",
            value="Nothing usable.",
            inline=False,
        )

    for line in extra:
        card.add_field(name="​", value=line, inline=False)

    if result["outcome"] == "lost":
        card.set_footer(text="Losing costs the HP and nothing else. It comes back on its own.")
    return card


async def spoils(result: dict, state: dict, player_id: int, region: str) -> list[str]:
    """What a corpse yields beyond materials.

    A beast may have been carrying a manual; only a rogue cultivator carries
    pages, because a page is written by a person.
    """
    if result["outcome"] != "won":
        return []

    found = []

    # A whole Gu is rare on purpose: the roster document is explicit that
    # materials are the common drop, because materials are what Gu refinement
    # will consume. This is the drip until that exists.
    gu_id = await db.fetch_value(
        "SELECT roll_gu_drop(%s, %s, %s)",
        (player_id, region, state["creature_rank"]),
    )
    if gu_id:
        gu = await db.fetch_one(
            """
            SELECT t.name, t.emoji, t.size, t.rank, p.name AS path_name
            FROM player_gu g
            JOIN gu_types t ON t.gu_type_id = g.gu_type_id
            JOIN paths p ON p.code = t.path_code
            WHERE g.gu_id = %s
            """,
            (gu_id,),
        )
        # Same shape as `gu_label` in SQL: the name, then the rank that says
        # whether to be pleased about it. A name alone reads identically at
        # rank 1 and rank 9.
        found.append(
            f"{gu['emoji']} **{gu['name']} \N{MIDDLE DOT} rank {gu['rank']}** — a "
            f"{gu['path_name']} Gu, size {gu['size']}. **/gu** to take it into "
            "your aperture."
        )

    if state["kind"] == "rogue":
        pages = await db.fetch_all(
            "SELECT rogue_pages(%s, %s, %s) AS page_id",
            (player_id, state["species_id"], region),
        )
        if pages:
            found.append(
                f"\N{PAGE FACING UP} **{len(pages)} manual page(s)**, torn loose. "
                "**/pages** to read them, **/refine** to make something of them."
            )
        return found

    manual_id = await db.fetch_value(
        "SELECT roll_manual_drop(%s, %s)", (player_id, state["species_id"])
    )
    if manual_id:
        book = await db.fetch_one(
            "SELECT name, tier FROM manuals WHERE manual_id = %s", (manual_id,)
        )
        found.append(
            f"\N{GRADUATION CAP} **{book['name']}** — Tier {book['tier']}. "
            "**/equipment** to carry it."
        )
    return found


class TechniqueSelect(discord.ui.Select):
    """Everything you can throw, which is to say what your manuals unlock.

    Unaffordable moves are listed and refused rather than hidden: a player
    needs to see that the good one is two guards away, not wonder where it
    went.
    """

    def __init__(self, view: "BattleView") -> None:
        self.battle = view
        options = []
        for row in view.techniques:
            cost = row["qi_cost"]
            afford = cost <= view.state["player_qi"]
            options.append(
                discord.SelectOption(
                    label=f"{row['name']} · {thousands(cost)} qi"[:100],
                    value=str(row["technique_id"]),
                    description=(
                        f"{row['paths'] or 'untyped'} · "
                        # A support move's power is zero and saying so tells
                        # nobody anything. What it DOES is the whole reason to
                        # spend a round on it.
                        + (
                            f"power {thousands(row['base_power'])}"
                            if row["category"] == "attack" or not row["effect_text"]
                            else row["effect_text"]
                        )
                        + ("" if afford else " · not enough qi")
                    )[:100],
                    emoji=row["emoji"][:1] if row["emoji"] else None,
                )
            )
        super().__init__(placeholder="Attack with…", options=options, row=0)

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.battle.act(interaction, "attack", int(self.values[0]))


class ActionButton(discord.ui.Button):
    def __init__(self, view: "BattleView", action: str, label: str, emoji: str, style) -> None:
        self.battle = view
        self.action = action
        super().__init__(label=label, emoji=emoji, style=style, row=1)

    async def callback(self, interaction: discord.Interaction) -> None:
        await self.battle.act(interaction, self.action)


class BattleView(AnsweringView):
    def __init__(
        self,
        player_id: int,
        user: discord.abc.User,
        state: dict,
        techniques: list[dict],
        region: str,
    ) -> None:
        super().__init__(timeout=600)
        self.player_id = player_id
        self.user = user
        self.state = state
        self.techniques = techniques
        self.region = region
        self.message: discord.Message | None = None
        self.build()

    def build(self) -> None:
        self.clear_items()
        if self.techniques:
            self.add_item(TechniqueSelect(self))
        self.add_item(
            ActionButton(self, "observe", "Observe", "\N{LEFT-POINTING MAGNIFYING GLASS}",
                         discord.ButtonStyle.success)
        )
        self.add_item(
            ActionButton(self, "guard", "Guard", "\N{SHIELD}", discord.ButtonStyle.secondary)
        )
        self.add_item(
            ActionButton(self, "flee", "Flee", "\N{RUNNER}", discord.ButtonStyle.danger)
        )
        # Killer moves are the next thing this screen grows, and a slot that
        # says so beats one that appears from nowhere later - the same call the
        # equipment page makes about its empty gear slots.
        later = discord.ui.Button(
            label="Killer Move", emoji="\N{SPARKLES}",
            style=discord.ButtonStyle.secondary, disabled=True, row=1,
        )
        self.add_item(later)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "That is not your fight.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        # The battle outlives the view on purpose. Nothing is resolved here.
        for item in self.children:
            item.disabled = True
        if self.message is not None:
            try:
                await self.message.edit(view=self)
            except discord.HTTPException:
                pass

    async def act(
        self, interaction: discord.Interaction, action: str, technique_id: int | None = None
    ) -> None:
        try:
            result = await db.fetch_one(
                "SELECT * FROM battle_act(%s, %s, %s)",
                (self.state["battle_id"], action, technique_id),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        after = await fetch_state(self.state["battle_id"])

        if result["finished"]:
            extra = await spoils(result, after, self.player_id, self.region)
            for item in self.children:
                item.disabled = True
            await interaction.response.edit_message(
                embed=ending_card(result, after, self.user.display_name, extra),
                view=self,
            )
            self.stop()
            return

        self.state = after
        self.techniques = await usable_techniques(self.player_id, after["player_max_qi"])
        self.build()
        await interaction.response.edit_message(
            embed=render_battle(
                after,
                self.user.display_name,
                round_log(result, after, self.user.display_name),
            ),
            view=self,
        )


async def open_battle(
    player_id: int, user: discord.abc.User, species_id: int, region: str
) -> tuple[discord.Embed, BattleView]:
    """Start a fight and hand back the screen for it."""
    try:
        battle_id = await db.fetch_value(
            "SELECT battle_open(%s, %s)", (player_id, species_id)
        )
    except psycopg.errors.CheckViolation as exc:
        # MATCH THE REFUSALS, DO NOT ASSUME THEM. `battle_open` raises exactly
        # two of its own, and SQLSTATE 23514 is `check_violation` for a CHECK
        # CONSTRAINT as well - so this used to report any constraint failure
        # inside the function as a sentence about the player's health.
        #
        # It hid a real bug for as long as it was confident: `battle_open`
        # called the volatile `creature_body_for` twice, so two fights in five
        # broke `battle_combatants_hp_within_cap` and players at full health
        # were told they had nothing left to fight with. 0554 fixed the cause;
        # this makes the next one of these legible instead of plausible.
        said = str(exc).splitlines()[0]
        if "already in a battle" in said:
            raise GameError(
                "You are already in a fight. **/battle** to get back to it."
            ) from exc
        if "no strength left to fight" in said:
            raise GameError(
                "You have nothing left to fight with. HP returns on its own."
            ) from exc
        # Anything else is a fault, not a refusal. Re-raised so it reaches the
        # log with its traceback rather than being dressed up as a game rule -
        # `answer_error` only swallows `GameError`, which this deliberately
        # is not.
        raise

    state = await fetch_state(battle_id)
    techniques = await usable_techniques(player_id, state["player_max_qi"])
    view = BattleView(player_id, user, state, techniques, region)
    return render_battle(state, user.display_name), view


async def open_tribulation(
    player_id: int, user: discord.abc.User, region: str
) -> tuple[discord.Embed, BattleView]:
    """Walk into the sky, and hand back the same screen every fight uses.

    `tribulation_face` opens an ordinary row in `battles` - it is the whole
    reason the feature needed no new combat code - so from here it is a fight
    like any other, playable with /battle if this message scrolls away.

    The refusals are its own, and every one of them is a sentence about what to
    do next rather than about what went wrong.
    """
    try:
        battle_id = await db.fetch_value(
            "SELECT tribulation_face(%s)", (player_id,)
        )
    except psycopg.errors.CheckViolation as exc:
        raise GameError(str(exc).splitlines()[0].capitalize() + ".") from exc

    state = await fetch_state(battle_id)
    techniques = await usable_techniques(player_id, state["player_max_qi"])
    view = BattleView(player_id, user, state, techniques, region)
    return render_battle(state, user.display_name), view
