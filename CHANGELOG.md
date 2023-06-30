## 0.3.3

- Add OpenSSL::SSL::SSLError to the list of retried exception

## 0.3.2

- Add Net::OpenTimeout to the list of retried exceptions

## 0.3.1

- Log and re-raise unknown errors
- Use [password](https://www.elastic.co/guide/en/logstash/current/configuration-file-structure.html#password) type for `api_key` configuration

## 0.3.0

- Log response bodies on client errors

## 0.2.0

- Add retries with exponential backoff (#8)

## 0.1.0

- Initial release
