-- 0175_an_emoji_is_not_a_python_escape
--
-- 0174 wrote its four emoji as `\N{NEW MOON SYMBOL}` and the like. That is
-- Python's syntax for a named character; Postgres has never heard of it and
-- stored the nineteen literal characters. Every screen that draws one of the
-- new materials would print a backslash and a word in braces where an icon
-- should be.
--
-- The bot's source is full of `\N{...}` because it is Python. A migration is
-- not, and the habit crossed a language boundary without complaining. So the
-- fix is the characters themselves, and a check that no material carries an
-- emoji with a backslash in it - which is the shape of this mistake and of no
-- correct value.
--
-- Forward-only. Do not edit once applied.


UPDATE materials SET emoji = '🌑' WHERE code = 'nightsilver';
UPDATE materials SET emoji = '✨' WHERE code = 'crescent_horn';
UPDATE materials SET emoji = '❄️' WHERE code = 'frost_scale';
UPDATE materials SET emoji = '⚡' WHERE code = 'thunder_horn';


DO $$
DECLARE
    wrong TEXT;
BEGIN
    SELECT string_agg(m.code || ' (' || m.emoji || ')', ', ' ORDER BY m.code)
    INTO wrong
    FROM materials m
    WHERE m.emoji LIKE '%\%' OR m.emoji LIKE '%{%' OR m.emoji = '';

    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION 'these are not emoji: %', wrong;
    END IF;

    -- The four from 0174 specifically, since they are why this exists.
    SELECT string_agg(m.code, ', ' ORDER BY m.code) INTO wrong
    FROM materials m
    WHERE m.code IN ('nightsilver', 'crescent_horn', 'frost_scale', 'thunder_horn')
      AND length(m.emoji) > 4;

    IF wrong IS NOT NULL THEN
        RAISE EXCEPTION 'still carrying an escape sequence: %', wrong;
    END IF;
END;
$$;
