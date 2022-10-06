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

require_relative '../spec_helper'
require_relative '../../version'
require 'logstash/codecs/plain'
require 'logstash/event'
require 'net/http'
require 'json'

describe LogStash::Outputs::Dynatrace do
  let(:events) do
    [
      LogStash::Event.new({ 'message' => 'message 1', '@timestamp' => "2021-06-25T15:46:45.693Z" }),
      LogStash::Event.new({ 'message' => 'message 2', '@timestamp' => "2021-06-25T15:46:46.693Z" }),
    ]
  end
  let(:url) { "http://localhost/good" }
  let(:key) { 'api.key' }
  let(:subject) { LogStash::Outputs::Dynatrace.new({ 'api_key' => key, 'ingest_endpoint_url' => url }) }

  before do
    subject.register
  end

  it 'does not send empty events' do
    expect_any_instance_of(Net::HTTP).to_not receive(:request)
    subject.multi_receive([])
  end

  context 'server response success' do
    it 'sends events' do
      response = Net::HTTPOK.new "1.1", "200", "OK"
      expect_any_instance_of(Net::HTTP).to receive(:request) do |http, req|
        body = JSON.parse(req.body)
        expect(body.length).to eql(2)
        expect(body[0]['message']).to eql('message 1')
        expect(body[0]['@timestamp']).to eql('2021-06-25T15:46:45.693Z')
        expect(body[1]['message']).to eql('message 2')
        expect(body[1]['@timestamp']).to eql('2021-06-25T15:46:46.693Z')
        response
      end
      subject.multi_receive(events)
    end

    it 'includes authorization header' do
      response = Net::HTTPOK.new "1.1", "200", "OK"
      expect_any_instance_of(Net::HTTP).to receive(:request) do |http, req|
        expect(req['Authorization']).to eql("Api-Token #{key}")
        response
      end
      subject.multi_receive(events)
    end

    it 'includes content type header' do
      response = Net::HTTPOK.new "1.1", "200", "OK"
      expect_any_instance_of(Net::HTTP).to receive(:request) do |http, req|
        expect(req['Content-Type']).to eql('application/json; charset=utf-8')
        response
      end
      subject.multi_receive(events)
    end

    it 'includes user agent' do
      response = Net::HTTPOK.new "1.1", "200", "OK"
      expect_any_instance_of(Net::HTTP).to receive(:request) do |http, req|
        expect(req['User-Agent']).to eql("logstash-output-dynatrace/#{::DynatraceConstants::VERSION}")
        response
      end
      subject.multi_receive(events)
    end

    it 'does not log on success' do
      allow(subject.logger).to receive(:debug)
      allow(subject.logger).to receive(:info) { raise "should not log" }
      allow(subject.logger).to receive(:error) { raise "should not log" }
      allow(subject.logger).to receive(:warn) { raise "should not log" }
      response = Net::HTTPOK.new "1.1", "200", "OK"
      expect_any_instance_of(Net::HTTP).to receive(:request) { response }
      subject.multi_receive(events)
    end
  end

  context 'with server error' do
    it 'retries 5 times with exponential backoff' do
      response = Net::HTTPServerError.new "1.1", "500", "Internal Server Error"
      # This prevents the elusive "undefined method `close' for nil:NilClass" error.
      expect(response).to receive(:body) { 'this is a failure' }.once
      expect(subject.logger).to receive(:error).with("Encountered an HTTP server error", {:body=>"this is a failure", :code=>"500", :message=> "Internal Server Error"}).once
      expect_any_instance_of(Net::HTTP).to receive(:request) { response }.exactly(6).times


      expect(subject).to receive(:sleep).with(1).ordered
      expect(subject).to receive(:sleep).with(2).ordered
      expect(subject).to receive(:sleep).with(4).ordered
      expect(subject).to receive(:sleep).with(8).ordered
      expect(subject).to receive(:sleep).with(16).ordered
      
      expect(subject.logger).to receive(:error).with("Failed to export logs to Dynatrace.")
      subject.multi_receive(events)
    end
  end

  context 'with client error' do
    it 'does not retry on 404' do
      allow(subject.logger).to receive(:error)
      response = Net::HTTPNotFound.new "1.1", "404", "Not Found"
      expect_any_instance_of(Net::HTTP).to receive(:request) { response }.once
      subject.multi_receive(events)
    end

    it 'logs the response body' do
      response = Net::HTTPClientError.new(1.0, '400', 'Client error')
      expect_any_instance_of(Net::HTTP).to receive(:request) { response }
      # This prevents the elusive "undefined method `close' for nil:NilClass" error.
      expect(response).to receive(:body) { 'this is a failure' }

      expect(subject.logger).to receive(:error).with("Encountered an HTTP client error",
        {:body=>"this is a failure", :code=>"400", :message=> "Client error"})

      subject.multi_receive(events)
    end
  end
end
