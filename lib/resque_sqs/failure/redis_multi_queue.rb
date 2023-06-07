module ResqueSqs
  module Failure
    # A Failure backend that stores exceptions in Redis. Very simple but
    # works out of the box, along with support in the Resque web app.
    class RedisMultiQueue < Base
      def save
        data = {
          :failed_at => Time.now.strftime("%Y/%m/%d %H:%M:%S %Z"),
          :payload   => payload,
          :exception => exception.class.to_s,
          :error     => UTF8Util.clean(exception.to_s),
          :backtrace => filter_backtrace(Array(exception.backtrace)),
          :worker    => worker.to_s,
          :queue     => queue
        }
        data = ResqueSqs.encode(data)
        ResqueSqs.redis.rpush(ResqueSqs::Failure.failure_queue_name(queue), data)
      end

      def self.count(queue = nil, class_name = nil)
        if queue
          if class_name
            n = 0
            each(0, count(queue), queue, class_name) { n += 1 } 
            n
          else
            ResqueSqs.redis.llen(queue).to_i
          end
        else
          total = 0
          queues.each { |q| total += count(q) }
          total
        end
      end

      def self.all(offset = 0, limit = 1, queue = :failed, order = 'desc')
        ResqueSqs.list_range(queue, offset, limit, order)
      end

      def self.queues
        Array(ResqueSqs.redis.smembers(:failed_queues))
      end

      def self.each(offset = 0, limit = self.count, queue = :failed, class_name = nil, order = 'desc')
        items = all(offset, limit, queue, order)
        items = [items] unless items.is_a? Array
        if order.eql? 'desc'
          items.reverse!
        end
        items.each_with_index do |item, i|
          if !class_name || (item['payload'] && item['payload']['class'] == class_name)
            yield offset + i, item
          end
        end
      end

      def self.clear(queue = :failed)
        ResqueSqs.redis.del(queue)
      end

      def self.requeue(id, queue = :failed)
        item = all(id, 1, queue)
        item['retried_at'] = Time.now.strftime("%Y/%m/%d %H:%M:%S")
        ResqueSqs.redis.lset(queue, id, ResqueSqs.encode(item))
        Job.create(item['queue'], item['payload']['class'], *item['payload']['args'])
      end

      def self.remove(id, queue = :failed)
        sentinel = ""
        ResqueSqs.redis.lset(queue, id, sentinel)
        ResqueSqs.redis.lrem(queue, 1,  sentinel)
      end

      def self.requeue_queue(queue)
        failure_queue = ResqueSqs::Failure.failure_queue_name(queue)
        each(0, count(failure_queue), failure_queue) { |id, _| requeue(id, failure_queue) }
      end

      def self.remove_queue(queue)
        ResqueSqs.redis.del(ResqueSqs::Failure.failure_queue_name(queue))
      end

      def filter_backtrace(backtrace)
        index = backtrace.index { |item| item.include?('/lib/resque/job.rb') }
        backtrace.first(index.to_i)
      end
    end
  end
end
