# frozen_string_literal: true

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

require 'logstash/namespace'
require 'logstash/outputs/base'
require 'logstash/json'
require 'openssl'

MAX_RETRIES = 5
PLUGIN_VERSION = '0.4.0'

module LogStash
  module Outputs
    class RetryableError < StandardError;
    end

    # An output which sends logs to the Dynatrace log ingest v2 endpoint formatted as JSON
    class Dynatrace < LogStash::Outputs::Base
      config_name 'dynatrace'

      concurrency :single

      # The full URL of the Dynatrace log ingestion endpoint:
      # - on SaaS:    https://{your-environment-id}.live.dynatrace.com/api/v2/logs/ingest
      # - on Managed: https://{your-domain}/e/{your-environment-id}/api/v2/logs/ingest
      config :ingest_endpoint_url, validate: :uri, required: true

      # The API token to use to authenticate requests to the log ingestion endpoint. Must have `logs.ingest` (Ingest Logs) scope.
      config :api_key, validate: :password, required: true

      # Disable SSL validation by setting :verify_mode OpenSSL::SSL::VERIFY_NONE
      config :ssl_verify_none, validate: :boolean, default: false

      default :codec, 'json'

      attr_accessor :uri, :plugin_version

      def register
        @logger.debug("Registering plugin")
        require 'net/https'
        require 'uri'
        @uri = URI.parse(@ingest_endpoint_url.uri.to_s)
        @client = Net::HTTP.new(@uri.host, @uri.port)

        if uri.scheme == 'https'
          @client.use_ssl = true
          @client.verify_mode = OpenSSL::SSL::VERIFY_NONE if @ssl_verify_none
        end
        @logger.info('Client', client: @client.inspect)
      end

      def headers
        {
          'User-Agent' => "logstash-output-dynatrace/#{PLUGIN_VERSION}",
          'Content-Type' => 'application/json; charset=utf-8',
          'Authorization' => "Api-Token #{@api_key.value}"
        }
      end

      # Takes an array of events
      def multi_receive(events)
        @logger.debug("Received #{events.length} events")
        return if events.length.zero?

        retries = 0
        begin
          request = Net::HTTP::Post.new(uri, headers)
          request.body = "#{LogStash::Json.dump(events.map(&:to_hash)).chomp}\n"
          response = @client.request(request)

          case response
          when Net::HTTPSuccess
            @logger.debug("successfully sent #{events.length} events#{" with #{retries} retries" if retries > 0}")
          when Net::HTTPServerError
            @logger.error("Encountered an HTTP server error", :message => response.message, :code => response.code, :body => response.body) if retries == 0
          when Net::HTTPNotFound
            @logger.error("Encountered a 404 Not Found error. Please check that log ingest is enabled and your API token has the `logs.ingest` (Ingest Logs) scope.", :message => response.message, :code => response.code)
          when Net::HTTPClientError
            @logger.error("Encountered an HTTP client error", :message => response.message, :code => response.code, :body => response.body)
          else
            @logger.error("Encountered an unexpected response code", :message => response.message, :code => response.code)
          end

          raise RetryableError.new "code #{response.code}" if retryable(response)

        rescue Net::OpenTimeout, Net::HTTPBadResponse, OpenSSL::SSL::SSLError, RetryableError => e
          # Net::OpenTimeout indicates a connection could not be established within the timeout period
          # Net::HTTPBadResponse indicates a protocol error
          # OpenSSL::SSL::SSLErrorWaitReadable indicates an error establishing the ssl connection
          if retries < MAX_RETRIES
            sleep_seconds = 2 ** retries
            @logger.warn("Failed to contact dynatrace: #{e.message}. Trying again after #{sleep_seconds} seconds.")
            sleep sleep_seconds
            retries += 1
            retry
          else
            @logger.error("Failed to export logs to Dynatrace.")
            return
          end
        rescue StandardError => e
          @logger.error("Unknown error raised", :error => e.inspect)
          raise e
        end
      end

      def retryable(response)
        return response.is_a? Net::HTTPServerError
      end
    end
  end
end
