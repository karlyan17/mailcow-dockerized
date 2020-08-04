#!/bin/bash

trap "postfix stop" EXIT

[[ ! -d /opt/postfix/conf/sql/ ]] && mkdir -p /opt/postfix/conf/sql/

# Wait for MySQL to warm-up
while ! mysqladmin status --socket=/var/run/mysqld/mysqld.sock -u${DBUSER} -p${DBPASS} --silent; do
  echo "Waiting for database to come up..."
  sleep 2
done

cat <<EOF > /etc/aliases
# Autogenerated by mailcow
null: /dev/null
watchdog: /dev/null
ham: "|/usr/local/bin/rspamd-pipe-ham"
spam: "|/usr/local/bin/rspamd-pipe-spam"
EOF
newaliases;

# create sni configuration
echo -n "" > /opt/postfix/conf/sni.map;
for cert_dir in /etc/ssl/mail/*/ ; do
  if [[ ! -f ${cert_dir}domains ]] || [[ ! -f ${cert_dir}cert.pem ]] || [[ ! -f ${cert_dir}key.pem ]]; then
    continue;
  fi
  IFS=" " read -r -a domains <<< "$(cat "${cert_dir}domains")"
  for domain in "${domains[@]}"; do
    echo -n "${domain} ${cert_dir}key.pem ${cert_dir}cert.pem" >> /opt/postfix/conf/sni.map;
    echo "" >> /opt/postfix/conf/sni.map;
  done
done
postmap -F hash:/opt/postfix/conf/sni.map;

cat <<EOF > /opt/postfix/conf/sql/mysql_relay_ne.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT IF(EXISTS(SELECT address, domain FROM alias
      WHERE address = '%s'
        AND domain IN (
          SELECT domain FROM domain
            WHERE backupmx = '1'
              AND relay_all_recipients = '1'
              AND relay_unknown_only = '1')

      ), 'lmtp:inet:dovecot:24', NULL) AS 'transport'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_relay_recipient_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT DISTINCT
  CASE WHEN '%d' IN (
    SELECT domain FROM domain
      WHERE relay_all_recipients=1
        AND domain='%d'
        AND backupmx=1
  )
  THEN '%s' ELSE (
    SELECT goto FROM alias WHERE address='%s' AND active='1'
  )
  END AS result;
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_tls_policy_override_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT CONCAT(policy, ' ', parameters) AS tls_policy FROM tls_policy_override WHERE active = '1' AND dest = '%s'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_tls_enforce_in_policy.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT IF(EXISTS(
  SELECT 'TLS_ACTIVE' FROM alias
    LEFT OUTER JOIN mailbox ON mailbox.username = alias.goto
      WHERE (address='%s'
        OR address IN (
          SELECT CONCAT('%u', '@', target_domain) FROM alias_domain
            WHERE alias_domain='%d'
        )
      ) AND json_extract(attributes, '$.tls_enforce_in') LIKE '%%1%%' AND mailbox.active = '1'
  ), 'reject_plaintext_session', NULL) AS 'tls_enforce_in';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_sender_dependent_default_transport_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT GROUP_CONCAT(transport SEPARATOR '') AS transport_maps
  FROM (
    SELECT IF(EXISTS(SELECT 'smtp_type' FROM alias
      LEFT OUTER JOIN mailbox ON mailbox.username = alias.goto
        WHERE (address = '%s'
          OR address IN (
            SELECT CONCAT('%u', '@', target_domain) FROM alias_domain
              WHERE alias_domain = '%d'
          )
        )
        AND json_extract(attributes, '$.tls_enforce_out') LIKE '%%1%%'
        AND mailbox.active = '1'
    ), 'smtp_enforced_tls:', 'smtp:') AS 'transport'
    UNION ALL
    SELECT hostname AS transport FROM relayhosts
      LEFT OUTER JOIN domain ON domain.relayhost = relayhosts.id
        WHERE relayhosts.active = '1'
          AND domain = '%d'
          OR domain IN (
            SELECT target_domain FROM alias_domain
              WHERE alias_domain = '%d'
          )
  )
  AS transport_view;
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_transport_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT CONCAT('smtp_via_transport_maps:', nexthop) AS transport FROM transports
  WHERE active = '1'
  AND destination = '%s';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_resource_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT 'null@localhost' FROM mailbox
  WHERE kind REGEXP 'location|thing|group' AND username = '%s';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_sasl_passwd_maps_sender_dependent.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT CONCAT_WS(':', username, password) AS auth_data FROM relayhosts
  WHERE id IN (
    SELECT relayhost FROM domain
      WHERE CONCAT('@', domain) = '%s'
      OR domain IN (
        SELECT target_domain FROM alias_domain WHERE CONCAT('@', alias_domain) =  '%s'
      )
  )
  AND active = '1'
  AND username != '';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_sasl_passwd_maps_transport_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT CONCAT_WS(':', username, password) AS auth_data FROM transports
  WHERE nexthop = '%s'
  AND active = '1'
  AND username != ''
  LIMIT 1;
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_alias_domain_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT username FROM mailbox, alias_domain
  WHERE alias_domain.alias_domain = '%d'
    AND mailbox.username = CONCAT('%u', '@', alias_domain.target_domain)
    AND (mailbox.active = '1' OR mailbox.active = '2')
    AND alias_domain.active='1'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_alias_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT goto FROM alias
  WHERE address='%s'
    AND active='1';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_recipient_bcc_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT bcc_dest FROM bcc_maps
  WHERE local_dest='%s'
    AND type='rcpt'
    AND active='1';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_sender_bcc_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT bcc_dest FROM bcc_maps
  WHERE local_dest='%s'
    AND type='sender'
    AND active='1';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_recipient_canonical_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT new_dest FROM recipient_maps
  WHERE old_dest='%s'
    AND active='1';
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_domains_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT alias_domain from alias_domain WHERE alias_domain='%s' AND active='1'
  UNION
  SELECT domain FROM domain
    WHERE domain='%s'
      AND active = '1'
      AND backupmx = '0'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_mailbox_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT CONCAT(JSON_UNQUOTE(JSON_EXTRACT(attributes, '$.mailbox_format')), mailbox_path_prefix, '%d/%u/') FROM mailbox WHERE username='%s' AND (active = '1' OR active = '2')
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_relay_domain_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT domain FROM domain WHERE domain='%s' AND backupmx = '1' AND active = '1'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_sender_acl.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
# First select queries domain and alias_domain to determine if domains are active.
query = SELECT goto FROM alias
  WHERE address='%s'
    AND active='1'
    AND (domain IN
      (SELECT domain FROM domain
        WHERE domain='%d'
          AND active='1')
      OR domain in (
        SELECT alias_domain FROM alias_domain
          WHERE alias_domain='%d'
            AND active='1'
      )
    )
  UNION
  SELECT logged_in_as FROM sender_acl
    WHERE send_as='@%d'
      OR send_as='%s'
      OR send_as='*'
      OR send_as IN (
        SELECT CONCAT('@',target_domain) FROM alias_domain
          WHERE alias_domain = '%d')
      OR send_as IN (
        SELECT CONCAT('%u','@',target_domain) FROM alias_domain
          WHERE alias_domain = '%d')
      AND logged_in_as NOT IN (
        SELECT goto FROM alias
          WHERE address='%s')
  UNION
  SELECT username FROM mailbox, alias_domain
    WHERE alias_domain.alias_domain = '%d'
      AND mailbox.username = CONCAT('%u','@',alias_domain.target_domain)
      AND (mailbox.active = '1' OR mailbox.active ='2')
      AND alias_domain.active='1'
EOF

cat <<EOF > /opt/postfix/conf/sql/mysql_virtual_spamalias_maps.cf
# Autogenerated by mailcow
user = ${DBUSER}
password = ${DBPASS}
hosts = unix:/var/run/mysqld/mysqld.sock
dbname = ${DBNAME}
query = SELECT goto FROM spamalias
  WHERE address='%s'
    AND validity >= UNIX_TIMESTAMP()
EOF

sed -i '/User overrides/q' /opt/postfix/conf/main.cf
echo >> /opt/postfix/conf/main.cf
if [ -f /opt/postfix/conf/extra.cf ]; then
  cat /opt/postfix/conf/extra.cf >> /opt/postfix/conf/main.cf
fi

if [ ! -f /opt/postfix/conf/custom_transport.pcre ]; then
  echo "Creating dummy custom_transport.pcre"
  touch /opt/postfix/conf/custom_transport.pcre
fi

if [[ ! -f /opt/postfix/conf/custom_postscreen_whitelist.cidr ]]; then
  echo "Creating dummy custom_postscreen_whitelist.cidr"
  echo '# Autogenerated by mailcow' > /opt/postfix/conf/custom_postscreen_whitelist.cidr
fi

# Fix Postfix permissions
chown -R root:postfix /opt/postfix/conf/sql/ /opt/postfix/conf/custom_transport.pcre
chmod 640 /opt/postfix/conf/sql/*.cf /opt/postfix/conf/custom_transport.pcre
chgrp -R postdrop /var/spool/postfix/public
chgrp -R postdrop /var/spool/postfix/maildrop
postfix set-permissions

# Check Postfix configuration
postconf -c /opt/postfix/conf > /dev/null

if [[ $? != 0 ]]; then
  echo "Postfix configuration error, refusing to start."
  exit 1
else
  postfix -c /opt/postfix/conf start
  sleep 126144000
fi
