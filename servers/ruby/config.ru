$LOAD_PATH.unshift(File.expand_path(__dir__))
require "app"

secret_file = ENV.fetch("HMAC_SECRET_FILE", File.expand_path("../../shared/secret.txt", __dir__))

run WebhookApp.new(secret_path: secret_file)
