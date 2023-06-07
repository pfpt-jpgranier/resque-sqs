require 'test_helper'
require 'resque_sqs/failure/redis'

context "ResqueSqs::Failure::Redis" do
  setup do
    @bad_string    = [39, 52, 127, 86, 93, 95, 39].map { |c| c.chr }.join
    exception      = StandardError.exception(@bad_string)
    worker         = ResqueSqs::Worker.new(:test)
    queue          = "queue"
    payload        = { "class" => Object, "args" => 3 }
    @redis_backend = ResqueSqs::Failure::Redis.new(exception, worker, queue, payload)
  end

  test 'cleans up bad strings before saving the failure, in order to prevent errors on the resque UI' do
    # test assumption: the bad string should not be able to round trip though JSON
    @redis_backend.save
    ResqueSqs::Failure::Redis.all # should not raise an error
  end
end
