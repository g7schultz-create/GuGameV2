"""The Discord half of the game.

`db/` owns the schema and the rules that live in SQL; this package owns the
commands, the embeds, and nothing else. Where a rule could plausibly live in
either place it lives in `db/`, so an ad-hoc psql query and a slash command
cannot disagree about what a technique does.
"""
