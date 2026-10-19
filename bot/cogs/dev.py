"""Owner-only commands for testing in a live server.

Everything here exists to reach a game state that would otherwise take hours of
real time to reach honestly — finishing a session early, granting insight,
picking a physique. None of it is reachable by anyone but the application's
owner, and all of it writes through the same functions the real commands use,
so testing with these does not exercise a second code path.

`/dev grant-*` deliberately does not touch admin_audit_log: that table records
privileged actions taken *against another player*, and these only act on the
owner's own character. The moment a moderation command arrives that edits
somebody else, it logs.
"""

import discord
import psycopg
from discord import app_commands
from discord.ext import commands

from bot import config
from bot import database as db
from bot.formatting import COLOUR_INFO, embed, thousands
from bot.lookups import path_autocomplete, resolve_path
from bot.players import GameError, require_player


class Dev(commands.Cog):
    def __init__(self, bot: commands.Bot) -> None:
        self.bot = bot

    dev = app_commands.Group(
        name="dev",
        description="Owner-only testing tools.",
        default_permissions=discord.Permissions(administrator=True),
    )

    async def cog_check(self, ctx: commands.Context) -> bool:  # prefix commands
        return await self.bot.is_owner(ctx.author)

    async def interaction_check(self, interaction: discord.Interaction) -> bool:
        """The real gate.

        `default_permissions` above only hides the command from members who
        cannot administer the server — it is a UI hint, and a server admin who
        is not the bot's owner would still get through it.
        """
        if not await self.bot.is_owner(interaction.user):
            raise app_commands.CheckFailure("owner only")
        return True

    # -----------------------------------------------------------------------

    @dev.command(name="sync", description="Re-register the command tree.")
    async def sync(self, interaction: discord.Interaction) -> None:
        await interaction.response.defer(ephemeral=True)
        synced = await self.bot.sync_commands()
        target = config.guild_id()
        await interaction.followup.send(
            embed=embed(
                "Synced",
                f"{len(synced)} command(s) registered "
                + (f"to guild `{target}`." if target else "globally (up to an hour to appear)."),
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @dev.command(name="horde", description="Send a Beast Horde at a region.")
    @app_commands.describe(
        region="Which region the tide comes for.",
        rank="Pitch it at this realm rank, or leave empty to read the room.",
    )
    async def horde(
        self,
        interaction: discord.Interaction,
        region: str,
        rank: int | None = None,
    ) -> None:
        """Hordes are meant to arrive on their own. Nothing schedules them yet,
        so this is how one starts - and it stays owner-only afterwards, because
        an event everybody can summon is not an event."""
        try:
            made = await db.fetch_value(
                "SELECT horde_open(%s, %s::smallint, %s)",
                (region, rank, config.horde_channel_id()),
            )
        except psycopg.errors.CheckViolation as exc:
            raise GameError(str(exc).splitlines()[0].capitalize()) from exc

        tide = await db.fetch_one(
            "SELECT * FROM horde_board WHERE horde_id = %s", (made,)
        )
        await interaction.response.send_message(
            embed=embed(
                "\N{PAW PRINTS} A tide is coming",
                f"**{tide['region_name']}** \N{BULLET} rank {tide['rank']} "
                f"\N{BULLET} {tide['beasts_total']} beasts \N{BULLET} the line "
                f"holds {tide['line_holds']}.\n\nBeasts start appearing in the "
                "horde channel within twenty seconds.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    @horde.autocomplete("region")
    async def horde_region(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        rows = await db.fetch_all(
            "SELECT code, name FROM regions WHERE name ILIKE %s ORDER BY sort_order "
            "LIMIT 25",
            (f"%{current}%",),
        )
        return [
            app_commands.Choice(name=r["name"], value=r["code"]) for r in rows
        ]

    # -----------------------------------------------------------------------

    @dev.command(name="advance", description="Pretend N hours of idle time have passed.")
    @app_commands.describe(hours="How far back to move your last settled tick.")
    async def advance(
        self,
        interaction: discord.Interaction,
        hours: app_commands.Range[int, 1, 240],
    ) -> None:
        """Moves `last_tick_at` back rather than granting anything.

        The payout still goes through settle_passive_cultivation on the next
        command, so what gets tested is the real accrual - including the cap,
        which is why this accepts values well past it.
        """
        player = await require_player(interaction.user)
        moved = await db.fetch_one(
            """
            UPDATE player_cultivation
            SET last_tick_at = last_tick_at - make_interval(hours => %s)
            WHERE player_id = %s
            RETURNING last_tick_at
            """,
            (hours, player["player_id"]),
        )
        if moved is None:
            raise GameError("You have no cultivation row.")
        await interaction.response.send_message(
            embed=embed(
                "Clock moved",
                f"You now read as having been away {hours}h. "
                "**/profile** or **/cultivation** settles it.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @dev.command(name="arrive", description="Finish the journey you are on, now.")
    async def dev_arrive(self, interaction: discord.Interaction) -> None:
        """Drags the whole journey into the past, not just the arrival.

        `arrives_at > departed_at` is a CHECK, so moving only the arrival back
        is refused - correctly, since it would describe a journey that landed
        before it left.
        """
        player = await require_player(interaction.user)
        moved = await db.fetch_one(
            """
            UPDATE player_location
            SET departed_at = departed_at - interval '1000 hours',
                arrives_at  = arrives_at  - interval '1000 hours'
            WHERE player_id = %s AND travelling_to IS NOT NULL
            RETURNING travelling_to
            """,
            (player["player_id"],),
        )
        if moved is None:
            raise GameError("You are not travelling.")

        await db.execute("SELECT arrive(%s)", (player["player_id"],))
        await interaction.response.send_message(
            embed=embed(
                "Arrived",
                f"You are now in **{moved['travelling_to']}**.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @dev.command(name="page", description="Mint yourself a manual page.")
    @app_commands.describe(
        count="How many to roll.", tier_min="Lowest tier.", tier_max="Highest tier."
    )
    async def page(
        self,
        interaction: discord.Interaction,
        count: app_commands.Range[int, 1, 20] = 1,
        tier_min: app_commands.Range[int, 1, 7] = 1,
        tier_max: app_commands.Range[int, 1, 7] = 7,
    ) -> None:
        """Pages have no drop source yet, so this is the only way to hold one.

        It calls the same mint_page the drop tables will, so what /dev hands
        out is what a kill will hand out - there is no second roller to drift.
        """
        player = await require_player(interaction.user)
        if tier_max < tier_min:
            raise GameError("tier_max cannot be below tier_min.")

        for _ in range(count):
            await db.execute(
                "SELECT mint_page(%s, %s::smallint, %s::smallint)",
                (player["player_id"], tier_min, tier_max),
            )

        await interaction.response.send_message(
            embed=embed(
                "Minted",
                f"{count} page(s), tier {tier_min}-{tier_max}. **/pages** to read them.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @dev.command(name="ready", description="Clear your gather and hunt cooldowns.")
    async def ready(self, interaction: discord.Interaction) -> None:
        player = await require_player(interaction.user)
        await db.execute(
            "DELETE FROM player_cooldowns WHERE player_id = %s", (player["player_id"],)
        )
        # And any half-worked set of tries. Leaving one open would mean the
        # next /gather RESUMES it rather than opening a fresh five - correct
        # behaviour everywhere else, and the opposite of what "ready" means.
        await db.execute(
            "DELETE FROM player_action_tries WHERE player_id = %s",
            (player["player_id"],),
        )
        await interaction.response.send_message(
            embed=embed(
                "Ready",
                "Every cooldown is clear and no set is half-worked.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @dev.command(name="reroll", description="Reopen character creation with fresh rerolls.")
    async def reroll(self, interaction: discord.Interaction) -> None:
        """Unconfirms the character and restores its rerolls.

        Not a wipe: the same player, the same history, back on the creation
        screen - which is the state worth being able to reach repeatedly while
        testing how a roll reads.
        """
        player = await require_player(interaction.user)
        reopened = await db.fetch_one(
            """
            UPDATE player_character
            SET confirmed_at          = NULL,
                root_rerolls_left     = game_config_value('character_root_rerolls')::smallint,
                physique_rerolls_left = game_config_value('character_physique_rerolls')::smallint
            WHERE player_id = %s
            RETURNING root_code
            """,
            (player["player_id"],),
        )
        if reopened is None:
            raise GameError("You have no character.")
        await interaction.response.send_message(
            embed=embed(
                "Creation reopened",
                "**/register** picks it back up with a full set of rerolls.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @dev.command(name="insight", description="Grant yourself Path insight.")
    @app_commands.describe(path="Which Path.", amount="How much insight.")
    @app_commands.autocomplete(path=path_autocomplete)
    async def insight(
        self,
        interaction: discord.Interaction,
        path: str,
        amount: app_commands.Range[int, 1, 10_000_000],
    ) -> None:
        player = await require_player(interaction.user)
        await resolve_path(path)

        tier = await db.fetch_value(
            "SELECT grant_path_insight(%s, %s, %s)",
            (player["player_id"], path, amount),
        )
        name = await db.fetch_value(
            "SELECT name FROM attainment_tiers WHERE tier = %s", (tier,)
        )
        await interaction.response.send_message(
            embed=embed(
                "Granted",
                f"{thousands(amount)} {path} insight. You are now **{name}**.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @dev.command(name="cultivation", description="Grant yourself cultivation.")
    @app_commands.describe(amount="How much cultivation.")
    async def cultivation(
        self,
        interaction: discord.Interaction,
        amount: app_commands.Range[int, 1, 10_000_000_000],
    ) -> None:
        player = await require_player(interaction.user)
        realm_id = await db.fetch_value(
            "SELECT apply_cultivation_xp(%s, %s)", (player["player_id"], amount)
        )
        realm = await db.fetch_value(
            "SELECT name FROM realms WHERE realm_id = %s", (realm_id,)
        )
        await interaction.response.send_message(
            embed=embed(
                "Granted",
                f"{thousands(amount)} cultivation. You are now at **{realm}**.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )

    # -----------------------------------------------------------------------

    @dev.command(name="physique", description="Set your physique.")
    @app_commands.describe(physique="Which physique to take on.")
    async def physique(self, interaction: discord.Interaction, physique: str) -> None:
        player = await require_player(interaction.user)

        row = await db.fetch_one(
            "SELECT physique_id, name FROM physiques WHERE code = %s", (physique,)
        )
        if row is None:
            raise GameError(f"There is no physique called `{physique}`.")

        await db.execute(
            "UPDATE player_physique SET physique_id = %s WHERE player_id = %s",
            (row["physique_id"], player["player_id"]),
        )
        # The stat contribution is a function of level and physique, so it has
        # to be recomputed - granting 0 XP is the cheapest way to say that.
        await db.execute(
            "SELECT apply_physique_xp(%s, 0)", (player["player_id"],)
        )
        await interaction.response.send_message(
            embed=embed("Set", f"You now bear the **{row['name']}**.", colour=COLOUR_INFO),
            ephemeral=True,
        )

    @physique.autocomplete("physique")
    async def physique_autocomplete(
        self, interaction: discord.Interaction, current: str
    ) -> list[app_commands.Choice[str]]:
        rows = await db.fetch_all(
            """
            SELECT code, name || ' (' || tier || ')' AS label
            FROM physiques
            WHERE name ILIKE %s OR code ILIKE %s
            ORDER BY tier, name
            LIMIT 25
            """,
            (f"%{current}%", f"%{current}%"),
        )
        return [
            app_commands.Choice(name=row["label"], value=row["code"]) for row in rows
        ]

    # -----------------------------------------------------------------------

    @dev.command(name="dao", description="Read any cultivator's Dao. /dao is the player-facing one.")
    @app_commands.describe(user="Whose Dao to read. Defaults to your own.")
    async def dao(
        self,
        interaction: discord.Interaction,
        user: discord.User | None = None,
    ) -> None:
        """The Venerable derivation, visible long before rank 19 ships.

        The player-facing screen is /dao, in `bot/cogs/venerable.py`. This
        one stays because it reads ANY cultivator, and the derivation can
        only be balanced by reading what it says about people who actually
        played.

        Nothing is written. `dao_aspects` and `dao_name_of` derive on every
        call; only the ascension stamps one.
        """
        target = user or interaction.user
        await interaction.response.defer(ephemeral=True)

        row = await db.fetch_one(
            """
            SELECT p.player_id,
                   COALESCE(NULLIF(pc.character_name, ''), p.discord_name) AS who,
                   dao_name_of(p.player_id) AS dao
            FROM players p
            LEFT JOIN player_character pc ON pc.player_id = p.player_id
            WHERE p.discord_id = %s AND p.deleted_at IS NULL
            """,
            (target.id,),
        )
        if row is None:
            raise GameError(f"**{target.display_name}** has no character.")
        if row["dao"] is None:
            raise GameError(
                f"**{row['who']}** has walked no path, so there is no Dao to read yet."
            )

        aspects = await db.fetch_all(
            """
            SELECT source_kind, source_code, label, weight, feeds
            FROM dao_aspects(%s)
            ORDER BY ordinal
            """,
            (row["player_id"],),
        )

        KINDS = {
            "path": "Path walked",
            "body": "Body forged",
            "craft": "Craft levelled",
            "root": "Root born with",
            "destiny": "Destiny taken",
            "gu": "Worm kept",
        }

        lines = []
        for a in aspects:
            share = int(round(float(a["weight"]) * 100))
            lines.append(
                f"**{a['label']}** · {KINDS.get(a['source_kind'], a['source_kind'])} "
                f"· {share}%\n\u00a0\u00a0\u00a0*{a['feeds']}*"
            )

        card = embed(
            row["dao"],
            f"The Dao of **{row['who']}**, read off what they have already done.",
            colour=COLOUR_INFO,
        )
        card.add_field(name="Aspects", value="\n".join(lines), inline=False)
        card.set_footer(
            text=(
                "Derived, not stored. The share is how far an aspect dominates "
                "its own axis. /dao is the same screen for a cultivator's "
                "own Dao."
            )
        )
        await interaction.followup.send(embed=card, ephemeral=True)

    # -----------------------------------------------------------------------

    @dev.command(
        name="venerable",
        description="Read any cultivator's understanding. /venerable is the player-facing one.",
    )
    @app_commands.describe(user="Whose understanding to read. Defaults to your own.")
    async def venerable(
        self,
        interaction: discord.Interaction,
        user: discord.User | None = None,
    ) -> None:
        """The Venerable meter, read for anybody rather than for yourself.

        A Dao is derived fresh every read until it is STAMPED; from then on the
        aspects and their weights are fixed and understanding is measured as
        movement away from a baseline taken at that moment. Freezing is the
        point - otherwise a cultivator could re-weight their own Dao by
        training a different Path and drag the ladder along behind them.

        This reads ANY cultivator, which is why it is still here now that
        /venerable exists: the rung costs can only be balanced by reading
        what understanding actually does to people who played, and it only
        accrues forward. It no longer STAMPS - `venerable_ascend` is the
        only thing that may, because a stamp from here would mint a
        Venerable who never fought the Sovereign Calamity.
        """
        target = user or interaction.user
        await interaction.response.defer(ephemeral=True)

        row = await db.fetch_one(
            """
            SELECT p.player_id,
                   COALESCE(NULLIF(pc.character_name, ''), p.discord_name) AS who,
                   d.dao_name, d.stamped_at,
                   dao_name_of(p.player_id) AS live_dao
            FROM players p
            LEFT JOIN player_character pc ON pc.player_id = p.player_id
            LEFT JOIN player_dao d ON d.player_id = p.player_id
            WHERE p.discord_id = %s AND p.deleted_at IS NULL
            """,
            (target.id,),
        )
        if row is None:
            raise GameError(f"**{target.display_name}** has no character.")

        if row["dao_name"] is None:
            card = embed(
                "Not stamped",
                f"**{row['who']}** would read as *{row['live_dao'] or 'nothing yet'}*, "
                "derived fresh. Nothing accrues until a Dao is frozen, and "
                "the ascension is the only thing that freezes it.",
                colour=COLOUR_INFO,
            )
            await interaction.followup.send(embed=card, ephemeral=True)
            return

        aspects = await db.fetch_all(
            """
            SELECT source_kind, label, unit_name, baseline, deed_now, gained,
                   understanding, weight
            FROM dao_understanding(%s)
            ORDER BY understanding DESC, ordinal
            """,
            (row["player_id"],),
        )
        step = await db.fetch_one(
            """
            SELECT held_rank, held_tier, held_name,
                   next_rank, next_tier, next_name,
                   understanding, floor_at, required, fraction,
                   aspects_realised, aspects_needed, per_aspect
            FROM venerable_progress(%s)
            """,
            (row["player_id"],),
        )

        total = float(step["understanding"] or 0) if step else 0.0

        lines = []
        for a in aspects:
            lines.append(
                f"**{a['label']}** \u00b7 {float(a['understanding']):,.1f} "
                f"\u00b7 {float(a['gained']):,.0f} {a['unit_name']} since the stamp "
                f"\u00b7 at {int(float(a['weight']) * 100)}% weight"
            )
        if not lines:
            lines = ["*Nothing \u2014 no aspect of this Dao records a deed.*"]

        held = "\u2014 not yet a Venerable"
        if step and step["held_tier"] is not None:
            held = f"Venerable Rank {step['held_tier']} \u00b7 {step['held_name']}"

        card = embed(
            row["dao_name"],
            f"**{row['who']}** \u00b7 stamped <t:{int(row['stamped_at'].timestamp())}:R>",
            colour=COLOUR_INFO,
        )
        card.add_field(
            name="Standing",
            value=f"{held}\n**{total:,.1f}** understanding",
            inline=False,
        )

        # The bar. It fills from the rung held rather than from zero, so each
        # rung starts it over instead of one bar creeping to full across all
        # nine.
        if step and step["next_tier"] is not None:
            frac = float(step["fraction"] or 0)
            filled = int(round(frac * 20))
            bar = "\u2588" * filled + "\u2591" * (20 - filled)
            into = total - float(step["floor_at"] or 0)
            span = float(step["required"]) - float(step["floor_at"] or 0)
            enough = int(step["aspects_realised"] or 0) >= int(step["aspects_needed"])
            card.add_field(
                name=(
                    f"Toward Venerable Rank {step['next_tier']} "
                    f"\u2014 {step['next_name']}"
                ),
                value=(
                    f"`{bar}` {frac * 100:.0f}%\n"
                    f"{into:,.0f} / {span:,.0f} understanding this rung\n"
                    f"{'\u2713' if enough else '\u2717'} "
                    f"{step['aspects_realised']} / {step['aspects_needed']} aspects at "
                    f"{float(step['per_aspect']):,.0f} or more"
                ),
                inline=False,
            )
        else:
            card.add_field(
                name="At the top of the ladder",
                value="Every aspect of this Dao is realised.",
                inline=False,
            )

        card.add_field(name="Where it came from", value="\n".join(lines), inline=False)
        card.set_footer(
            text=(
                "Understanding is movement since the stamp, weighted by each "
                "aspect. Root and destiny record no deed and do not appear."
            )
        )
        await interaction.followup.send(embed=card, ephemeral=True)

    # -----------------------------------------------------------------------

    @dev.command(name="wipe", description="Delete your character so /register can be tested again.")
    async def wipe(self, interaction: discord.Interaction) -> None:
        """A hard DELETE, unlike the soft delete a real account removal does.

        This is for the owner's own throwaway test character, and the point of
        it is to leave nothing behind — including the cascades, which is worth
        exercising deliberately now and then.
        """
        player = await require_player(interaction.user)
        await db.execute(
            "DELETE FROM players WHERE player_id = %s", (player["player_id"],)
        )
        await interaction.response.send_message(
            embed=embed(
                "Gone",
                "Your character and everything cascading from it is deleted. "
                "**/register** to start again.",
                colour=COLOUR_INFO,
            ),
            ephemeral=True,
        )


async def setup(bot: commands.Bot) -> None:
    await bot.add_cog(Dev(bot))
