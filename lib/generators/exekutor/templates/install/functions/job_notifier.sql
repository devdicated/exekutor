CREATE OR REPLACE FUNCTION exekutor_job_notifier() RETURNS TRIGGER AS $$
  BEGIN
          PERFORM pg_notify('exekutor::job_enqueued',
                            CONCAT('id:', NEW.id,';q:', NEW.queue,';t:', extract ('epoch' from NEW.scheduled_at)));
  RETURN NULL;
  END;
      $$ LANGUAGE plpgsql