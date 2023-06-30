# encoding: utf-8

# Copyright 2021 Dynatrace LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require "logstash/outputs/base"
require "logstash/namespace"
require "logstash/json"
require "uri"
require "logstash/plugin_mixins/http_client"

PLUGIN_VERSION = '0.4.0'

# These constants came from the http plugin config but we don't want them configurable
# If encountered as response codes this plugin will retry these requests
RETRYABLE_CODES = [429, 500, 502, 503, 504]
RETRY_FAILED = true

class LogStash::Outputs::Dynatrace < LogStash::Outputs::Base
  include LogStash::PluginMixins::HttpClient

  concurrency :shared

  RETRYABLE_MANTICORE_EXCEPTIONS = [
    ::Manticore::Timeout,
    ::Manticore::SocketException,
    ::Manticore::ClientProtocolException,
    ::Manticore::ResolutionFailure,
    ::Manticore::SocketTimeout
  ]

  RETRYABLE_UNKNOWN_EXCEPTION_STRINGS = [
    /Connection reset by peer/i,
    /Read Timed out/i
  ]

  class PluginInternalQueueLeftoverError < StandardError; end

  # This output will execute up to 'pool_max' requests in parallel for performance.
  # Consider this when tuning this plugin for performance.
  #
  # Additionally, note that when parallel execution is used strict ordering of events is not
  # guaranteed!

  config_name "dynatrace"

  # The full URL of the Dynatrace log ingestion endpoint:
  # - on SaaS:    https://{your-environment-id}.live.dynatrace.com/api/v2/logs/ingest
  # - on Managed: https://{your-domain}/e/{your-environment-id}/api/v2/logs/ingest
  config :ingest_endpoint_url, validate: :uri, required: true

  # The API token to use to authenticate requests to the log ingestion endpoint. Must have `logs.ingest` (Ingest Logs) scope.
  config :api_key, validate: :password, required: true

  # TODO do we want to defer to ssl_verification_mode from mixin?
  # Disable SSL validation by setting :verify_mode OpenSSL::SSL::VERIFY_NONE
  config :ssl_verify_none, validate: :boolean, default: false

  def register
    # ssl_verification_mode config is from mixin but ssl_verify_none is our documented config
    @ssl_verification_mode = "none" if @ssl_verify_none

    # TODO I don't really understand how this mechanism works. Does it work?
    # TODO try to remove this and see what happens
    # We count outstanding requests with this queue
    # This queue tracks the requests to create backpressure
    # When this queue is empty no new requests may be sent,
    # tokens must be added back by the client on success
    @request_tokens = SizedQueue.new(@pool_max)
    @pool_max.times {|t| @request_tokens << true }
    @requests = Array.new

    # Run named Timer as daemon thread
    @timer = java.util.Timer.new("HTTP Output #{self.params['id']}", true)
  end # def register

  def make_headers
    {
      'User-Agent' => "logstash-output-dynatrace/#{PLUGIN_VERSION}",
      'Content-Type' => 'application/json; charset=utf-8',
      'Authorization' => "Api-Token #{@api_key.value}"
    }
  end

  def multi_receive(events)
    return if events.empty?
    send_events(events)
  end

  class RetryTimerTask < java.util.TimerTask
    def initialize(pending, event, attempt)
      @pending = pending
      @event = event
      @attempt = attempt
      super()
    end

    def run
      @pending << [@event, @attempt]
    end
  end

  def log_retryable_response(response)
    retry_msg = RETRY_FAILED ? 'will retry' : "won't retry"
    if (response.code == 429)
      @logger.debug? && @logger.debug("Encountered a 429 response, #{retry_msg}. This is not serious, just flow control via HTTP")
    else
      @logger.warn("Encountered a retryable HTTP request in HTTP output, #{retry_msg}", :code => response.code, :body => response.body)
    end
  end

  def log_error_response(response, ingest_endpoint_url, event)
    log_failure(
              "Encountered non-2xx HTTP code #{response.code}",
              :response_code => response.code,
              :ingest_endpoint_url => ingest_endpoint_url,
              :event => event
            )
  end

  def send_events(events)
    successes = java.util.concurrent.atomic.AtomicInteger.new(0)
    failures  = java.util.concurrent.atomic.AtomicInteger.new(0)

    pending = Queue.new
    pending << [events, 0]

    while popped = pending.pop
      break if popped == :done

      event, attempt = popped

      raise PluginInternalQueueLeftoverError.new("Received pipeline shutdown request but http output has unfinished events. " \
              "If persistent queue is enabled, events will be retried.") if attempt > 2 && pipeline_shutdown_requested?

      action, event, attempt = send_event(event, attempt)
      begin
        action = :failure if action == :retry && !RETRY_FAILED

        case action
        when :success
          successes.incrementAndGet
        when :retry
          next_attempt = attempt+1
          if (next_attempt >= MAX_RETRIES)
            sleep_for = sleep_for_attempt(next_attempt)
            @logger.info("Retrying http request, will sleep for #{sleep_for} seconds")
            timer_task = RetryTimerTask.new(pending, event, next_attempt)
            @timer.schedule(timer_task, sleep_for*1000)
          else
            @logger.info("Maximum retries exceeded. Dropping the batch")
          end
        when :failure
          failures.incrementAndGet
        else
          # this should never happen. It means send_event returned a symbol we didn't recognize
          raise "Unknown action #{action}"
        end

        if action == :success || action == :failure
          if successes.get+failures.get == 1
            pending << :done
          end
        end
      rescue => e
        # This should never happen unless there's a flat out bug in the code
        @logger.error("Error sending HTTP Request",
          :class => e.class.name,
          :message => e.message,
          :backtrace => e.backtrace)
        failures.incrementAndGet
        raise e
      end
    end
  rescue => e
    @logger.error("Error in http output loop",
            :class => e.class.name,
            :message => e.message,
            :backtrace => e.backtrace)
    raise e
  end

  def pipeline_shutdown_requested?
    return super if defined?(super) # since LS 8.1.0
    nil
  end

  def sleep_for_attempt(attempt)
    sleep_for = attempt**2
    sleep_for = sleep_for <= 60 ? sleep_for : 60
    (sleep_for/2) + (rand(0..sleep_for)/2)
  end

  def send_event(event, attempt)
    body = event_body(event)
    headers = make_headers()

    # TODO keep? If we want this make sure to require zlib
    # # Compress the body and add appropriate header
    # if @http_compression == true
    #   headers["Content-Encoding"] = "gzip"
    #   body = gzip(body)
    # end

    # Create an async request
    response = client.post(ingest_endpoint_url, :body => body, :headers => headers)

    if !response_success?(response)
      if retryable_response?(response)
        log_retryable_response(response)
        return :retry, event, attempt
      else
        log_error_response(response, ingest_endpoint_url, event)
        return :failure, event, attempt
      end
    else
      return :success, event, attempt
    end

  rescue => exception
    will_retry = retryable_exception?(exception)
    log_params = {
      :ingest_endpoint_url => ingest_endpoint_url,
      :message => exception.message,
      :class => exception.class,
      :will_retry => will_retry
    }
    if @logger.debug?
      # TODO how sensitive should we be with debug log data?
      # backtraces are big
      log_params[:backtrace] = exception.backtrace
      # headers can have sensitive data
      log_params[:headers] = headers
      # body can be big and may have sensitive data
      log_params[:body] = body
    end
    log_failure("Could not fetch URL", log_params)

    if will_retry
      return :retry, event, attempt
    else
      return :failure, event, attempt
    end
  end

  def close
    @timer.cancel
    client.close
  end

  private

  def response_success?(response)
    return response.code >= 200 && response.code <= 299
  end

  def retryable_response?(response)
    RETRYABLE_CODES.include?(response.code)
  end

  def retryable_exception?(exception)
    retryable_manticore_exception?(exception) || retryable_unknown_exception?(exception)
  end

  def retryable_manticore_exception?(exception)
    RETRYABLE_MANTICORE_EXCEPTIONS.any? {|me| exception.is_a?(me)}
  end

  def retryable_unknown_exception?(exception)
    exception.is_a?(::Manticore::UnknownException) &&
        RETRYABLE_UNKNOWN_EXCEPTION_STRINGS.any? { |snippet| exception.message =~ snippet }
  end

  # This is split into a separate method mostly to help testing
  def log_failure(message, opts)
    @logger.error(message, opts)
  end

  # Format the HTTP body
  def event_body(event)
    LogStash::Json.dump(event.map {|e| map_event(e) })
  end
end
