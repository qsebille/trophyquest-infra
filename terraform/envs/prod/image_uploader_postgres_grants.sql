\set ON_ERROR_STOP on

BEGIN;

GRANT CONNECT ON DATABASE :"DBNAME" TO :"uploader_role";
GRANT USAGE ON SCHEMA psn, igdb, app TO :"uploader_role";

GRANT SELECT (id, created_at, psn_avatar_url, aws_avatar_url),
      UPDATE (aws_avatar_url) ON psn.player TO :"uploader_role";
GRANT SELECT (id, created_at, psn_image_url, aws_image_url),
      UPDATE (aws_image_url) ON psn.suite TO :"uploader_role";
GRANT SELECT (id, created_at, psn_icon_url, aws_icon_url),
      UPDATE (aws_icon_url) ON psn.trophy TO :"uploader_role";
GRANT SELECT (id, created_at, igdb_cover_url, aws_cover_url, igdb_background_url, aws_background_url),
      UPDATE (aws_cover_url, aws_background_url) ON igdb.game TO :"uploader_role";
GRANT SELECT (id, created_at, game_id, igdb_url, aws_url),
      UPDATE (aws_url) ON igdb.screenshot TO :"uploader_role";
GRANT SELECT (matched_game_id, status) ON app.igdb_matching TO :"uploader_role";

COMMIT;
