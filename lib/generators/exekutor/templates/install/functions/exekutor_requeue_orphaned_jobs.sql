CREATE
OR REPLACE FUNCTION exekutor_requeue_orphaned_jobs() RETURNS TRIGGER AS $$
BEGIN
UPDATE exekutor_jobs
SET status = 'p'
WHERE worker_id = OLD.id
  AND status = 'e';
RETURN OLD;
END;
      $$
LANGUAGE plpgsql
