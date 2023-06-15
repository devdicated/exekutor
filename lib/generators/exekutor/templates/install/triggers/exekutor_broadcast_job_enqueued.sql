CREATE TRIGGER exekutor_broadcast_job_enqueued
    AFTER INSERT OR
UPDATE OF queue, scheduled_at, status
ON exekutor_jobs
    FOR EACH ROW
    WHEN (NEW.status = 'p')
    EXECUTE FUNCTION exekutor_broadcast_job_enqueued()
