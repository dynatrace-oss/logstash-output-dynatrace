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

source 'https://rubygems.org'

gemspec

logstash_path = ENV['LOGSTASH_PATH'] || '../../logstash'
use_logstash_source = ENV['LOGSTASH_SOURCE'] && ENV['LOGSTASH_SOURCE'].to_s == '1'

if Dir.exist?(logstash_path) && use_logstash_source
  gem 'logstash-core', path: "#{logstash_path}/logstash-core"
  gem 'logstash-core-plugin-api', path: "#{logstash_path}/logstash-core-plugin-api"
end
