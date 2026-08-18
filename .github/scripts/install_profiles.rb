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

uri = URI("https://api.appstoreconnect.apple.com/v1/profiles?limit=200&include=bundleId")
resp = Net::HTTP.get(uri, { "Authorization" => "Bearer #{token}" })
payload = JSON.parse(resp)
bundle_ids = {}
(payload["included"] || []).each do |inc|
  next unless inc["type"] == "bundleIds"

  bundle_ids[inc["id"]] = inc["attributes"]["identifier"]
end

dest = File.expand_path("~/Library/MobileDevice/Provisioning Profiles")
FileUtils.mkdir_p(dest)
installed = 0
mapping = {}
(payload["data"] || []).each do |profile|
  attrs = profile["attributes"]
  next unless attrs["profileState"] == "ACTIVE" && attrs["profileType"] == "IOS_APP_STORE"

  path = File.join(dest, "#{attrs['uuid']}.mobileprovision")
  File.binwrite(path, Base64.decode64(attrs["profileContent"]))
  identifier = bundle_ids.dig(profile.dig("relationships", "bundleId", "data", "id"))
  mapping[identifier] = attrs["uuid"] if identifier
  puts "Installed #{attrs['uuid']} #{attrs['name']} (#{identifier})"
  installed += 1
end

puts "Installed #{installed} IOS_APP_STORE profiles"
exit 1 if installed.zero?

export_method = ENV.fetch("EXPORT_METHOD", "app-store-connect")
plist = <<~PLIST
  <?xml version="1.0" encoding="UTF-8"?>
  <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
  <plist version="1.0">
  <dict>
    <key>method</key>
    <string>#{export_method}</string>
    <key>teamID</key>
    <string>#{ENV.fetch("TEAM_ID", "S76D7JCS9V")}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>provisioningProfiles</key>
    <dict>
  #{mapping.map { |ident, uuid| "    <key>#{ident}</key>\n    <string>#{uuid}</string>" }.join("\n")}
    </dict>
  </dict>
  </plist>
PLIST
File.write("ExportOptions.plist", plist)
puts "Wrote ExportOptions.plist with #{mapping.size} provisioning profiles"
