require 'test_helper'

context "Resque" do
  setup do
    ResqueSqs.redis.flushall

    ResqueSqs.push(:people, { 'name' => 'chris' })
    ResqueSqs.push(:people, { 'name' => 'bob' })
    ResqueSqs.push(:people, { 'name' => 'mark' })
    @original_redis = ResqueSqs.redis
  end

  teardown do
    ResqueSqs.redis = @original_redis
  end

  test "can set a namespace through a url-like string" do
    assert ResqueSqs.redis
    assert_equal :resque, ResqueSqs.redis.namespace
    ResqueSqs.redis = 'localhost:9736/namespace'
    assert_equal 'namespace', ResqueSqs.redis.namespace
  end

  test "redis= works correctly with a Redis::Namespace param" do
    new_redis = Redis.new(:host => "localhost", :port => 9736)
    new_namespace = Redis::Namespace.new("namespace", :redis => new_redis)
    ResqueSqs.redis = new_namespace
    assert_equal new_namespace, ResqueSqs.redis

    ResqueSqs.redis = 'localhost:9736/namespace'
  end

  test "can put jobs on a queue" do
    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 20, '/tmp')
    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 20, '/tmp')
  end

  test "can grab jobs off a queue" do
    ResqueSqs::Job.create(:jobs, 'some-job', 20, '/tmp')

    job = ResqueSqs.reserve(:jobs)

    assert_kind_of ResqueSqs::Job, job
    assert_equal SomeJob, job.payload_class
    assert_equal 20, job.args[0]
    assert_equal '/tmp', job.args[1]
  end

  test "can re-queue jobs" do
    ResqueSqs::Job.create(:jobs, 'some-job', 20, '/tmp')

    job = ResqueSqs.reserve(:jobs)
    job.recreate

    assert_equal job, ResqueSqs.reserve(:jobs)
  end

  test "can put jobs on a queue by way of an ivar" do
    assert_equal 0, ResqueSqs.size(:ivar)
    assert ResqueSqs.enqueue(SomeIvarJob, 20, '/tmp')
    assert ResqueSqs.enqueue(SomeIvarJob, 20, '/tmp')

    job = ResqueSqs.reserve(:ivar)

    assert_kind_of ResqueSqs::Job, job
    assert_equal SomeIvarJob, job.payload_class
    assert_equal 20, job.args[0]
    assert_equal '/tmp', job.args[1]

    assert ResqueSqs.reserve(:ivar)
    assert_equal nil, ResqueSqs.reserve(:ivar)
  end

  test "can remove jobs from a queue by way of an ivar" do
    assert_equal 0, ResqueSqs.size(:ivar)
    assert ResqueSqs.enqueue(SomeIvarJob, 20, '/tmp')
    assert ResqueSqs.enqueue(SomeIvarJob, 30, '/tmp')
    assert ResqueSqs.enqueue(SomeIvarJob, 20, '/tmp')
    assert ResqueSqs::Job.create(:ivar, 'blah-job', 20, '/tmp')
    assert ResqueSqs.enqueue(SomeIvarJob, 20, '/tmp')
    assert_equal 5, ResqueSqs.size(:ivar)

    assert_equal 1, ResqueSqs.dequeue(SomeIvarJob, 30, '/tmp')
    assert_equal 4, ResqueSqs.size(:ivar)
    assert_equal 3, ResqueSqs.dequeue(SomeIvarJob)
    assert_equal 1, ResqueSqs.size(:ivar)
  end

  test "jobs have a nice #inspect" do
    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 20, '/tmp')
    job = ResqueSqs.reserve(:jobs)
    assert_equal '(Job{jobs} | SomeJob | [20, "/tmp"])', job.inspect
  end

  test "jobs can be destroyed" do
    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 20, '/tmp')
    assert ResqueSqs::Job.create(:jobs, 'BadJob', 20, '/tmp')
    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 20, '/tmp')
    assert ResqueSqs::Job.create(:jobs, 'BadJob', 30, '/tmp')
    assert ResqueSqs::Job.create(:jobs, 'BadJob', 20, '/tmp')

    assert_equal 5, ResqueSqs.size(:jobs)
    assert_equal 2, ResqueSqs::Job.destroy(:jobs, 'SomeJob')
    assert_equal 3, ResqueSqs.size(:jobs)
    assert_equal 1, ResqueSqs::Job.destroy(:jobs, 'BadJob', 30, '/tmp')
    assert_equal 2, ResqueSqs.size(:jobs)
  end

  test "jobs can test for equality" do
    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 20, '/tmp')
    assert ResqueSqs::Job.create(:jobs, 'some-job', 20, '/tmp')
    assert_equal ResqueSqs.reserve(:jobs), ResqueSqs.reserve(:jobs)

    assert ResqueSqs::Job.create(:jobs, 'SomeMethodJob', 20, '/tmp')
    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 20, '/tmp')
    assert_not_equal ResqueSqs.reserve(:jobs), ResqueSqs.reserve(:jobs)

    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 20, '/tmp')
    assert ResqueSqs::Job.create(:jobs, 'SomeJob', 30, '/tmp')
    assert_not_equal ResqueSqs.reserve(:jobs), ResqueSqs.reserve(:jobs)
  end

  test "can put jobs on a queue by way of a method" do
    assert_equal 0, ResqueSqs.size(:method)
    assert ResqueSqs.enqueue(SomeMethodJob, 20, '/tmp')
    assert ResqueSqs.enqueue(SomeMethodJob, 20, '/tmp')

    job = ResqueSqs.reserve(:method)

    assert_kind_of ResqueSqs::Job, job
    assert_equal SomeMethodJob, job.payload_class
    assert_equal 20, job.args[0]
    assert_equal '/tmp', job.args[1]

    assert ResqueSqs.reserve(:method)
    assert_equal nil, ResqueSqs.reserve(:method)
  end

  test "can define a queue for jobs by way of a method" do
    assert_equal 0, ResqueSqs.size(:method)
    assert ResqueSqs.enqueue_to(:new_queue, SomeMethodJob, 20, '/tmp')

    job = ResqueSqs.reserve(:new_queue)
    assert_equal SomeMethodJob, job.payload_class
    assert_equal 20, job.args[0]
    assert_equal '/tmp', job.args[1]
  end

  test "needs to infer a queue with enqueue" do
    assert_raises ResqueSqs::NoQueueError do
      ResqueSqs.enqueue(SomeJob, 20, '/tmp')
    end
  end

  test "validates job for queue presence" do
    assert_raises ResqueSqs::NoQueueError do
      ResqueSqs.validate(SomeJob)
    end
  end

  test "can put items on a queue" do
    assert ResqueSqs.push(:people, { 'name' => 'jon' })
  end

  test "can pull items off a queue" do
    assert_equal({ 'name' => 'chris' }, ResqueSqs.pop(:people))
    assert_equal({ 'name' => 'bob' }, ResqueSqs.pop(:people))
    assert_equal({ 'name' => 'mark' }, ResqueSqs.pop(:people))
    assert_equal nil, ResqueSqs.pop(:people)
  end

  test "knows how big a queue is" do
    assert_equal 3, ResqueSqs.size(:people)

    assert_equal({ 'name' => 'chris' }, ResqueSqs.pop(:people))
    assert_equal 2, ResqueSqs.size(:people)

    assert_equal({ 'name' => 'bob' }, ResqueSqs.pop(:people))
    assert_equal({ 'name' => 'mark' }, ResqueSqs.pop(:people))
    assert_equal 0, ResqueSqs.size(:people)
  end

  test "can peek at a queue" do
    assert_equal({ 'name' => 'chris' }, ResqueSqs.peek(:people))
    assert_equal 3, ResqueSqs.size(:people)
  end

  test "can peek multiple items on a queue" do
    assert_equal({ 'name' => 'bob' }, ResqueSqs.peek(:people, 1, 1))

    assert_equal([{ 'name' => 'bob' }, { 'name' => 'mark' }], ResqueSqs.peek(:people, 1, 2))
    assert_equal([{ 'name' => 'chris' }, { 'name' => 'bob' }], ResqueSqs.peek(:people, 0, 2))
    assert_equal([{ 'name' => 'chris' }, { 'name' => 'bob' }, { 'name' => 'mark' }], ResqueSqs.peek(:people, 0, 3))
    assert_equal({ 'name' => 'mark' }, ResqueSqs.peek(:people, 2, 1))
    assert_equal nil, ResqueSqs.peek(:people, 3)
    assert_equal [], ResqueSqs.peek(:people, 3, 2)
  end

  test "knows what queues it is managing" do
    assert_equal %w( people ), ResqueSqs.queues
    ResqueSqs.push(:cars, { 'make' => 'bmw' })
    assert_equal %w( cars people ).sort, ResqueSqs.queues.sort
  end

  test "queues are always a list" do
    ResqueSqs.redis.flushall
    assert_equal [], ResqueSqs.queues
  end

  test "can delete a queue" do
    ResqueSqs.push(:cars, { 'make' => 'bmw' })
    assert_equal %w( cars people ).sort, ResqueSqs.queues.sort
    ResqueSqs.remove_queue(:people)
    assert_equal %w( cars ), ResqueSqs.queues
    assert_equal nil, ResqueSqs.pop(:people)
  end

  test "keeps track of resque keys" do
    assert_equal ["queue:people", "queues"].sort, ResqueSqs.keys.sort
  end

  test "badly wants a class name, too" do
    assert_raises ResqueSqs::NoClassError do
      ResqueSqs::Job.create(:jobs, nil)
    end
  end

  test "keeps stats" do
    ResqueSqs::Job.create(:jobs, SomeJob, 20, '/tmp')
    ResqueSqs::Job.create(:jobs, BadJob)
    ResqueSqs::Job.create(:jobs, GoodJob)

    ResqueSqs::Job.create(:others, GoodJob)
    ResqueSqs::Job.create(:others, GoodJob)

    stats = ResqueSqs.info
    assert_equal 8, stats[:pending]

    @worker = ResqueSqs::Worker.new(:jobs)
    @worker.register_worker
    2.times { @worker.process }

    job = @worker.reserve
    @worker.working_on job

    stats = ResqueSqs.info
    assert_equal 1, stats[:working]
    assert_equal 1, stats[:workers]

    @worker.done_working

    stats = ResqueSqs.info
    assert_equal 3, stats[:queues]
    assert_equal 3, stats[:processed]
    assert_equal 1, stats[:failed]
    if ENV.key? 'RESQUE_DISTRIBUTED'
      assert_equal [ResqueSqs.redis.respond_to?(:server) ? 'localhost:9736, localhost:9737' : 'redis://localhost:9736/0, redis://localhost:9737/0'], stats[:servers]
    else
      assert_equal [ResqueSqs.redis.respond_to?(:server) ? 'localhost:9736' : 'redis://localhost:9736/0'], stats[:servers]
    end
  end

  test "decode bad json" do
    assert_raises ResqueSqs::Helpers::DecodeException do
      ResqueSqs.decode("{\"error\":\"Module not found \\u002\"}")
    end
  end

  test "inlining jobs" do
    begin
      ResqueSqs.inline = true
      ResqueSqs.enqueue(SomeIvarJob, 20, '/tmp')
      assert_equal 0, ResqueSqs.size(:ivar)
    ensure
      ResqueSqs.inline = false
    end
  end
end
