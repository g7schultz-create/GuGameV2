-- 0297_twenty_thunder_horns_for_grafv
--
-- Twenty Thunder Horns to grafv, who is holding none: the eighteen from the
-- earlier grant have all been spent.
--
-- A Thunder Horn is an uncommon beast material, so this is `grant_material`
-- and nothing else - the same call a hunt makes when one drops. Added to
-- whatever is held rather than set, which matters here only in that it will
-- keep being true if this is run against a purse that is no longer empty.
--
-- Forward-only. Do not edit once applied.


DO $$
DECLARE
    who    BIGINT;
    before BIGINT;
    after  BIGINT;
    gift   INTEGER := 20;
BEGIN
    SELECT player_id INTO who FROM players
    WHERE discord_name = 'grafv' AND deleted_at IS NULL;

    IF who IS NULL THEN
        RAISE EXCEPTION 'there is no live cultivator called grafv';
    END IF;

    SELECT COALESCE(quantity, 0) INTO before
    FROM player_materials
    WHERE player_id = who AND material_code = 'thunder_horn';
    before := COALESCE(before, 0);

    after := grant_material(who, 'thunder_horn', gift);

    IF after <> before + gift THEN
        RAISE EXCEPTION
            'grafv had % Thunder Horns, was given %, and now holds %',
            before, gift, after;
    END IF;

    -- Nothing else in the purse may have moved on the way past.
    IF EXISTS (
        SELECT 1 FROM player_materials
        WHERE player_id = who AND material_code = 'thunder_horn'
          AND quantity <> after
    ) THEN
        RAISE EXCEPTION 'the ledger disagrees with what was returned';
    END IF;

    RAISE NOTICE 'grafv: % Thunder Horns -> %', before, after;
END;
$$;
