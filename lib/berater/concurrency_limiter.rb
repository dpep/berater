module Berater
  class ConcurrencyLimiter < Limiter

    class Incapacitated < Overloaded; end

    attr_reader :capacity, :timeout

    def initialize(key, capacity, **opts)
      super(key, **opts)

      self.capacity = capacity
      self.timeout = opts[:timeout] || 0
    end

    private def capacity=(capacity)
      unless capacity.is_a? Integer
        raise ArgumentError, "expected Integer, found #{capacity.class}"
      end

      raise ArgumentError, "capacity must be >= 0" unless capacity >= 0

      @capacity = capacity
    end

    private def timeout=(timeout)
      unless timeout.is_a? Integer
        raise ArgumentError, "expected Integer, found #{timeout.class}"
      end

      raise ArgumentError, "timeout must be >= 0" unless timeout >= 0

      @timeout = timeout
    end

    LUA_SCRIPT = Berater::LuaScript(<<~LUA
      local key = KEYS[1]
      local lock_key = KEYS[2]
      local capacity = tonumber(ARGV[1])
      local ts = tonumber(ARGV[2])
      local ttl = tonumber(ARGV[3])
      local cost = tonumber(ARGV[4])
      local lock_ids = {}

      -- purge stale hosts
      if ttl > 0 then
        redis.call('ZREMRANGEBYSCORE', key, '-inf', ts - ttl)
      end

      -- check capacity
      local count = redis.call('ZCARD', key)

      if (count + cost <= capacity) and (cost > 0) then
        -- grab locks, one per cost
        local lock_id = redis.call('INCRBY', lock_key, cost)
        local locks = {}

        for i = lock_id - cost + 1, lock_id do
          table.insert(lock_ids, i)

          table.insert(locks, ts)
          table.insert(locks, i)
        end

        redis.call('ZADD', key, unpack(locks))
        count = count + cost
      end

      return { count, unpack(lock_ids) }
    LUA
    )

    def limit(cost: 1, &block)
      # cost is Integer >= 0
      count, *lock_ids = LUA_SCRIPT.eval(
        redis,
        [ cache_key(key), cache_key('lock_id') ],
        [ capacity, Time.now.to_i, timeout, cost ]
      )

      if cost == 0
        lock = Lock.new(self, nil, count)
      else
        raise Incapacitated if lock_ids.empty?
        lock = Lock.new(self, lock_ids[0], count, -> { release(lock_ids) })
      end

      yield_lock(lock, &block)
    end

    def overloaded?
      limit(cost: 0) { |lock| lock.contention >= capacity }
    rescue Overloaded
      true
    end
    alias incapacitated? overloaded?

    private def release(lock_ids)
      res = redis.zrem(cache_key(key), lock_ids)
      res == true || res == lock_ids.count # depending on which version of Redis
    end

    def to_s
      "#<#{self.class}(#{key}: #{capacity} at a time)>"
    end

  end
end
