module RedisFailover
  # NodeManager manages a list of redis nodes.
  class NodeManager
    include Util

    def initialize(*nodes)
      @master, @slaves = parse_nodes(nodes)
      @unreachable = []
      @queue = Queue.new
      @lock = Mutex.new
    end

    def start
      trap_signals
      spawn_watchers

      logger.info('Redis Failover Server started successfully.')
      while node = @queue.pop
        if node.unreachable?
          handle_unreachable(node)
        elsif node.reachable?
          handle_reachable(node)
        end
      end
    end

    def notify_state_change(node)
      @queue << node
    end

    def current_master
      @master
    end

    def nodes
      @lock.synchronize do
        {
          :master => current_master.to_s,
          :slaves => @slaves.map(&:to_s)
        }
      end
    end

    def shutdown
      logger.info('Shutting down ...')
      @watchers.each(&:shutdown)
      exit(0)
    end

    private

    def handle_unreachable(node)
      @lock.synchronize do
        # no-op if we already know about this node
        return if @unreachable.include?(node)
        logger.info("Handling unreachable node: #{node}")

        # find a new master if this node was a master
        if node == @master
          logger.info("Demoting currently unreachable master #{node}.")
          promote_new_master
        end
        @unreachable << node
      end
    end

    def handle_reachable(node)
      @lock.synchronize do
        # no-op if we already know about this node
        return if @master == node || @slaves.include?(node)
        logger.info("Handling reachable node: #{node}")

        @unreachable.delete(node)
        @slaves << node
        if current_master
          # master already exists, make a slave
          node.make_slave!
        else
          # no master exists, make this the new master
          promote_new_master
        end
      end
    end

    def promote_new_master
      @master = nil

      if @slaves.empty?
        logger.error('Failed to promote a new master since no slaves available.')
        return
      else
        # make a slave the new master
        node = @slaves.pop
        node.make_master!
        @master = node
        logger.info("Successfully promoted #{@master} to master.")
      end
    end

    def parse_nodes(nodes)
      nodes = nodes.map { |opts| Node.new(self, opts) }
      raise NoMasterError unless master = nodes.find(&:master?)
      [master, nodes - [master]]
    end

    def spawn_watchers
      @watchers = [@master, *@slaves].map do |node|
          NodeWatcher.new(self, node)
      end
      @watchers.each(&:watch)
    end

    def trap_signals
      %w(INT TERM).each do |signal|
        trap(signal) { shutdown }
      end
    end
  end
end