-- Implements the FAUST CTF Scoring Formula as per: https://2022.faustctf.net/information/rules/


-- #### flag points MATERIALIZED VIEW #####

DROP MATERIALIZED VIEW IF EXISTS "scoreboard_v2_flag_points";

-- calculates for each flag:
-- - the bonus part of the attack points:
--   "offense += (1 / count(all_captures_of[flag]))"
-- - the defense points:
--   "count(all_captures_of[flag]) ** 0.75"
CREATE MATERIALIZED VIEW "scoreboard_v2_flag_points" AS
WITH
  -- calculate the captures of a flag_id in a tick
  -- sparse so only captures >= 1 are in the result
  captures_per_tick AS (
    SELECT scoring_capture.tick,
           scoring_capture.flag_id,
           COUNT(*) as captures
    FROM scoring_capture
    GROUP BY scoring_capture.tick, scoring_capture.flag_id
  ),
  -- calculate the total captures of a flag_id up to a tick
  -- sparse so only changed all_captures are in the result
  all_captures_of_flag AS (
    SELECT tick, flag_id,
           SUM(captures) over(PARTITION BY flag_id ORDER BY tick) as all_captures
    FROM captures_per_tick
  ),
  -- Calculate the rank of each team based on their current score at the specific tick
  team_ranks AS (
    select team_id,
           tick + 1 AS tick, -- adding 1 because score calculation needs ranks from the previous ticks
           SUM(attack+defense+sla) AS total,
           dense_rank() OVER(partition by tick order by sum(attack+defense+sla) DESC) AS rank 
    from scoreboard_v2_board 
    group by team_id, tick order by tick DESC
  ),

  -- Calculate the rank difference between the attacker's team and the victim's team for each attack
  rank_difference AS (
    SELECT scoring_capture.tick,
           scoring_capture.flag_id AS flag_id,
           capturing_team_id AS attacker_team_id,
           tr_a.rank AS attacker_rank,
           scoring_flag.protecting_team_id AS victim_team_id,
           tr_p.rank AS victim_rank,
           tr_a.rank - tr_p.rank AS rank_diff
    FROM scoring_capture
    INNER JOIN scoring_flag ON scoring_capture.flag_id = scoring_flag.id
    INNER JOIN team_ranks tr_a ON scoring_capture.capturing_team_id = tr_a.team_id AND scoring_capture.tick = tr_a.tick
    INNER JOIN team_ranks tr_p ON scoring_flag.protecting_team_id = tr_p.team_id AND scoring_capture.tick = tr_p.tick
  ),

  -- Calculate the attack bonus for each flag based on the rank difference
  flag_points_per_tick AS (
    SELECT all_captures_of_flag.tick,
           all_captures_of_flag.flag_id,
           all_captures,
           attacker_team_id,
           attacker_rank,
           victim_team_id,
           victim_rank,
           rank_diff,
           CASE 
             WHEN all_captures_of_flag.tick = 0 OR rank_diff = 0 THEN (float8 '1.0' / all_captures) + float8 '1.0'  -- Handle tick 0 separately
             ELSE (float8 '1.0' / all_captures) + (float8 '0.1' * rank_diff)
           END AS attack_bonus,
           POWER(all_captures, float8 '0.75') AS defense
           -- Calculate the modified attack bonus based on the rank difference
    FROM all_captures_of_flag
    -- Join with rank_difference to get the rank difference for each flag capture
    LEFT JOIN rank_difference ON all_captures_of_flag.tick = rank_difference.tick AND all_captures_of_flag.flag_id = rank_difference.flag_id
    order by tick, flag_id
  ),
 -- flag_points_per_tick AS (
    -- calculate:
    -- the attack bonus (1 / count(all_captures_of[flag]) and
    -- the defense points (count(all_captures_of[flag]) ** 0.75)
    -- per tick and flag
   -- SELECT tick, flag_id,
     --      float8 '1.0' / all_captures as attack_bonus,
       --    POWER(all_captures, float8 '0.75') as defense
    --FROM all_captures_of_flag
  --),
  flag_points_development AS (
    -- convert the value per tick to a difference to the previous tick's value
    -- We do this so we can add up the points in the recurisve CTE
    -- e.g. if a flag is captured 2 times @ tick 100 and 3 times @ tick 101
    -- it will generate the following output:
    -- |tick|attack_bonus_delta| defense_delta |
    -- | 100|               0.5|        2**0.75|
    -- | 101|(1/5)-(1/2) = -0.3|5**0.75-2**0.75|
    SELECT tick, flag_id,
           attack_bonus,
           attack_bonus - coalesce(lag(attack_bonus) OVER (PARTITION BY flag_id ORDER BY tick), float '0.0') as attack_bonus_delta,
           defense - coalesce(lag(defense) OVER (PARTITION BY flag_id ORDER BY tick), float '0.0') as defense_delta
    FROM flag_points_per_tick
  )
SELECT flag_points_development.tick,
       flag_id,
       scoring_service.service_group_id AS service_group_id,
       attack_bonus,  -- Use the modified attack bonus
       attack_bonus_delta,
       defense_delta
FROM flag_points_development
INNER JOIN scoring_flag ON scoring_flag.id = flag_id
INNER JOIN scoring_service ON scoring_service.id = service_id;
--SELECT flag_points_development.tick,
--       flag_id,
--       scoring_service.service_group_id as service_group_id,
--       attack_bonus, attack_bonus_delta, defense_delta
--FROM flag_points_development
--INNER JOIN scoring_flag ON scoring_flag.id = flag_id
--INNER JOIN scoring_service ON scoring_service.id = service_id;

CREATE INDEX flag_points_per_tick
  ON "scoreboard_v2_flag_points" (tick, flag_id, service_group_id, attack_bonus, attack_bonus_delta, defense_delta);




-- ALTER MATERIALIZED VIEW "scoreboard_v2_flag_points" OWNER TO gameserver_controller;
-- GRANT SELECT on TABLE "scoreboard_v2_flag_points" TO gameserver_web;


--### rankings materialized view
--DROP MATERIALIZED VIEW IF EXISTS "scoreboard_v2_board_with_rankings";
---- This is an extension of the previous "scoreboard_v2_board" materialized view
---- Now includes team rankings for each tick based on their scores
--
--CREATE MATERIALIZED VIEW "scoreboard_v2_board_with_rankings" AS
--WITH RECURSIVE
--  -- ... (The existing CTEs from the original "scoreboard_v2_board" materialized view go here) ...
--  -- (You can keep all the existing CTEs from the original "scoreboard_v2_board" materialized view unchanged)
--  -- Calculate team rankings for each tick
--  rankings AS (
--    SELECT
--      tick,
--      team_id,
--      RANK() OVER (PARTITION BY tick ORDER BY (attack + defense + sla) DESC) AS ranking
--    FROM scoreboard_v2_board
--  )
--SELECT
--  b.tick,
--  b.team_id,
--  b.flags_captured,
--  b.attack,
--  b.flags_lost,
--  b.defense,
--  b.sla,
--  r.ranking
--FROM scoreboard_v2_board b
--JOIN rankings r ON b.tick = r.tick AND b.team_id = r.team_id
--ORDER BY b.tick, r.ranking;



-- #### scoreboard MATERIALIZED VIEW ####

DROP TABLE IF EXISTS "scoreboard_v2_board";
DROP MATERIALIZED VIEW IF EXISTS "scoreboard_v2_board";

-- This makes heavy use of RECURSIVE CTEs:
-- https://www.postgresql.org/docs/14/queries-with.html#QUERIES-WITH-RECURSIVE
-- We do this to calculate the score based on the previous tick

CREATE MATERIALIZED VIEW "scoreboard_v2_board" AS
WITH RECURSIVE
  -- calculate the max tick of the scoreboard.
  -- Normally this is current_tick - 1 because the current_tick is running and thus does not have final scoring
  -- However on game end we want the scoreboard to include the current_tick==last tick as current_tick is not incremented on game end
  max_scoreboard_tick AS (
    SELECT CASE WHEN (
      -- Check if the game is still running
      -- Use a slack of 1 sec to avoid time sync issues
      SELECT ("end" - INTERVAL '1 sec') > NOW() FROM scoring_gamecontrol
    ) THEN (
      -- game is running - avoid current_tick
      SELECT current_tick - 1 FROM scoring_gamecontrol 
    ) ELSE (
      -- game ended - include current_tick
      SELECT current_tick from scoring_gamecontrol
    ) END
  ),
  valid_ticks AS (
    SELECT valid_ticks from scoring_gamecontrol
  ),
  servicegroup AS (
    SELECT scoring_service.service_group_id AS service_group_id,
           count(scoring_service.id) AS services_count
    FROM scoring_service
    GROUP BY scoring_service.service_group_id
  ),
  -- all teams considered for scoreboard - must be is_active and not NOP-Team
  teams as (
    SELECT user_id as team_id
    FROM registration_team
    INNER JOIN auth_user ON auth_user.id = registration_team.user_id
    WHERE is_active = true
          AND nop_team = false
  ),
  -- calculate flags_captured using Recursive CTE
  flags_captured(tick, team_id, service_group_id, flags_captured) AS (
    -- inital value of recursion:
    -- Get the first capture of each team and service, go back 1 tick and assign 0 captures
    SELECT min(scoring_capture.tick)-1 as tick,
           capturing_team_id as team_id,
           service_group_id,
           integer '0'
    FROM scoring_capture
    INNER JOIN scoring_flag ON scoring_capture.flag_id = scoring_flag.id
    INNER JOIN scoring_service ON scoring_service.id = service_id
    GROUP BY capturing_team_id, service_group_id
   UNION ALL
    -- recursion step:
    -- increment tick and add captures for tick
    SELECT prev_tick.tick + 1,
           prev_tick.team_id,
           prev_tick.service_group_id,
           prev_tick.flags_captured
           -- calculate the captures for this tick, team and service
            + coalesce((SELECT COUNT(*)
             FROM scoring_capture
             INNER JOIN scoring_flag ON scoring_capture.flag_id = scoring_flag.id
             INNER JOIN scoring_service ON scoring_service.id = scoring_flag.service_id
              AND scoring_service.service_group_id = prev_tick.service_group_id
             WHERE scoring_capture.tick = prev_tick.tick + 1
              AND scoring_capture.capturing_team_id = prev_tick.team_id), 0)::integer
    FROM flags_captured prev_tick
    -- perform recursion until max_scoreboard_tick
    WHERE prev_tick.tick + 1 <= (SELECT * FROM max_scoreboard_tick)
  ),
  -- calculate the attack bonus using Recursive CTE
  attack_bonus(tick, team_id, service_group_id, attack_bonus) AS (
    -- inital value of recursion:
    -- Get the first capture of each team and service, go back 1 tick and assign score 0.0
    SELECT min(scoring_capture.tick) - 1,
           capturing_team_id as team_id,
           service_group_id,
           float8 '0.0'
    FROM scoring_capture
    INNER JOIN scoring_flag ON scoring_flag.id = scoring_capture.flag_id
    INNER JOIN scoring_service ON scoring_service.id = service_id
    GROUP BY capturing_team_id, service_group_id
   UNION ALL
    -- recursion step:
    -- increment tick and add attack bonus increment for tick
    SELECT prev_tick.tick + 1,
           prev_tick.team_id,
           prev_tick.service_group_id,
           prev_tick.attack_bonus
           -- for each flag captured in this tick get the attack_bonus from this tick
            + coalesce((SELECT SUM(points.attack_bonus)
             FROM scoreboard_v2_flag_points points
             -- inner join scoring_capture for each flag captured in this tick
             INNER JOIN scoring_capture ON scoring_capture.flag_id = points.flag_id
              AND scoring_capture.capturing_team_id = prev_tick.team_id
              AND scoring_capture.tick = prev_tick.tick + 1
             -- points from this tick
             WHERE points.tick = prev_tick.tick + 1
              AND points.service_group_id = prev_tick.service_group_id), float8 '0.0')
           -- for each flag captured in a previous tick get the attack_bonus_delta in this tick
            + coalesce((SELECT SUM(points.attack_bonus_delta)
             FROM scoreboard_v2_flag_points points
             -- inner join scoring_capture for each flag captured in a previous tick - limit to valid_ticks for performance 
             INNER JOIN scoring_capture ON scoring_capture.flag_id = points.flag_id
              AND scoring_capture.capturing_team_id = prev_tick.team_id
              AND prev_tick.tick + 1 - (SELECT * from valid_ticks) < scoring_capture.tick
              AND scoring_capture.tick < prev_tick.tick + 1
             -- points from this tick
             WHERE points.tick = prev_tick.tick + 1
              AND points.service_group_id = prev_tick.service_group_id), float8 '0.0')
    FROM attack_bonus prev_tick
    -- perform recursion until max_scoreboard_tick
    WHERE prev_tick.tick + 1 <= (SELECT * FROM max_scoreboard_tick)
  ),
  -- calculate flags_lost using Recursive CTE
  flags_lost(tick, team_id, service_group_id, flags_lost) AS (
    -- inital value of recursion:
    -- Get the first capture from each team and service, go back 1 ticks and assign 0 captures
    SELECT min(scoring_capture.tick)-1 as tick,
           protecting_team_id as team_id,
           service_group_id,
           integer '0'
    FROM scoring_flag
    INNER JOIN scoring_capture ON scoring_capture.flag_id = scoring_flag.id
    INNER JOIN scoring_service ON scoring_service.id = service_id
    GROUP BY protecting_team_id, service_group_id
   UNION ALL
    -- recursion step:
    -- increment tick and add flag loss for tick
    SELECT prev_tick.tick + 1,
           prev_tick.team_id,
           prev_tick.service_group_id,
           prev_tick.flags_lost
           -- calculate the captures for this tick, team and service
            + coalesce((SELECT COUNT(*)
             FROM scoring_flag
             INNER JOIN scoring_capture ON scoring_capture.flag_id = scoring_flag.id
              AND scoring_capture.tick = prev_tick.tick + 1
             INNER JOIN scoring_service ON scoring_service.id = scoring_flag.service_id
             -- we actually want the tick of the capture to match
             -- but limiting the tick of the flag placement to a range of valid_ticks make this more efficient
             WHERE prev_tick.tick + 1 - (SELECT * from valid_ticks) < scoring_flag.tick
              AND scoring_flag.tick <= prev_tick.tick + 1
              AND scoring_service.service_group_id = prev_tick.service_group_id
              AND scoring_flag.protecting_team_id = prev_tick.team_id), 0)::integer
    FROM flags_lost prev_tick
    -- perform recursion until max_scoreboard_tick
    WHERE prev_tick.tick + 1 <= (SELECT * FROM max_scoreboard_tick)
  ),
  -- calculate defense using Recursive CTE
  defense (tick, team_id, service_group_id, defense) AS (
    -- inital value of recursion:
    -- Get the first capture from each team and service subtract 1 from tick and assign score 0.0
    SELECT min(scoring_capture.tick) - 1,
           protecting_team_id as team_id,
           service_group_id,
           float8 '0.0'
    FROM scoring_capture
    INNER JOIN scoring_flag ON scoring_flag.id = scoring_capture.flag_id
    INNER JOIN scoring_service ON scoring_service.id = service_id
    GROUP BY protecting_team_id, service_group_id
   UNION ALL
    -- recursion step:
    -- increment tick and add defense increment for tick
    SELECT prev_tick.tick + 1,
           prev_tick.team_id,
           prev_tick.service_group_id,
           prev_tick.defense
           -- calculate the increment of defense for this tick, team and service
            + coalesce((SELECT SUM(points.defense_delta)
             FROM scoreboard_v2_flag_points points
             -- inner join flag to get all flags owned by team
             INNER JOIN scoring_flag ON scoring_flag.id = points.flag_id
              AND scoring_flag.protecting_team_id = prev_tick.team_id
             INNER JOIN scoring_service ON scoring_service.id = scoring_flag.service_id
              AND scoring_service.service_group_id = prev_tick.service_group_id
             -- we actually want the tick of the points to match
             -- but limiting the tick of the flag placement to a range of valid_ticks make this more efficient
              AND prev_tick.tick + 1 - (SELECT * from valid_ticks) < scoring_flag.tick
              AND scoring_flag.tick <= prev_tick.tick + 1
             WHERE points.tick = prev_tick.tick + 1), float8 '0.0')
    FROM defense prev_tick
    -- perform recursion until max_scoreboard_tick
    WHERE prev_tick.tick + 1 <= (SELECT * FROM max_scoreboard_tick)
  ),
  sla (tick, team_id, service_group_id, sla) AS (
    -- inital value of recursion:
    -- start at tick -1 for each team and service
    -- To fill the whole scoreboard beginning at tick -1 this
    -- must start at tick -1 cause the other tables (attack, defense, ...) might start at a later tick
    SELECT -1 as tick,
           team_id,
           scoring_servicegroup.id AS service_group_id,
           integer '0'
    FROM teams, scoring_servicegroup
   UNION ALL
    -- recursion step:
    -- increment tick and add sla score for tick
    SELECT prev_tick.tick + 1,
           prev_tick.team_id,
           prev_tick.service_group_id,
           prev_tick.sla
           -- calculate the increment of sla score for this tick, team and service
           -- note: this is double the value from formula and is later halfed
            + coalesce(
              (SELECT servicegroup.services_count *
                       ((COUNT(CASE WHEN status=0 THEN 1 END) = servicegroup.services_count)::int -- all up
                       +(COUNT(*) = servicegroup.services_count)::int)         -- all recovering or up
               FROM scoring_statuscheck
               INNER JOIN scoring_service ON scoring_service.id = scoring_statuscheck.service_id
               INNER JOIN servicegroup ON scoring_service.service_group_id = servicegroup.service_group_id
               WHERE scoring_statuscheck.tick = prev_tick.tick + 1
                 AND scoring_service.service_group_id = prev_tick.service_group_id
                 AND scoring_statuscheck.team_id = prev_tick.team_id
                 AND status IN (0, 4)
               GROUP BY servicegroup.service_group_id, servicegroup.services_count), 0)::integer
    FROM sla prev_tick
    -- perform recursion until max_scoreboard_tick
    WHERE prev_tick.tick + 1 <= (SELECT * FROM max_scoreboard_tick)
  )
SELECT tick,
       team_id,
       service_group_id,
       coalesce(flags_captured, 0)::integer as flags_captured,
       (coalesce(flags_captured, 0) + coalesce(attack_bonus, 0))::double precision as attack,
       coalesce(flags_lost, 0)::integer as flags_lost,
       (-1.0 * coalesce(defense, 0))::double precision as defense,
       -- no coalesce here this must exists for each tick, team and service
       (sla * 0.5 * (SELECT sqrt(count(*)) FROM teams))::double precision as sla
FROM (SELECT * FROM flags_captured ORDER BY tick) AS flags_captured
NATURAL FULL OUTER JOIN (SELECT * FROM attack_bonus ORDER BY tick) AS attack_bonus
NATURAL FULL OUTER JOIN (SELECT * FROM flags_lost ORDER BY tick) AS flags_lost
NATURAL FULL OUTER JOIN (SELECT * FROM defense ORDER BY tick) AS defense
NATURAL FULL OUTER JOIN (SELECT * FROM sla ORDER BY tick) AS sla
-- filter out -1 tick and larger ticks
WHERE tick >= -1 AND tick <= (SELECT * FROM max_scoreboard_tick);

CREATE UNIQUE INDEX unique_per_tick
  ON "scoreboard_v2_board" (tick, team_id, service_group_id);

-- ALTER MATERIALIZED VIEW "scoreboard_v2_board" OWNER TO gameserver_controller;
-- GRANT SELECT on TABLE "scoreboard_v2_board" TO gameserver_web;



-- ## team rankings materialized view ####
--DROP TABLE IF EXISTS "scoreboard_v2_team_rankings";
--DROP MATERIALIZED VIEW IF EXISTS "scoreboard_v2_team_rankings";
--
---- This makes heavy use of RECURSIVE CTEs:
---- https://www.postgresql.org/docs/14/queries-with.html#QUERIES-WITH-RECURSIVE
---- We do this to calculate the score based on the previous tick
--
--CREATE MATERIALIZED VIEW "scoreboard_v2_team_rankings" AS
--WITH RECURSIVE
--  -- calculate the max tick of the scoreboard.
--  -- Normally this is current_tick - 1 because the current_tick is running and thus does not have final scoring
--  -- However on game end we want the scoreboard to include the current_tick==last tick as current_tick is not incremented on game end
--  max_scoreboard_tick AS (
--    SELECT CASE WHEN (
--      -- Check if the game is still running
--      -- Use a slack of 1 sec to avoid time sync issues
--      SELECT ("end" - INTERVAL '1 sec') > NOW() FROM scoring_gamecontrol
--    ) THEN (
--      -- game is running - avoid current_tick
--      SELECT current_tick - 1 FROM scoring_gamecontrol 
--    ) ELSE (
--      -- game ended - include current_tick
--      SELECT current_tick from scoring_gamecontrol
--    ) END
--  ),
--  last_teams_rankings AS (
--    SELECT dense_rank() OVER(order by total DESC) AS rank, team_id, tick, total from
--    (select team_id, tick, SUM(attack+defense+sla) AS total from scoreboard_v2_board 
--    WHERE tick >= -1 AND tick <= (SELECT * FROM max_scoreboard_tick) GROUP BY
--    team_id, tick ORDER BY total DESC)
--    AS subquery
--  )
--SELECT team_id, tick, rank, total
--FROM last_teams_rankings;
---- filter out -1 tick and larger ticks
----WHERE tick >= -1 AND tick <= (SELECT * FROM max_scoreboard_tick);
--
--CREATE UNIQUE INDEX rankings_unique_per_tick
--  ON "scoreboard_v2_team_rankings" (tick, team_id);


-- #### first_bloods VIEW ####

DROP TABLE IF EXISTS "scoreboard_v2_firstbloods";
DROP VIEW IF EXISTS "scoreboard_v2_firstbloods";

CREATE VIEW "scoreboard_v2_firstbloods" AS
-- select first row ordered by timestamp for each service_id
SELECT DISTINCT ON (service_id)
  service_id,
  capturing_team_id as team_id,
  scoring_capture.tick,
  scoring_capture.timestamp
FROM scoring_flag
INNER JOIN scoring_capture ON scoring_capture.flag_id = scoring_flag.id
ORDER BY service_id, scoring_capture.timestamp;

-- GRANT SELECT on TABLE "scoreboard_v2_firstbloods" TO gameserver_web;

-- NOTE: REFRESH MATERIALIZED VIEW CONCURRENTLY needs additional permissions:
-- GRANT TEMPORARY ON DATABASE $db TO gameserver_controller;
