FROM nginx:alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
# Extension point: bind-mount host snippets here (see nginx.conf). Created
# empty so the image is valid unmounted — nginx tolerates an empty glob.
RUN mkdir -p /etc/nginx/gateway.d
# nginx opens access_log targets at startup and fails hard if the directory
# is missing — unlike gateway.d's empty glob, an absent access_log directory
# is a startup error, not a tolerated no-op. Needed so the image (and the
# existing standalone test suite) still starts with the audit-logs volume
# unmounted; the runtime mount shadows this once compose wires it up.
RUN mkdir -p /var/log/audit
