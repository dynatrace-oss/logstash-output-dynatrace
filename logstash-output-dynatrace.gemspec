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

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'dynatrace/constants'

Gem::Specification.new do |s|
  s.name = 'logstash-output-dynatrace'
  s.version = Dynatrace::Constants::VERSION
  s.summary = 'A logstash output plugin for sending logs to the Dynatrace Generic log ingest API v2'
  s.description = <<-EOF
    This gem is a Logstash plugin required to be installed on top of the Logstash
    core pipeline using `$LS_HOME/bin/logstash-plugin install logstash-output-dynatrace`.
    This gem is not a stand-alone program.
  EOF
  s.authors       = ['Dynatrace Open Source Engineering']
  s.email         = ['opensource@dynatrace.com']
  s.homepage      = 'https://github.com/dynatrace-oss/logstash-output-dynatrace'
  s.licenses      = ['Apache-2.0']
  s.require_paths = ['lib']

  # Files
  s.files = Dir['lib/**/*', 'spec/**/*', 'vendor/**/*', '*.gemspec', '*.md', 'CONTRIBUTORS', 'Gemfile', 'LICENSE',
                'NOTICE.TXT', 'VERSION']
  # Tests
  s.test_files = s.files.grep(%r{^(test|spec|features)/})

  # Special flag to let logstash know this is actually a logstash plugin
  s.metadata = { 'logstash_plugin' => 'true', 'logstash_group' => 'output' }

  # Gem dependencies
  s.add_runtime_dependency 'logstash-codec-json'
  s.add_runtime_dependency 'logstash-core-plugin-api', '>= 2.0.0', '< 3'

  s.add_development_dependency 'insist'
  s.add_development_dependency 'logstash-devutils'
  s.add_development_dependency 'logstash-input-generator'
  s.add_development_dependency 'sinatra'
  s.add_development_dependency 'webrick'

  s.add_development_dependency 'rubocop', '1.9.1'
  s.add_development_dependency 'rubocop-rake', '0.5.1'
end
