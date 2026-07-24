FROM nginx:alpine
RUN apk add --no-cache curl
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html /usr/share/nginx/html/index.html
COPY manifest.plist /usr/share/nginx/html/manifest.plist
RUN curl -fsSL -o /usr/share/nginx/html/Souvera.ipa \
      "https://github.com/PhiGi87/souvera_ios/releases/download/ota-33.1.0/Nextcloud.ipa"
EXPOSE 80
