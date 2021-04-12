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
require 'logstash/codecs/plain'
require 'logstash/event'
require 'sinatra'
require 'insist'
require_relative '../supports/compressed_requests'

PORT = rand(65_535 - 1024) + 1025

# NOTE: that Sinatra startup and shutdown messages are directly logged to stderr so
# it is not really possible to disable them without reopening stderr which is not advisable.
#
# == Sinatra (v1.4.6) has taken the stage on 51572 for development with backup from WEBrick
# == Sinatra has ended his set (crowd applauds)
#
class TestApp < Sinatra::Base
  # on the fly uncompress gzip content
  use CompressedRequests

  # disable WEBrick logging
  def self.server_settings
    { AccessLog: [], Logger: WEBrick::BasicLog.new(nil, WEBrick::BasicLog::FATAL) }
  end

  class << self
    attr_accessor :last_request

    def clear
      self.last_request = nil
    end
  end

  post '/good' do
    self.class.last_request = request
    [201, 'Accepted']
  end

  post '/bad' do
    self.class.last_request = request
    [400, 'Bad']
  end
end

RSpec.configure do |config|
  # http://stackoverflow.com/questions/6557079/start-and-call-ruby-http-server-in-the-same-script
  def sinatra_run_wait(app, opts)
    queue = Queue.new

    t = java.lang.Thread.new(
      proc do
        begin
          app.run!(opts) do |_server|
            queue.push('started')
          end
        rescue StandardError => e
          puts "Error in webserver thread #{e}"
          # ignore
        end
      end
    )
    t.daemon = true
    t.start
    queue.pop # blocks until the run! callback runs
  end

  config.before(:suite) do
    sinatra_run_wait(TestApp, port: PORT, server: 'webrick')
    puts "Test webserver on port #{PORT}"
  end
end

describe LogStash::Outputs::Dynatrace do
  let(:port) { PORT }
  let(:event) do
    LogStash::Event.new({ 'message' => 'hi' })
  end
  let(:url) { "http://localhost:#{port}/good" }
  let(:key) { 'api.key' }
  let(:subject) { LogStash::Outputs::Dynatrace.new({ 'api_key' => key, 'active_gate_url' => url }) }

  before do
    subject.register
    allow(subject).to receive(:log_failure).with(any_args)
  end

  context 'sending no events' do
    it 'should not block the pipeline' do
      subject.multi_receive([])
    end
  end

  context 'with passing requests' do
    before do
      # TestApp.last_request = nil
      TestApp.clear
      subject.multi_receive([event])
    end

    let(:last_request) { TestApp.last_request }
    let(:body) { last_request.body.read }
    let(:content_type) { last_request.env['CONTENT_TYPE'] }
    let(:authorization) { last_request.env['HTTP_AUTHORIZATION'] }

    let(:expected_body) { "#{LogStash::Json.dump([event])}\n" }
    let(:expected_content_type) { 'application/json; charset=utf-8' }
    let(:expected_authorization) { "Api-Token #{key}" }

    it 'should not log a failure' do
      expect(subject).not_to have_received(:log_failure).with(any_args)
    end

    it 'should receive the request' do
      expect(last_request).to be_truthy
    end

    it 'should receive the event as a hash' do
      expect(body).to eql(expected_body)
    end

    it 'should have the correct content type' do
      expect(content_type).to eql(expected_content_type)
    end

    it 'should have the correct authorization' do
      expect(authorization).to eql(expected_authorization)
    end
  end

  context 'with failing requests' do
    let(:url) { "http://localhost:#{port}/bad" }

    before do
      subject.multi_receive([event])
    end

    it 'should log a failure' do
      expect(subject).to have_received(:log_failure).with(any_args)
    end
  end
end
