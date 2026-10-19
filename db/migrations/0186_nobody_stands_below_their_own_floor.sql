-- 0186_nobody_stands_below_their_own_floor
--
-- `breakthrough` only moves a cultivator into a stage once they have met its
-- requirement, so "your cultivation is at least the floor of the realm you
-- are standing in" has always been true. Nothing states it, because nothing
-- had to - until 0184 raised the requirements under people who had already
-- passed them.
--
-- Five of eleven ended up below their own floor, and the progress bar reads
-- the difference:
--
--     -9,226 / 7,363 toward Core Formation - Early      -125%
--
-- The bar is not wrong. It is subtracting a floor from a total that is now
-- underneath it, which is a state the game could not previously produce.
--
--   m_i_y_u_k_i.  Core Formation - Mid            -12,501
--   grafv         Foundation Establishment - Peak  -9,226
--   pashu0        Foundation Establishment - Mid   -5,829
--   ._.visha._.   Foundation Establishment - Mid   -5,321
--   luckymate0_0  Foundation Establishment - Mid   -5,168
--
-- Lifting them to the floor restores the invariant every screen assumes. It
-- is not a gift: each of them met the requirement for the stage they are in
-- under the rules they played by, and 0184 moved it afterwards. The retune
-- still applies in full to the stage AHEAD of them, which is where it was
-- aimed.
--
-- The lesson for the next retune is in the check at the bottom: raising
-- `realms.cultivation_required` means topping up whoever is left behind it,
-- in the same migration.
--
-- Forward-only. Do not edit once applied.


UPDATE player_cultivation pc
SET cultivation = r.cultivation_required
FROM realms r
WHERE r.realm_id = pc.realm_id
  AND pc.cultivation < r.cultivation_required;


DO $$
DECLARE
    below TEXT;
BEGIN
    SELECT string_agg(p.discord_name || ' (' || r.name || ', '
                      || (pc.cultivation - r.cultivation_required) || ')',
                      ', ' ORDER BY p.discord_name)
    INTO below
    FROM player_cultivation pc
    JOIN players p ON p.player_id = pc.player_id
    JOIN realms r ON r.realm_id = pc.realm_id
    WHERE pc.cultivation < r.cultivation_required;

    IF below IS NOT NULL THEN
        RAISE EXCEPTION 'still standing below their own floor: %', below;
    END IF;

    -- Nobody was pushed PAST the next stage by the lift either - that would
    -- be handing out a breakthrough rather than restoring a floor.
    SELECT string_agg(p.discord_name, ', ' ORDER BY p.discord_name) INTO below
    FROM player_cultivation pc
    JOIN players p ON p.player_id = pc.player_id
    JOIN realms nxt ON nxt.realm_id = pc.realm_id + 1
    WHERE pc.cultivation >= nxt.cultivation_required
      AND pc.cultivation = (SELECT r2.cultivation_required FROM realms r2
                            WHERE r2.realm_id = pc.realm_id);

    IF below IS NOT NULL THEN
        RAISE EXCEPTION 'the lift carried somebody into the next stage: %', below;
    END IF;
END;
$$;
