require 'sinatra/base'
require 'erb'
require 'resque_sqs'
require 'resque_sqs/version'
require 'time'
require 'yaml'

if defined? Encoding
  Encoding.default_external = Encoding::UTF_8
end

module ResqueSqs
  class Server < Sinatra::Base
    require 'resque_sqs/server/helpers'

    dir = File.dirname(File.expand_path(__FILE__))

    set :views,  "#{dir}/server/views"

    if respond_to? :public_folder
      set :public_folder, "#{dir}/server/public"
    else
      set :public, "#{dir}/server/public"
    end

    set :static, true

    helpers do
      include Rack::Utils
      alias_method :h, :escape_html

      def current_section
        url_path request.path_info.sub('/','').split('/')[0].downcase
      end

      def current_page
        url_path request.path_info.sub('/','')
      end

      def url_path(*path_parts)
        [ path_prefix, path_parts ].join("/").squeeze('/')
      end
      alias_method :u, :url_path

      def path_prefix
        request.env['SCRIPT_NAME']
      end

      def class_if_current(path = '')
        'class="current"' if current_page[0, path.size] == path
      end

      def tab(name)
        dname = name.to_s.downcase
        path = url_path(dname)
        "<li #{class_if_current(path)}><a href='#{path}'>#{name}</a></li>"
      end

      def tabs
        ResqueSqs::Server.tabs
      end

      def redis_get_size(key)
        case ResqueSqs.redis.type(key)
        when 'none'
          []
        when 'list'
          ResqueSqs.redis.llen(key)
        when 'set'
          ResqueSqs.redis.scard(key)
        when 'string'
          ResqueSqs.redis.get(key).length
        when 'zset'
          ResqueSqs.redis.zcard(key)
        end
      end

      def redis_get_value_as_array(key, start=0)
        case ResqueSqs.redis.type(key)
        when 'none'
          []
        when 'list'
          ResqueSqs.redis.lrange(key, start, start + 20)
        when 'set'
          ResqueSqs.redis.smembers(key)[start..(start + 20)]
        when 'string'
          [ResqueSqs.redis.get(key)]
        when 'zset'
          ResqueSqs.redis.zrange(key, start, start + 20)
        end
      end

      def show_args(args)
        Array(args).map do |a|
          a.to_yaml
        end.join("\n")
      end

      def worker_hosts
        @worker_hosts ||= worker_hosts!
      end

      def worker_hosts!
        hosts = Hash.new { [] }

        ResqueSqs.workers.each do |worker|
          host, _ = worker.to_s.split(':')
          hosts[host] += [worker.to_s]
        end

        hosts
      end

      def partial?
        @partial
      end

      def partial(template, local_vars = {})
        @partial = true
        erb(template.to_sym, {:layout => false}, local_vars)
      ensure
        @partial = false
      end

      def poll
        if @polling
          text = "Last Updated: #{Time.now.strftime("%H:%M:%S")}"
        else
          text = "<a href='#{u(request.path_info)}.poll' rel='poll'>Live Poll</a>"
        end
        "<p class='poll'>#{text}</p>"
      end

    end

    def show(page, layout = true)
      response["Cache-Control"] = "max-age=0, private, must-revalidate"
      begin
        erb page.to_sym, {:layout => layout}, :resque => ResqueSqs
      rescue Errno::ECONNREFUSED
        erb :error, {:layout => false}, :error => "Can't connect to Redis! (#{ResqueSqs.redis_id})"
      end
    end

    def show_for_polling(page)
      content_type "text/html"
      @polling = true
      show(page.to_sym, false).gsub(/\s{1,}/, ' ')
    end

    # to make things easier on ourselves
    get "/?" do
      redirect url_path(:overview)
    end

    %w( overview workers ).each do |page|
      get "/#{page}.poll/?" do
        show_for_polling(page)
      end

      get "/#{page}/:id.poll/?" do
        show_for_polling(page)
      end
    end

    %w( overview queues working workers key ).each do |page|
      get "/#{page}/?" do
        show page
      end

      get "/#{page}/:id/?" do
        show page
      end
    end

    post "/queues/:id/remove" do
      ResqueSqs.remove_queue(params[:id])
      redirect u('queues')
    end

    get "/failed/?" do
      if ResqueSqs::Failure.url
        redirect ResqueSqs::Failure.url
      else
        show :failed
      end
    end

    get "/failed/:queue" do
      if ResqueSqs::Failure.url
        redirect ResqueSqs::Failure.url
      else
        show :failed
      end
    end

    post "/failed/clear" do
      ResqueSqs::Failure.clear
      redirect u('failed')
    end

    post "/failed/:queue/clear" do
      ResqueSqs::Failure.clear params[:queue]
      redirect u('failed')
    end

    post "/failed/requeue/all" do
      ResqueSqs::Failure.count.times do |num|
        ResqueSqs::Failure.requeue(num)
      end
      redirect u('failed')
    end

    post "/failed/:queue/requeue/all" do
      ResqueSqs::Failure.requeue_queue ResqueSqs::Failure.job_queue_name(params[:queue])
      redirect url_path("/failed/#{params[:queue]}")
    end

    get "/failed/requeue/:index/?" do
      ResqueSqs::Failure.requeue(params[:index])
      if request.xhr?
        return ResqueSqs::Failure.all(params[:index])['retried_at']
      else
        redirect u('failed')
      end
    end

    get "/failed/remove/:index/?" do
      ResqueSqs::Failure.remove(params[:index])
      redirect u('failed')
    end

    get "/stats/?" do
      redirect url_path("/stats/resque")
    end

    get "/stats/:id/?" do
      show :stats
    end

    get "/stats/keys/:key/?" do
      show :stats
    end

    get "/stats.txt/?" do
      info = ResqueSqs.info

      stats = []
      stats << "resque.pending=#{info[:pending]}"
      stats << "resque.processed+=#{info[:processed]}"
      stats << "resque.failed+=#{info[:failed]}"
      stats << "resque.workers=#{info[:workers]}"
      stats << "resque.working=#{info[:working]}"

      ResqueSqs.queues.each do |queue|
        stats << "queues.#{queue}=#{ResqueSqs.size(queue)}"
      end

      content_type 'text/html'
      stats.join "\n"
    end

    def resque
      ResqueSqs
    end

    def self.tabs
      @tabs ||= ["Overview", "Working", "Failed", "Queues", "Workers", "Stats"]
    end
  end
end
