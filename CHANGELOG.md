## 0.7.0

- Add new development dependency `rackup` for logstash 8.x compatibility
- Enable `compression` configuration to compress payloads using `gzip`
- Document `proxy` configuration

## 0.6.0

- Disable cookie processing by default

## 0.5.1

- Split large batches into smaller requests in order to meet Dynatrace API payload size limitations

## 0.5.0

- Rewrite plugin using http client mixin

## 0.4.0

- Add` OpenSSL::SSL::SSLError` to the list of retried exception
- Change concurrency mode to `:single`

## 0.3.2

- Add `Net::OpenTimeout` to the list of retried exceptions

## 0.3.1

- Log and re-raise unknown errors
- Use [password](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#password) type for `api_key` configuration

## 0.3.0

- Log response bodies on client errors

## 0.2.0

- Add retries with exponential backoff (#8)

## 0.1.0

- Initial release
