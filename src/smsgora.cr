require "crypto/subtle"
require "http/client"
require "json"
require "openssl/hmac"
require "uri"

# Crystal client for the SMS Gora SMS Gateway API (https://tekservix.com/smsgora/).
#
# ```
# require "smsgora"
# sms = SmsGora::Client.new(ENV["SMSGORA_KEY"])
# result = sms.send_sms(["+15551234567"], "Your code is 482913")
# result["message_ids"][0] # => 1873
# ```
#
# Needs a Tekservix account with SMS Gora and an API key. Keep it on your server.
module SmsGora
  VERSION          = "1.0.0"
  DEFAULT_BASE_URL = "https://tekservix.com/smsgora/api/v1"

  # Raised when the API answers with an error. `status` is 0 when the request never reached the API.
  class Error < Exception
    getter status : Int32
    getter errors : JSON::Any?
    getter body : String
    getter retry_after : Float64?

    def initialize(message : String, @status : Int32, @errors : JSON::Any? = nil, @body : String = "", @retry_after : Float64? = nil)
      super(message)
    end
  end

  # One entry for `Client#send_bulk_sms`. Leave `message` nil to use the shared template.
  record BulkMessage, recipients : Array(String), message : String? = nil do
    def to_json(json : JSON::Builder)
      json.object do
        json.field "recipients", recipients
        json.field "message", message if message
      end
    end
  end

  class Client
    getter base_url : String

    def initialize(@api_key : String, base_url : String = DEFAULT_BASE_URL, @timeout : Time::Span = 30.seconds)
      raise ArgumentError.new("SmsGora: api_key is required (create one in SMS Gora -> API keys)") if @api_key.empty?
      @base_url = base_url.rstrip('/')
    end

    # Call any documented endpoint, e.g. `request("GET", "/devices")`. Returns the `data` field.
    def request(method : String, path : String, body = nil) : JSON::Any
      headers = HTTP::Headers{
        "x-api-key"  => @api_key,
        "Accept"     => "application/json",
        "User-Agent" => "smsgora-crystal/#{VERSION}",
      }
      payload = nil
      unless body.nil?
        headers["Content-Type"] = "application/json"
        payload = body.to_json
      end

      uri = URI.parse(@base_url + path)
      response = begin
        client = HTTP::Client.new(uri)
        client.connect_timeout = @timeout
        client.read_timeout = @timeout
        client.exec(method.upcase, uri.request_target, headers, payload)
      rescue ex : IO::Error | Socket::Error
        raise Error.new("SmsGora: request failed (#{ex.message})", 0)
      end

      text = response.body
      data = text.empty? ? nil : (JSON.parse(text) rescue nil)
      hash = data.try &.as_h?
      failed = hash && hash["success"]? == JSON::Any.new(false)
      if response.status_code >= 400 || failed
        message = hash.try(&.["message"]?).try(&.as_s?) || "HTTP #{response.status_code}"
        retry = response.headers["Retry-After"]?.try &.to_f?
        raise Error.new(message, response.status_code, hash.try(&.["errors"]?), text, retry)
      end
      return hash["data"] if hash && hash.has_key?("data")
      data || JSON::Any.new(nil)
    end

    # Send an SMS to up to 1,000 numbers. `sim_slot`: 0 = SIM 1, 1 = SIM 2. Returns `{"message_ids": [...]}`.
    def send_sms(to : Array(String), message : String, device_id = nil, sim_slot : Int32? = nil, schedule_at : Time | String | Nil = nil) : JSON::Any
      raise ArgumentError.new("send_sms: at least one recipient is required") if to.empty?
      body = {} of String => JSON::Any
      body["recipients"] = JSON::Any.new(to.map { |n| JSON::Any.new(n) })
      body["message"] = JSON::Any.new(message)
      body["sim_slot"] = JSON::Any.new(sim_slot.to_i64) if sim_slot
      case schedule_at
      when Time   then body["schedule_at"] = JSON::Any.new(schedule_at.to_utc.to_s("%Y-%m-%dT%H:%M:%SZ"))
      when String then body["schedule_at"] = JSON::Any.new(schedule_at)
      end
      path = device_id ? "/devices/#{esc(device_id)}/send-sms" : "/send-sms"
      request("POST", path, body)
    end

    # Send an SMS to one number.
    def send_sms(to : String, message : String, **opts) : JSON::Any
      send_sms([to], message, **opts)
    end

    # Different texts for different people in one call (up to 5,000 recipients).
    # `messages`: `[SmsGora::BulkMessage.new(["+1555..."], "own text"), ...]`
    def send_bulk_sms(device_id, messages : Array(BulkMessage), message_template : String? = nil) : JSON::Any
      body = {"messages" => JSON.parse(messages.to_json)} of String => JSON::Any
      body["messageTemplate"] = JSON::Any.new(message_template) if message_template
      request("POST", "/devices/#{esc(device_id)}/send-bulk-sms", body)
    end

    # Status is queued, dispatched, sent, delivered, failed or cancelled.
    def get_message(id) : JSON::Any
      request("GET", "/messages/#{esc(id)}")
    end

    # Cancel a queued or scheduled message.
    def cancel_message(id) : JSON::Any
      request("POST", "/messages/#{esc(id)}/cancel")
    end

    # Filters: direction, status, device_id, phone, since, after_id, page, limit.
    def list_messages(**filters) : JSON::Any
      request("GET", "/messages" + query(filters))
    end

    # Incoming SMS for all phones, or one phone with `device_id`.
    def list_received_sms(device_id = nil, **filters) : JSON::Any
      path = device_id ? "/devices/#{esc(device_id)}/get-received-sms" : "/received-sms"
      request("GET", path + query(filters))
    end

    def get_batch(id) : JSON::Any
      request("GET", "/batches/#{esc(id)}")
    end

    # Your linked Android phones.
    def list_devices : JSON::Any
      request("GET", "/devices")
    end

    def get_device(id) : JSON::Any
      request("GET", "/devices/#{esc(id)}")
    end

    # Account, plan and usage.
    def get_account : JSON::Any
      request("GET", "/account")
    end

    def list_webhooks : JSON::Any
      request("GET", "/webhooks")
    end

    # Register a webhook. The answer includes the secret (returned only once).
    def create_webhook(url : String, events : Array(String) = ["sms.received"], device_id = nil) : JSON::Any
      request("POST", "/webhooks", {"url" => url, "events" => events, "device_id" => device_id})
    end

    def delete_webhook(id) : JSON::Any
      request("DELETE", "/webhooks/#{esc(id)}")
    end

    private def esc(value) : String
      URI.encode_path_segment(value.to_s).gsub("+", "%2B").gsub("@", "%40")
    end

    private def query(params) : String
      pairs = [] of {String, String}
      params.each { |k, v| pairs << {k.to_s, v.to_s} unless v.nil? || v.to_s.empty? }
      return "" if pairs.empty?
      pairs.sort_by!(&.[0])
      "?" + pairs.map { |k, v| "#{URI.encode_www_form(k)}=#{URI.encode_www_form(v)}" }.join("&")
    end
  end

  # Check the X-SmsGora-Signature header (`sha256=<hex HMAC-SHA256 of the raw body>`).
  # Pass the raw request body exactly as received, before JSON parsing.
  def self.verify_webhook(raw_body : String, signature : String?, secret : String) : Bool
    return false if raw_body.empty? || signature.nil? || signature.empty? || secret.empty?
    expected = "sha256=" + OpenSSL::HMAC.hexdigest(:sha256, secret, raw_body)
    Crypto::Subtle.constant_time_compare(expected, signature)
  end
end
