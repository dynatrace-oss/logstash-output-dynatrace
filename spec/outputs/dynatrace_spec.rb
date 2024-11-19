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

require File.expand_path('../spec_helper.rb', File.dirname(__FILE__))

describe LogStash::Outputs::Dynatrace do
  # Wait for the async request to finish in this spinlock
  # Requires pool_max to be 1

  before(:all) do
    @server = start_app_and_wait(TestApp)
  end

  after(:all) do
    @server.shutdown # WEBrick::HTTPServer
    begin
      TestApp.stop!
    rescue StandardError
      nil
    end
  end

  let(:port) { PORT }
  let(:event) do
    LogStash::Event.new({ 'message' => 'hi' })
  end
  let(:ingest_endpoint_url) { "http://localhost:#{port}/good" }
  let(:api_key) { 'placeholder-key' }

  shared_examples('failure log behaviour') do
    it 'logs failure' do
      expect(subject).to have_received(:log_failure).with(any_args)
    end

    it 'does not log headers' do
      expect(subject).to have_received(:log_failure).with(anything, hash_not_including(:headers))
    end

    it 'does not log the message body' do
      expect(subject).to have_received(:log_failure).with(anything, hash_not_including(:body))
    end

    context 'with debug log level' do
      before :all do
        @current_log_level = LogStash::Logging::Logger.get_logging_context.get_root_logger.get_level.to_s.downcase
        LogStash::Logging::Logger.configure_logging 'debug'
      end
      after :all do
        LogStash::Logging::Logger.configure_logging @current_log_level
      end

      it 'logs a failure' do
        expect(subject).to have_received(:log_failure).with(anything, hash_including(:backtrace))
      end

      context 'with debug_include_headers false (default)' do
        it 'does not log headers' do
          expect(subject).to have_received(:log_failure).with(anything, hash_not_including(:headers))
        end
      end

      context 'with debug_include_body false (default)' do
        it 'does not log body' do
          expect(subject).to have_received(:log_failure).with(anything, hash_not_including(:body))
        end
      end

      context 'with debug_include_headers true' do
        let(:config) { super().merge 'debug_include_headers' => true }

        it 'logs headers' do
          expect(subject).to have_received(:log_failure).with(anything, hash_including(:headers))
        end
      end

      context 'with debug_include_body true' do
        let(:config) { super().merge 'debug_include_body' => true }

        it 'logs body' do
          expect(subject).to have_received(:log_failure).with(anything, hash_including(:body))
        end
      end

      context 'with debug_include_headers false' do
        let(:config) { super().merge 'debug_include_headers' => false }

        it 'logs headers' do
          expect(subject).to have_received(:log_failure).with(anything, hash_not_including(:headers))
        end
      end

      context 'with debug_include_body false' do
        let(:config) { super().merge 'debug_include_body' => false }

        it 'logs body' do
          expect(subject).to have_received(:log_failure).with(anything, hash_not_including(:body))
        end
      end
    end
  end

  let(:config) { { 'ingest_endpoint_url' => ingest_endpoint_url, 'api_key' => api_key, 'pool_max' => 1 } }
  subject { LogStash::Outputs::Dynatrace.new(config) }

  let(:client) { subject.client }

  before do
    subject.register
    allow(client).to receive(:post)
      .with(ingest_endpoint_url, hash_including(:body, :headers))
      .and_call_original
    allow(subject).to receive(:log_failure).with(any_args)
    allow(subject).to receive(:log_warning).with(any_args)
    allow(subject).to receive(:log_retryable_response).with(any_args)
  end

  context 'sending no events' do
    it 'should not block the pipeline' do
      subject.multi_receive([])
    end
  end

  context 'performing a request' do
    describe 'invoking the request' do
      before do
        subject.multi_receive([event])
      end

      it 'should execute the request' do
        expect(client).to have_received(:post)
          .with(ingest_endpoint_url, hash_including(:body, :headers))
      end
    end

    context 'with passing requests' do
      before do
        subject.multi_receive([event])
      end

      it 'should not log a failure' do
        expect(subject).not_to have_received(:log_failure).with(any_args)
      end
    end

    context 'with failing requests' do
      let(:ingest_endpoint_url) { "http://localhost:#{port}/bad" }
      let(:api_key) { 'placeholder-key' }

      before do
        subject.multi_receive([event])
      end

      it 'should log a failure' do
        expect(subject).to have_received(:log_failure).with(any_args)
      end
    end

    context 'with retryable failing requests' do
      let(:ingest_endpoint_url) { "http://localhost:#{port}/retry" }
      let(:api_key) { 'placeholder-key' }

      before do
        TestApp.retry_fail_count = 2
        allow(subject).to receive(:send_event).and_call_original
        allow(subject).to receive(:sleep_for_attempt) { 0 }
        subject.multi_receive([event])
      end

      it 'should log a retryable response 2 times' do
        expect(subject).to have_received(:log_retryable_response).with(any_args).twice
      end

      it 'should make three total requests' do
        expect(subject).to have_received(:send_event).exactly(3).times
      end
    end

    context 'with more than 4.5MB of events' do
      before do
        allow(subject).to receive(:send_event) { |e, att| [:success, e, att] }
        subject.multi_receive([1, 2].map { |n| LogStash::Event.new({ 'n' => n.to_s * 2_500_001 }) })
      end

      it 'should split the chunk into multiple requests' do
        expect(subject).to have_received(:send_event).exactly(2).times
      end
    end

    shared_examples('send small and drop large') do
      it 'should only send the small event' do
        expect(subject).to have_received(:send_event).exactly(1).times
      end

      it 'should log a warning' do
        expect(subject).to have_received(:log_warning)
          .with('Event larger than max_payload_size dropped', hash_including(:size))
          .exactly(:once)
      end
    end

    context 'with one small event and one too large event' do
      before do
        allow(subject).to receive(:send_event) { |e, att| [:success, e, att] }
        subject.multi_receive([LogStash::Event.new({ 'event' => 'small' }),
                               LogStash::Event.new({ 'event' => 'n' * 4_500_001 })])
      end

      include_examples('send small and drop large')
    end

    context 'with one too large event and one small event' do
      before do
        allow(subject).to receive(:send_event) { |e, att| [:success, e, att] }
        subject.multi_receive([LogStash::Event.new({ 'event' => 'n' * 4_500_001 }),
                               LogStash::Event.new({ 'event' => 'small' })])
      end

      include_examples('send small and drop large')
    end
  end

  context 'max_payload_size 2MB' do
    let(:config) { { 'ingest_endpoint_url' => ingest_endpoint_url, 'api_key' => api_key, 'max_payload_size' => 2_000_000 } }
    subject { LogStash::Outputs::Dynatrace.new(config) }

    before do
      allow(subject).to receive(:send_event) { |e, att| [:success, e, att] }
      subject.multi_receive([1, 2].map { |n| LogStash::Event.new({ 'n' => n.to_s * 1_250_000 }) })
    end

    it 'should split the chunk into multiple requests' do
      expect(subject).to have_received(:send_event).exactly(2).times
    end
  end

  context 'on retryable unknown exception' do
    before :each do
      raised = false
      original_method = subject.client.method(:post)
      allow(subject).to receive(:send_event).and_call_original
      expect(subject.client).to receive(:post) do |*args|
        unless raised
          raised = true
          raise ::Manticore::UnknownException, 'Read timed out'
        end
        original_method.call(args)
      end
      subject.multi_receive([event])
    end

    include_examples('failure log behaviour')

    it 'retries' do
      expect(subject).to have_received(:send_event).exactly(2).times
    end
  end

  context 'on non-retryable unknown exception' do
    before :each do
      raised = false
      original_method = subject.client.method(:post)
      allow(subject).to receive(:send_event).and_call_original
      expect(subject.client).to receive(:post) do |*args|
        unless raised
          raised = true
          raise ::Manticore::UnknownException, 'broken'
        end
        original_method.call(args)
      end
      subject.multi_receive([event])
    end

    include_examples('failure log behaviour')

    it 'does not retry' do
      expect(subject).to have_received(:send_event).exactly(1).times
    end
  end

  context 'on non-retryable exception' do
    before :each do
      raised = false
      original_method = subject.client.method(:post)
      allow(subject).to receive(:send_event).and_call_original
      expect(subject.client).to receive(:post) do |*args|
        unless raised
          raised = true
          raise 'broken'
        end
        original_method.call(args)
      end
      subject.multi_receive([event])
    end

    include_examples('failure log behaviour')

    it 'does not retry' do
      expect(subject).to have_received(:send_event).exactly(1).times
    end
  end

  context 'on retryable exception' do
    before :each do
      raised = false
      original_method = subject.client.method(:post)
      allow(subject).to receive(:send_event).and_call_original
      expect(subject.client).to receive(:post) do |*args|
        unless raised
          raised = true
          raise ::Manticore::Timeout, 'broken'
        end
        original_method.call(args)
      end
      subject.multi_receive([event])
    end

    it 'retries' do
      expect(subject).to have_received(:send_event).exactly(2).times
    end

    include_examples('failure log behaviour')
  end

  shared_examples('a received event') do
    before do
      TestApp.last_request = nil
    end

    let(:events) { [event] }

    describe 'with a good code' do
      before do
        subject.multi_receive(events)
      end

      let(:last_request) { TestApp.last_request }
      let(:body) { last_request.body.read }
      let(:content_type) { last_request.env['CONTENT_TYPE'] }

      it 'should receive the request' do
        expect(last_request).to be_truthy
      end

      it 'should receive the event as a hash' do
        expect(body).to eql(expected_body)
      end

      it 'should have the correct content type' do
        expect(content_type).to eql(expected_content_type)
      end
    end

    describe 'a retryable code' do
      let(:ingest_endpoint_url) { "http://localhost:#{port}/retry" }
      let(:api_key) { 'placeholder-key' }

      before do
        TestApp.retry_fail_count = 2
        allow(subject).to receive(:send_event).and_call_original
        allow(subject).to receive(:log_retryable_response)
        subject.multi_receive(events)
      end

      it 'should retry' do
        expect(subject).to have_received(:log_retryable_response).with(any_args).twice
      end
    end
  end

  shared_examples 'integration tests' do
    let(:base_config) { {} }
    let(:ingest_endpoint_url) { "http://localhost:#{port}/good" }
    let(:api_key) { 'placeholder-key' }
    let(:event) do
      LogStash::Event.new('foo' => 'bar', 'baz' => 'bot', 'user' => 'McBest')
    end

    subject { LogStash::Outputs::Dynatrace.new(config) }

    before do
      subject.register
    end

    describe 'sending with the default (JSON) config' do
      let(:config) do
        base_config.merge({ 'ingest_endpoint_url' => ingest_endpoint_url, 'api_key' => api_key, 'pool_max' => 1 })
      end
      let(:expected_body) { "#{LogStash::Json.dump([event].map(&:to_hash)).chomp}\n" }
      let(:expected_content_type) { 'application/json; charset=utf-8' }

      include_examples('a received event')
    end
  end

  describe 'integration test without gzip compression' do
    include_examples('integration tests')
  end

  describe "integration test with gzip compression" do
    include_examples("integration tests") do
      let(:base_config) { { "http_compression" => true } }
    end
  end

  describe 'retryable error in termination' do
    let(:ingest_endpoint_url) { "http://localhost:#{port - 1}/invalid" }
    let(:api_key) { 'placeholder-key' }
    let(:events) { [event] }
    let(:config) { { 'ingest_endpoint_url' => ingest_endpoint_url, 'api_key' => api_key, 'pool_max' => 1 } }

    subject { LogStash::Outputs::Dynatrace.new(config) }

    before do
      subject.register
      allow(subject).to receive(:pipeline_shutdown_requested?).and_return(true)
    end

    it 'raise exception to exit indefinitely retry' do
      expect do
        subject.multi_receive(events)
      end.to raise_error(LogStash::Outputs::Dynatrace::PluginInternalQueueLeftoverError)
    end
  end
end

RSpec.describe LogStash::Outputs::Dynatrace do # different block as we're starting web server with TLS
  @@default_server_settings = TestApp.server_settings.dup

  before do
    TestApp.server_settings = @@default_server_settings.merge(webrick_config)

    TestApp.last_request = nil

    @server = start_app_and_wait(TestApp)
  end

  let(:webrick_config) do
    cert, key = WEBrick::Utils.create_self_signed_cert 2048, [['CN', ssl_cert_host]], 'Logstash testing'
    {
      SSLEnable: true,
      SSLVerifyClient: OpenSSL::SSL::VERIFY_NONE,
      SSLCertificate: cert,
      SSLPrivateKey: key
    }
  end

  after do
    @server.shutdown # WEBrick::HTTPServer

    begin
      TestApp.stop!
    rescue StandardError
      nil
    end
    TestApp.server_settings = @@default_server_settings
  end

  let(:ssl_cert_host) { 'localhost' }

  let(:port) { PORT }
  let(:ingest_endpoint_url) { "https://localhost:#{port}/good" }
  let(:api_key) { 'placeholder-key' }
  let(:method) { 'post' }

  let(:config) { { 'ingest_endpoint_url' => ingest_endpoint_url, 'api_key' => api_key } }

  subject { LogStash::Outputs::Dynatrace.new(config) }

  before { subject.register }
  after  { subject.close }

  let(:last_request) { TestApp.last_request }
  let(:last_request_body) { last_request.body.read }

  let(:event) { LogStash::Event.new('message' => 'hello!') }

  context 'with default (full) verification' do
    let(:config) { super() } # 'ssl_verification_mode' => 'full'

    it 'does NOT process the request (due client protocol exception)' do
      # Manticore's default verification does not accept self-signed certificates!
      Thread.start do
        subject.multi_receive [event]
      end
      sleep 1.5

      expect(last_request).to be nil
    end
  end

  context 'with verification disabled' do
    let(:config) { super().merge 'ssl_verification_mode' => 'none' }

    it 'should process the request' do
      subject.multi_receive [event]
      expect(last_request_body).to include '"message":"hello!"'
    end
  end

  unless tls_version_enabled_by_default?('TLSv1.1')
    context 'with supported_protocols set to (disabled) 1.1' do
      let(:config) { super().merge 'ssl_supported_protocols' => ['TLSv1.1'], 'ssl_verification_mode' => 'none' }

      it 'keeps retrying due a protocol exception' do # TLSv1.1 not enabled by default
        expect(subject).to receive(:log_failure)
          .with('Could not fetch URL', hash_including(message: 'No appropriate protocol (protocol is disabled or cipher suites are inappropriate)'))
          .at_least(:once)
        Thread.start { subject.multi_receive [event] }
        sleep 1.0
      end
    end
  end

  context 'with supported_protocols set to 1.2/1.3' do
    let(:config) do
      super().merge 'ssl_supported_protocols' => ['TLSv1.2', 'TLSv1.3'], 'ssl_verification_mode' => 'none'
    end

    let(:webrick_config) { super().merge SSLVersion: 'TLSv1.2' }

    it 'should process the request' do
      subject.multi_receive [event]
      expect(last_request_body).to include '"message":"hello!"'
    end
  end

  if tls_version_enabled_by_default?('TLSv1.3') && JOpenSSL::VERSION > '0.12'
    context 'with supported_protocols set to 1.3' do
      let(:config) { super().merge 'ssl_supported_protocols' => ['TLSv1.3'], 'ssl_verification_mode' => 'none' }

      let(:webrick_config) { super().merge SSLVersion: 'TLSv1.3' }

      it 'should process the request' do
        subject.multi_receive [event]
        expect(last_request_body).to include '"message":"hello!"'
      end
    end
  end
end
