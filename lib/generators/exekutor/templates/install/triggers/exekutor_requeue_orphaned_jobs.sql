CREATE TRIGGER exekutor_requeue_orphaned_jobs
    BEFORE DELETE
    ON exekutor_workers
    FOR EACH ROW
EXECUTE FUNCTION exekutor_requeue_orphaned_jobs()
