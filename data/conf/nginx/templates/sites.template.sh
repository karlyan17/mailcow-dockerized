echo '
server {
  listen 127.0.0.1:65510;
  include /etc/nginx/conf.d/listen_plain.active;

  include /etc/nginx/conf.d/server_name.active;

  include /etc/nginx/conf.d/includes/site-defaults.conf;
}
';
