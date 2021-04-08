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

require 'zlib'

class CompressedRequests
  def initialize(app)
    @app = app
  end

  def encoding_handled?(env)
    %w[gzip deflate].include? env['HTTP_CONTENT_ENCODING']
  end

  def call(env)
    if encoding_handled?(env)
      extracted = decode(env['rack.input'], env['HTTP_CONTENT_ENCODING'])

      env.delete('HTTP_CONTENT_ENCODING')
      env['CONTENT_LENGTH'] = extracted.bytesize
      env['rack.input'] = StringIO.new(extracted)
    end

    status, headers, response = @app.call(env)
    [status, headers, response]
  end

  def decode(input, content_encoding)
    case content_encoding
    when 'gzip' then Zlib::GzipReader.new(input).read
    when 'deflate' then Zlib::Inflate.inflate(input.read)
    end
  end
end
