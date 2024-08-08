# frozen_string_literal: true

require "helper"

class TestInternals < Minitest::Test
  include Helper::Client

  def test_logger
    r.ping

    assert log.string["[Redis] command=PING"]
    assert log.string =~ /\[Redis\] call_time=\d+\.\d+ ms/
  end

  def test_large_payload
    # see: https://github.com/redis/redis-rb/issues/962
    # large payloads will trigger write_nonblock to write a portion
    # of the payload in connection/ruby.rb _write_to_socket
    large = "\u3042" * 4_000_000
    r.setex("foo", 10, large)
    result = r.get("foo")
    assert_equal result, large
  end

  def test_logger_with_pipelining
    r.pipelined do
      r.set "foo", "bar"
      r.get "foo"
    end

    assert log.string[" command=SET args=\"foo\" \"bar\""]
    assert log.string[" command=GET args=\"foo\""]
  end

  def test_recovers_from_failed_commands
    # See https://github.com/redis/redis-rb/issues#issue/28

    assert_raises(Redis::CommandError) do
      r.command_that_doesnt_exist
    end

    r.info
  end

  def test_raises_on_protocol_errors
    redis_mock(ping: ->(*_) { "foo" }) do |redis|
      assert_raises(Redis::ProtocolError) do
        redis.ping
      end
    end
  end

  def test_redis_current
    assert_equal "127.0.0.1", Redis.current._client.host
    assert_equal 6379, Redis.current._client.port
    assert_equal 0, Redis.current._client.db

    Redis.current = Redis.new(OPTIONS.merge(port: 6380, db: 1))

    t = Thread.new do
      assert_equal "127.0.0.1", Redis.current._client.host
      assert_equal 6380, Redis.current._client.port
      assert_equal 1, Redis.current._client.db
    end

    t.join

    assert_equal "127.0.0.1", Redis.current._client.host
    assert_equal 6380, Redis.current._client.port
    assert_equal 1, Redis.current._client.db
  end

  def test_redis_connected?
    fresh_client = _new_client
    assert !fresh_client.connected?

    fresh_client.ping
    assert fresh_client.connected?

    fresh_client.quit
    assert !fresh_client.connected?
  end

  def test_timeout
    Redis.new(OPTIONS.merge(timeout: 0))
  end

  driver(:ruby) do
    def test_tcp_keepalive
      keepalive = { time: 20, intvl: 10, probes: 5 }

      redis = Redis.new(OPTIONS.merge(tcp_keepalive: keepalive))
      redis.ping

      connection = redis._client.connection
      actual_keepalive = connection.get_tcp_keepalive

      %i[time intvl probes].each do |key|
        assert_equal actual_keepalive[key], keepalive[key] if actual_keepalive.key?(key)
      end
    end
  end

  def test_time
    target_version "2.5.4" do
      # Test that the difference between the time that Ruby reports and the time
      # that Redis reports is minimal (prevents the test from being racy).
      rv = r.time

      redis_usec = rv[0] * 1_000_000 + rv[1]
      ruby_usec = Integer(Time.now.to_f * 1_000_000)

      assert((ruby_usec - redis_usec).abs < 500_000)
    end
  end

  def test_connection_timeout
    opts = OPTIONS.merge(host: "10.255.255.254", connect_timeout: 0.1, timeout: 5.0)
    start_time = Time.now
    assert_raises Redis::CannotConnectError do
      Redis.new(opts).ping
    end
    assert((Time.now - start_time) <= opts[:timeout])
  end

  def test_missing_socket
    opts = { path: '/missing.sock' }
    assert_raises Redis::CannotConnectError do
      Redis.new(opts).ping
    end
  end

  def close_on_ping(seq, options = {}, &block)
    @request = 0

    command = lambda do
      idx = @request
      @request += 1

      rv = "+%d" % idx
      rv = nil if seq.include?(idx)
      rv
    end

    redis_mock({ ping: command }, { timeout: 0.1 }.merge(options), &block)
  end

  def test_retry_by_default
    close_on_ping([0]) do |redis|
      assert_equal "1", redis.ping
    end
  end

  def test_retry_when_wrapped_in_with_reconnect_true
    close_on_ping([0]) do |redis|
      redis.with_reconnect(true) do
        assert_equal "1", redis.ping
      end
    end
  end

  def test_dont_retry_when_wrapped_in_with_reconnect_false
    close_on_ping([0]) do |redis|
      assert_raises Redis::ConnectionError do
        redis.with_reconnect(false) do
          redis.ping
        end
      end
    end
  end

  def test_dont_retry_when_wrapped_in_without_reconnect
    close_on_ping([0]) do |redis|
      assert_raises Redis::ConnectionError do
        redis.without_reconnect do
          redis.ping
        end
      end
    end
  end

  def test_retry_only_once_when_read_raises_econnreset
    close_on_ping([0, 1]) do |redis|
      assert_raises Redis::ConnectionError do
        redis.ping
      end

      assert !redis._client.connected?
    end
  end

  # JDH - ADDED
  def test_retry_multi
    # close_on_ping([0]) do |redis|
    #   assert_equal "1", redis.ping
    # end

    ping = lambda do
      idx = 1
      rv = "+%d" % idx
      rv
    end

    commands = {
      multi: -> { "+OK\r\n" },
      ping: ping,
      exec: -> { :exit }
    }

    redis_mock(commands, { delay: 0.5 }) do |redis|
      redis.multi do |multi|
        multi.ping
      end
    end

    # seq = [0, 1]
    # @request = 0
    # ping = lambda do
    #   idx = @request
    #   @request += 1
    #   rv = "+%d" % idx
    #   rv = nil if seq.include?(idx)
    #   rv
    # end



    # redis_mock(commands) do |redis|
    #   result = redis.multi do
    #     redis.ping
    #   end
    #   assert_equal("PONG", result)
    # end

    # ping_future = nil



    # close_on_ping([0, 1], delay: 0.5) do |redis|
    #   redis.multi do |multi|
    #     ping_future = redis.ping
    #   end
    #   assert_equal "1", ping_future.value
    # end
   

    # ping_future = nil
    # close_on_ping([0, 1]) do |redis|
    #   redis.multi do |multi|
    #     ping_future = redis.ping
    #   end
    # end
    # assert_equal "1", ping_future.value

  end

  # JDH - END

  def test_retry_with_custom_reconnect_attempts
    close_on_ping([0, 1], reconnect_attempts: 2) do |redis|
      assert_equal "2", redis.ping
    end
  end

  def test_retry_with_custom_reconnect_attempts_can_still_fail
    close_on_ping([0, 1, 2], reconnect_attempts: 2) do |redis|
      assert_raises Redis::ConnectionError do
        redis.ping
      end

      assert !redis._client.connected?
    end
  end

  def test_retry_with_custom_reconnect_attempts_and_exponential_backoff
    close_on_ping([0, 1, 2], reconnect_attempts: 3,
                             reconnect_delay_max: 0.5,
                             reconnect_delay: 0.01) do |redis|
      Kernel.expects(:sleep).with(0.01).returns(true)
      Kernel.expects(:sleep).with(0.02).returns(true)
      Kernel.expects(:sleep).with(0.04).returns(true)

      assert_equal "3", redis.ping
    end
  end

  def test_don_t_retry_when_second_read_in_pipeline_raises_econnreset
    close_on_ping([1]) do |redis|
      assert_raises Redis::ConnectionError do
        redis.pipelined do
          redis.ping
          redis.ping # Second #read times out
        end
      end

      assert !redis._client.connected?
    end
  end

  def close_on_connection(seq, &block)
    @n = 0

    read_command = lambda do |session|
      Array.new(session.gets[1..-3].to_i) do
        bytes = session.gets[1..-3].to_i
        arg = session.read(bytes)
        session.read(2) # Discard \r\n
        arg
      end
    end

    handler = lambda do |session|
      n = @n
      @n += 1

      select = read_command.call(session)
      if select[0].downcase == "select"
        session.write("+OK\r\n")
      else
        raise "Expected SELECT"
      end
      unless seq.include?(n)
        session.write("+#{n}\r\n") while read_command.call(session)
      end
    end

    redis_mock_with_handler(handler, &block)
  end

  def test_retry_on_write_error_by_default
    close_on_connection([0]) do |redis|
      assert_equal "1", redis._client.call(["x" * 128 * 1024])
    end
  end

  def test_retry_on_write_error_when_wrapped_in_with_reconnect_true
    close_on_connection([0]) do |redis|
      redis.with_reconnect(true) do
        assert_equal "1", redis._client.call(["x" * 128 * 1024])
      end
    end
  end

  def test_dont_retry_on_write_error_when_wrapped_in_with_reconnect_false
    close_on_connection([0]) do |redis|
      assert_raises Redis::ConnectionError do
        redis.with_reconnect(false) do
          redis._client.call(["x" * 128 * 1024])
        end
      end
    end
  end

  def test_dont_retry_on_write_error_when_wrapped_in_without_reconnect
    close_on_connection([0]) do |redis|
      assert_raises Redis::ConnectionError do
        redis.without_reconnect do
          redis._client.call(["x" * 128 * 1024])
        end
      end
    end
  end

  def test_connecting_to_unix_domain_socket
    Redis.new(OPTIONS.merge(path: ENV.fetch("REDIS_SOCKET_PATH"))).ping
  end

  driver(:ruby, :hiredis) do
    def test_bubble_timeout_without_retrying
      serv = TCPServer.new(6380)

      redis = Redis.new(port: 6380, timeout: 0.1)

      assert_raises(Redis::TimeoutError) do
        redis.ping
      end
    ensure
      serv&.close
    end
  end

  def test_client_options
    redis = Redis.new(OPTIONS.merge(host: "host", port: 1234, db: 1, scheme: "foo"))

    assert_equal "host", redis._client.options[:host]
    assert_equal 1234, redis._client.options[:port]
    assert_equal 1, redis._client.options[:db]
    assert_equal "foo", redis._client.options[:scheme]
  end

  def test_resolves_localhost
    Redis.new(OPTIONS.merge(host: 'localhost')).ping
  end

  class << self
    def af_family_supported(af_type)
      hosts = {
        Socket::AF_INET => "127.0.0.1",
        Socket::AF_INET6 => "::1"
      }

      begin
        s = Socket.new(af_type, Socket::SOCK_STREAM, 0)
        begin
          tries = 5
          begin
            sa = Socket.pack_sockaddr_in(Random.rand(1024..64_099), hosts[af_type])
            s.bind(sa)
          rescue Errno::EADDRINUSE => e
            # On JRuby (9.1.15.0), if IPv6 is globally disabled on the system,
            # we get an EADDRINUSE with belows message.
            return if e.message =~ /Protocol family unavailable/

            tries -= 1
            retry if tries > 0

            raise
          end
          yield
        rescue Errno::EADDRNOTAVAIL
        ensure
          s.close
        end
      rescue Errno::ESOCKTNOSUPPORT
      end
    end
  end

  def af_test(host)
    commands = {
      ping: ->(*_) { "+pong" }
    }

    redis_mock(commands, host: host, &:ping)
  end

  driver(:ruby) do
    af_family_supported(Socket::AF_INET) do
      def test_connect_ipv4
        af_test("127.0.0.1")
      end
    end
  end

  driver(:ruby) do
    af_family_supported(Socket::AF_INET6) do
      def test_connect_ipv6
        af_test("::1")
      end
    end
  end

  def test_can_be_duped_to_create_a_new_connection
    clients = r.info["connected_clients"].to_i

    r2 = r.dup
    r2.ping

    assert_equal clients + 1, r.info["connected_clients"].to_i
  end
end
