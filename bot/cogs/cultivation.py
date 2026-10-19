"""Cultivation: /cultivation and /focus.

Cultivation is idle. It accrues from elapsed time and is settled whenever the
player looks at it, so there is no scheduler to fall behind, no job to miss a
tick, and a bot that was down for a day still owes exactly what that day was
worth. `player_cultivation.last_tick_at` is the only state this needs.

The one decision a cultivator makes here is where to aim. A focus Path trades
a little raw cultivation for insight into that Path - the same bargain the
design's sections 10 and 11 describe, and it uses the same configured rate.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import database as db
from bot.character import cultivation_bar
from bot.formatting import (
    COLOUR_BAD,
    COLOUR_GOOD,
    COLOUR_INFO,
    bar,
    embed,
    error_embed,
    humanise_duration,
    multiplier,
    percent,
    thousands,
)
from bot.pathpicker import BUTTON_ROWS, PathPicker, fetch_paths
from bot.views import AnsweringView
from bot.players import GameError, require_player, settle_passive

def gate_line(row: dict) -> str:
    """One requirement of a crossing, as a player reads it.

    Everything the door asks for is a count except the tribulation, which is a
    yes or a no - printing that one as "0 / 1" is a number that means nothing
    and hides the only thing worth saying, which is where to go and do it.
    """
    mark = (
        "\N{WHITE HEAVY CHECK MARK}" if row["met"] else "\N{WHITE MEDIUM SQUARE}"
    )
    if row["need"] == "Heavenly Tribulation":
        return (
            f"{mark} **{row['detail'] or 'Heavenly Tribulation'}** "
            + ("survived" if row["met"] else "still stands there \N{EM DASH} **/tribulation**")
        )
    return (
        f"{mark} **{row['need']}** {thousands(row['have'])} / "
        f"{thousands(row['want'])}"
        + (f"  *{row['detail']}*" if row["detail"] else "")
    )


class TribulationView(AnsweringView):
    """One button, and it is not pressed by accident.

    The fight it opens cannot be backed out of - fleeing is failing - so the
    screen says so and then asks once.
    """

    def __init__(self, player_id: int, user: discord.abc.User) -> None:
        super().__init__(timeout=120)
        self.player_id = player_id
        self.user = user

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Not your sky.", ephemeral=True
            )
            return False
        return True

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True

    @discord.ui.button(label="Face it", style=discord.ButtonStyle.danger)
    async def face(self, interaction: discord.Interaction, button) -> None:
        from bot.battle import open_tribulation

        region = await db.fetch_value(
            "SELECT region_code FROM player_location WHERE player_id = %s",
            (self.player_id,),
        )
        card, fight = await open_tribulation(self.player_id, self.user, region)

        for item in self.children:
            item.disabled = True
        await interaction.response.edit_message(view=self)
        await interaction.followup.send(embed=card, view=fight)
        fight.message = await interaction.original_response()
        self.stop()


# The three pillars, named as a player would say them. Keys are the values
# `weakest_foundation()` returns, so a fourth pillar would surface here as a
# missing key rather than as a blank line.
FOUNDATION = {
    "hp": "maximum HP",
    "defense": "defence",
    "strength": "strength",
}


def waiting_behind(state: dict, which: str) -> str:
    """The weaker boost hours queued under the one in force.

    Named rather than blended. They are real hours the player paid for and
    will get, just not at the rate showing - and saying "1,131 hours" beside a
    rate that only covers 153 of them would be the same lie the average told.
    """
    total = float(state[f"{which}_boost_hours"] or 0)
    now = float(state[f"{which}_boost_top_hours"] or 0)
    behind = total - now
    if behind < 1:
        return ""
    return (
        f"\n\N{IDEOGRAPHIC SPACE}*{behind:,.0f} weaker hours queued behind it "
        f"across {int(state[f'{which}_boost_stacks']) - 1} more dose(s).*"
    )


async def claim(player_id: int, action: str, config_key: str) -> None:
    """Take a cooldown or explain when it is free.

    The same helper `world.py` uses, written out rather than imported: this
    module has no other reason to depend on the world, and one shared six-line
    function is not worth the coupling.
    """
    row = await db.fetch_one(
        "SELECT * FROM claim_cooldown(%s, %s, game_config_value(%s))",
        (player_id, action, config_key),
    )
    if not row["claimed"]:
        raise GameError(
            f"Not yet — you can {action} again "
            f"{discord.utils.format_dt(row['ready_at'], style='R')}."
        )


class MeditateButton(discord.ui.Button):
    """One of the two axes. The cooldown is claimed HERE rather than when the
    screen opens, so a player who changes their mind and closes it has not
    spent the hour on a menu."""

    def __init__(self, screen: "MeditateView", axis: str, label: str, emoji: str) -> None:
        self.screen = screen
        self.axis = axis
        super().__init__(label=label, emoji=emoji, style=discord.ButtonStyle.primary)

    async def callback(self, interaction: discord.Interaction) -> None:
        screen = self.screen
        await claim(screen.player_id, "meditate", "meditate_cooldown_minutes")

        try:
            got = await db.fetch_one(
                "SELECT * FROM meditate(%s, %s)", (screen.player_id, self.axis)
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        if self.axis == "cultivation":
            card = embed(
                f"\N{LOTUS} +{thousands(got['gained'])} cultivation",
                "You sit with it until the hour is gone.",
                colour=COLOUR_GOOD if got["gained"] else COLOUR_BAD,
            )
            if got["at_the_door"]:
                card.add_field(
                    name="At the door",
                    value="Cultivation stops at the next realm's threshold. "
                    "**/breakthrough** is what takes it.",
                    inline=False,
                )
            if got["offered"] > got["gained"]:
                card.set_footer(
                    text=f"The hour was worth {thousands(got['offered'])} — the "
                    "door took what it could hold."
                )
        else:
            card = embed(
                f"{screen.where['emoji']} +{thousands(got['gained'])} insight",
                f"An hour inside the **{screen.where['path_name']}**.",
                colour=COLOUR_GOOD,
            )
            if got["tier_after"] > got["tier_before"]:
                tier = await db.fetch_value(
                    "SELECT name FROM attainment_tiers WHERE tier = %s",
                    (got["tier_after"],),
                )
                card.add_field(
                    name="A step up",
                    value=f"You are **{tier}** in this Path now.",
                    inline=False,
                )

        for item in screen.children:
            item.disabled = True
        await interaction.response.edit_message(embed=card, view=screen)
        screen.stop()


class MeditateView(AnsweringView):
    def __init__(self, player_id: int, user: discord.abc.User, where: dict) -> None:
        super().__init__(timeout=180)
        self.player_id = player_id
        self.user = user
        self.where = where
        self.add_item(
            MeditateButton(self, "cultivation", "Cultivation", "\N{HERB}")
        )
        # Offered only when there is a Path to sit in. A button that always
        # refuses is worse than a button that is not there.
        if where["focus_path"]:
            self.add_item(
                MeditateButton(self, "path", where["path_name"], where["emoji"])
            )

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        if interaction.user.id != self.user.id:
            await interaction.response.send_message(
                "Sit with your own thoughts.", ephemeral=True
            )
            return False
        return True

    async def on_error(self, interaction, error: Exception, item) -> None:
        if isinstance(error, GameError):
            card = error_embed(str(error))
            if interaction.response.is_done():
                await interaction.followup.send(embed=card, ephemeral=True)
            else:
                await interaction.response.send_message(embed=card, ephemeral=True)
            return
        await super().on_error(interaction, error, item)

    async def on_timeout(self) -> None:
        for item in self.children:
            item.disabled = True


class Cultivation(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    @app_commands.command(description="Your cultivation, in detail: rate, progress, and what is left.")
    async def cultivation(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        state = await db.fetch_one(
            """
            SELECT
                pc.cultivation, pc.aptitude, pc.focus_path,
                pc.reserve, cultivation_reserve_cap(pc.player_id) AS reserve_cap,
                cultivation_halt(pc.player_id) AS halt,
                r.name AS realm_name,
                r.cultivation_required AS realm_floor,
                next.cultivation_required AS next_floor,
                next.name AS next_realm,
                tr.cultivation_multiplier, tr.physique_multiplier,
                COALESCE(mb.cultivation_rate_bonus, 0) AS manual_cultivation,
                COALESCE(mb.physique_rate_bonus, 0) AS manual_physique,
                gu_stat(pc.player_id, 'cultivation_rate') AS gu_cultivation,
                COALESCE(cb.magnitude, 0) AS cult_boost,
                COALESCE(cb.hours_left, 0) AS cult_boost_hours,
                COALESCE(cb.hours_at_this_rate, 0) AS cult_boost_top_hours,
                COALESCE(cb.stacks, 0) AS cult_boost_stacks,
                COALESCE(ab.magnitude, 0) AS att_boost,
                COALESCE(ab.hours_left, 0) AS att_boost_hours,
                COALESCE(ab.hours_at_this_rate, 0) AS att_boost_top_hours,
                COALESCE(ab.stacks, 0) AS att_boost_stacks,
                cultivation_per_hour(pc.player_id) AS rate_per_hour,
                game_config_value('passive_cultivation_per_hour') AS base_rate,
                game_config_value('passive_physique_per_hour') AS base_physique,
                game_config_value('passive_insight_per_hour') AS base_insight,
                game_config_value('passive_cap_hours') AS cap_hours,
                game_config_value('training_aptitude_baseline') AS baseline,
                game_config_value('path_cultivation_xp_rate') AS focus_rate
            FROM player_cultivation pc
            JOIN realms r ON r.realm_id = pc.realm_id
            LEFT JOIN realms next ON next.realm_id = pc.realm_id + 1
            LEFT JOIN player_trait_rates tr ON tr.player_id = pc.player_id
            LEFT JOIN player_manual_bonuses mb ON mb.player_id = pc.player_id
            LEFT JOIN player_boost_standing cb
                   ON cb.player_id = pc.player_id AND cb.kind = 'cultivation_rate'
            LEFT JOIN player_boost_standing ab
                   ON ab.player_id = pc.player_id AND ab.kind = 'attainment_rate'
            WHERE pc.player_id = %s
            """,
            (player["player_id"],),
        )

        # 0185. This used to perform the same arithmetic
        # `settle_passive_cultivation` does, with a comment warning that a
        # rate here which ignored something "would advertise one number and
        # pay out another". It did exactly that twice: it summed `gu_stat`
        # where the settle sums `player_stat`, so gear and dwelling never
        # counted, and when 0183 gave the settle a realm term this copy did
        # not learn it - a realm 2 card read 103 an hour against 412 paid.
        #
        # So it asks now. A boost is still added on top, because a boost buys
        # extra HOURS in the settle rather than a faster hour, and this line
        # is what an hour is worth.
        rate = float(state["rate_per_hour"] or 0) * (
            1 + float(state["cult_boost"])
        )
        physique_rate = float(state["base_physique"]) * (
            float(state["physique_multiplier"] or 1) + float(state["manual_physique"])
        )

        card = embed(
            f"\N{CYCLONE} {interaction.user.display_name} cultivates...",
            "You circulate your qi, drawing in the ambient energy around you.",
            colour=COLOUR_INFO,
        )
        # A card that advertises an hourly rate it is not paying is the
        # exact fault 0185 was written about, so a halt is said first and
        # the rate below is labelled as not being paid.
        if state["halt"]:
            card.colour = COLOUR_BAD
            card.add_field(
                name="\N{WARNING SIGN} Your cultivation is stopped",
                value=(
                    f"{state['halt'][0].upper()}{state['halt'][1:]}\n"
                    "*Nothing is banked and nothing is stored while this stands \u2014 "
                    "the hours are spent either way.*"
                ),
                inline=False,
            )
        card.add_field(
            name="\N{GLOWING STAR} Next realm progress",
            value=cultivation_bar(state),
            inline=False,
        )

        lines = [
            f"\N{HIGH VOLTAGE SIGN} **{rate:,.0f}** cultivation"
            + (" \u2014 *not being paid*" if state["halt"] else ""),
            f"\N{FLEXED BICEPS} **{physique_rate:,.0f}** physique XP",
        ]
        if state["focus_path"]:
            insight_rate = await db.fetch_value(
                "SELECT game_config_value('passive_insight_per_hour') "
                "* player_attainment_rate(%s, %s)",
                (player["player_id"], state["focus_path"]),
            )
            insight_rate = float(insight_rate) * (1 + float(state["att_boost"]))
            lines.append(
                f"\N{OPEN BOOK} **{insight_rate:,.0f}** "
                f"{state['focus_path']} insight"
            )
        card.add_field(
            name="\N{CHART WITH UPWARDS TREND} Gained each hour",
            value="\n".join(lines),
            inline=False,
        )

        # A boost is hours rather than a clock, so what it has left is a
        # quantity of cultivation and not a time of day.
        #
        # Since 0199 a boost is a STACK of rates spent strongest first, so the
        # number that matters is the one in force RIGHT NOW rather than an
        # average of everything banked. Blending them is what made a +240%
        # pill land on 978 cheap hours and read as +101%.
        quickened = []
        if state["cult_boost_hours"]:
            quickened.append(
                f"\N{BLACK RIGHT-POINTING DOUBLE TRIANGLE} Cultivation "
                f"{percent(state['cult_boost'])} for "
                f"**{float(state['cult_boost_top_hours']):,.0f}** more hours"
                + waiting_behind(state, "cult")
            )
        if state["att_boost_hours"]:
            quickened.append(
                f"\N{CRYSTAL BALL} Insight {percent(state['att_boost'])} for "
                f"**{float(state['att_boost_top_hours']):,.0f}** more hours"
                + waiting_behind(state, "att")
            )
        if quickened:
            card.add_field(
                name="\N{SPARKLES} Quickened",
                value="\n".join(quickened)
                + "\n*Spent by time you actually settle, never by the clock.*",
                inline=False,
            )

        if state["next_floor"] is not None:
            remaining = state["next_floor"] - state["cultivation"]
            if remaining <= 0:
                value = (
                    f"**{state['next_realm']}** is within reach, and cultivation "
                    "has stopped accruing until you take it.\n**/breakthrough**."
                )
            elif rate > 0:
                value = (
                    f"{thousands(remaining)} cultivation — about "
                    f"{humanise_duration(remaining / rate * 3600)} of idle time."
                )
            else:
                value = f"{thousands(remaining)} cultivation."
            card.add_field(
                name="\N{SMALL BLUE DIAMOND} What is left",
                value=value,
                inline=False,
            )

        focus = (
            f"**{state['focus_path']}** — cultivation at "
            f"{percent(state['focus_rate'], signed=False)} in exchange for insight."
            if state["focus_path"]
            else "None — full cultivation rate, no insight. **/focus** to aim it."
        )
        card.add_field(
            name="\N{DIRECT HIT} Focus", value=focus, inline=False
        )
        card.set_footer(
            text=f"Idle time is paid up to {int(state['cap_hours'])}h at a stretch. "
            "Nothing ticks — it is computed when you look."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="Sit down and let the body close what it can.")
    async def rest(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])
        await claim(player["player_id"], "rest", "rest_cooldown_minutes")

        got = await db.fetch_one("SELECT * FROM rest(%s)", (player["player_id"],))

        if got["healed"] == 0 and not got["pet_healed"]:
            card = embed(
                "\N{SLEEPING SYMBOL} Already whole",
                "There is nothing to close. The rest is wasted on you.",
                colour=COLOUR_INFO,
            )
        elif got["healed"] == 0:
            # The body had nothing to close and the beast did. Saying the rest
            # was wasted here is how nobody found out beasts mend at all.
            card = embed(
                f"\N{SLEEPING SYMBOL} {got['pet_name']} rests",
                "You are whole already. It is not.",
                colour=COLOUR_GOOD,
            )
        else:
            card = embed(
                f"\N{SLEEPING SYMBOL} +{thousands(got['healed'])} HP",
                "You sit until the worst of it stops.",
                colour=COLOUR_GOOD,
            )
        card.add_field(
            name="Body",
            value=f"{bar(got['current_hp'], got['max_hp'], width=16)}\n"
            f"**{thousands(got['current_hp'])}** / {thousands(got['max_hp'])}",
            inline=False,
        )
        # The beast at your heel mends here as well, and this is the only
        # screen that says so.
        if got["pet_max_hp"]:
            card.add_field(
                name=got["pet_name"] or "At your heel",
                value=f"{bar(got['pet_hp'], got['pet_max_hp'], width=16)}\n"
                f"**{thousands(got['pet_hp'])}** / {thousands(got['pet_max_hp'])}"
                + (f"  \N{EM DASH}  +{thousands(got['pet_healed'])}"
                   if got["pet_healed"] else "")
                + ("  \N{EM DASH}  *still down, rest again*"
                   if got["pet_hp"] <= 0 else ""),
                inline=False,
            )

        # What was offered and what was banked differ at the cap, and a screen
        # that quoted the roll would be quoting a number nobody received.
        if got["full_up"] and got["offered"] > got["healed"]:
            card.set_footer(
                text=f"The rest was worth {thousands(got['offered'])} — the body "
                "could not hold the rest of it."
            )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(description="Sit with your cultivation, or with your Path.")
    async def meditate(self, interaction: discord.Interaction) -> None:
        """Two axes, one wait.

        A second cooldown would let a player take both every time, and then
        there would be no choice in it at all.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        where = await db.fetch_one(
            """
            SELECT pc.focus_path, p.name AS path_name, p.emoji,
                   r.name AS realm_name,
                   (SELECT n.cultivation_required FROM realms n
                    WHERE n.realm_id = pc.realm_id + 1) AS realm_span
            FROM player_cultivation pc
            JOIN realms r ON r.realm_id = pc.realm_id
            LEFT JOIN paths p ON p.code = pc.focus_path
            WHERE pc.player_id = %s
            """,
            (player["player_id"],),
        )

        card = embed(
            "\N{LOTUS} Meditate",
            "One quiet hour, spent on one thing. A share of the realm you are "
            "crossing, or of the next step on a Path — not a share of what you "
            "already hold, so it is worth the same at every realm.",
            colour=COLOUR_INFO,
        )
        card.add_field(
            name="Toward",
            value=f"**{where['realm_name']}**"
            + (
                f"\n{where['emoji']} aimed at the **{where['path_name']}**"
                if where["focus_path"]
                else "\n*No Path chosen — **/focus** opens that half.*"
            ),
            inline=False,
        )
        view = MeditateView(player["player_id"], interaction.user, where)
        await interaction.response.send_message(embed=card, view=view)

    # -----------------------------------------------------------------------

    async def gate_lines(self, player_id: int) -> str | None:
        """What the next crossing is asking for.

        Read from `breakthrough_gate`, which is also what the door itself
        checks - so the warning and the refusal cannot drift apart.
        """
        rows = await db.fetch_all(
            "SELECT * FROM breakthrough_gate(%s)", (player_id,)
        )
        if not rows:
            return None
        return "\n".join(gate_line(r) for r in rows)

    @app_commands.command(description="Take the next realm.")
    async def breakthrough(self, interaction: discord.Interaction) -> None:
        """The one place a realm changes.

        Cultivation fills to the next realm's requirement and stops there, so
        this is never automatic and never a surprise — which is the room the
        tribulation took in 0386 when it arrived to stand in the way of it.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        try:
            done = await db.fetch_one(
                "SELECT * FROM breakthrough(%s)", (player["player_id"],)
            )
        except psycopg.errors.CheckViolation as exc:
            # The whole list, not the one thing that happened to be checked
            # first - somebody short of three things should learn that once.
            wants = await self.gate_lines(player["player_id"])
            raise GameError(
                str(exc).splitlines()[0].capitalize()
                + ".\n\n"
                + (wants + "\n\n" if wants else "")
                + "**/cultivation** shows how far off you are."
            ) from exc

        card = embed(
            f"\N{HIGH VOLTAGE SIGN} {done['name_after']}",
            f"You break out of **{done['name_before']}**.",
            colour=COLOUR_GOOD,
        )

        gained = [
            f"\N{FIRE} Qi capacity **{thousands(done['qi_capacity'])}**",
            f"\N{DROPLET} Essence capacity **{thousands(done['essence_capacity'])}**",
        ]
        if done["aperture_gained"]:
            gained.append(
                f"\N{BUG} Aperture **{done['gu_capacity']}** "
                f"(+{done['aperture_gained']}) — **/gu**"
            )
        if done["techniques_freed"]:
            gained.append(
                f"\N{CROSSED SWORDS} **{done['techniques_freed']}** technique(s) of "
                f"Rank {done['rank_after']} are now within reach — **/techniques**"
            )
        # Only a body that tempers on the crossing has this, and it grants real
        # physique XP — so it is reported here rather than left to be noticed
        # on /physique afterwards.
        if done["tempering_gained"]:
            levels = done["body_levels"]
            gained.append(
                f"\N{SNOW CAPPED MOUNTAIN} Your body tempers on the way through — "
                f"**{thousands(done['tempering_gained'])}** physique XP"
                + (f", **{levels}** body level(s)" if levels else "")
            )
        # Which pillar was weakest is the interesting half — it changes as the
        # body grows, and it is the only way to see the mechanic working.
        if done["founded_by"]:
            gained.append(
                f"\N{CLASSICAL BUILDING} Your weakest pillar rises — "
                f"**{percent(done['founded_by'])} {FOUNDATION[done['founded_stat']]}**, "
                "and it will keep rising until it is not the weakest"
            )
        # The reserve is the payoff for having waited at the door, so it
        # goes in the list of what the crossing was worth, not a footnote.
        if done["reserve_drawn"]:
            gained.append(
                f"\N{DROPLET} **{thousands(done['reserve_drawn'])}** cultivation "
                "poured in from your reserve - none of the wait was wasted"
                + (
                    f", **{thousands(done['reserve_left'])}** still held"
                    if done["reserve_left"]
                    else ""
                )
            )
        card.add_field(name="What it is worth", value="\n".join(gained), inline=False)

        if done["next_ceiling"] is not None:
            card.add_field(
                name="Next",
                value=(
                    f"{thousands(done['next_ceiling'] - done['cultivation'])} "
                    "cultivation to the realm after this one."
                ),
                inline=False,
            )
        else:
            card.add_field(
                name="Next",
                value="Nothing above this. The ladder ends here.",
                inline=False,
            )

        card.set_footer(
            text="One day this will cost you a tribulation. Today it costs the wait."
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Drink immortal essence. The only way up, past the Dao Realm."
    )
    @app_commands.describe(
        essence="Which essence to absorb — the list shows what you are holding.",
        amount="How many to drink.",
    )
    async def absorb(
        self, interaction: discord.Interaction, essence: str, amount: int
    ) -> None:
        """Typed rather than picked, unlike **/focus**.

        The Path list is short, fixed and visual; a cultivator's essence is a
        running count of nine things they may hold thousands of, and the
        number they want to drink is the whole decision. Autocomplete shows
        what is in the bag, so nothing has to be memorised to use it.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        try:
            done = await db.fetch_one(
                "SELECT * FROM absorb_essence(%s, %s, %s)",
                (player["player_id"], essence, amount),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize() + ".") from exc

        card = embed(
            f"{done['emoji']} {done['essence']}",
            f"You draw **{thousands(done['absorbed'])}** of it in, and it goes.",
            colour=COLOUR_GOOD,
        )
        card.add_field(
            name="Taken",
            value=(
                f"**+{thousands(done['gained'])}** cultivation\n"
                f"{thousands(done['cultivation'])} held"
                + (f" \N{BULLET} {thousands(done['ceiling'])} for the next realm"
                   if done["ceiling"] else "")
            ),
            inline=False,
        )
        # Spill is the one thing worth interrupting for: a cultivator who
        # drinks a Yellow Apricot at Dewberry Immortal has just poured most of
        # a fortune onto the floor, and ought to hear about it the first time
        # rather than work it out from a number that did not move enough.
        if done["spilled"] > 0:
            card.add_field(
                name="\N{WARNING SIGN} Spilled",
                value=(
                    f"**{thousands(done['spilled'])}** had nowhere to go — "
                    "cultivation stops at the next realm. Break through, then "
                    "drink the rest."
                ),
                inline=False,
            )
        if done["ready"]:
            card.add_field(
                name="Ready",
                value="**/breakthrough** — the next realm is open to you.",
                inline=False,
            )
        card.set_footer(
            text=f"{thousands(done['held'])} left \N{BULLET} now {done['realm_name']}"
        )
        await interaction.response.send_message(embed=card)

    # -----------------------------------------------------------------------

    @app_commands.command(
        description="Face the sky standing in the door of the next great realm."
    )
    async def tribulation(self, interaction: discord.Interaction) -> None:
        """The last gate, and the only one you cannot buy.

        Everything this screen knows comes from `tribulation_standing`, which
        is also what `tribulation_face` refuses on - so a screen that offers
        the button is a screen whose button works.
        """
        player = await require_player(interaction.user)
        await settle_passive(player["player_id"])

        here = await db.fetch_one(
            "SELECT * FROM tribulation_standing(%s)", (player["player_id"],)
        )
        if here is None or not here["owed"]:
            raise GameError(
                "No great realm is waiting for you. A stage inside a realm is "
                "crossed with **/breakthrough** and asks nothing of you but "
                "the cultivation."
            )

        if here["passed"]:
            # Above the eighteen realms the door is NOT /breakthrough,
            # which walks `realms` by realm_id + 1 and would tell them
            # there is nothing above them. The Venerable ladder is its own
            # table and its own crossing.
            top = await db.fetch_value("SELECT max(rank) FROM realms")
            door = "**/ascend**" if here["rank"] > top else "**/breakthrough**"
            card = embed(
                f"\N{HIGH VOLTAGE SIGN} {here['trial_name']} is behind you",
                f"You survived it. **{here['realm_name']}** is open \N{EM DASH} "
                f"{door}.",
                colour=COLOUR_GOOD,
            )
            halt = await db.fetch_value(
                "SELECT cultivation_halt(%s)", (player["player_id"],)
            )
            if halt:
                card.add_field(
                    name="\N{WARNING SIGN} The sky is still owed",
                    value=f"{halt[0].upper()}{halt[1:]}",
                    inline=False,
                )
            await interaction.response.send_message(embed=card)
            return

        if here["facing_battle"] is not None:
            raise GameError(
                f"You are standing in the {here['trial_name']} right now. "
                "**/battle** to get back to it."
            )

        card = embed(
            f"\N{CLOUD WITH LIGHTNING} {here['trial_name']}",
            f"*{here['trial_text']}*",
            colour=COLOUR_GOOD if here["may_face"] else COLOUR_INFO,
        )
        card.add_field(
            name="What stands there",
            value=(
                f"\N{HEAVY BLACK HEART} **{thousands(here['trial_hp'])}** health "
                f"\N{BULLET} \N{CROSSED SWORDS} **{thousands(here['trial_attack'])}** "
                "attack\n*It has no Path, so nothing you carry is strong against "
                "it and nothing is weak.*"
            ),
            inline=False,
        )
        # Read rather than remembered: a second copy of a tuning constant
        # in a cog is a second thing to keep in step with game_config.
        shut_for = await db.fetch_value(
            "SELECT game_config_value('tribulation_retry_hours')"
        )
        # Both read rather than remembered, for the same reason the
        # retry wait is: a second copy of a tuning constant in a cog is
        # a second thing to keep in step with game_config.
        fee = await db.fetch_value(
            "SELECT game_config_value('tribulation_failure_jade')"
        )
        fee_from = await db.fetch_value(
            "SELECT game_config_value('tribulation_debt_from_rank')"
        )
        owes_jade = here["rank"] >= int(fee_from)
        card.add_field(
            name="What it asks",
            value=(
                f"Break it before the fight runs out of turns. Failing costs "
                f"the fight and shuts the sky for "
                f"{humanise_duration(float(shut_for) * 3600)}"
                + (
                    f", and leaves **{thousands(int(fee))} jade** owed "
                    f"\N{EM DASH} your cultivation stops advancing until "
                    "it is paid (**/paydebt**)"
                    if owes_jade
                    else f" \N{EM DASH} nothing you have already earned"
                )
                + ". Fleeing counts as failing."
            ),
            inline=False,
        )

        if not here["may_face"]:
            if here["wait_seconds"] > 0:
                card.add_field(
                    name="\N{WARNING SIGN} The sky has not settled",
                    value=f"**{humanise_duration(int(here['wait_seconds']))}** "
                    "before it will look at you again.",
                    inline=False,
                )
            else:
                card.add_field(
                    name="\N{WARNING SIGN} Not yet",
                    value=f"You are short of **{here['blocked_by']}** \N{EM DASH} "
                    "**/cultivation** shows the whole list.",
                    inline=False,
                )
            await interaction.response.send_message(embed=card)
            return

        card.set_footer(text="Once you walk in, walking out counts as failing.")
        await interaction.response.send_message(
            embed=card,
            view=TribulationView(player["player_id"], interaction.user),
        )

    # -----------------------------------------------------------------------

    @absorb.autocomplete("essence")
    async def absorb_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        rows = await db.fetch_all(
            """
            SELECT m.code, m.name, m.emoji, pm.quantity, e.unit_value
            FROM player_materials pm
            JOIN immortal_essences e ON e.material_code = pm.material_code
            JOIN materials m ON m.code = pm.material_code
            JOIN players p ON p.player_id = pm.player_id
            WHERE p.discord_id = %s AND pm.quantity > 0
              AND m.name ILIKE %s
            ORDER BY e.unit_value DESC
            LIMIT 25
            """,
            (interaction.user.id, f"%{current}%"),
        )
        return [
            app_commands.Choice(
                name=f"{r['emoji']} {r['name']} \N{MULTIPLICATION SIGN}"
                     f"{thousands(r['quantity'])}"[:100],
                value=r["code"],
            )
            for r in rows
        ]

    # -----------------------------------------------------------------------

    @app_commands.command(description="Aim your cultivation at a Path.")
    async def focus(self, interaction: discord.Interaction) -> None:
        """Pick from buttons.

        There is no typed argument: the Path list is fixed, short and visual,
        and a picker that shows every option beats an autocomplete that shows
        the ones you already knew how to spell.
        """
        player = await require_player(interaction.user)
        paths = await fetch_paths()
        current = await db.fetch_value(
            "SELECT focus_path FROM player_cultivation WHERE player_id = %s",
            (player["player_id"],),
        )
        view = FocusPicker(player["player_id"], interaction.user, paths, current)
        await interaction.response.send_message(embed=view.prompt(), view=view)


# ---------------------------------------------------------------------------
# Setting a focus
# ---------------------------------------------------------------------------


async def apply_focus(player_id: int, row: dict | None) -> discord.Embed:
    """Settle, then switch.

    Insight already earned belongs to the Path it was earned in. Settling
    before the change is what stops eight hours aimed at Fire paying out into
    Ice because the player changed their mind on the way back.
    """
    await settle_passive(player_id)

    if row is None:
        await db.execute(
            "UPDATE player_cultivation SET focus_path = NULL WHERE player_id = %s",
            (player_id,),
        )
        return embed(
            "Focus cleared",
            "Pure cultivation from here: full rate, no insight.",
            colour=COLOUR_GOOD,
        )

    await db.execute(
        "UPDATE player_cultivation SET focus_path = %s WHERE player_id = %s",
        (row["code"], player_id),
    )

    rate = await db.fetch_value(
        "SELECT player_attainment_rate(%s, %s)", (player_id, row["code"])
    )
    focus_rate = await db.fetch_value(
        "SELECT game_config_value('path_cultivation_xp_rate')"
    )

    # Exotic Paths can be cultivated like any other; saying so beats a player
    # wondering why their new focus never shows up in a matchup.
    note = (
        ""
        if row.get("uses_matchups", True)
        else "\n\nAn exotic Path — attainment still accrues, but it takes no "
        "part in the matchup chart."
    )

    return embed(
        f"{row.get('emoji', '')} Cultivating toward {row['name']}".strip(),
        f"Insight accrues {multiplier(rate)} faster from your Race, Root and Physique.\n"
        f"Cultivation drops to {percent(focus_rate, signed=False)} in exchange."
        + note,
        colour=COLOUR_GOOD,
    )


class ClearButton(discord.ui.Button):
    def __init__(self, picker: "FocusPicker") -> None:
        self.picker = picker
        super().__init__(
            label="No focus",
            emoji="\N{HEAVY MULTIPLICATION X}",
            row=BUTTON_ROWS,
            style=discord.ButtonStyle.danger,
            disabled=picker.highlight is None,
        )

    async def callback(self, interaction: discord.Interaction) -> None:
        card = await apply_focus(self.picker.player_id, None)
        self.picker.highlight = None
        self.picker.render()
        await interaction.response.edit_message(embed=card, view=self.picker)


class FocusPicker(PathPicker):
    prompt_title = "Choose a focus"
    prompt_body = (
        "Cultivation aimed at a Path earns insight into it, at 85% of the raw "
        "rate. Leave it unfocused for full speed and no insight."
    )

    def __init__(
        self,
        player_id: int,
        user: discord.abc.User,
        paths: list[dict],
        current: str | None,
    ) -> None:
        self.player_id = player_id
        super().__init__(user, paths, highlight=current)

    async def on_pick(self, path: dict) -> discord.Embed:
        return await apply_focus(self.player_id, path)

    def extra_items(self) -> list[discord.ui.Item]:
        return [ClearButton(self)]

    def prompt(self) -> discord.Embed:
        card = super().prompt()
        if self.highlight:
            card.set_footer(text=f"Currently focused on {self.highlight}.")
        else:
            card.set_footer(text="No focus set.")
        return card


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Cultivation(bot))
