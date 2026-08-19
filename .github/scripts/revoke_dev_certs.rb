# SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
# SPDX-License-Identifier: GPL-2.0-or-later

require "jwt"
require "net/http"
require "json"

key_id = ENV.fetch("ASC_API_KEY_ID")
issuer_id = ENV.fetch("ASC_API_ISSUER_ID")
key_path = File.expand_path("~/private_keys/AuthKey_#{key_id}.p8")

token = JWT.encode(
  { iss: issuer_id, exp: Time.now.to_i + 600, aud: "appstoreconnect-v1" },
  OpenSSL::PKey::EC.new(File.read(key_path)),
  "ES256",
  { kid: key_id, typ: "JWT" }
)

uri = URI("https://api.appstoreconnect.apple.com/v1/certificates?limit=50")
resp = Net::HTTP.get(uri, { "Authorization" => "Bearer #{token}" })
certificates = JSON.parse(resp).fetch("data", [])

revoked = 0
certificates.each do |certificate|
  next if certificate["attributes"]["certificateType"] == "DISTRIBUTION"

  delete_uri = URI("https://api.appstoreconnect.apple.com/v1/certificates/#{certificate['id']}")
  http = Net::HTTP.new(delete_uri.host, delete_uri.port)
  http.use_ssl = true
  request = Net::HTTP::Delete.new(delete_uri.request_uri, { "Authorization" => "Bearer #{token}" })
  http.request(request)
  puts "Revoked #{certificate['id']} (#{certificate['attributes']['certificateType']})"
  revoked += 1
end

puts "Revoked #{revoked} development certificates"
