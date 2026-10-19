-- 0072_a_realm_crossed_tempers_the_body
--
-- The tenth consumer, and the only one that needed a new column on the way out.
--
-- Primordial Origin Body promises that "every realm crossed, two foundation
-- stats rise permanently". There is already exactly one thing in this game
-- that raises HP, defence and strength permanently, and it is physique XP - so
-- the promise is not a new mechanic, it is `apply_physique_xp` called from a
-- place that has never called it.
--
-- IT REPORTS WHAT IT BANKED. 0045 and 0058 both shipped a screen that told the
-- player what a function OFFERED rather than what it deposited, and both were
-- bugs. So `breakthrough` grows a `tempering_gained` column rather than
-- quietly granting body levels the breakthrough card does not mention - which
-- is a return type change, and therefore a DROP and a CREATE rather than a
-- CREATE OR REPLACE.
--
-- Forward-only. Do not edit once applied.

DROP FUNCTION breakthrough(BIGINT);

CREATE FUNCTION breakthrough(p_player_id BIGINT)
RETURNS TABLE (
    realm_before     SMALLINT,
    realm_after      SMALLINT,
    name_before      TEXT,
    name_after       TEXT,
    rank_before      SMALLINT,
    rank_after       SMALLINT,
    stage_after      TEXT,
    cultivation      BIGINT,
    next_ceiling     BIGINT,
    qi_capacity      BIGINT,
    essence_capacity BIGINT,
    gu_capacity      SMALLINT,
    aperture_gained  SMALLINT,
    techniques_freed INTEGER,
    tempering_gained BIGINT,
    body_levels      SMALLINT
)
LANGUAGE plpgsql
AS $$
DECLARE
    cult      player_cultivation%ROWTYPE;
    was       realms%ROWTYPE;
    becomes   realms%ROWTYPE;
    tempering BIGINT := 0;
    body_was  SMALLINT;
    body_now  SMALLINT;
BEGIN
    SELECT * INTO cult FROM player_cultivation
    WHERE player_id = p_player_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'player % has no cultivation row', p_player_id;
    END IF;

    SELECT * INTO was FROM realms WHERE realm_id = cult.realm_id;
    SELECT * INTO becomes FROM realms WHERE realm_id = cult.realm_id + 1;

    IF becomes.realm_id IS NULL THEN
        RAISE EXCEPTION 'there is nothing above % in this world', was.name
            USING ERRCODE = 'check_violation';
    END IF;

    IF cult.cultivation < becomes.cultivation_required THEN
        RAISE EXCEPTION
            'you hold % of the % needed to break into %',
            cult.cultivation, becomes.cultivation_required, becomes.name
            USING ERRCODE = 'check_violation';
    END IF;

    -- The tribulation goes here: a roll before this line, and an outcome
    -- column on the way out. Everything below is what surviving one is worth.
    UPDATE player_cultivation pc
    SET realm_id = becomes.realm_id
    WHERE pc.player_id = p_player_id;

    -- A body that grows on the crossing itself. Measured in body levels
    -- because that is the currency the promise is written in - "foundation
    -- stats rise permanently" is what a body level IS.
    SELECT pp.body_level INTO body_was
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    tempering := round(player_stat(p_player_id, 'realm_tempering')
                       * game_config_value('physique_xp_per_level'));

    IF tempering > 0 THEN
        PERFORM apply_physique_xp(p_player_id, tempering);
    END IF;

    SELECT pp.body_level INTO body_now
    FROM player_physique pp WHERE pp.player_id = p_player_id;

    RETURN QUERY
    SELECT was.realm_id, becomes.realm_id,
           was.name, becomes.name,
           was.rank, becomes.rank, becomes.stage,
           cult.cultivation,
           (SELECT after.cultivation_required FROM realms after
            WHERE after.realm_id = becomes.realm_id + 1),
           becomes.qi_capacity, becomes.essence_capacity,
           becomes.gu_capacity,
           (becomes.gu_capacity - was.gu_capacity)::smallint,
           (SELECT count(*)::integer FROM techniques t
            WHERE t.created_by IS NULL
              AND t.rank > was.rank AND t.rank <= becomes.rank),
           tempering,
           COALESCE(body_now - body_was, 0)::smallint;
END;
$$;

COMMENT ON FUNCTION breakthrough(BIGINT) IS
    'Takes the next realm, and tempers the body on the way through. The only thing that moves realm_id - which is what leaves room for a tribulation to stand in the way of it.';
