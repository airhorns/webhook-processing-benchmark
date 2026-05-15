require "json"
require "openssl"
require "base64"

# Variant: WPB_JSON=oj swaps stdlib json for the oj gem on the hot path.
USE_OJ = ENV["WPB_JSON"] == "oj"
if USE_OJ
  require "oj"
  Oj.default_options = { mode: :strict }
end

module JsonCodec
  module_function

  if USE_OJ
    def parse(s) = Oj.load(s, mode: :strict)
    def dump(o)  = Oj.dump(o, mode: :strict)
  else
    def parse(s) = JSON.parse(s)
    def dump(o)  = JSON.dump(o)
  end
end

class WebhookApp
  HMAC_HEADER = "HTTP_X_SHOPIFY_HMAC_SHA256".freeze
  HMAC_HEADER_RACK = "x-shopify-hmac-sha256".freeze
  EMPTY = [].freeze
  STATUS_HEADERS = { "content-length" => "0" }.freeze
  NEWLINE = "\n".freeze

  def initialize(secret_path:)
    @secret = File.read(secret_path).strip
    @devnull = File.open("/dev/null", "wb")
    @devnull.sync = true
  end

  def call(env)
    return [404, STATUS_HEADERS, EMPTY] unless env["REQUEST_METHOD"] == "POST" && env["PATH_INFO"] == "/webhook"

    body = env["rack.input"].read

    header = env[HMAC_HEADER] || env[HMAC_HEADER_RACK]
    return [401, STATUS_HEADERS, EMPTY] unless valid_hmac?(body, header)

    begin
      payload = JsonCodec.parse(body)
    rescue StandardError
      return [400, STATUS_HEADERS, EMPTY]
    end

    variants = payload["variants"]
    return [400, STATUS_HEADERS, EMPTY] unless variants.is_a?(Array)

    variants.each do |variant|
      upcased = upcase_values(variant)
      @devnull.write(JsonCodec.dump(upcased))
      @devnull.write(NEWLINE)
    end

    [200, STATUS_HEADERS, EMPTY]
  end

  private

  def valid_hmac?(body, header)
    return false unless header

    expected = Base64.decode64(header)
    computed = OpenSSL::HMAC.digest("sha256", @secret, body)
    return false unless expected.bytesize == computed.bytesize

    OpenSSL.fixed_length_secure_compare(expected, computed)
  rescue ArgumentError
    false
  end

  def upcase_values(value)
    case value
    when String then value.upcase
    when Array  then value.map { |v| upcase_values(v) }
    when Hash
      result = {}
      value.each_pair { |k, v| result[k] = upcase_values(v) }
      result
    else
      value
    end
  end
end
