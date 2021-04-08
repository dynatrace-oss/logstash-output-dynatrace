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

module LogStash
  module Outputs
    # An output which sends logs to the Dynatrace log ingest v2 endpoint formatted as JSON
    class Dynatrace < LogStash::Outputs::Base
      config_name 'dynatrace'

      concurrency :single

      # The full URL of the Dynatrace log ingestion endpoint, e.g. https://my-active-gate.example.com/api/logs/ingest
      config :active_gate_url, validate: :string, required: true

      # The API token to use to authenticate requests to the log ingestion endpoint. Must have TODO scope
      config :api_key, validate: :string, required: true

      # Disable SSL validation by setting :verify_mode OpenSSL::SSL::VERIFY_NONE
      config :ssl_verify_none, validate: :boolean, default: false

      default :codec, 'json'

      attr_accessor :uri

      def register
        require 'net/https'
        require 'uri'
        @uri = URI.parse(@active_gate_url)
        @client = Net::HTTP.new(@uri.host, @uri.port)

        if uri.scheme == 'https'
          @client.use_ssl = true
          @client.verify_mode = OpenSSL::SSL::VERIFY_NONE if @ssl_verify_none
        end
        @logger.debug('Client', client: @client.inspect)
      end

      # This is split into a separate method mostly to help testing
      def log_failure(message, opts)
        @logger.error("[Dynatrace Output Failure] #{message}", opts)
      end

      def headers
        {
          'User-Agent' => 'logstash-output-dynatrace v0.1.0',
          'Content-Type' => 'application/json; charset=utf-8',
          'Authorization' => "Api-Token #{@api_key}"
        }
      end

      # Takes an array of events
      def multi_receive(events)
        return if events.length.zero?

        request = Net::HTTP::Post.new(uri, headers)
        request.body = "#{LogStash::Json.dump(events.map(&:to_hash)).chomp}\n"
        response = @client.request(request)
        return if response.code =~ /^2\d\d$/

        log_failure('Bad Response', request: request.inspect, response: response.inspect)
      end
    end
  end
end
