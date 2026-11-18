-- Frozen schema 2 addition to schema 1. Record/timing encodings are unchanged.
ALTER TABLE runs ADD COLUMN practice_scope BLOB;
CREATE INDEX runs_practice_chronological ON runs(practice_scope,timestamp,id);
PRAGMA user_version=2;
