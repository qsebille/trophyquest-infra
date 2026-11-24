\set ON_ERROR_STOP on

BEGIN;

GRANT CONNECT ON DATABASE :"DBNAME" TO :"backfill_role";
GRANT USAGE ON SCHEMA app, igdb TO :"backfill_role";
GRANT SELECT (matched_game_id, status) ON app.igdb_matching TO :"backfill_role";
GRANT SELECT (id), INSERT (id, game_id, igdb_url) ON igdb.screenshot TO :"backfill_role";

COMMIT;
