require 'test_helper'
require 'tempfile'

describe "Resque Hooks" do
  class CallNotifyJob
    def self.perform
      $called = true
    end
  end

  before do
    $called = false
    @worker = ResqueSqs::Worker.new(:jobs)
  end

  it 'retrieving hooks if none have been set' do
    assert_equal [], ResqueSqs.before_first_fork
    assert_equal [], ResqueSqs.before_fork
    assert_equal [], ResqueSqs.after_fork
  end

  it 'it calls before_first_fork once' do
    counter = 0

    ResqueSqs.before_first_fork { counter += 1 }
    2.times { ResqueSqs::Job.create(:jobs, CallNotifyJob) }

    assert_equal(0, counter)
    @worker.work(0)
    assert_equal(1, counter)
  end

  it 'it calls before_fork before each job' do
    file = Tempfile.new("resque_before_fork") # to share state with forked process

    begin
      File.open(file.path, "w") {|f| f.write(0)}
      ResqueSqs.before_fork do
        val = File.read(file).strip.to_i
        File.open(file.path, "w") {|f| f.write(val + 1)}
      end
      2.times { ResqueSqs::Job.create(:jobs, CallNotifyJob) }

      val = File.read(file.path).strip.to_i
      assert_equal(0, val)
      @worker.work(0)
      val = File.read(file.path).strip.to_i
      assert_equal(2, val)
    ensure
      file.delete
    end
  end

  it 'it calls after_fork after each job' do
    file = Tempfile.new("resque_after_fork") # to share state with forked process

    begin
      File.open(file.path, "w") {|f| f.write(0)}
      ResqueSqs.after_fork do
        val = File.read(file).strip.to_i
        File.open(file.path, "w") {|f| f.write(val + 1)}
      end
      2.times { ResqueSqs::Job.create(:jobs, CallNotifyJob) }

      val = File.read(file.path).strip.to_i
      assert_equal(0, val)
      @worker.work(0)
      val = File.read(file.path).strip.to_i
      assert_equal(2, val)
    ensure
      file.delete
    end
  end

  it 'it calls before_first_fork before forking' do
    ResqueSqs.before_first_fork { assert(!$called) }

    ResqueSqs::Job.create(:jobs, CallNotifyJob)
    @worker.work(0)
  end

  it 'it calls before_fork before forking' do
    ResqueSqs.before_fork { assert(!$called) }

    ResqueSqs::Job.create(:jobs, CallNotifyJob)
    @worker.work(0)
  end

  it 'it calls after_fork after forking' do
    ResqueSqs.after_fork { assert($called) }

    ResqueSqs::Job.create(:jobs, CallNotifyJob)
    @worker.work(0)
  end

  it 'it registers multiple before_first_forks' do
    first = false
    second = false

    ResqueSqs.before_first_fork { first = true }
    ResqueSqs.before_first_fork { second = true }
    ResqueSqs::Job.create(:jobs, CallNotifyJob)

    assert(!first && !second)
    @worker.work(0)
    assert(first && second)
  end

  it 'it registers multiple before_forks' do
    # use tempfiles to share state with forked process
    file = Tempfile.new("resque_before_fork_first")
    file2 = Tempfile.new("resque_before_fork_second")

    begin
      File.open(file.path, "w") {|f| f.write(1)}
      File.open(file2.path, "w") {|f| f.write(2)}

      ResqueSqs.before_fork do
        val = File.read(file.path).strip.to_i
        File.open(file.path, "w") {|f| f.write(val + 1)}
      end

      ResqueSqs.before_fork do
        val = File.read(file2.path).strip.to_i
        File.open(file2.path, "w") {|f| f.write(val + 1)}
      end
      ResqueSqs::Job.create(:jobs, CallNotifyJob)

      @worker.work(0)
      val = File.read(file.path).strip.to_i
      val2 = File.read(file2.path).strip.to_i
      assert_equal(val, 2)
      assert_equal(val2, 3)
    ensure
      file.delete
      file2.delete
    end
  end

  it 'it registers multiple after_forks' do
    # use tempfiles to share state with forked process
    file = Tempfile.new("resque_after_fork_first")
    file2 = Tempfile.new("resque_after_fork_second")

    begin
      File.open(file.path, "w") {|f| f.write(1)}
      File.open(file2.path, "w") {|f| f.write(2)}

      ResqueSqs.after_fork do
        val = File.read(file.path).strip.to_i
        File.open(file.path, "w") {|f| f.write(val + 1)}
      end

      ResqueSqs.after_fork do
        val = File.read(file2.path).strip.to_i
        File.open(file2.path, "w") {|f| f.write(val + 1)}
      end
      ResqueSqs::Job.create(:jobs, CallNotifyJob)

      @worker.work(0)
      val = File.read(file.path).strip.to_i
      val2 = File.read(file2.path).strip.to_i
      assert_equal(val, 2)
      assert_equal(val2, 3)
    ensure
      file.delete
      file2.delete
    end
  end
end
