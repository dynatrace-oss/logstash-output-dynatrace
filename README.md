<!-- omit in toc -->
# Logstash Dynatrace output plugin

[![Travis Build Status](https://api.travis-ci.com/dynatrace-oss/logstash-output-dynatrace.svg?branch=main)](https://app.travis-ci.com/dynatrace-oss/logstash-output-dynatrace)

> This project is developed and maintained by Dynatrace R&D.

- [Installation Prerequisites](#installation-prerequisites)
- [Installation Steps](#installation-steps)
- [Example Configuration](#example-configuration)
- [Configuration Overview](#configuration-overview)
  - [Dynatrace-Specific Options](#dynatrace-specific-options)
  - [Common Options](#common-options)
- [Configuration Detail](#configuration-detail)
  - [`ingest_endpoint_url`](#ingest_endpoint_url)
  - [`api_key`](#api_key)
  - [`ssl_verify_none`](#ssl_verify_none)
  - [`proxy`](#proxy)
  - [`enable_metric`](#enable_metric)
  - [`id`](#id)
- [Troubleshooting issues](#troubleshooting-issues)
  - [Enable Debug Logs](#enable-debug-logs)

A [Logstash](https://github.com/elastic/logstash) output plugin for sending logs to the Dynatrace [Generic log ingest API v2](https://docs.dynatrace.com/docs/shortlink/api-log-monitoring-v2-post-ingest).
Please review the documentation for this API before using the plugin.

## Installation Prerequisites

- Logstash 7.6+

## Installation Steps

Logstash is typically installed in the `/usr/share/logstash` directory, and plugins are installed using the `/usr/share/logstash/bin/logstash-plugin` command.
If your logstash installation directory is different than this, your `logstash-plugin` command may be in a different location.

```sh
/usr/share/logstash/bin/logstash-plugin install logstash-output-dynatrace
```

## Example Configuration

See below for a detailed explanation of the options used in this example configuration.

```ruby
output {
  dynatrace {
    id => "dynatrace_output"
    ingest_endpoint_url => "${ACTIVE_GATE_URL}/api/v2/logs/ingest"
    api_key => "${API_KEY}"
  }
}
```

## Configuration Overview

The following configuration options are supported by the Dynatrace output plugin as well as the common options supported by all output plugins described below.

### Dynatrace-Specific Options


| Setting                                       | Input Type                                                                                            | Required |
| --------------------------------------------- | ----------------------------------------------------------------------------------------------------- | -------- |
| [`ingest_endpoint_url`](#ingest_endpoint_url) | [String](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#string)   | Yes      |
| [`api_key`](#api_key)                         | [String](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#string)   | Yes      |
| [`ssl_verify_none`](#ssl_verify_none)         | [Boolean](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#boolean) | No       |
| [`http_compression`](#http_compression)         | [Boolean](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#boolean) | No       |


### Common Options

The following configuration options are supported by all output plugins:

| Setting                           | Input type                                                                                            | Required |
| --------------------------------- | ----------------------------------------------------------------------------------------------------- | -------- |
| [`proxy`](#proxy)                 | [String](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#string) or [Hash](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#hash) | No |
|  `codec`                          | [Codec](https://www.elastic.co/guide/en/logstash/7.16/configuration-file-structure.html#codec)        | No       |
| [`enable_metric`](#enable_metric) | [Boolean](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#boolean) | No       |
| [`id`](#id)                       | [String](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#string)   | No       |

## Configuration Detail

### `ingest_endpoint_url` 

* Value type is [string](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#string)
* Required

This is the full URL of the [Generic log ingest API v2](https://docs.dynatrace.com/docs/shortlink/api-log-monitoring-v2-post-ingest/) endpoint on your ActiveGate.
Example: `"ingest_endpoint_url" => "https://abc123456.live.dynatrace.com/api/v2/logs/ingest"`

### `api_key`

* Value type is [string](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#string)
* Required

This is the [Dynatrace API token](https://docs.dynatrace.com/docs/shortlink/api-authentication) which will be used to authenticate log ingest requests.
It requires the `logs.ingest` (Ingest Logs) scope to be set and it is recommended to limit scope to only this one.
Example: `"api_key" => "dt0c01.4XLO3..."`

### `ssl_verify_none`

* Value type is [boolean](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#boolean)
* Optional
* Default value is `false`

It is recommended to leave this optional configuration set to `false` unless absolutely required.
Setting `ssl_verify_none` to `true` causes the output plugin to skip certificate verification when sending log ingest requests to SSL and TLS protected HTTPS endpoints.
This option may be required if you are using a self-signed certificate, an expired certificate, or a certificate which was generated for a different domain than the one in use.

> NOTE: Starting in plugin version `0.5.0`, this option has no effect in versions of Logstash older than `8.1.0`.
> If this functionality is required, it is recommended to update Logstash or stay at plugin version `0.4.x` or older.

### `max_payload_size`

* Value type is [number](https://www.elastic.co/docs/reference/logstash/configuration-file-structure#number)
* Optional
* Default value is `9_500_000`

It is recommended **not** to set this optional configuration unless you have a specific reason to do so.
If you, for example, are using a proxy with a payload size limit, this configuration can be used to reduce the maximum size batch that is sent to the server.

### `proxy`

* Value type is [string](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#string) or [hash](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#hash)
* Optional
* No default value
* Introduced in `logstash-output-dynatrace` version `0.5.0` (not available in older versions)

This setting configures an HTTP proxy to route exported data through.

The supported configuration options and their syntax are the same as for the [proxy option](https://www.elastic.co/guide/en/logstash/current/plugins-outputs-http.html#plugins-outputs-http-proxy) in the HTTP output plugin:

1. `proxy => http://example.org:1234`
2. `proxy => { host => "example.org" port => 80 scheme => 'http' user => 'username@host' password => 'password' }`
3. `proxy => { url =>  'http://example.org:1234' user => 'username@host' password => 'password' }`

Note that [Hashes](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#hash) in the Logstash configuration file format use spaces as delimiters between entries, not commas.

### `enable_metric`

* Value type is [boolean](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#boolean)
* Default value is true

Disable or enable metric logging for this specific plugin instance. By default we record all the metrics we can, but you can disable metrics collection for a specific plugin.

### `id`

* Value type is string
* No default value

Add a unique ID to the plugin configuration. If no ID is specified, Logstash will generate one. It is strongly recommended to set this ID in your configuration. This is particularly useful when you have two or more plugins of the same type. For example, if you have 2 dynatrace outputs. Adding a named ID in this case will help in monitoring Logstash when using the monitoring APIs.

```ruby
output {
  dynatrace {
    id => "my_plugin_id"
  }
}
```

### `http_compression`

* Value type is [boolean](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#boolean)
* Optional
* Default value is `false`

Setting `http_compression` to `true` causes the output plugin to compress all requests to the Dynatrace API using `gzip`.
This can result in a reduction in size and transmission time of network requests at the expense of some additional CPU and memory consumption.

## Troubleshooting issues

When troubleshooting, always try to reduce the configuration as much as possible.
It is recommended to disable all plugins except the Dynatrace output plugin and
a simple input plugin like the [http input plugin](https://www.elastic.co/guide/en/logstash/current/plugins-inputs-http.html)
in order to isolate problems caused by only the Dynatrace output plugin.

### Enable Debug Logs

See <https://www.elastic.co/guide/en/logstash/current/logging.html#logging>.

You can enable debug logging in one of several ways:

- Use the `--log.level debug` command line flag
- Configure the `log4j2.properties` file (usually in `/etc/logstash`) - More info [here](https://www.elastic.co/guide/en/logstash/current/logging.html#log4j2)
- Use the logging API - details [here](https://www.elastic.co/guide/en/logstash/current/logging.html#_update_logging_levels)
