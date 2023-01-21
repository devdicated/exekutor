CREATE TRIGGER notify_exekutor_workers
  AFTER INSERT OR UPDATE OF queue, scheduled_at, status
                  ON exekutor_jobs
                    FOR EACH ROW
                    WHEN (NEW.status = 'p')
                    EXECUTE FUNCTION exekutor_job_notifier()