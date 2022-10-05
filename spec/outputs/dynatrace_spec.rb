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
require 'sinatra'
require 'insist'
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
    allow(subject).to receive(:send)
    subject.multi_receive([])
    expect(subject).to_not have_received(:send)
  end

  context 'server response success' do
    it 'sends events' do
      allow(subject).to receive(:send) do |req|
        body = JSON.parse(req.body)
        expect(body.length).to eql(2)
        expect(body[0]['message']).to eql('message 1')
        expect(body[0]['@timestamp']).to eql('2021-06-25T15:46:45.693Z')
        expect(body[1]['message']).to eql('message 2')
        expect(body[1]['@timestamp']).to eql('2021-06-25T15:46:46.693Z')
        Net::HTTPOK.new "1.1", "200", "OK"
      end
      subject.multi_receive(events)
      expect(subject).to have_received(:send)
    end

    it 'includes authorization header' do
      allow(subject).to receive(:send) do |req|
        expect(req['Authorization']).to eql("Api-Token #{key}")
        Net::HTTPOK.new "1.1", "200", "OK"
      end
      subject.multi_receive(events)
      expect(subject).to have_received(:send)
    end

    it 'includes content type header' do
      allow(subject).to receive(:send) do |req|
        expect(req['Content-Type']).to eql('application/json; charset=utf-8')
        Net::HTTPOK.new "1.1", "200", "OK"
      end
      subject.multi_receive(events)
      expect(subject).to have_received(:send)
    end

    it 'includes user agent' do
      allow(subject).to receive(:send) do |req|
        expect(req['User-Agent']).to eql("logstash-output-dynatrace/#{::DynatraceConstants::VERSION}")
        Net::HTTPOK.new "1.1", "200", "OK"
      end
      subject.multi_receive(events)
      expect(subject).to have_received(:send)
    end

    it 'does not log on success' do
      allow(subject.logger).to receive(:debug)
      allow(subject.logger).to receive(:info) { raise "should not log" }
      allow(subject.logger).to receive(:error) { raise "should not log" }
      allow(subject.logger).to receive(:warn) { raise "should not log" }
      allow(subject).to receive(:send) do |req|
        Net::HTTPOK.new "1.1", "200", "OK"
      end
      subject.multi_receive(events)
      expect(subject).to have_received(:send)
    end
  end

  context 'with bad client request' do
    it 'does not retry on 404' do
      allow(subject).to receive(:send) { Net::HTTPNotFound.new "1.1", "404", "Not Found" }
      subject.multi_receive(events)
      expect(subject).to have_received(:send).once
    end
  end

  context 'with server error' do
    it 'retries 5 times with exponential backoff' do
      allow(subject).to receive(:sleep)
      allow(subject).to receive(:send) { Net::HTTPInternalServerError.new "1.1", "500", "Internal Server Error" }

      subject.multi_receive(events)

      expect(subject).to have_received(:sleep).with(1).ordered
      expect(subject).to have_received(:sleep).with(2).ordered
      expect(subject).to have_received(:sleep).with(4).ordered
      expect(subject).to have_received(:sleep).with(8).ordered
      expect(subject).to have_received(:sleep).with(16).ordered

      expect(subject).to have_received(:sleep).exactly(5).times
      expect(subject).to have_received(:send).exactly(6).times
    end
  end

  context 'with client error' do
    let(:response){ instance_double(Net::HTTPClientError, body: response_body, code: response_code, message: response_message)}
    let(:response_body) { "this is a failure" }
    let(:response_message) { "Client error" }
    let(:response_code) { "400" }


    it 'logs the response body' do
      allow(subject.logger).to receive(:error)
      allow(subject).to receive(:send).and_return(response)
      subject.multi_receive(events)

      expect(subject.logger).to have_received(:error).with("Encountered a client error in HTTP output",
        {:body=>"this is a failure", :code=>"400", :message=> "Client error"})
    end
  end
end
