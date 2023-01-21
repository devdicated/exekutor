CREATE TRIGGER requeue_orphaned_jobs
  BEFORE DELETE
  ON exekutor_workers
  FOR EACH ROW
  EXECUTE FUNCTION requeue_orphaned_jobs()