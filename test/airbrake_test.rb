
require 'test_helper'

begin
  require 'airbrake'
rescue LoadError
  warn "Install airbrake gem to run Airbrake tests."
end

if defined? Airbrake
  require 'resque_sqs/failure/airbrake'
  context "Airbrake" do
    test "should be notified of an error" do
      exception = StandardError.new("BOOM")
      worker = ResqueSqs::Worker.new(:test)
      queue = "test"
      payload = {'class' => Object, 'args' => 66}

      Airbrake.expects(:notify_or_ignore).with(
        exception,
        :parameters => {:payload_class => 'Object', :payload_args => '66'})

      backend = ResqueSqs::Failure::Airbrake.new(exception, worker, queue, payload)
      backend.save
    end
  end
end
