-- Defense-in-depth bound on stream-name length (MasterPlan 9 / EP-5,
-- docs/plans/60-...). The Haskell store validates this before any SQL
-- (StoreError StreamNameTooLong, maxStreamNameBytes = 512); the constraint
-- catches writers that bypass the library (raw SQL via runTransaction,
-- psql sessions). 512 bytes is far below pg_notify's 8,000-byte payload
-- limit, so the append-notification trigger can never abort on payload size.
ALTER TABLE kiroku.streams
    ADD CONSTRAINT chk_streams_stream_name_length
    CHECK (octet_length(stream_name) <= 512);
