-- Frozen schema 1. Do not generate this from the current schema.
PRAGMA application_id=0x5a4d5052;
PRAGMA user_version=1;
CREATE TABLE runs(id BLOB PRIMARY KEY CHECK(length(id)=16),timestamp INTEGER NOT NULL,record BLOB NOT NULL,timing BLOB,cohort BLOB NOT NULL) STRICT;
CREATE INDEX runs_chronological ON runs(timestamp,id);
CREATE INDEX runs_cohort_chronological ON runs(cohort,timestamp,id);
CREATE TABLE events(run_id BLOB NOT NULL REFERENCES runs(id) ON DELETE CASCADE,ordinal INTEGER NOT NULL,elapsed_us INTEGER NOT NULL,active_us INTEGER NOT NULL,kind INTEGER NOT NULL,position INTEGER NOT NULL,expected INTEGER,typed INTEGER,batch INTEGER NOT NULL,input INTEGER NOT NULL,eligibility INTEGER NOT NULL,interval_us INTEGER,correct INTEGER NOT NULL,assistance INTEGER NOT NULL,observed_us INTEGER NOT NULL,clock INTEGER NOT NULL,PRIMARY KEY(run_id,ordinal)) STRICT;
CREATE TABLE legacy_imports(id BLOB PRIMARY KEY,record BLOB NOT NULL) STRICT;
