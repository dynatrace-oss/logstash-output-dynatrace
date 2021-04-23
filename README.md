# Logstash Plugin

[![Travis Build Status](https://travis-ci.com/logstash-plugins/logstash-output-example.svg)](https://travis-ci.com/logstash-plugins/logstash-output-example)

> This project is developed and maintained by Dynatrace R&D.

A [Logstash](https://github.com/elastic/logstash) output plugin for sending logs to the Dynatrace [Generic log ingest API v2](https://www.dynatrace.com/support/help/how-to-use-dynatrace/log-monitoring/log-monitoring-v2/post-log-ingest/).

## Documentation

Logstash provides plugin documentation in a [central location](https://www.elastic.co/guide/en/logstash/current/plugins-outputs-dynatrace.html).

## Developing

### 1. Plugin Developement and Testing

#### Code

- To get started, you'll need JRuby with the Bundler gem installed.

- Clone the plugin from github

- Install dependencies

```sh
bundle install
```

#### Test

- Update your dependencies

```sh
bundle install
```

- Run tests

```sh
bundle exec rspec
```

### 2. Running your unpublished Plugin in Logstash

#### 2.1 Run in a local Logstash clone

- Edit Logstash `Gemfile` and add the local plugin path, for example:

```ruby
gem "logstash-output-dynatrace", :path => "/your/local/logstash-output-dynatrace"
```

- Install plugin

```sh
# Logstash 2.3 and higher
bin/logstash-plugin install --no-verify

# Prior to Logstash 2.3
bin/plugin install --no-verify
```

- Run Logstash with your plugin

```sh
bin/logstash -e \
    'input { generator { count => 100 } } output { dynatrace { api_key => "your_api_key_here" ingest_endpoint_url => "https://{your-environment-id}.live.dynatrace.com/api/v2/logs/ingest" } }'
```

At this point any modifications to the plugin code will be applied to this local Logstash setup. After modifying the plugin, simply rerun Logstash.

#### 2.2 Run in an installed Logstash

You can use the same **2.1** method to run your plugin in an installed Logstash by editing its `Gemfile` and pointing the `:path` to your local plugin development directory or you can build the gem and install it using:

- Build your plugin gem

```sh
gem build logstash-output-dynatrace.gemspec

```

- Install the plugin from the Logstash home

```sh
# Logstash 2.3 and higher
bin/logstash-plugin install --no-verify

# Prior to Logstash 2.3
bin/plugin install --no-verify
```

- Start Logstash and proceed to test the plugin

## Contributing

All contributions are welcome: ideas, patches, documentation, bug reports, complaints, and even something you drew up on a napkin.

Programming is not a required skill. Whatever you've seen about open source and maintainers or community members  saying "send patches or die" - you will not see that here.

It is more important to the community that you are able to contribute.

For more information about contributing, see the [CONTRIBUTING](https://github.com/elastic/logstash/blob/master/CONTRIBUTING.md) file.
