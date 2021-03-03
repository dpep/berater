module Berater
  class ConcurrencyLimiter < Limiter

    class Incapacitated < Overloaded; end

    attr_reader :timeout

    def initialize(key, capacity, **opts)
      super(key, capacity, **opts)

      self.timeout = opts[:timeout] || 0
    end

    private def timeout=(timeout)
      @timeout = timeout
      timeout = 0 if timeout == Float::INFINITY
      @timeout_usec = Berater::Utils.to_usec(timeout)
    end

    LUA_SCRIPT = Berater::LuaScript(<<~LUA
      local key = KEYS[1]
      local lock_key = KEYS[2]
      local conf_key = KEYS[3]
      local capacity = tonumber(ARGV[1])
      local ts = tonumber(ARGV[2])
      local ttl = tonumber(ARGV[3])
      local cost = tonumber(ARGV[4])
      local lock_ids = {}

      if conf_key then
        local config = redis.call('GET', conf_key)

        if config then
          -- use dynamic capacity limit
          capacity = tonumber(config)

          -- reset ttl for a week
          redis.call('EXPIRE', conf_key, 604800)
        end
      end

      -- purge stale hosts
      if ttl > 0 then
        redis.call('ZREMRANGEBYSCORE', key, '-inf', ts - ttl)
      end

      -- check capacity
      local count = redis.call('ZCARD', key)

      if cost == 0 then
        -- just check limit, ie. for .overlimit?
        if count < capacity then
          table.insert(lock_ids, true)
        end
      elseif (count + cost) <= capacity then
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

        if ttl > 0 then
          redis.call('PEXPIRE', key, ttl)
        end
      end

      return { count, unpack(lock_ids) }
    LUA
    )

    def limit(capacity: nil, cost: 1, &block)
      limit_key = if capacity.nil? && dynamic_limits
        config_key
      end
      capacity ||= @capacity

      # timestamp in microseconds
      ts = (Time.now.to_f * 10**6).to_i

      count, *lock_ids = LUA_SCRIPT.eval(
        redis,
        [ cache_key(key), cache_key('lock_id'), limit_key ],
        [ capacity, ts, @timeout_usec, cost ]
      )

      raise Incapacitated if lock_ids.empty?

      if cost == 0
        lock = Lock.new(self, nil, count)
      else
        lock = Lock.new(self, lock_ids[0], count, -> { release(lock_ids) })
      end

      yield_lock(lock, &block)
    end

    def overloaded?
      limit(cost: 0) { false }
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
