require 'test_helper'
require 'minitest/mock'

context "ResqueSqs::Logging" do
  teardown { reset_logger }

  test "sets and receives the active logger" do
    my_logger = Object.new
    ResqueSqs.logger = my_logger
    assert_equal my_logger, ResqueSqs.logger
  end

  %w(debug info error fatal).each do |severity|
    test "logs #{severity} messages" do
      message       = "test message"
      mock_logger   = MiniTest::Mock.new
      mock_logger.expect severity.to_sym, nil, [message]
      ResqueSqs.logger = mock_logger

      ResqueSqs::Logging.send severity, message
      mock_logger.verify
    end
  end
end