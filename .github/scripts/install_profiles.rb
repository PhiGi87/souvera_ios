# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: GPL-2.0-or-later

require "jwt"
require "net/http"
require "json"
require "base64"
require "fileutils"

key_id = ENV.fetch("ASC_API_KEY_ID")
issuer_id = ENV.fetch("ASC_API_ISSUER_ID")
key_path = File.expand_path("~/private_keys/AuthKey_#{key_id}.p8")

token = JWT.encode(
  { iss: issuer_id, exp: Time.now.to_i + 600, aud: "appstoreconnect-v1" },
  OpenSSL::PKey::EC.new(File.read(key_path)),
  "ES256",
  { kid: key_id, typ: "JWT" }
)

uri = URI("https://api.appstoreconnect.apple.com/v1/profiles?limit=200")
resp = Net::HTTP.get(uri, { "Authorization" => "Bearer #{token}" })
profiles = JSON.parse(resp).fetch("data", [])

dest = File.expand_path("~/Library/MobileDevice/Provisioning Profiles")
FileUtils.mkdir_p(dest)
installed = 0
profiles.each do |profile|
  attrs = profile["attributes"]
  next unless attrs["profileState"] == "ACTIVE" && attrs["profileType"] == "IOS_APP_STORE"

  path = File.join(dest, "#{attrs['uuid']}.mobileprovision")
  File.binwrite(path, Base64.decode64(attrs["profileContent"]))
  puts "Installed #{attrs['uuid']} #{attrs['name']}"
  installed += 1
end

puts "Installed #{installed} IOS_APP_STORE profiles"
exit 1 if installed.zero?
