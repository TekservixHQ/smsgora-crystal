# smsgora (Crystal)

[![tests](https://github.com/TekservixHQ/smsgora-crystal/actions/workflows/tests.yml/badge.svg)](https://github.com/TekservixHQ/smsgora-crystal/actions/workflows/tests.yml)

**SMS Gora SMS Gateway** - official Crystal client (shard): send and receive SMS through your own Android phones. By Tekservix.

Crystal shard for the [SMS Gora SMS Gateway](https://tekservix.com/smsgora/) API.

SMS Gora turns Android phones with ordinary SIM cards into an SMS gateway. Your server calls the API, a linked phone sends the text, and replies and delivery reports come back to you. There's no sender ID registration and no per-message fee from us: your mobile operator bills the texts like any SMS.

No dependencies beyond the Crystal standard library. Works with Kemal, Lucky, Amber and plain scripts.

## Install

Add to `shard.yml`:

```yaml
dependencies:
  smsgora:
    github: TekservixHQ/smsgora-crystal
```

then run `shards install`.

## Usage

You need a Tekservix account with SMS Gora and an API key (SMS Gora → API keys). Keep it on your server.

```crystal
require "smsgora"

sms = SmsGora::Client.new(ENV["SMSGORA_KEY"])

result = sms.send_sms("+15551234567", "Your verification code is 482913")
result["message_ids"][0]   # => 1873

# Several numbers, a chosen phone and SIM, scheduled
sms.send_sms(["+15551234567", "+447700900123"], "Reminder: 10:00 tomorrow",
  device_id: 42, sim_slot: 1, schedule_at: Time.utc(2026, 12, 1, 8, 0, 0))

# Different texts in one call (up to 5,000 recipients)
sms.send_bulk_sms(42, [
  SmsGora::BulkMessage.new(["+15551234567"], "Hi Aline, parcel #1042 is ready."),
  SmsGora::BulkMessage.new(["+15557654321"]),
], message_template: "Hello, your parcel is ready for pickup.")

sms.get_message(1873)["status"]              # queued, dispatched, sent, delivered, failed
sms.list_received_sms(since: "2026-11-01", limit: 50)
sms.list_devices
sms.get_account
sms.request("GET", "/batches/311")           # any other endpoint
```

Failed calls raise `SmsGora::Error` with `status`, `message`, `errors`, `body` and `retry_after`.

## Webhooks (Kemal)

```crystal
post "/sms-webhook" do |env|
  raw = env.request.body.try(&.gets_to_end) || ""
  halt env, 401 unless SmsGora.verify_webhook(raw, env.request.headers["X-SmsGora-Signature"]?, ENV["SMSGORA_WEBHOOK_SECRET"])
  event = JSON.parse(raw)
  # event["data"]["from"], event["data"]["message"]
  "ok"
end
```

## More from Tekservix

- [WAservix WhatsApp API Gateway](https://tekservix.com/waservix/) ([Crystal shard](https://github.com/TekservixHQ/waservix-crystal))
- [AI Sales Agent](https://tekservix.com/ai-sales-agent) and [Website to App](https://tekservix.com/mobile-apps)
- SMS Gora libraries for many more languages: [github.com/TekservixHQ](https://github.com/TekservixHQ)

## License

MIT
