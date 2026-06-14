-- Guard append notifications at the trigger level.
--
-- The trigger function and payload format stay unchanged:
--   stream_name,stream_id,stream_version
--
-- INSERT covers newly-created streams. UPDATE covers later appends to an
-- existing stream. Both exclude the internal $all row (stream_id = 0), and the
-- UPDATE trigger only fires when an append advances stream_version, not for
-- lifecycle updates such as soft-delete or undelete.

DROP TRIGGER IF EXISTS stream_events_notify ON kiroku.streams;

DROP TRIGGER IF EXISTS stream_events_notify_insert ON kiroku.streams;
CREATE TRIGGER stream_events_notify_insert
    AFTER INSERT ON kiroku.streams
    FOR EACH ROW
    WHEN (NEW.stream_id <> 0)
    EXECUTE FUNCTION kiroku.notify_events();

DROP TRIGGER IF EXISTS stream_events_notify_update ON kiroku.streams;
CREATE TRIGGER stream_events_notify_update
    AFTER UPDATE ON kiroku.streams
    FOR EACH ROW
    WHEN (NEW.stream_id <> 0
          AND NEW.stream_version IS DISTINCT FROM OLD.stream_version)
    EXECUTE FUNCTION kiroku.notify_events();
