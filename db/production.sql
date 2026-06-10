-- Runs once on the postgres accessory's first boot (docker-entrypoint-initdb.d).
-- The primary database is created by POSTGRES_DB; these hold Solid Cache and
-- Solid Queue (see config/database.yml production).
CREATE DATABASE paste_html_dev_production_cache;
CREATE DATABASE paste_html_dev_production_queue;
