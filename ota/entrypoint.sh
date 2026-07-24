#!/bin/sh
set -e
echo "Downloading IPA..."
curl -fsSL -o /usr/share/nginx/html/Souvera.ipa \
  "https://github.com/PhiGi87/souvera_ios/releases/download/ota-33.1.0/Nextcloud.ipa" && \
echo "IPA ready ($(du -h /usr/share/nginx/html/Souvera.ipa | cut -f1))"
exec nginx -g "daemon off;"
