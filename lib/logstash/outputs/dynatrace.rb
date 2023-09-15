# frozen_string_literal: true

# Copyright 2023 Dynatrace LLC
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

require 'logstash/outputs/base'
require 'logstash/namespace'
require 'logstash/json'
require 'logstash/version'
require 'dynatrace/version'
require 'uri'
require 'logstash/plugin_mixins/http_client'

# These constants came from the http plugin config but we don't want them configurable
# If encountered as response codes this plugin will retry these requests
RETRYABLE_CODES = [429, 500, 502, 503, 504].freeze
RETRY_FAILED = true

module LogStash
  module Outputs
    class Dynatrace < LogStash::Outputs::Base
      include LogStash::PluginMixins::HttpClient

      concurrency :shared

      RETRYABLE_MANTICORE_EXCEPTIONS = [
        ::Manticore::Timeout,
        ::Manticore::SocketException,
        ::Manticore::ClientProtocolException,
        ::Manticore::ResolutionFailure,
        ::Manticore::SocketTimeout
      ].freeze

      RETRYABLE_UNKNOWN_EXCEPTION_STRINGS = [
        /Connection reset by peer/i,
        /Read Timed out/i
      ].freeze

      class PluginInternalQueueLeftoverError < StandardError; end

      # This output will execute up to 'pool_max' requests in parallel for performance.
      # Consider this when tuning this plugin for performance.
      #
      # Additionally, note that when parallel execution is used strict ordering of events is not
      # guaranteed!

      config_name 'dynatrace'

      # The full URL of the Dynatrace log ingestion endpoint:
      # - on SaaS:    https://{your-environment-id}.live.dynatrace.com/api/v2/logs/ingest
      # - on Managed: https://{your-domain}/e/{your-environment-id}/api/v2/logs/ingest
      config :ingest_endpoint_url, validate: :uri, required: true

      # The API token to use to authenticate requests to the log ingestion endpoint. Must have `logs.ingest` (Ingest Logs) scope.
      config :api_key, validate: :password, required: true

      # Disable SSL validation by setting :verify_mode OpenSSL::SSL::VERIFY_NONE
      config :ssl_verify_none, validate: :boolean, default: false

      # Include headers in debug logs when HTTP errors occur. Headers include sensitive data such as API tokens.
      config :debug_include_headers, validate: :boolean, default: false

      # Include body in debug logs when HTTP errors occur. Body may be large and include sensitive data.
      config :debug_include_body, validate: :boolean, default: false

      # Maximum size payload to send to the Dynatrace API. Batches of events which would be larger than max_payload_size when serialized will be split into smaller batches of events.
      config :max_payload_size, validate: :number, default: 4_500_000

      def register
        # ssl_verification_mode config is from mixin but ssl_verify_none is our documented config
        @ssl_verification_mode = 'none' if @ssl_verify_none

        @ingest_endpoint_url = @ingest_endpoint_url.to_s

        # Run named Timer as daemon thread
        @timer = java.util.Timer.new("HTTP Output #{params['id']}", true)
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

      class BatchSerializer
        def initialize(max_batch_size)
          @max_batch_size = max_batch_size
          @batch_events_size = 0
          @serialized_events = []
        end

        def offer(event)
          serialized_event = LogStash::Json.dump(event.to_hash)
          if batch_size + serialized_event.length + (@serialized_events.length.positive? ? 1 : 0) > @max_batch_size
            return false
          end

          @serialized_events.push(serialized_event)
          @batch_events_size += serialized_event.length
          true
        end

        def batch_size
          2 + @batch_events_size + @serialized_events.length - 1
        end

        def drain_and_serialize
          out = "[#{@serialized_events.join(',')}]\n"
          @batch_events_size = 0
          @serialized_events = []
          out
        end

        def empty?
          @serialized_events.empty?
        end
      end

      def make_headers
        {
          'User-Agent' => "logstash-output-dynatrace/#{DynatraceConstants::VERSION} logstash/#{LOGSTASH_VERSION}",
          'Content-Type' => 'application/json; charset=utf-8',
          'Authorization' => "Api-Token #{@api_key.value}"
        }
      end

      def log_retryable_response(response)
        retry_msg = RETRY_FAILED ? 'will retry' : "won't retry"
        if response.code == 429
          @logger.debug? && @logger.debug("Encountered a 429 response, #{retry_msg}. This is not serious, just flow control via HTTP")
        else
          @logger.warn("Encountered a retryable HTTP request in HTTP output, #{retry_msg}", code: response.code,
                                                                                            body: response.body)
        end
      end

      def log_error_response(response, ingest_endpoint_url, event)
        log_failure(
          "Encountered non-2xx HTTP code #{response.code}",
          response_code: response.code,
          ingest_endpoint_url: ingest_endpoint_url,
          event: event
        )
      end

      def send_events(events)
        successes = java.util.concurrent.atomic.AtomicInteger.new(0)
        failures  = java.util.concurrent.atomic.AtomicInteger.new(0)

        pending = Queue.new
        batcher = BatchSerializer.new(@max_payload_size)

        events.each do |event|
          next if batcher.offer(event)

          pending << [batcher.drain_and_serialize, 0]
          unless batcher.offer(event)
            @logger.warn('Event larger than max_payload_size dropped',
                         size: LogStash::Json.dump(event.to_hash).length)
          end
        end

        pending << [batcher.drain_and_serialize, 0] unless batcher.empty?

        while popped = pending.pop
          break if popped == :done

          event, attempt = popped

          if attempt > 2 && pipeline_shutdown_requested?
            raise PluginInternalQueueLeftoverError, 'Received pipeline shutdown request but http output has unfinished events. ' \
                    'If persistent queue is enabled, events will be retried.'
          end

          action, event, attempt = send_event(event, attempt)
          begin
            action = :failure if action == :retry && !RETRY_FAILED

            case action
            when :success
              successes.incrementAndGet
            when :retry
              next_attempt = attempt + 1
              sleep_for = sleep_for_attempt(next_attempt)
              @logger.info("Retrying http request, will sleep for #{sleep_for} seconds")
              timer_task = RetryTimerTask.new(pending, event, next_attempt)
              @timer.schedule(timer_task, sleep_for * 1000)
            when :failure
              failures.incrementAndGet
            else
              # this should never happen. It means send_event returned a symbol we didn't recognize
              raise "Unknown action #{action}"
            end

            pending << :done if %i[success failure].include?(action) && (successes.get + failures.get == 1)
          rescue StandardError => e
            # This should never happen unless there's a flat out bug in the code
            @logger.error('Error sending HTTP Request',
                          class: e.class.name,
                          message: e.message,
                          backtrace: e.backtrace)
            failures.incrementAndGet
            raise e
          end
        end
      rescue StandardError => e
        @logger.error('Error in http output loop',
                      class: e.class.name,
                      message: e.message,
                      backtrace: e.backtrace)
        raise e
      end

      def pipeline_shutdown_requested?
        return super if defined?(super) # since LS 8.1.0

        nil
      end

      def sleep_for_attempt(attempt)
        sleep_for = attempt**2
        sleep_for = sleep_for <= 60 ? sleep_for : 60
        (sleep_for / 2) + (rand(0..sleep_for) / 2)
      end

      def send_event(event, attempt)
        headers = make_headers

        # Create an async request
        response = client.post(ingest_endpoint_url, body: event, headers: headers)

        if response_success?(response)
          [:success, event, attempt]
        elsif retryable_response?(response)
          log_retryable_response(response)
          [:retry, event, attempt]
        else
          log_error_response(response, ingest_endpoint_url, event)
          [:failure, event, attempt]
        end
      rescue StandardError => e
        will_retry = retryable_exception?(e)
        log_params = {
          ingest_endpoint_url: ingest_endpoint_url,
          message: e.message,
          class: e.class,
          will_retry: will_retry
        }
        if @logger.debug?
          # backtraces are big
          log_params[:backtrace] = e.backtrace
          if @debug_include_headers
            # headers can have sensitive data
            log_params[:headers] = headers
          end
          if @debug_include_body
            # body can be big and may have sensitive data
            log_params[:body] = event
          end
        end
        log_failure('Could not fetch URL', log_params)

        if will_retry
          [:retry, event, attempt]
        else
          [:failure, event, attempt]
        end
      end

      def close
        @timer.cancel
        client.close
      end

      private

      def response_success?(response)
        response.code >= 200 && response.code <= 299
      end

      def retryable_response?(response)
        RETRYABLE_CODES.include?(response.code)
      end

      def retryable_exception?(exception)
        retryable_manticore_exception?(exception) || retryable_unknown_exception?(exception)
      end

      def retryable_manticore_exception?(exception)
        RETRYABLE_MANTICORE_EXCEPTIONS.any? { |me| exception.is_a?(me) }
      end

      def retryable_unknown_exception?(exception)
        exception.is_a?(::Manticore::UnknownException) &&
          RETRYABLE_UNKNOWN_EXCEPTION_STRINGS.any? { |snippet| exception.message =~ snippet }
      end

      # This is split into a separate method mostly to help testing
      def log_failure(message, opts)
        @logger.error(message, opts)
      end
    end
  end
end
