"""Command groups, one module per system.

Modules here map to the layers in `db/migrations/`: paths, techniques,
bestiary, cultivation. Keeping that alignment means a new system arrives as a
migration plus a cog rather than as columns and branches spread through
whatever already existed.
"""
