# _Say hello to_ Exekutor

**Exekutor** is a PostgreSQL backed [active job](https://edgeguides.rubyonrails.org/active_job_basics.html) adapter,
which uses powerful PostgreSQL features for low latency and efficient locking;

## Features

- Designed for active job;
- Multithreaded job execution using [Concurrent Ruby](https://github.com/ruby-concurrency/concurrent-ruby);
- Uses `LISTEN/NOTIFY` to listen for jobs and `FOR UPDATE SKIP LOCKED` to reserve jobs;
- Custom job options to limit execution time and prevent execution of stale jobs;
- An `Asynchronous` module to execute plain ruby methods using active job;
- Hooks to integrate your error monitoring system;
- An HTTP healthcheck server.

## Installation and set up

In a nutshell:
- Install the `exekutor` gem;
- Run `rails g exekutor:install` and `rails db:migrate`;
- Configure Rails to use Exekutor;
- Start your worker and queue your jobs.

Read the [Getting started guide](GETTING_STARTED.md) for the detailed documentation.


## Configuration

Exekutor can be configured in multiple ways: using [code](#code), a [yaml file](#yaml), and
[command line options](#command-line-options).

### Code

Most of the configuration options can be configured from the initializer file. This file will be generated for you when 
you run `rails g exekutor:install`.

#### Default queue priority

The default priority for jobs without an explicitly specified priority. The valid range for a job priority is between 1
(_highest_ priority) and 32,767 (_lowest_ priority).

```ruby
Exekutor.config.default_queue_priority = 16383
```


#### Base record class name

The base class for the active record models of Exekutor.

```ruby
Exekutor.config.base_record_class_name = "ActiveRecord::Base"
```

#### JSON serializer

The JSON serializer to use.

```ruby
Exekutor.config.json_serializer = JSON
```

#### Logger

The logger to use.

```ruby
Exekutor.config.logger = Rails.active_job.logger
```

#### Set DB connection name

Whether the listener should set the DB connection name. When Exekutor is started using the CLI, this option also 
configures whether to name the other DB connections used by the worker.

```ruby
Exekutor.config.set_db_connection_name = false # (true for the CLI)
```

#### Enable listener

Whether to use the listener. You can set this option to `false` and decrease the polling interval
to make Exekutor work like an old-fashioned polling worker. This is necessary if you have a tool like _PgBouncer_ which
does not allow long running connections.

```ruby
Exekutor.config.enable_listener = true
```

#### Polling interval

The polling interval in seconds. Exekutor polls for jobs every 60 seconds by default to check for jobs that the listener
might have missed.

```ruby
Exekutor.config.polling_interval = 60
```

#### Polling jitter

Sets a "jitter" for this polling interval so all worker don't hit the database at the same time if they were started at
the same time. A value of 0.1 means the polling interval can deviate up to 10%, from 5% sooner to 5% later.

_For example:_
With a polling interval of **60** and a jitter of **0.1**, the actual polling interval can range from **57** to **63**
seconds.
 
```ruby
Exekutor.config.polling_jitter = 0.1
``` 

#### Minimum execution threads

The minimum number of threads to keep active for executing jobs.

```ruby
Exekutor.config.min_execution_threads = 1
```

#### Maximum execution threads

The maximum number of threads that may be active to execute jobs. By default, Exekutor uses your database connection
pool size minus 1. Be aware that if you set this to a value greater than `connection_db_config.pool`, workers may have 
to wait for database connections to become available because all connections are occupied by other threads. This may 
result in an `ActiveRecord::ConnectionTimeoutError` if the thread has to wait too long.

```ruby
Exekutor.config.max_execution_threads = 10
```

#### Maximum execution thread idletime

The number of seconds that an execution thread may be idle before being reclaimed.

```ruby
Exekutor.config.max_execution_thread_idletime = 60
```

#### Healthcheck handler

The Rack handler to use for the healthcheck server

```ruby
Exekutor.config.healthcheck_handler = "webrick"
```

#### Healthcheck timeout

The timeout in minutes after which the healthcheck server deems a worker to be down. The worker updates a heartbeat 
every time it finishes a job and after polling for jobs. This heartbeat is used to check whether the worker is still 
executing jobs. This means that the timeout should be longer than the execution time of your jobs.

```ruby
Exekutor.config.healthcheck_timeout = 30
```

#### Quiet

Whether to suppress the logger output to just the errors.

```ruby
Exekutor.config.quiet = false
```

### YAML

When starting a worker from the CLI, a number of configuration options can be overridden using a YAML configuration 
file. 

#### Queues

The queues this worker should perform jobs out of.

```yaml
exekutor:
  queues: ["queues", "to", "watch"]
```

#### Json serializer

The JSON serializer to use for deserializing jobs by this worker.

```yaml
exekutor:
  json_serializer: "Oj"
```

#### Set db connection name

Whether to set the application name of the DB connections for this worker.

```yaml
exekutor:
  set_db_connection_name: true
```

#### Enable listener

Whether to enable the listener for this worker.

```yaml
exekutor:
  enable_listener: true
```

#### Polling interval / jitter

The polling interval and jitter for this worker.

```yaml
exekutor:
  polling_interval: 60
  polling_jitter: 0.1
```

#### Execution thread options

The minimum and maximum threads this worker should spawn and the thread idletime for reclaiming threads.

```yaml
exekutor:
  min_execution_threads: 1
  max_execution_threads: 14
  max_execution_thread_idletime: 60
```

#### Healthcheck options

The healthcheck server handler, the port to use, and the worker timeout.

```yaml
exekutor:
  healthcheck_port: 10100
  healthcheck_handler: webrick
  healthcheck_timeout: 60
```

#### Quiet

Whether to suppress log output to just the errors.

```yaml
exekutor:
  quiet: true
```

#### Wait for termination

Whether and how long to wait for the execution threads to finish upon exit. 
- If the value is `false` or `nil`, the worker will not wait for the execution threads to finish but will not kill the 
threads either; 
- If the value is zero, the worker will kill the execution threads immediately upon exit;
- If the value is a positive number, the worker will wait for the indicated amount of seconds to let the execution 
threads finish and will kill the threads if the timeout is exceeded. 
- Otherwise the worker will wait for the execution threads to finish indefinitely.

```yaml
exekutor:
  wait_for_termination: 120
```

### Command line options

A small number of options are also configurable through the command line. The command line options override the values 
set from the YAML and initializer files.

#### Queues

The queues this worker should perform jobs out of. The option can be specified mulitple time to indicate multiple queues.

```sh
exekutor start --queue queue --queue another_queue --queue third_queue
```

#### Polling interval

The polling interval in seconds.

```sh
exekutor start --poll_interval 90
```

#### Maximum execution threads

The minimum and maximum number of execution threads, specified as `min:max`. If only 1 value is specified, the thread 
pool will have a fixed size.

```sh
exekutor start --threads 10:20
```

## Command line interface

### Start

Starts a worker.

```sh
exekutor start [options]
```

#### Options

- `--help` – Show the help message.
- `--identifier=arg` – The identifier for this worker. This identifier is shown in the process name and the connection 
name.
- `--pidfile=path` – The path to the PID file for a daemonized worker.
- `--configfile=path` – The path to the YAML configfile.
- `--daemonize` – Whether to daemonize the worker.
- `--env` – The Rails environment to load.
- `--poll_interval` – The poll interval for this worker.
- `--max_threads` – The maximum execution threads for this worker.
- `--queue` – The queue to work off. Can be specified multiple times.

### Stop

Stops a daemonized worker.

```sh
exekutor stop [options]
```

#### Options

- `--identifier=arg` – The identifier of the worker to stop. (translates to `--pidfile=tmp/pids/exekutor.%{identifier}.pid`)
- `--pidfile=path` – The path to the PID file of the worker to stop.
- `--all` – Stops all daemonized workers with default pidfiles (ie. `tmp/pids/exekutor*.pid`). You can use `pidfile` option 
to use a custom pidfile pattern.
- `--shutdown_timeout=int` – The amount of seconds to wait before killing a worker process.

### Restart

Restarts a daemonized worker with the specified options.

```sh
exekutor restart [options]
```

#### Options

See [start](#start). 

>Exekutor will not remember the original start options, they have to be fully specified again when
you restart a worker.

- `--shutdown_timeout=int` – The amount of seconds to wait before killing a worker process.

### Info

Prints info about the active workers and pending jobs.

```sh
exekutor info [options]
```

#### Options

- `--environment` – The Rails environment to load.

### Cleanup

Cleans up finished jobs and/or stale workers

```sh
exekutor cleanup [all|jobs|workers] [options]
```

#### Options

- `--environment=arg` – The Rails environment to load.
- `--job_status=arg` – The statuses to purge. 
- `--timeout=int` – The timeout in hours. Workers and jobs before the timeout will be purged.
- `--job_timeout=int` – The job timeout in hours (overrides `--timeout`). Jobs where `scheduled_at` is before the timeout 
will be purged.
- `--worker_timeout=int` – The worker timeout in hours (overrides `--timeout`). Workers where the last heartbeat is before 
the timeout will be purged.

## Job options

You can include the `Exekutor::JobObtions` mixin into your active job class to use custom job options.

### Execution timeout

Limit the execution time of your job. 

> Be aware that `Timeout::timeout` is used internally for this, which can raise an error at any line of code in your 
> application. _Use with caution_

```ruby
class MyJob < ActiveJob::Base
  include Exekutor::JobOptions
  exekutor_options execution_timeout: 10.seconds
end

# Or per job
MyJob.set(execution_timeout: 1.minute).perform_later
```

### Queue timeout

When a queue timeout is specified, Exekutor will not execute or job if it has been in the queue for longer than the 
timeout.

```ruby
class MyJob < ActiveJob::Base
  include Exekutor::JobOptions
  exekutor_options queue_timeout: 1.hour
end

# Or per job
MyJob.set(queue_timeout: 15.minutes).perform_later
```

## Asynchronous methods

Include the `Exekutor::Asynchronous` mixin in any class to make one or more of its methods be executed asynchronously
through active job. 

```ruby
class MyRecord < ActiveRecord::Base 
  include Exekutor::Asynchronous

  def method(arg1, arg2)
    puts "arg1: #{arg1.inspect}; arg2: #{arg2.inspect}"
  end
  
  perform_asynchronously :method

  def self.class_method(arg1, arg2)
    puts "arg1: #{arg1.inspect}; arg2: #{arg2.inspect}"
  end
  
  perform_asynchronously :class_method, class_method: true
end
```

### Caveats

#### Method arguments
Exekutor can only perform methods asynchronously if all the arguments can be serialized by active job. See the [active
job documentation](https://guides.rubyonrails.org/v6.1/active_job_basics.html#supported-types-for-arguments) for the
supported arguments.

#### Executing instance methods
Exekutor can only perform instance methods asynchronously if the class instance can be serialized by active job.
In practice, this means that you can only do this on active record models because they are serialized to a `GlobalID`.
If you want to use this mixin on another class, you'll have to write your own active job serializer.

## Hooks

You can register hooks to be called for certain lifecycle events in Exekutor. These hooks work similar to 
`ActiveSupport::Callbacks`.

```ruby
class MyHook 
  include Exekutor::Hook
  
  around_job_execution :instrument 
  after_job_failure {|_job, error| report_error error }
  after_fatal_error :report_error
    
  def instrument(job)
    ErrorMonitoring.monitor_transaction(job) { yield }
  end
    
  def report_error(error)
    ErrorMonitoring.report error
  end
end
``` 

#### Hook types

- `before_enqueue` – Called before a job is enqueued. Receives the job as an argument.
- `around_enqueue` – Called when a job is enqueued, `yield` must be called to propagate the call. Receives the job as an 
argument. 
- `after_enqueue` – Called after a job is enqueued. Receives the job as an argument.
- `before_job_execution` – Called before a job is executed. Receives a `Hash` with job info as an argument.
- `around_job_execution` – Called when a job is executed, `yield` must be called to propagate the call. Receives a `Hash` 
with job info as an argument.
- `after_job_execution` – Called after a job is executed. Receives a `Hash` with job info as an argument.
- `on_job_failure` – Called after a job has raised an error. Receives a `Hash` with job info and the raised error as 
arguments.
- `on_fatal_error` – Called after an error was raised outside job execution. Receives the raised error as an argument.
- `before_startup` – Called before starting up a worker. Receives the worker as an argument.
- `after_startup` – Called after a worker has started up. Receives the worker as an argument.
- `before_shutdown` – Called before shutting down a worker. Receives the worker as an argument.
- `after_shutdown` – Called after a worker has shutdown. Receives the worker as an argument.

#### The job execution hooks

The job execution hooks receive a `Hash` with job info instead of a active job instance. This has contains the following
values:

- `id` – The Exekutor id of the job.
- `options` – The custom Exekutor options for this job.
- `payload` – The active job payload for this job.
- `scheduled_at` – The time this job was meant to be executed.

## Running a worker from Ruby

You can also start a worker from Ruby code:

```ruby
Exekutor::Worker.start(worker_options)
```

### Options

- `:identifier` – the identifier for this worker
- `:queues` – the queues to work on 
- `:enable_listener` – whether to enable the listener
- `:min_threads` – the minimum number of execution threads that should be active
- `:max_threads` – the maximum number of execution threads that may be active
- `:max_thread_idletime` – the maximum number of seconds a thread may be idle before being stopped 
- `:polling_interval` – the polling interval in seconds 
- `:poling_jitter` – the polling jitter 
- `:set_db_connection_name` – whether the DB connection name should be set
- `:wait_for_termination` – how long the worker should wait on jobs to be completed before exiting
- `:healthcheck_port` – the port to run the healthcheck server on 
- `:healthcheck_handler` – The name of the rack handler to use for the healthcheck server
- `:healthcheck_timeout` – The timeout of a worker in minutes before the healthcheck server deems it as down

The default values for most of the options can be fetched by:
```ruby
Exekutor.config.worker_options # => { enable_listener: … } 
```

### Methods

#### Start

Starts the worker in the background. The method will return immediately after startup.

```ruby
worker = Worker.new(options)
worker.start

# or

worker = Worker.start(options)
```

#### Stop

Stops the worker. This method may block until the worker has finished its jobs depending `wait_for_termination` option.

```ruby
worker.stop
```

#### Kill

Kills the worker. This method cancels job execution and return the jobs back to the pending state. This method does 
**not** invoke the `shutdown` hooks.

```ruby
worker.kill
```

#### Join

Joins the current thread with the worker thread. This method blocks until the worker shuts down.

```ruby
worker.join
```

## Cleanup

You can clean up the jobs from the CLI and from Ruby:

See [Command line interface](#command-line-interface) for the CLI options.

```ruby
cleanup = Exekutor::Cleanup.new
cleanup.cleanup_workers(options)
cleanup.cleanup_jos(options)
```

### Cleanup workers

Cleans up stale workers. Worker records should be automatically purged upon shutdown, but when for example the DB 
connection is down or when a worker is killed the records might be left behind.

Exekutor has a DB trigger to automatically release unfinished jobs when a worker record is deleted. This means that 
stale worker records can lock jobs without them being executed. Cleaning up these records will release these jobs so 
they can be performed by other workers.  

#### Options
- `:timeout` – The timeout for worker heartbeats. Workers where the last heartbeat is before the timeout will be purged. 
    Make sure the timeout is not shorter than the execution time of your jobs.

### Cleanup jobs

Exekutor does not delete jobs after they are finished. This means the jobs table will fill up with finished jobs, which
will slow down your table. Regularly purging these jobs will make sure your jobs table will remain blazing fast.

#### Options
- `:timeout` – The timeout for jobs. Jobs where `scheduled_at` is before the timeout will be purged.
- `:status` – The job statuses to purgs. Only jobs with the specified status will be purged.

## Deployment

When deploying on a server, use a process monitoring tool like Eye, Bluepill, or God to manage your workers in a 
production environment. This will ensure your workers will be kept active.

### Error reporting

Use a hook to report any failed jobs and low level errors to your favorite error monitoring tool.
If you want to add your monitoring tool of choice as a plugin, feel free to open a PR!

There is only 1 error monitoring plugin for now: [Appsignal](https://www.appsignal.com)

```ruby
Exekutor.load_plugin :appsignal
```

### Healthcheck server

Use the healthcheck server to check if your worker is running by `curl localhost:[port]/ready` or `…/live`.

The `ready` endpoint checks if the worker is running and if the database connection is active.
The `live` endpoint checks if the worker is running and is active by looking at the worker heartbeat.

```shell
$ curl localhost:9000/ready
[OK] ID: f1a2ee6a-cdac-459c-a4b8-de7c6a8bbae6; State: started
```

## Caveats

### No run-once guarantee
 
**Make your jobs idempotent**

Although Exekutor does it's best to execute a job only once, there is no guarantee this actually happens. If the
database connection is lost while executing a job, a worker cannot mark the job as completed. While the connection is
down, the worker keeps track of which jobs were finished and mark them as such as soon as the database connection comes
back up. 

If the worker is stopped or killed before this happens, the job will be stuck in the `executing` status (and the worker 
record will become stale). The cleanup task will purge any stale workers and release the jobs, after which these jobs 
will be executed again by another worker.

This means you have to design your jobs to be idempotent: executing it multiple times should have the same effect. It 
also means that it's not wise to shutdown your workers without an active database connection.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Then, run `rake test` to run the tests. You can
also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the
version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version,
push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

### Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/devdicated/exekutor. This project is intended
to be a safe, welcoming space for collaboration, and contributors are expected to adhere to
the [code of conduct](https://github.com/devdicated/exekutor/blob/master/CODE_OF_CONDUCT.md).

### License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

### Code of Conduct

Everyone interacting in the Exekutor project's codebases, issue trackers, chat rooms and mailing lists is expected to
follow the [code of conduct](https://github.com/devdicated/exekutor/blob/master/CODE_OF_CONDUCT.md).
