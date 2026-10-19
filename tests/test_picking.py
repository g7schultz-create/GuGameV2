"""The 25-option ceiling, and the module that stops it hiding things.

These need no database: `bot.picking` is arithmetic and sorting, and the two
views exercised here are built from plain dicts. That is deliberate - a screen
whose paging can only be checked by owning 26 pills in a live database is a
screen whose paging never gets checked.
"""

import discord
import pytest

from bot.picking import (
    PER_PAGE,
    by_type_and_strength,
    page_count,
    page_note,
    page_of,
)


def pills(n: int) -> list[dict]:
    # Code and display name both, the way `fetch_pills` returns them - the
    # shelf reads the code to know that an insight pill asks where to go.
    kinds = (
        ("healing", "Healing"),
        ("cultivation", "Cultivation"),
        ("physique", "Body Tempering"),
        ("insight", "Insight"),
    )
    return [
        {
            "pill_id": i,
            "name": f"Pill {i}",
            "quantity": 1,
            "tier": (i % 7) + 1,
            "magnitude": 10 * i,
            "harmony": 50,
            "kind": kinds[i % len(kinds)][0],
            "kind_name": kinds[i % len(kinds)][1],
            "kind_emoji": "\N{PILL}",
            "kind_text": "does a thing",
            "path_code": "fire",
            "path_name": "Fire Path",
        }
        for i in range(n)
    ]


# ---------------------------------------------------------------------------
# Order
# ---------------------------------------------------------------------------


def test_it_groups_by_type_then_puts_the_strongest_first():
    rows = [
        {"name": "weak", "kind": "Healing", "tier": 1},
        {"name": "strong", "kind": "Healing", "tier": 5},
        {"name": "middling", "kind": "Healing", "tier": 3},
        {"name": "cult", "kind": "Cultivation", "tier": 2},
    ]
    out = by_type_and_strength(
        rows, kind=lambda r: r["kind"], strength=lambda r: r["tier"]
    )
    assert [r["name"] for r in out] == ["cult", "strong", "middling", "weak"]


def test_strength_may_be_a_tuple():
    """Rank first, stars second - which cannot be done by negating a number."""
    rows = [
        {"name": "a", "kind": "k", "rank": 1, "stars": 5},
        {"name": "b", "kind": "k", "rank": 2, "stars": 1},
        {"name": "c", "kind": "k", "rank": 2, "stars": 3},
    ]
    out = by_type_and_strength(
        rows, kind=lambda r: r["kind"], strength=lambda r: (r["rank"], r["stars"])
    )
    assert [r["name"] for r in out] == ["c", "b", "a"]


def test_ties_break_by_name_so_the_order_is_stable():
    rows = [
        {"name": "zeta", "kind": "k", "tier": 1},
        {"name": "alpha", "kind": "k", "tier": 1},
    ]
    out = by_type_and_strength(
        rows, kind=lambda r: r["kind"], strength=lambda r: r["tier"]
    )
    assert [r["name"] for r in out] == ["alpha", "zeta"]


# ---------------------------------------------------------------------------
# Pages
# ---------------------------------------------------------------------------


def test_every_row_is_on_exactly_one_page():
    """The whole point. `rows[:25]` put the 26th thing on no page at all."""
    rows = pills(103)
    seen = []
    for page in range(page_count(rows)):
        seen.extend(page_of(rows, page))
    assert len(seen) == len(rows)
    assert {id(r) for r in seen} == {id(r) for r in rows}


def test_no_page_is_bigger_than_discord_allows():
    for size in (0, 1, 25, 26, 51, 200):
        rows = pills(size)
        for page in range(page_count(rows)):
            assert len(page_of(rows, page)) <= PER_PAGE


def test_an_empty_list_still_has_one_page():
    assert page_count([]) == 1
    assert page_of([], 0) == []


def test_paging_wraps_rather_than_running_off_the_end():
    rows = pills(30)
    assert page_of(rows, 2) == page_of(rows, 0), "two pages, so page 2 is page 0"
    assert page_of(rows, -1) == page_of(rows, 1)


def test_the_note_is_silent_when_everything_fits():
    assert page_note(pills(25), 0, "batches") == ""
    assert page_note(pills(26), 0, "batches") != ""


def test_the_note_counts_from_one_and_names_the_last():
    note = page_note(pills(60), 1, "batches")
    assert "Page 2 of 3" in note
    assert "batches 26" in note and "50 of 60" in note


# ---------------------------------------------------------------------------
# The screens that use it
# ---------------------------------------------------------------------------


def pages_across_paths(spread: dict[str, int]) -> list[dict]:
    """Manual pages, so many to a Path, as `/refine` reads them."""
    made = []
    for code, n in spread.items():
        for i in range(n):
            made.append({
                "page_id": len(made) + 1,
                "tier": (i % 5) + 1,
                "power": 100 + i,
                "quality": 50,
                "path_code": code,
                "path_name": f"{code.title()} Path",
                "type_code": "attack",
                "type_name": "Attack",
                "trait_name": None,
            })
    return made


class Someone:
    id = 1
    display_name = "Tester"


def test_the_pill_shelf_pages_and_groups():
    from bot.cogs.alchemy import ShelfView

    view = ShelfView(1, Someone(), pills(60))
    assert view.page_count() == 3

    select = next(c for c in view.children if isinstance(c, discord.ui.Select))
    assert len(select.options) == PER_PAGE, "Discord would refuse more"

    # Grouped: the first page is one kind, strongest first.
    kinds = [r["kind_name"] for r in view.sorted_rows]
    assert kinds == sorted(kinds), "kinds are contiguous"

    # And every pill is reachable.
    reachable = set()
    for page in range(view.page_count()):
        view.page = page
        view.build()
        select = next(c for c in view.children if isinstance(c, discord.ui.Select))
        reachable.update(o.value for o in select.options)
    assert len(reachable) == 60


def test_a_short_shelf_has_no_page_buttons():
    from bot.cogs.alchemy import ShelfView

    view = ShelfView(1, Someone(), pills(5))
    assert not [c for c in view.children if isinstance(c, discord.ui.Button)]


def test_the_shelf_embed_shows_the_page_it_is_on():
    from bot.cogs.alchemy import ShelfView

    view = ShelfView(1, Someone(), pills(60))
    first = view.card()
    view.page = 1
    view.build()
    second = view.card()
    assert first.fields[1].value != second.fields[1].value, "the page moved"
    assert "Page 2 of 3" in second.footer.text


# ---------------------------------------------------------------------------
# The refinement shelf, which can be arranged three ways
# ---------------------------------------------------------------------------


def manual_pages(n: int) -> list[dict]:
    # Code and name both, the way the command's own query returns them - the
    # Path filter keys on the code and the shelf tallies by the name.
    paths = (("fire", "Fire Path"), ("water", "Water Path"),
             ("sword", "Sword Path"))
    # Code and name both here too, for the same reason: the kind filter
    # keys on the code and the menu labels with the name.
    types = (("attack", "Attack"), ("defense", "Defense"),
             ("cultivation", "Cultivation"), ("speed", "Speed"))
    return [
        {
            "page_id": i,
            "tier": (i % 3) + 1,
            "power": 20 - (i % 7),
            "quality": 50 + (i % 40),
            "path_code": paths[i % len(paths)][0],
            "path_name": paths[i % len(paths)][1],
            "type_code": types[i % len(types)][0],
            "type_name": types[i % len(types)][1],
            "trait_name": None,
        }
        for i in range(n)
    ]


def a_shelf(n: int = 40):
    from bot.cogs.refine import RefineView

    return RefineView(1, Someone(), manual_pages(n), cap=5)


def test_the_shelf_opens_grouped_by_path():
    """Path is the default because +6 against -5 is the widest swing on the
    score `refine_forecast` gives a batch."""
    assert a_shelf().group == "path"


def test_each_arrangement_actually_regroups():
    from bot.cogs.refine import GROUPINGS

    view = a_shelf()
    orders = {}
    for code, _, key, _ in GROUPINGS:
        view.group = code
        orders[code] = [p["page_id"] for p in view.sorted_pages()]
    assert len({tuple(o) for o in orders.values()}) == 3, "three real orders"


def test_a_group_is_contiguous_however_it_is_arranged():
    from bot.cogs.refine import GROUPINGS

    view = a_shelf()
    for code, _, key, _ in GROUPINGS:
        view.group = code
        seen = [p[key] for p in view.sorted_pages()]
        # Every run of a value appears once: that is what "grouped" means, and
        # it is the whole reason the screen is easier to read.
        runs = [v for i, v in enumerate(seen) if i == 0 or seen[i - 1] != v]
        assert len(runs) == len(set(runs)), f"{code} scatters its groups"


def test_no_page_is_lost_by_rearranging():
    from bot.cogs.refine import GROUPINGS

    view = a_shelf()
    everything = {p["page_id"] for p in view.pages}
    for code, _, _, _ in GROUPINGS:
        view.group = code
        assert {p["page_id"] for p in view.sorted_pages()} == everything


def test_every_page_is_still_reachable_by_paging():
    view = a_shelf(60)
    reachable = set()
    for page in range(view.page_count()):
        view.page = page
        view.build()
        select = next(c for c in view.children if isinstance(c, discord.ui.Select))
        assert len(select.options) <= PER_PAGE
        reachable.update(o.value for o in select.options)
    assert len(reachable) == 60


def test_the_shelf_counts_what_pairs():
    """The counts are the useful half: "four Attack pages" is what says a good
    refinement is available, and it is the number the +5 term is paid on."""
    view = a_shelf(12)
    view.group = "type"
    card = view.card()
    tally = card.fields[0].value
    assert "Attack" in tally
    assert "✅" in tally, "a group of two or more is marked"


def test_a_shelf_of_strangers_says_so():
    from bot.cogs.refine import RefineView

    lonely = manual_pages(3)
    for i, p in enumerate(lonely):
        p["path_code"] = f"path{i}"
        p["path_name"] = f"Path {i}"
    view = RefineView(1, Someone(), lonely, cap=5)
    card = view.card()
    assert any("Nothing pairs" in f.name for f in card.fields)


def test_tier_groups_sort_as_numbers():
    """Ten before two is what casting a tier to text would give."""
    from bot.cogs.refine import RefineView

    pages = manual_pages(4)
    for p, tier in zip(pages, (2, 10, 1, 10)):
        p["tier"] = tier
    view = RefineView(1, Someone(), pages, cap=5)
    view.group = "tier"
    assert [p["tier"] for p in view.sorted_pages()] == [1, 2, 10, 10]


# ---------------------------------------------------------------------------
# The Path slot on /refine
#
# A refinement draws only from the pages in front of it: Discord posts a
# multi-select's values on submit, so turning the page throws away what was
# ticked on the one before. At 500 pages across 34 Paths that made combining
# two named Paths impossible unless they happened to land in the same slice
# of 25 - and there was no way to make them.
# ---------------------------------------------------------------------------


def test_filtering_to_two_paths_puts_every_page_of_both_in_reach():
    from bot.cogs.refine import RefineView

    view = RefineView(
        1, Someone(),
        pages_across_paths({"lightning": 2, "wind": 3, "poison": 40}),
        6,
    )
    select = next(c for c in view.children if isinstance(c, discord.ui.Select)
                  and c.row == 0)
    assert len(select.options) == PER_PAGE, "unfiltered, the shelf is one slice"

    view.chosen_paths = {"lightning", "wind"}
    view.page = 0
    view.build()

    select = next(c for c in view.children if isinstance(c, discord.ui.Select)
                  and c.row == 0)
    assert len(select.options) == 5, (
        "all five Lightning and Wind pages have to be on one screen, because "
        "that is the only place a refinement can draw from"
    )
    assert view.page_count() == 1, "five pages should not be spread over slices"


def test_paths_from_different_slices_can_be_chosen_together():
    """More Paths than a select holds, so the filter slices too.

    A chosen Path now rides along on every slice rather than living only on
    the one it came from. That is what makes it visible after the page is
    turned - it used to disappear from the dropdown while still narrowing the
    shelf, which reads as the filter having been cleared - and it is also what
    lets it be unticked from anywhere.
    """
    from bot.cogs.refine import PATHS_PER_SLICE, RefineView

    spread = {f"p{i:02d}": 30 - i for i in range(PATHS_PER_SLICE + 5)}
    view = RefineView(1, Someone(), pages_across_paths(spread), 6)
    assert view.path_slice_count() == 2

    first = [code for code, _, _ in view.path_slice()]
    view.apply_path_choice([first[0]])
    assert view.chosen_paths == {first[0]}

    view.path_page = 1
    second = [code for code, _, _ in view.path_slice()]
    assert first[0] in second, "a chosen Path has to ride along on every slice"

    # It is shown already ticked, so keeping it and adding another is one
    # submission carrying both.
    other = next(code for code in second if code != first[0])
    view.apply_path_choice([first[0], other])
    assert view.chosen_paths == {first[0], other}, (
        "answering the second slice threw away the first slice's choice"
    )

    # And what you see is what you get: a slice showing both, answered with
    # nothing, takes both off.
    view.apply_path_choice([])
    assert view.chosen_paths == set()


def test_a_filter_down_to_one_page_still_offers_it_and_says_why():
    """This used to show no picker at all.

    The select asked for two pages at once and Discord refuses a select whose
    min_values exceeds its options, so a one-page filter had to hide it. The
    batch is kept by the screen now and the select asks for none, so the lone
    page is offered - it pairs with one from another Path or another screen -
    while the card still says a refinement needs two.
    """
    from bot.cogs.refine import RefineView

    view = RefineView(
        1, Someone(), pages_across_paths({"rule": 1, "poison": 6}), 6
    )
    view.chosen_paths = {"rule"}
    view.build()

    picker = next(c for c in view.children
                  if isinstance(c, discord.ui.Select) and c.row == 0)
    assert len(picker.options) == 1
    assert picker.min_values == 0, "a select nobody can answer is on the screen"
    told = "\n".join(f.value for f in view.card().fields)
    assert "needs two" in told, told

    # Found by class rather than by label: it read "All Paths" until the kind
    # filter arrived and it became "Clear filters", and what this test cares
    # about is that the way back exists and is pressable, not what it says.
    from bot.cogs.refine import ClearFilter

    back = next(c for c in view.children if isinstance(c, ClearFilter))
    assert not back.disabled, "no way back off a filter with nothing in it"


def test_no_select_on_the_refine_screen_asks_for_more_than_it_shows():
    """The invariant behind the one above, asked of every arrangement and
    every slice rather than of the case that happened to break."""
    from bot.cogs.refine import RefineView

    view = RefineView(
        1, Someone(),
        pages_across_paths({"lightning": 1, "wind": 1, "poison": 30}),
        6,
    )
    for group in ("path", "type", "tier"):
        for chosen in (set(), {"lightning"}, {"lightning", "wind"}, {"poison"}):
            view.group = group
            view.chosen_paths = set(chosen)
            view.page = 0
            view.build()
            for item in view.children:
                if isinstance(item, discord.ui.Select):
                    assert item.min_values <= len(item.options), (
                        f"{group}/{chosen}: {item.placeholder!r} asks for "
                        f"{item.min_values} of {len(item.options)}"
                    )
                    assert item.max_values <= len(item.options)
                    assert len(item.options) <= PER_PAGE


# ---------------------------------------------------------------------------
# The technique catalogue
# ---------------------------------------------------------------------------


def techniques(n: int) -> list[dict]:
    """Shelf rows as `technique_shelf` returns them."""
    paths = ("Fire Path", "Ice Path", "Sword Path", "Shadow Path")
    return [
        {
            "technique_id": i,
            "name": f"Move {i}",
            "tech_rank": (i % 9) + 1,
            "grade": "advanced" if i % 7 == 0 else "basic",
            "category": "attack",
            "base_power": 100 * (i + 1),
            "typing": paths[i % len(paths)],
            "path_name": paths[i % len(paths)],
            "need_tier": 0,
            "need_tier_name": "Uninitiated",
            "have_tier": 0,
            "stone_cost": 25 * ((i % 5) + 1),
            "stones_held": 5000,
            "manual_id": None,
            "manual_name": None,
            "manual_held": False,
            "known": i % 4 == 0,
            "on_loan": False,
            "realm_ok": True,
            "tier_ok": True,
            "stones_ok": True,
            "ready": i % 3 == 0,
            "study_cost": 0,
            "study_ready": False,
        }
        for i in range(n)
    ]


def test_the_technique_shelf_narrows_without_losing_anything():
    """A hundred rows at eight to a page is thirteen pages, and the only way
    to narrow it was a command argument you had to know existed - and could
    not change without running the command again."""
    from bot.cogs.techniques import Shelf

    rows = techniques(100)
    view = Shelf(rows, "Techniques", 5000, {0: "Uninitiated"})
    assert len(view.matching()) == 100

    view.narrow = "ready"
    ready = view.matching()
    assert 0 < len(ready) < 100
    assert all(r["ready"] for r in ready)

    # Narrowing is reversible from the screen, which is the whole point.
    view.narrow = "all"
    assert len(view.matching()) == 100

    # And rank cuts across the filter rather than replacing it.
    view.rank = 3
    assert {r["tech_rank"] for r in view.matching()} == {3}
    view.rank = None
    assert len(view.matching()) == 100


def test_every_ordering_keeps_every_row():
    """A sort that drops rows is a sort that hides techniques - the failure
    this screen already had once with `rows[:25]`."""
    from bot.cogs.techniques import SHELF_SORTS, Shelf

    rows = techniques(60)
    view = Shelf(rows, "Techniques", 5000, {0: "Uninitiated"})
    for code, _, _, _ in SHELF_SORTS:
        view.sort = code
        got = view.matching()
        assert len(got) == 60, f"{code} lost rows"
        assert {r["technique_id"] for r in got} == {r["technique_id"] for r in rows}


def test_sorting_by_path_groups_a_path_together():
    """A technique's Path is its type here, and "what is there on my Path" is
    the question a hundred-row catalogue is usually being asked."""
    from bot.cogs.techniques import Shelf

    view = Shelf(techniques(60), "Techniques", 5000, {0: "Uninitiated"})
    view.sort = "path"
    names = [r["path_name"] for r in view.matching()]
    assert names == sorted(names), "a Path is split across the list"


def test_every_page_of_the_shelf_is_reachable():
    from bot.cogs.techniques import Shelf

    view = Shelf(techniques(100), "Techniques", 5000, {0: "Uninitiated"})
    seen = set()
    for page in range(view.page_count()):
        view.page = page
        shown = view.matching()
        here = shown[page * 8:(page + 1) * 8]
        seen.update(r["technique_id"] for r in here)
    assert len(seen) == 100, f"{100 - len(seen)} techniques cannot be paged to"


# ---------------------------------------------------------------------------
# A chosen Path stays visible however the screen is paged
# ---------------------------------------------------------------------------


def many_path_pages(paths: int = 34, each: int = 4) -> list[dict]:
    """More Paths than a select holds, which is where the filter came apart."""
    return [
        {
            "page_id": p * each + i,
            "tier": (i % 3) + 1,
            "power": 20 - (i % 7),
            "quality": 50 + (i % 40),
            "path_code": f"path{p:02d}",
            "path_name": f"Path {p:02d} Path",
            "type_code": "attack",
            "type_name": "Attack",
            "trait_name": None,
        }
        for p in range(paths)
        for i in range(each)
    ]


def a_wide_shelf(paths: int = 34):
    from bot.cogs.refine import RefineView

    return RefineView(1, Someone(), many_path_pages(paths), cap=5)


def _filter_select(view):
    from bot.cogs.refine import PathFilter

    return next(c for c in view.children if isinstance(c, PathFilter))


def test_a_chosen_path_is_still_ticked_on_the_next_slice():
    """The filter was never cleared by turning the page - it was made
    invisible. A Path chosen on one slice of the dropdown did not appear on
    the next, so the shelf was still narrowed while the control that narrowed
    it looked untouched."""
    view = a_wide_shelf()
    assert view.path_slice_count() > 1, "this shelf no longer needs slicing"

    view.apply_path_choice(["path00"])
    view.build()
    assert [o.value for o in _filter_select(view).options if o.default] == ["path00"]

    view.path_page = 1
    view.build()
    assert [o.value for o in _filter_select(view).options if o.default] == ["path00"], (
        "the chosen Path vanished from the dropdown on another slice"
    )
    assert view.chosen_paths == {"path00"}


def test_turning_the_shelf_page_leaves_the_filter_alone():
    view = a_wide_shelf()
    view.apply_path_choice(["path00"])
    view.build()
    narrowed = len(view.visible_pages())

    view.page = (view.page + 1) % view.page_count()
    view.build()

    assert view.chosen_paths == {"path00"}
    assert len(view.visible_pages()) == narrowed
    assert [o.value for o in _filter_select(view).options if o.default] == ["path00"]


def test_a_path_can_be_unticked_from_any_slice():
    """It rides along on every slice, so it can be taken off from any of them
    rather than only from the one it was chosen on."""
    view = a_wide_shelf()
    view.apply_path_choice(["path00"])
    view.path_page = 1
    view.build()

    view.apply_path_choice([])
    assert view.chosen_paths == set(), "the Path could not be unticked from here"


def test_the_filter_never_offers_more_than_a_select_holds():
    """Pinned Paths take room from the browsable ones rather than adding to
    them - Discord refuses a select with 26 options outright."""
    from bot.picking import PER_PAGE

    view = a_wide_shelf()
    for chosen in (1, 10, 24, 30, 34):
        view.chosen_paths = {code for code, _, _ in view.held_paths()[:chosen]}
        for slice_no in range(view.path_slice_count()):
            view.path_page = slice_no
            view.build()
            assert len(_filter_select(view).options) <= PER_PAGE, (
                f"{chosen} chosen on slice {slice_no} offered "
                f"{len(_filter_select(view).options)} options"
            )


def test_a_shelf_with_few_paths_still_shows_them_all():
    """The pinning must not start slicing a screen that never needed it."""
    view = a_wide_shelf(paths=3)
    view.apply_path_choice(["path00"])
    view.build()
    assert view.path_slice_count() == 1
    assert len(_filter_select(view).options) == 3


# ---------------------------------------------------------------------------
# Ticked pages survive a page turn
# ---------------------------------------------------------------------------


def _page_select(view):
    from bot.cogs.refine import PageSelect

    return next(c for c in view.children if isinstance(c, PageSelect))


def _ticked(view):
    return {int(o.value) for o in _page_select(view).options if o.default}


def _on_screen(view):
    from bot.picking import page_of

    return [p["page_id"] for p in page_of(view.sorted_pages(), view.page)]


def test_a_ticked_page_is_still_ticked_after_turning_the_page_and_back():
    """clearwest: 'the first one i check it but when i turn the next page and
    turn it back to that page its unchecked'.

    Discord hands back only what was on the screen that was submitted, so the
    select cannot hold a batch by itself. The screen holds it instead.
    """
    view = a_shelf(60)
    here = _on_screen(view)

    view.apply_page_choice(here, here[:2])
    view.build()
    assert _ticked(view) == set(here[:2])

    view.page = 1
    view.build()
    assert _ticked(view) == set(), "another screen's pages should not be ticked"
    assert view.picked == set(here[:2]), "turning the page threw the batch away"

    view.page = 0
    view.build()
    assert _ticked(view) == set(here[:2]), (
        "the ticks did not come back when the page did"
    )


def test_a_batch_can_be_gathered_from_more_than_one_page():
    """The whole point: a refinement is up to eight pages and a screen holds
    twenty-five, so a batch that spans screens has to be possible."""
    view = a_shelf(60)
    first = _on_screen(view)
    view.apply_page_choice(first, first[:2])

    view.page = 1
    view.build()
    second = _on_screen(view)
    view.apply_page_choice(second, second[:1])

    assert view.picked == set(first[:2]) | set(second[:1])
    assert view.ordered_picks() == sorted(
        view.picked, key=lambda i: [p["page_id"] for p in view.sorted_pages()].index(i)
    ), "the batch is not in the order the shelf is arranged"


def test_a_page_can_be_unticked_where_it_was_ticked():
    view = a_shelf(60)
    here = _on_screen(view)
    view.apply_page_choice(here, here[:2])
    view.apply_page_choice(here, [here[0]])
    assert view.picked == {here[0]}

    view.apply_page_choice(here, [])
    assert view.picked == set()


def test_the_refine_button_waits_for_two_and_refuses_more_than_the_cap():
    from bot.cogs.refine import RefineNowButton

    view = a_shelf(60)
    here = _on_screen(view)

    def button():
        view.build()
        return next(c for c in view.children if isinstance(c, RefineNowButton))

    assert button().disabled, "an empty cauldron offered a refinement"

    view.apply_page_choice(here, here[:1])
    assert button().disabled, "one page is not a refinement"

    view.apply_page_choice(here, here[:2])
    assert not button().disabled

    view.apply_page_choice(here, here[: view.cap + 1])
    assert button().disabled, "more pages than the cauldron holds was allowed"


def test_one_page_on_a_screen_is_still_offered():
    """It used to be hidden, because the select asked for two at once and
    Discord refuses a select whose min_values exceeds its options. It asks for
    none now, and a lone page pairs with one from another screen."""
    from bot.cogs.refine import RefineView

    view = RefineView(1, Someone(), pages_across_paths({"rule": 1, "poison": 6}), 6)
    view.chosen_paths = {"rule"}
    view.build()

    select = _page_select(view)
    assert len(select.options) == 1
    assert select.min_values == 0
