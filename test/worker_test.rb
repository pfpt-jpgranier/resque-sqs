require 'test_helper'
require 'tmpdir'

describe "ResqueSqs::Worker" do
  class DummyLogger
    def initialize
      @rd, @wr = IO.pipe
    end

    def info(message); @wr << message << "\0"; end
    alias_method :debug, :info
    alias_method :warn,  :info
    alias_method :error, :info
    alias_method :fatal, :info

    def messages
      @wr.close
      @rd.read.split("\0")
    end
  end

  before do
    @worker = ResqueSqs::Worker.new(:jobs)
    ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')
  end

  it 'worker is paused' do
    ResqueSqs.redis.set('pause-all-workers', 'true')
    assert_equal true, @worker.paused?
    ResqueSqs.redis.set('pause-all-workers', 'TRUE')
    assert_equal true, @worker.paused?
    ResqueSqs.redis.set('pause-all-workers', 'True')
    assert_equal true, @worker.paused?
  end

  it 'worker is not paused' do
    assert_equal false, @worker.paused?
    ResqueSqs.redis.set('pause-all-workers', 'false')
    assert_equal false, @worker.paused?
    ResqueSqs.redis.del('pause-all-workers')
    assert_equal false, @worker.paused?
  end

  it "can fail jobs" do
    ResqueSqs::Job.create(:jobs, BadJob)
    @worker.work(0)
    assert_equal 1, ResqueSqs::Failure.count
  end

  it "failed jobs report exception and message" do
    ResqueSqs::Job.create(:jobs, BadJobWithSyntaxError)
    @worker.work(0)
    assert_equal('SyntaxError', ResqueSqs::Failure.all['exception'])
    assert_equal('Extra Bad job!', ResqueSqs::Failure.all['error'])
  end

  it "does not allow exceptions from failure backend to escape" do
    job = ResqueSqs::Job.new(:jobs, {})
    with_failure_backend BadFailureBackend do
      @worker.perform job
    end
  end

  it "does not raise exception for completed jobs" do
    without_forking do
      @worker.work(0)
    end
    assert_equal 0, ResqueSqs::Failure.count
  end

  it "writes to ENV['PIDFILE'] when supplied and #prepare is called" do
    with_pidfile do
      tmpfile = Tempfile.new("test_pidfile")
      File.expects(:open).with(ENV["PIDFILE"], anything).returns tmpfile
      @worker.prepare
    end
  end

  it "daemonizes when ENV['BACKGROUND'] is supplied and #prepare is called" do
    Process.expects(:daemon)
    with_background do
      @worker.prepare
    end
  end

  it "executes at_exit hooks when configured with run_at_exit_hooks" do
    tmpfile = File.join(Dir.tmpdir, "resque_at_exit_test_file")
    FileUtils.rm_f tmpfile

    if worker_pid = Kernel.fork
      Process.waitpid(worker_pid)
      assert File.exist?(tmpfile), "The file '#{tmpfile}' does not exist"
      assert_equal "at_exit", File.open(tmpfile).read.strip
    else
      # ensure we actually fork
      ResqueSqs.redis.disconnect!
      ResqueSqs::Job.create(:at_exit_jobs, AtExitJob, tmpfile)
      worker = ResqueSqs::Worker.new(:at_exit_jobs)
      worker.run_at_exit_hooks = true
      suppress_warnings do
        worker.work(0)
      end
      exit
    end

  end

  class ::RaiseExceptionOnFailure

    def self.on_failure_throw_exception(exception,*args)
      raise "The worker threw an exception"
    end

    def self.perform
      ""
    end
  end

  it "should not treat SystemExit as an exception in the child with run_at_exit_hooks == true" do
    if worker_pid = Kernel.fork
      Process.waitpid(worker_pid)
    else
      # ensure we actually fork
      ResqueSqs.redis.disconnect!
      ResqueSqs::Job.create(:not_failing_job, RaiseExceptionOnFailure)
      worker = ResqueSqs::Worker.new(:not_failing_job)
      worker.run_at_exit_hooks = true
      suppress_warnings do
        worker.work(0)
      end
      exit
    end
  end

  it "does not execute at_exit hooks by default" do
    tmpfile = File.join(Dir.tmpdir, "resque_at_exit_test_file")
    FileUtils.rm_f tmpfile

    if worker_pid = Kernel.fork
      Process.waitpid(worker_pid)
      assert !File.exist?(tmpfile), "The file '#{tmpfile}' exists, at_exit hooks were run"
    else
      # ensure we actually fork
      ResqueSqs.redis.disconnect!
      ResqueSqs::Job.create(:at_exit_jobs, AtExitJob, tmpfile)
      worker = ResqueSqs::Worker.new(:at_exit_jobs)
      suppress_warnings do
        worker.work(0)
      end
      exit
    end
  end

  it "does report failure for jobs with invalid payload" do
    job = ResqueSqs::Job.new(:jobs, { 'class' => 'NotAValidJobClass', 'args' => '' })
    @worker.perform job
    assert_equal 1, ResqueSqs::Failure.count, 'failure not reported'
  end

  it "register 'run_at' time on UTC timezone in ISO8601 format" do
    job = ResqueSqs::Job.new(:jobs, {'class' => 'GoodJob', 'args' => "blah"})
    now = Time.now.utc.iso8601
    @worker.working_on(job)
    assert_equal now, @worker.processing['run_at']
  end

  it "fails uncompleted jobs with DirtyExit by default on exit" do
    job = ResqueSqs::Job.new(:jobs, {'class' => 'GoodJob', 'args' => "blah"})
    @worker.working_on(job)
    @worker.unregister_worker
    assert_equal 1, ResqueSqs::Failure.count
    assert_equal('ResqueSqs::DirtyExit', ResqueSqs::Failure.all['exception'])
    assert_equal('Job still being processed', ResqueSqs::Failure.all['error'])
  end

  it "fails uncompleted jobs with worker exception on exit" do
    job = ResqueSqs::Job.new(:jobs, {'class' => 'GoodJob', 'args' => "blah"})
    @worker.working_on(job)
    @worker.unregister_worker(StandardError.new)
    assert_equal 1, ResqueSqs::Failure.count
    assert_equal('StandardError', ResqueSqs::Failure.all['exception'])
  end

  it "does not mask exception when timeout getting job metadata" do
    job = ResqueSqs::Job.new(:jobs, {'class' => 'GoodJob', 'args' => "blah"})
    @worker.working_on(job)
    ResqueSqs.data_store.redis.stubs(:get).raises(Redis::CannotConnectError)

    error_message = "Something bad happened"
    exception_caught = assert_raises Redis::CannotConnectError do
      @worker.unregister_worker(raised_exception(StandardError,error_message))
    end
    assert_match(/StandardError/, exception_caught.message)
    assert_match(/#{error_message}/, exception_caught.message)
    assert_match(/Redis::CannotConnectError/, exception_caught.message)
  end

  def raised_exception(klass,message)
    raise klass,message
  rescue Exception => ex
    ex
  end

  class ::SimpleJobWithFailureHandling
    def self.on_failure_record_failure(exception, *job_args)
      @@exception = exception
    end

    def self.exception
      @@exception
    end
  end

  it "fails uncompleted jobs on exit, and calls failure hook" do
    job = ResqueSqs::Job.new(:jobs, {'class' => 'SimpleJobWithFailureHandling', 'args' => ""})
    @worker.working_on(job)
    @worker.unregister_worker
    assert_equal 1, ResqueSqs::Failure.count
    assert_kind_of ResqueSqs::DirtyExit, SimpleJobWithFailureHandling.exception
  end

  it "fails uncompleted jobs on exit and unregisters without erroring out and logs helpful message if error occurs during a failure hook" do
    ResqueSqs.logger = DummyLogger.new

    begin
      job = ResqueSqs::Job.new(:jobs, {'class' => 'BadJobWithOnFailureHookFail', 'args' => []})
      @worker.working_on(job)
      @worker.unregister_worker
      messages = ResqueSqs.logger.messages
    ensure
      reset_logger
    end
    assert_equal 1, ResqueSqs::Failure.count
    error_message = messages.first
    assert_match('Additional error (RuntimeError: This job is just so bad!)', error_message)
    assert_match('occurred in running failure hooks', error_message)
    assert_match('for job (Job{jobs} | BadJobWithOnFailureHookFail | [])', error_message)
    assert_match('Original error that caused job failure was RuntimeError: ResqueSqs::DirtyExit', error_message)
  end

  class ::SimpleFailingJob
    @@exception_count = 0

    def self.on_failure_record_failure(exception, *job_args)
      @@exception_count += 1
    end

    def self.exception_count
      @@exception_count
    end

    def self.perform
      raise Exception.new
    end
  end

  it "only calls failure hook once on exception" do
    job = ResqueSqs::Job.new(:jobs, {'class' => 'SimpleFailingJob', 'args' => ""})
    @worker.perform(job)
    assert_equal 1, ResqueSqs::Failure.count
    assert_equal 1, SimpleFailingJob.exception_count
  end

  it "can peek at failed jobs" do
    10.times { ResqueSqs::Job.create(:jobs, BadJob) }
    @worker.work(0)
    assert_equal 10, ResqueSqs::Failure.count

    assert_equal 10, ResqueSqs::Failure.all(0, 20).size
  end

  it "can clear failed jobs" do
    ResqueSqs::Job.create(:jobs, BadJob)
    @worker.work(0)
    assert_equal 1, ResqueSqs::Failure.count
    ResqueSqs::Failure.clear
    assert_equal 0, ResqueSqs::Failure.count
  end

  it "catches exceptional jobs" do
    ResqueSqs::Job.create(:jobs, BadJob)
    ResqueSqs::Job.create(:jobs, BadJob)
    @worker.process
    @worker.process
    @worker.process
    assert_equal 2, ResqueSqs::Failure.count
  end

  it "supports setting the procline to have arbitrary prefixes and suffixes" do
    prefix = 'WORKER-TEST-PREFIX/'
    suffix = 'worker-test-suffix'
    ver = ResqueSqs::VERSION

    old_prefix = ENV['RESQUE_PROCLINE_PREFIX']
    ENV.delete('RESQUE_PROCLINE_PREFIX')
    old_procline = $0

    @worker.procline(suffix)
    assert_equal $0, "resque-#{ver}: #{suffix}"

    ENV['RESQUE_PROCLINE_PREFIX'] = prefix
    @worker.procline(suffix)
    assert_equal $0, "#{prefix}resque-#{ver}: #{suffix}"

    $0 = old_procline
    if old_prefix.nil?
      ENV.delete('RESQUE_PROCLINE_PREFIX')
    else
      ENV['RESQUE_PROCLINE_PREFIX'] = old_prefix
    end
  end

  it "strips whitespace from queue names" do
    queues = "critical, high, low".split(',')
    worker = ResqueSqs::Worker.new(*queues)
    assert_equal %w( critical high low ), worker.queues
  end

  it "can work on multiple queues" do
    ResqueSqs::Job.create(:high, GoodJob)
    ResqueSqs::Job.create(:critical, GoodJob)

    worker = ResqueSqs::Worker.new(:critical, :high)

    worker.process
    assert_equal 1, ResqueSqs.size(:high)
    assert_equal 0, ResqueSqs.size(:critical)

    worker.process
    assert_equal 0, ResqueSqs.size(:high)
  end

  it "can work off one job" do
    ResqueSqs::Job.create(:jobs, GoodJob)
    assert_equal 2, ResqueSqs.size(:jobs)
    assert_equal true, @worker.work_one_job
    assert_equal 1, ResqueSqs.size(:jobs)

    job = ResqueSqs::Job.new(:jobs, {'class' => 'GoodJob'})
    assert_equal 1, ResqueSqs.size(:jobs)
    assert_equal true, @worker.work_one_job(job)
    assert_equal 1, ResqueSqs.size(:jobs)

    @worker.pause_processing
    @worker.work_one_job
    assert_equal 1, ResqueSqs.size(:jobs)

    @worker.unpause_processing
    assert_equal true, @worker.work_one_job
    assert_equal 0, ResqueSqs.size(:jobs)

    assert_equal false, @worker.work_one_job
  end

  it "the queues method avoids unnecessary calls to retrieve queue names" do
    worker = ResqueSqs::Worker.new(:critical, :high, "num*")
    actual_queues = ["critical", "high", "num1", "num2"]
    ResqueSqs.data_store.expects(:queue_names).once.returns(actual_queues)
    assert_equal actual_queues, worker.queues
  end

  it "can work on all queues" do
    ResqueSqs::Job.create(:high, GoodJob)
    ResqueSqs::Job.create(:critical, GoodJob)
    ResqueSqs::Job.create(:blahblah, GoodJob)

    @worker = ResqueSqs::Worker.new("*")
    @worker.work(0)

    assert_equal 0, ResqueSqs.size(:high)
    assert_equal 0, ResqueSqs.size(:critical)
    assert_equal 0, ResqueSqs.size(:blahblah)
  end

  it "can work with wildcard at the end of the list" do
    ResqueSqs::Job.create(:high, GoodJob)
    ResqueSqs::Job.create(:critical, GoodJob)
    ResqueSqs::Job.create(:blahblah, GoodJob)
    ResqueSqs::Job.create(:beer, GoodJob)

    @worker = ResqueSqs::Worker.new(:critical, :high, "*")
    @worker.work(0)

    assert_equal 0, ResqueSqs.size(:high)
    assert_equal 0, ResqueSqs.size(:critical)
    assert_equal 0, ResqueSqs.size(:blahblah)
    assert_equal 0, ResqueSqs.size(:beer)
  end

  it "can work with wildcard at the middle of the list" do
    ResqueSqs::Job.create(:high, GoodJob)
    ResqueSqs::Job.create(:critical, GoodJob)
    ResqueSqs::Job.create(:blahblah, GoodJob)
    ResqueSqs::Job.create(:beer, GoodJob)

    @worker = ResqueSqs::Worker.new(:critical, "*", :high)
    @worker.work(0)

    assert_equal 0, ResqueSqs.size(:high)
    assert_equal 0, ResqueSqs.size(:critical)
    assert_equal 0, ResqueSqs.size(:blahblah)
    assert_equal 0, ResqueSqs.size(:beer)
  end

  it "processes * queues in alphabetical order" do
    ResqueSqs::Job.create(:high, GoodJob)
    ResqueSqs::Job.create(:critical, GoodJob)
    ResqueSqs::Job.create(:blahblah, GoodJob)

    processed_queues = []
    @worker = ResqueSqs::Worker.new("*")
    without_forking do
      @worker.work(0) do |job|
        processed_queues << job.queue
      end
    end

    assert_equal %w( jobs high critical blahblah ).sort, processed_queues
  end

  it "works with globs" do
    ResqueSqs::Job.create(:critical, GoodJob)
    ResqueSqs::Job.create(:test_one, GoodJob)
    ResqueSqs::Job.create(:test_two, GoodJob)

    @worker = ResqueSqs::Worker.new("test_*")
    @worker.work(0)

    assert_equal 1, ResqueSqs.size(:critical)
    assert_equal 0, ResqueSqs.size(:test_one)
    assert_equal 0, ResqueSqs.size(:test_two)
  end

  it "excludes a negated queue" do
    ResqueSqs::Job.create(:critical, GoodJob)
    ResqueSqs::Job.create(:high, GoodJob)
    ResqueSqs::Job.create(:low, GoodJob)

    @worker = ResqueSqs::Worker.new(:critical, "!low", "*")
    @worker.work(0)

    assert_equal 0, ResqueSqs.size(:critical)
    assert_equal 0, ResqueSqs.size(:high)
    assert_equal 1, ResqueSqs.size(:low)
  end

  it "excludes multiple negated queues" do
    ResqueSqs::Job.create(:critical, GoodJob)
    ResqueSqs::Job.create(:high, GoodJob)
    ResqueSqs::Job.create(:foo, GoodJob)
    ResqueSqs::Job.create(:bar, GoodJob)

    @worker = ResqueSqs::Worker.new("*", "!foo", "!bar")
    @worker.work(0)

    assert_equal 0, ResqueSqs.size(:critical)
    assert_equal 0, ResqueSqs.size(:high)
    assert_equal 1, ResqueSqs.size(:foo)
    assert_equal 1, ResqueSqs.size(:bar)
  end

  it "works with negated globs" do
    ResqueSqs::Job.create(:critical, GoodJob)
    ResqueSqs::Job.create(:high, GoodJob)
    ResqueSqs::Job.create(:test_one, GoodJob)
    ResqueSqs::Job.create(:test_two, GoodJob)

    @worker = ResqueSqs::Worker.new("*", "!test_*")
    @worker.work(0)

    assert_equal 0, ResqueSqs.size(:critical)
    assert_equal 0, ResqueSqs.size(:high)
    assert_equal 1, ResqueSqs.size(:test_one)
    assert_equal 1, ResqueSqs.size(:test_two)
  end

  it "has a unique id" do
    assert_equal "#{`hostname`.chomp}:#{$$}:jobs", @worker.to_s
  end

  it "complains if no queues are given" do
    assert_raises ResqueSqs::NoQueueError do
      ResqueSqs::Worker.new
    end
  end

  it "fails if a job class has no `perform` method" do
    ResqueSqs::Job.create(:perform_less, Object)
    assert_equal 0, ResqueSqs::Failure.count

    @worker = ResqueSqs::Worker.new(:perform_less)
    @worker.work(0)

    assert_equal 1, ResqueSqs::Failure.count
  end

  it "inserts itself into the 'workers' list on startup" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert_equal @worker, ResqueSqs.workers[0]
      end
    end
  end

  it "removes itself from the 'workers' list on shutdown" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert_equal @worker, ResqueSqs.workers[0]
      end
    end

    assert_equal [], ResqueSqs.workers
  end

  it "removes worker with stringified id" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        worker_id = ResqueSqs.workers[0].to_s
        ResqueSqs.remove_worker(worker_id)
        assert_equal [], ResqueSqs.workers
      end
    end
  end

  it "records what it is working on" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        task = @worker.job
        assert_equal({"args"=>[20, "/tmp"], "class"=>"SomeJob"}, task['payload'])
        assert task['run_at']
        assert_equal 'jobs', task['queue']
      end
    end
  end

  it "clears its status when not working on anything" do
    @worker.work(0)
    assert_equal Hash.new, @worker.job
  end

  it "knows when it is working" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert @worker.working?
      end
    end
  end

  it "knows when it is idle" do
    @worker.work(0)
    assert @worker.idle?
  end

  it "knows who is working" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert_equal [@worker], ResqueSqs.working
      end
    end
  end

  it "caches the current job iff reloading is disabled" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        first_instance = @worker.job
        second_instance = @worker.job
        refute_equal first_instance.object_id, second_instance.object_id

        first_instance = @worker.job(false)
        second_instance = @worker.job(false)
        assert_equal first_instance.object_id, second_instance.object_id
      end
    end
  end

  it "keeps track of how many jobs it has processed" do
    ResqueSqs::Job.create(:jobs, BadJob)
    ResqueSqs::Job.create(:jobs, BadJob)

    3.times do
      job = @worker.reserve
      @worker.process job
    end
    assert_equal 3, @worker.processed
  end

  it "keeps track of how many failures it has seen" do
    ResqueSqs::Job.create(:jobs, BadJob)
    ResqueSqs::Job.create(:jobs, BadJob)

    3.times do
      job = @worker.reserve
      @worker.process job
    end
    assert_equal 2, @worker.failed
  end

  it "stats are erased when the worker goes away" do
    @worker.work(0)
    assert_equal 0, @worker.processed
    assert_equal 0, @worker.failed
  end

  it "knows when it started" do
    time = Time.now
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert Time.parse(@worker.started) - time < 0.1
      end
    end
  end

  it "knows whether it exists or not" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        assert ResqueSqs::Worker.exists?(@worker)
        assert !ResqueSqs::Worker.exists?('blah-blah')
      end
    end
  end

  it "knows what host it's running on" do
    without_forking do
      blah_worker = nil
      Socket.stub :gethostname, 'blah-blah' do
        blah_worker = ResqueSqs::Worker.new(:jobs)
        blah_worker.register_worker
      end

      @worker.extend(AssertInWorkBlock).work(0) do
        assert ResqueSqs::Worker.exists?(blah_worker)
        assert_equal ResqueSqs::Worker.find(blah_worker).hostname, 'blah-blah'
      end
    end
  end

  it "sets $0 while working" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        prefix = ENV['RESQUE_PROCLINE_PREFIX']
        ver = ResqueSqs::VERSION
        assert_equal "#{prefix}resque-#{ver}: Processing jobs since #{Time.now.to_i} [SomeJob]", $0
      end
    end
  end

  it "can be found" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        found = ResqueSqs::Worker.find(@worker.to_s)

        # we ensure that the found ivar @pid is set to the correct value since
        # ResqueSqs::Worker#pid will use it instead of Process.pid if present
        assert_equal @worker.pid, found.instance_variable_get(:@pid)

        assert_equal @worker.to_s, found.to_s
        assert found.working?
        assert_equal @worker.job, found.job
      end
    end
  end

  it 'can find others' do
    without_forking do
      # inject fake worker
      other_worker = ResqueSqs::Worker.new(:other_jobs)
      other_worker.pid = 123456
      other_worker.register_worker

      begin
        @worker.extend(AssertInWorkBlock).work(0) do
          found = ResqueSqs::Worker.find(other_worker.to_s)
          assert_equal other_worker.to_s, found.to_s
          assert_equal other_worker.pid, found.pid
          assert !found.working?
          assert found.job.empty?
        end
      ensure
        other_worker.unregister_worker
      end
    end
  end

  it "doesn't find fakes" do
    without_forking do
      @worker.extend(AssertInWorkBlock).work(0) do
        found = ResqueSqs::Worker.find('blah-blah')
        assert_nil found
      end
    end
  end

  it "doesn't write PID file when finding" do
    with_pidfile do
      File.expects(:open).never

      without_forking do
        @worker.work(0) do
          ResqueSqs::Worker.find(@worker.to_s)
        end
      end
    end
  end

  it "retrieve queues (includes colon) from worker_id" do
    worker = ResqueSqs::Worker.new("jobs", "foo:bar")
    worker.register_worker

    found = ResqueSqs::Worker.find(worker.to_s)
    assert_equal worker.queues, found.queues
  end

  it "prunes dead workers with heartbeat older than prune interval" do
    assert_equal({}, ResqueSqs::Worker.all_heartbeats)
    now = Time.now

    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.to_s = "bar:3:jobs"
    workerA.register_worker
    workerA.heartbeat!(now - ResqueSqs.prune_interval - 1)

    assert_equal 1, ResqueSqs.workers.size
    assert ResqueSqs::Worker.all_heartbeats.key?(workerA.to_s)

    workerB = ResqueSqs::Worker.new(:jobs)
    workerB.to_s = "foo:5:jobs"
    workerB.register_worker
    workerB.heartbeat!(now)

    assert_equal 2, ResqueSqs.workers.size
    assert ResqueSqs::Worker.all_heartbeats.key?(workerB.to_s)
    assert_equal [workerA], ResqueSqs::Worker.all_workers_with_expired_heartbeats

    @worker.prune_dead_workers

    assert_equal 1, ResqueSqs.workers.size
    refute ResqueSqs::Worker.all_heartbeats.key?(workerA.to_s)
    assert ResqueSqs::Worker.all_heartbeats.key?(workerB.to_s)
    assert_equal [], ResqueSqs::Worker.all_workers_with_expired_heartbeats
  end

  it "does not prune if another worker has pruned (started pruning) recently" do
    now = Time.now
    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.to_s = 'workerA:1:jobs'
    workerA.register_worker
    workerA.heartbeat!(now - ResqueSqs.prune_interval - 1)
    assert_equal 1, ResqueSqs.workers.size
    assert_equal [workerA], ResqueSqs::Worker.all_workers_with_expired_heartbeats

    workerB = ResqueSqs::Worker.new(:jobs)
    workerB.to_s = 'workerB:1:jobs'
    workerB.register_worker
    workerB.heartbeat!(now)
    assert_equal 2, ResqueSqs.workers.size

    workerB.prune_dead_workers
    assert_equal [], ResqueSqs::Worker.all_workers_with_expired_heartbeats

    workerC = ResqueSqs::Worker.new(:jobs)
    workerC.to_s = "workerC:1:jobs"
    workerC.register_worker
    workerC.heartbeat!(now - ResqueSqs.prune_interval - 1)
    assert_equal 2, ResqueSqs.workers.size
    assert_equal [workerC], ResqueSqs::Worker.all_workers_with_expired_heartbeats

    workerD = ResqueSqs::Worker.new(:jobs)
    workerD.to_s = 'workerD:1:jobs'
    workerD.register_worker
    workerD.heartbeat!(now)
    assert_equal 3, ResqueSqs.workers.size

    # workerC does not get pruned because workerB already pruned recently
    workerD.prune_dead_workers
    assert_equal [workerC], ResqueSqs::Worker.all_workers_with_expired_heartbeats
  end

  it "does not prune workers that haven't set a heartbeat" do
    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.to_s = "bar:3:jobs"
    workerA.register_worker

    assert_equal 1, ResqueSqs.workers.size
    assert_equal({}, ResqueSqs::Worker.all_heartbeats)

    @worker.prune_dead_workers

    assert_equal 1, ResqueSqs.workers.size
  end

  it "prunes workers that haven't been registered but have set a heartbeat" do
    assert_equal({}, ResqueSqs::Worker.all_heartbeats)
    now = Time.now

    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.to_s = "bar:3:jobs"
    workerA.heartbeat!(now - ResqueSqs.prune_interval - 1)

    assert_equal 0, ResqueSqs.workers.size
    assert ResqueSqs::Worker.all_heartbeats.key?(workerA.to_s)
    assert_equal [], ResqueSqs::Worker.all

    @worker.prune_dead_workers

    assert_equal 0, ResqueSqs.workers.size
    assert_equal({}, ResqueSqs::Worker.all_heartbeats)
  end

  it "does return a valid time when asking for heartbeat" do
    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.register_worker
    workerA.heartbeat!

    assert_instance_of Time, workerA.heartbeat

    workerA.remove_heartbeat
    assert_nil workerA.heartbeat
  end

  it "removes old heartbeats before starting heartbeat thread" do
    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.register_worker
    workerA.expects(:remove_heartbeat).once
    workerA.start_heartbeat
  end

  it "cleans up heartbeat after unregistering" do
    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.register_worker
    workerA.start_heartbeat

    Timeout.timeout(5) do
      sleep 0.1 while ResqueSqs::Worker.all_heartbeats.empty?

      assert ResqueSqs::Worker.all_heartbeats.key?(workerA.to_s)
      assert_instance_of Time, workerA.heartbeat

      workerA.unregister_worker
      sleep 0.1 until ResqueSqs::Worker.all_heartbeats.empty?
    end

    assert_nil workerA.heartbeat
  end

  it "does not generate heartbeats that depend on the worker clock, but only on the server clock" do
    server_time_before = ResqueSqs.data_store.server_time
    fake_time = Time.parse("2000-01-01")

    with_fake_time(fake_time) do
      worker_time = Time.now

      workerA = ResqueSqs::Worker.new(:jobs)
      workerA.register_worker
      workerA.heartbeat!

      heartbeat_time = workerA.heartbeat
      refute_equal heartbeat_time, worker_time

      server_time_after = ResqueSqs.data_store.server_time
      assert server_time_before <= heartbeat_time
      assert heartbeat_time <= server_time_after
    end
  end

  it "correctly reports a job that the pruned worker was processing" do
    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.to_s = "jobs01.company.com:3:jobs"
    workerA.register_worker

    job = ResqueSqs::Job.new(:jobs, {'class' => 'GoodJob', 'args' => "blah"})
    workerA.working_on(job)
    workerA.heartbeat!(Time.now - ResqueSqs.prune_interval - 1)

    @worker.prune_dead_workers

    assert_equal 1, ResqueSqs::Failure.count
    failure = ResqueSqs::Failure.all(0)
    assert_equal "ResqueSqs::PruneDeadWorkerDirtyExit", failure["exception"]
    assert_equal "Worker jobs01.company.com:3:jobs did not gracefully exit while processing GoodJob", failure["error"]
  end

  # This was added because PruneDeadWorkerDirtyExit does not have a backtrace,
  # and the error handling code did not account for that.
  it "correctly reports errors that occur while pruning workers" do
    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.to_s = "bar:3:jobs"
    workerA.register_worker
    workerA.heartbeat!(Time.now - ResqueSqs.prune_interval - 1)

    # the specific error isn't important, could be something else
    ResqueSqs.data_store.redis.stubs(:get).raises(Redis::CannotConnectError)

    exception_caught = assert_raises Redis::CannotConnectError do
      @worker.prune_dead_workers
    end

    assert_match(/PruneDeadWorkerDirtyExit/, exception_caught.message)
    assert_match(/bar:3:jobs/, exception_caught.message)
    assert_match(/Redis::CannotConnectError/, exception_caught.message)
  end

  it "cleans up dead worker info on start (crash recovery)" do
    # first we fake out several dead workers
    # 1: matches queue and hostname; gets pruned.
    workerA = ResqueSqs::Worker.new(:jobs)
    workerA.instance_variable_set(:@to_s, "#{`hostname`.chomp}:1:jobs")
    workerA.register_worker
    workerA.heartbeat!

    # 2. matches queue but not hostname; no prune.
    workerB = ResqueSqs::Worker.new(:jobs)
    workerB.instance_variable_set(:@to_s, "#{`hostname`.chomp}-foo:2:jobs")
    workerB.register_worker
    workerB.heartbeat!

    # 3. matches hostname but not queue; no prune.
    workerB = ResqueSqs::Worker.new(:high)
    workerB.instance_variable_set(:@to_s, "#{`hostname`.chomp}:3:high")
    workerB.register_worker
    workerB.heartbeat!

    # 4. matches neither hostname nor queue; no prune.
    workerB = ResqueSqs::Worker.new(:high)
    workerB.instance_variable_set(:@to_s, "#{`hostname`.chomp}-foo:4:high")
    workerB.register_worker
    workerB.heartbeat!

    assert_equal 4, ResqueSqs.workers.size

    # then we prune them
    @worker.work(0)

    worker_strings = ResqueSqs::Worker.all.map(&:to_s)

    assert_equal 3, ResqueSqs.workers.size

    # pruned
    assert !worker_strings.include?("#{`hostname`.chomp}:1:jobs")

    # not pruned
    assert worker_strings.include?("#{`hostname`.chomp}-foo:2:jobs")
    assert worker_strings.include?("#{`hostname`.chomp}:3:high")
    assert worker_strings.include?("#{`hostname`.chomp}-foo:4:high")
  end

  it "worker_pids returns pids" do
    @worker.work(0)
    known_workers = @worker.worker_pids
    assert !known_workers.empty?
  end

  it "Processed jobs count" do
    @worker.work(0)
    assert_equal 1, ResqueSqs.info[:processed]
  end

  it "Will call a before_first_fork hook only once" do
    $BEFORE_FORK_CALLED = 0
    ResqueSqs.before_first_fork = Proc.new { $BEFORE_FORK_CALLED += 1 }
    workerA = ResqueSqs::Worker.new(:jobs)
    ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')

    assert_equal 0, $BEFORE_FORK_CALLED

    workerA.work(0)
    assert_equal 1, $BEFORE_FORK_CALLED

    #Verify it's only run once.
    workerA.work(0)
    assert_equal 1, $BEFORE_FORK_CALLED
  end

  it "Will call a before_pause hook before pausing" do
    $BEFORE_PAUSE_CALLED = 0
    $WORKER_NAME = nil
    ResqueSqs.before_pause = Proc.new { |w| $BEFORE_PAUSE_CALLED += 1; $WORKER_NAME = w.to_s; }
    workerA = ResqueSqs::Worker.new(:jobs)

    assert_equal 0, $BEFORE_PAUSE_CALLED
    workerA.pause_processing
    assert_equal 1, $BEFORE_PAUSE_CALLED
    assert_equal workerA.to_s, $WORKER_NAME
  end

  it "Will call a after_pause hook after pausing" do
    $AFTER_PAUSE_CALLED = 0
    $WORKER_NAME = nil
    ResqueSqs.after_pause = Proc.new { |w| $AFTER_PAUSE_CALLED += 1; $WORKER_NAME = w.to_s; }
    workerA = ResqueSqs::Worker.new(:jobs)

    assert_equal 0, $AFTER_PAUSE_CALLED
    workerA.unpause_processing
    assert_equal 1, $AFTER_PAUSE_CALLED
    assert_equal workerA.to_s, $WORKER_NAME
  end

  it "Will call a before_fork hook before forking" do
    $BEFORE_FORK_CALLED = false
    ResqueSqs.before_fork = Proc.new { $BEFORE_FORK_CALLED = true }
    workerA = ResqueSqs::Worker.new(:jobs)

    assert !$BEFORE_FORK_CALLED
    ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')
    workerA.work(0)
    assert $BEFORE_FORK_CALLED
  end

  it "Will not call a before_fork hook when the worker cannot fork" do
    without_forking do
      $BEFORE_FORK_CALLED = false
      ResqueSqs.before_fork = Proc.new { $BEFORE_FORK_CALLED = true }
      workerA = ResqueSqs::Worker.new(:jobs)

      assert !$BEFORE_FORK_CALLED, "before_fork should not have been called before job runs"
      ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')
      workerA.work(0)
      assert !$BEFORE_FORK_CALLED, "before_fork should not have been called after job runs"
    end
  end

  it "Will not call a before_fork hook when forking set to false" do
    $BEFORE_FORK_CALLED = false
    ResqueSqs.before_fork = Proc.new { $BEFORE_FORK_CALLED = true }
    workerA = ResqueSqs::Worker.new(:jobs)

    assert !$BEFORE_FORK_CALLED, "before_fork should not have been called before job runs"
    ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')
    # This sets ENV['FORK_PER_JOB'] = 'false' and then restores it
    without_forking do
      workerA.work(0)
    end
    assert !$BEFORE_FORK_CALLED, "before_fork should not have been called after job runs"
  end

  describe "ResqueSqs::Job queue_empty" do
    before { ResqueSqs.send(:clear_hooks, :queue_empty) }

    it "will call the queue empty hook when the worker becomes idle" do
      # There is already a job in the queue from line 24
      $QUEUE_EMPTY_CALLED = false
      ResqueSqs.queue_empty = Proc.new { $QUEUE_EMPTY_CALLED = true }
      workerA = ResqueSqs::Worker.new(:jobs)

      assert !$QUEUE_EMPTY_CALLED
      workerA.work(0)
      assert $QUEUE_EMPTY_CALLED
    end

    it "will not call the queue empty hook on start-up when it has no jobs to process" do
      ResqueSqs.remove_queue(:jobs)
      $QUEUE_EMPTY_CALLED = false
      ResqueSqs.queue_empty = Proc.new { $QUEUE_EMPTY_CALLED = true }
      workerA = ResqueSqs::Worker.new(:jobs)

      assert !$QUEUE_EMPTY_CALLED
      workerA.work(0)
      assert !$QUEUE_EMPTY_CALLED
    end

    it "will call the queue empty hook only once at the beginning and end of a series of jobs" do
      $QUEUE_EMPTY_CALLED = 0
      ResqueSqs.queue_empty = Proc.new { $QUEUE_EMPTY_CALLED += 1 }
      workerA = ResqueSqs::Worker.new(:jobs)

      assert_equal(0, $QUEUE_EMPTY_CALLED)
      ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')
      workerA.work(0)
      assert_equal(1, $QUEUE_EMPTY_CALLED)
    end
  end

  describe "ResqueSqs::Job worker_exit" do
    before { ResqueSqs.send(:clear_hooks, :worker_exit) }

    it "will call the worker exit hook when the worker terminates normally" do
      $WORKER_EXIT_CALLED = false
      ResqueSqs.worker_exit = Proc.new { $WORKER_EXIT_CALLED = true }
      workerA = ResqueSqs::Worker.new(:jobs)

      assert !$WORKER_EXIT_CALLED
      workerA.work(0)
      assert $WORKER_EXIT_CALLED
    end

    it "will call the worker exit hook when the worker fails to start" do
      $WORKER_EXIT_CALLED = false
      ResqueSqs.worker_exit = Proc.new { $WORKER_EXIT_CALLED = true }
      workerA = ResqueSqs::Worker.new(:jobs)
      workerA.stubs(:startup).raises(Exception.new("testing startup failure"))

      assert !$WORKER_EXIT_CALLED
      workerA.work(0)
      assert $WORKER_EXIT_CALLED
    end
  end

  it "setting verbose to true" do
    @worker.verbose = true

    assert @worker.verbose
    assert !@worker.very_verbose
  end

  it "setting verbose to false" do
    @worker.verbose = false

    assert !@worker.verbose
    assert !@worker.very_verbose
  end

  it "setting very_verbose to true" do
    @worker.very_verbose = true

    assert !@worker.verbose
    assert @worker.very_verbose
  end

  it "setting setting verbose to true and then very_verbose to false" do
    @worker.very_verbose = true
    @worker.verbose      = true
    @worker.very_verbose = false

    assert @worker.verbose
    assert !@worker.very_verbose
  end

  it "verbose prints out logs" do
    messages        = StringIO.new
    ResqueSqs.logger   = Logger.new(messages)
    @worker.verbose = true

    @worker.log("omghi mom")

    assert_equal "*** omghi mom\n", messages.string
  end

  it "unsetting verbose works" do
    messages        = StringIO.new
    ResqueSqs.logger   = Logger.new(messages)
    @worker.verbose = true
    @worker.verbose = false

    @worker.log("omghi mom")

    assert_equal "", messages.string
  end

  it "very verbose works in the afternoon" do
    messages        = StringIO.new
    ResqueSqs.logger   = Logger.new(messages)

    with_fake_time(Time.parse("15:44:33 2011-03-02")) do
      @worker.very_verbose = true
      @worker.log("some log text")

      assert_match(/\*\* \[15:44:33 2011-03-02\] \d+: some log text/, messages.string)
    end
  end

  it "keeps a custom logger state after a new worker is instantiated if there is no verbose options" do
    messages                = StringIO.new
    custom_logger           = Logger.new(messages)
    custom_logger.level     = Logger::FATAL
    custom_formatter        = proc do |severity, datetime, progname, msg|
      formatter.call(severity, datetime, progname, msg.dump)
    end
    custom_logger.formatter = custom_formatter

    ResqueSqs.logger = custom_logger

    ENV.delete 'VERBOSE'
    ENV.delete 'VVERBOSE'
    @worker = ResqueSqs::Worker.new(:jobs)

    assert_equal custom_logger, ResqueSqs.logger
    assert_equal Logger::FATAL, ResqueSqs.logger.level
    assert_equal custom_formatter, ResqueSqs.logger.formatter
  end

  it "won't fork if ENV['FORK_PER_JOB'] is false" do
    old_fork_per_job = ENV["FORK_PER_JOB"]
    begin
      ENV["FORK_PER_JOB"] = 'false'
      assert_equal false, ResqueSqs::Worker.new(:jobs).fork_per_job?
    ensure
      ENV["FORK_PER_JOB"] = old_fork_per_job
    end
  end

  it "Will call an after_fork hook after forking" do
    begin
      pipe_rd, pipe_wr = IO.pipe

      ResqueSqs.after_fork = Proc.new { pipe_wr.write('hey') }
      workerA = ResqueSqs::Worker.new(:jobs)

      ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')
      workerA.work(0)

      pipe_rd.wait_readable(1)
      assert_equal('hey', pipe_rd.read_nonblock(3))
    ensure
      pipe_rd.close
      pipe_wr.close
    end
  end

  it "Will not call an after_fork hook when the worker won't fork" do
    without_forking do
      $AFTER_FORK_CALLED = false
      ResqueSqs.after_fork = Proc.new { $AFTER_FORK_CALLED = true }
      workerA = ResqueSqs::Worker.new(:jobs)

      assert !$AFTER_FORK_CALLED
      ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')
      workerA.work(0)
      assert !$AFTER_FORK_CALLED
    end
  end

  it "returns PID of running process" do
    assert_equal @worker.to_s.split(":")[1].to_i, @worker.pid
  end

  it "requeue failed queue" do
    queue = 'good_job'
    ResqueSqs::Failure.create(:exception => Exception.new, :worker => ResqueSqs::Worker.new(queue), :queue => queue, :payload => {'class' => 'GoodJob'})
    ResqueSqs::Failure.create(:exception => Exception.new, :worker => ResqueSqs::Worker.new(queue), :queue => 'some_job', :payload => {'class' => 'SomeJob'})
    ResqueSqs::Failure.requeue_queue(queue)
    assert ResqueSqs::Failure.all(0).has_key?('retried_at')
    assert !ResqueSqs::Failure.all(1).has_key?('retried_at')
  end

  it "remove failed queue" do
    queue = 'good_job'
    queue2 = 'some_job'
    ResqueSqs::Failure.create(:exception => Exception.new, :worker => ResqueSqs::Worker.new(queue), :queue => queue, :payload => {'class' => 'GoodJob'})
    ResqueSqs::Failure.create(:exception => Exception.new, :worker => ResqueSqs::Worker.new(queue2), :queue => queue2, :payload => {'class' => 'SomeJob'})
    ResqueSqs::Failure.create(:exception => Exception.new, :worker => ResqueSqs::Worker.new(queue), :queue => queue, :payload => {'class' => 'GoodJob'})
    ResqueSqs::Failure.remove_queue(queue)
    assert_equal queue2, ResqueSqs::Failure.all(0)['queue']
    assert_equal 1, ResqueSqs::Failure.count
  end

  it '.clear_retried should clear all retried jobs' do
    # Job 1
    ResqueSqs::Failure.create(:exception => Exception.new, :worker => ResqueSqs::Worker.new('queue'), :queue => 'queue', :payload => {'class' => 'GoodJob' })

    # Job 2
    ResqueSqs::Failure.create(:exception => Exception.new, :worker => ResqueSqs::Worker.new('queue'), :queue => 'queue', :payload => {'class' => 'GoodJob' })

    # Job 3
    ResqueSqs::Failure.create(:exception => Exception.new, :worker => ResqueSqs::Worker.new('queue'), :queue => 'other_queue', :payload => {'class' => 'GoodJob' })

    assert_equal 3, ResqueSqs::Failure.count

    # Retry Job 1 and Job 3
    ResqueSqs::Failure.requeue(0)
    ResqueSqs::Failure.requeue(2)

    assert_equal 3, ResqueSqs::Failure.count

    ResqueSqs::Failure.clear_retried

    assert_equal 1, ResqueSqs::Failure.count
  end

  it "no disconnect from redis when not forking" do
    original_connection = redis_socket(ResqueSqs.redis)
    without_forking do
      @worker.work(0)
    end
    assert_equal original_connection, redis_socket(ResqueSqs.redis)
  end

  it "logs errors with the correct logging level" do
    messages = StringIO.new
    ResqueSqs.logger = Logger.new(messages)
    @worker.report_failed_job(BadJobWithSyntaxError, SyntaxError)

    assert_equal 0, messages.string.scan(/INFO/).count
    assert_equal 2, messages.string.scan(/ERROR/).count
  end

  it "logs info with the correct logging level" do
    messages = StringIO.new
    ResqueSqs.logger = Logger.new(messages)
    @worker.shutdown

    assert_equal 1, messages.string.scan(/INFO/).count
    assert_equal 0, messages.string.scan(/ERROR/).count
  end

  class CounterJob
    class << self
      attr_accessor :perform_count
    end
    self.perform_count = 0

    def self.perform
      self.perform_count += 1
    end
  end

  it "runs jobs without forking if fork isn't implemented" do
    nil while @worker.reserve # empty queue
    @worker.expects(:fork).raises(NotImplementedError)
    ResqueSqs.enqueue_to(:jobs, CounterJob)

    begin
      @worker.work(0)
      assert_equal 1, CounterJob.perform_count
      assert_equal false, @worker.fork_per_job?
    ensure
      CounterJob.perform_count = 0
    end
  end

  if !defined?(RUBY_ENGINE) || RUBY_ENGINE != "jruby"
    class ForkResultJob
      @queue = :jobs

      def self.perform_with_result(worker, &block)
        @rd, @wr = IO.pipe
        @block = block
        ResqueSqs.enqueue(self)
        worker.work(0)
        @wr.close
        Marshal.load(@rd.read)
      ensure
        @rd, @wr, @block = nil
      end

      def self.perform
        result = @block.call
        @wr.write(Marshal.dump(result))
        @wr.close
      end
    end

    def run_in_job(&block)
      ForkResultJob.perform_with_result(@worker, &block)
    end

    it "reconnects to redis after fork" do
      original_connection = redis_socket(ResqueSqs.redis).object_id
      new_connection = run_in_job do
        redis_socket(ResqueSqs.redis).object_id
      end
      assert ResqueSqs.redis._client.connected?
      refute_equal original_connection, new_connection
    end

    it "tries to reconnect three times before giving up and the failure does not unregister the parent" do
      @worker.data_store.stubs(:reconnect).raises(Redis::BaseConnectionError)
      @worker.stubs(:sleep)

      ResqueSqs.logger = DummyLogger.new
      @worker.work(0)
      messages = ResqueSqs.logger.messages

      assert_equal 3, messages.grep(/retrying/).count
      assert_equal 1, messages.grep(/quitting/).count
      assert_equal 0, messages.grep(/Failed to start worker/).count
      assert_equal 1, messages.grep(/Redis::BaseConnectionError: Redis::BaseConnectionError/).count
    end

    it "tries to reconnect three times before giving up" do
      @worker.data_store.stubs(:reconnect).raises(Redis::BaseConnectionError)
      @worker.stubs(:sleep)

      ResqueSqs.logger = DummyLogger.new
      @worker.work(0)
      messages = ResqueSqs.logger.messages

      assert_equal 3, messages.grep(/retrying/).count
      assert_equal 1, messages.grep(/quitting/).count
    end

    if !defined?(RUBY_ENGINE) || defined?(RUBY_ENGINE) && RUBY_ENGINE != "jruby"
      class PreShutdownLongRunningJob
        @queue = :long_running_job

        def self.perform(run_time)
          ResqueSqs.redis.disconnect! # get its own connection
          ResqueSqs.redis.rpush('pre-term-timeout-test:start', Process.pid)
          sleep run_time
          ResqueSqs.redis.rpush('pre-term-timeout-test:result', 'Finished Normally')
        rescue ResqueSqs::TermException => e
          ResqueSqs.redis.rpush('pre-term-timeout-test:result', %Q(Caught TermException: #{e.inspect}))
        ensure
          ResqueSqs.redis.rpush('pre-term-timeout-test:final', 'exiting.')
        end
      end

      {
        'job finishes in allotted time' => 0.5,
        'job takes too long' => 1.1
      }.each do |scenario, run_time|
        it "gives time to finish before sending term if pre_shutdown_timeout is set: when #{scenario}" do
          begin
            pre_shutdown_timeout = 1
            ResqueSqs.enqueue(PreShutdownLongRunningJob, run_time)

            worker_pid = Kernel.fork do
              # reconnect to redis
              ResqueSqs.redis.disconnect!

              worker = ResqueSqs::Worker.new(:long_running_job)
              worker.pre_shutdown_timeout = pre_shutdown_timeout
              worker.term_timeout = 2
              worker.term_child = 1

              worker.work(0)
              exit!
            end

            # ensure the worker is started
            start_status = ResqueSqs.redis.blpop('pre-term-timeout-test:start', timeout: 5)
            refute start_status == nil
            child_pid = start_status[1].to_i
            assert_operator child_pid, :>, 0

            # send signal to abort the worker
            Process.kill('TERM', worker_pid)
            Process.waitpid(worker_pid)

            # wait to see how it all came down
            result = ResqueSqs.redis.blpop('pre-term-timeout-test:result', timeout: 5)
            refute result == nil

            if run_time >= pre_shutdown_timeout
              assert !result[1].start_with?('Finished Normally'), 'Job finished normally when running over pre term timeout'
              assert result[1].start_with?('Caught TermException'), 'TermException not raised in child.'
            else
              assert result[1].start_with?('Finished Normally'), 'Job did not finish normally. Pre term timeout too short?'
              assert !result[1].start_with?('Caught TermException'), 'TermException raised in child.'
            end

            # ensure that the child pid is no longer running
            child_still_running = !(`ps -p #{child_pid.to_s} -o pid=`).empty?
            assert !child_still_running
          ensure
            remaining_keys = ResqueSqs.redis.keys('pre-term-timeout-test:*') || []
            ResqueSqs.redis.del(*remaining_keys) unless remaining_keys.empty?
          end
        end
      end
    end

    class SuicidalJob
      @queue = :jobs

      def self.perform
        Process.kill('KILL', Process.pid)
      end

      def self.on_failure_store_exception(exc, *args)
        @@failure_exception = exc
      end
    end

    it "will notify failure hooks and attach process status when a job is killed by a signal" do
      ResqueSqs.enqueue(SuicidalJob)
      suppress_warnings do
        @worker.work(0)
      end

      exception = SuicidalJob.send(:class_variable_get, :@@failure_exception)

      assert_kind_of ResqueSqs::DirtyExit, exception
      assert_match(/Child process received unhandled signal pid \d+ SIGKILL \(signal 9\)/, exception.message)

      assert_kind_of Process::Status, exception.process_status
    end
  end

  private

  def redis_socket(redis)
    if ::Redis::VERSION < "5"
      redis._client.connection.instance_variable_get(:@sock)
    else
      redis._client.instance_variable_get(:@raw_connection)
    end
  end
end
