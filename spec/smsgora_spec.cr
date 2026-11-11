require "spec"
require "http/server"
require "../src/smsgora"

# Local fake API: records the last request and answers by path prefix.
record Seen, method : String, resource : String, key : String?, body : JSON::Any?

LAST = Channel(Seen).new(100)

SERVER = HTTP::Server.new do |ctx|
  req = ctx.request
  raw = req.body.try(&.gets_to_end) || ""
  LAST.send(Seen.new(req.method, req.resource, req.headers["x-api-key"]?, raw.empty? ? nil : JSON.parse(raw)))
  ctx.response.content_type = "application/json"
  if req.path.starts_with?("/limited")
    ctx.response.status_code = 429
    ctx.response.headers["Retry-After"] = "12"
    ctx.response.print %({"success":false,"message":"Too many requests","errors":{"recipients":["bad"]}})
  elsif req.path.starts_with?("/broken")
    ctx.response.status_code = 502
    ctx.response.content_type = "text/html"
    ctx.response.print "<html>bad gateway</html>"
  else
    ctx.response.print %({"success":true,"data":{"message_ids":[1873]}})
  end
end
ADDR = SERVER.bind_tcp("127.0.0.1", 0)
spawn { SERVER.listen }

def client(prefix = "/api/")
  SmsGora::Client.new("sgk_test", base_url: "http://127.0.0.1:#{ADDR.port}#{prefix}")
end

describe SmsGora do
  it "sends an SMS" do
    result = client.send_sms("+15551234567", "Hi")
    result["message_ids"][0].as_i.should eq 1873
    seen = LAST.receive
    seen.method.should eq "POST"
    seen.resource.should eq "/api/send-sms"
    seen.key.should eq "sgk_test"
    seen.body.not_nil!["recipients"].as_a.map(&.as_s).should eq ["+15551234567"]
    seen.body.not_nil!["message"].as_s.should eq "Hi"
    seen.body.not_nil!.as_h.has_key?("sim_slot").should be_false
  end

  it "uses phone, SIM and schedule" do
    client.send_sms(["+1", "+2"], "x", device_id: 42, sim_slot: 1, schedule_at: Time.utc(2026, 12, 1, 8, 0, 0))
    seen = LAST.receive
    seen.resource.should eq "/api/devices/42/send-sms"
    seen.body.not_nil!["sim_slot"].as_i.should eq 1
    seen.body.not_nil!["schedule_at"].as_s.should eq "2026-12-01T08:00:00Z"
  end

  it "builds paths and queries" do
    c = client
    c.send_bulk_sms(42, [{"recipients" => ["+1"], "message" => "a"}, {"recipients" => ["+2"]}] of Hash(String, String | Array(String)), message_template: "t")
    seen = LAST.receive
    seen.resource.should eq "/api/devices/42/send-bulk-sms"
    seen.body.not_nil!["messageTemplate"].as_s.should eq "t"
    c.list_received_sms(phone: "+1555", since: "2026-11-01")
    LAST.receive.resource.should eq "/api/received-sms?phone=%2B1555&since=2026-11-01"
    c.list_received_sms(device_id: 3)
    LAST.receive.resource.should eq "/api/devices/3/get-received-sms"
    c.cancel_message(7)
    LAST.receive.resource.should eq "/api/messages/7/cancel"
    c.create_webhook("https://my.app/hook")
    LAST.receive.body.not_nil!["events"].as_a.map(&.as_s).should eq ["sms.received"]
    c.delete_webhook(9)
    LAST.receive.method.should eq "DELETE"
    expect_raises(ArgumentError) { c.send_sms([] of String, "x") }
    expect_raises(ArgumentError) { SmsGora::Client.new("") }
  end

  it "raises API errors" do
    err = expect_raises(SmsGora::Error) { client("/limited").get_account }
    LAST.receive
    err.status.should eq 429
    err.message.should eq "Too many requests"
    err.retry_after.should eq 12.0
    err.errors.not_nil!["recipients"][0].as_s.should eq "bad"

    err2 = expect_raises(SmsGora::Error) { client("/broken").list_devices }
    LAST.receive
    err2.message.should eq "HTTP 502"
    err2.body.should eq "<html>bad gateway</html>"
  end

  it "verifies webhooks" do
    raw = %({"event":"sms.received","data":{"from":"+15551234567"}})
    sig = "sha256=e125c07dfbecb498e8979383d7b9f0815efb128755409794b486d4bbb7199583"
    SmsGora.verify_webhook(raw, sig, "whsec_test").should be_true
    SmsGora.verify_webhook(raw, sig, "other").should be_false
    SmsGora.verify_webhook("{}", sig, "whsec_test").should be_false
    SmsGora.verify_webhook(raw, nil, "whsec_test").should be_false
  end
end
