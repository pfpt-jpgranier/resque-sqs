require 'rack/test'
require 'resque_sqs/server'

module ResqueSqs
  module TestHelper
    class Test::Unit::TestCase
      include Rack::Test::Methods
      def app
        ResqueSqs::Server.new
      end 

      def self.should_respond_with_success
        test "should respond with success" do
          assert last_response.ok?, last_response.errors
        end
      end
    end
  end
end
