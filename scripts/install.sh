#!/bin/bash -v
export PATH="/usr/local/bin:$PATH"
dnf upgrade -y
dnf install -y centos-release-openstack-bobcat wget
wget -q -O gpg.key https://rpm.grafana.com/gpg.key
rpm --import gpg.key
wget -q -O /etc/yum.repos.d/grafana.repo https://raw.githubusercontent.com/linitio/openstack-monitoring-stack/main/conf/grafana.repo
dnf install -y wget jq bc nc gnupg python3-openstackclient python3-devel python3-pip memcached httpd python3-mod_wsgi cairo-devel libffi-devel grafana
systemctl enable memcached
systemctl start memcached
export PYTHONPATH="/opt/graphite/lib/:/opt/graphite/webapp/"
pip3 install --no-binary=:all: https://github.com/graphite-project/whisper/tarball/master
pip3 install --no-binary=:all: https://github.com/graphite-project/carbon/tarball/master
pip3 install --no-binary=:all: https://github.com/graphite-project/graphite-web/tarball/master
pip3 install --upgrade pyopenssl
mkdir -p /etc/uwsgi/apps-available/
tee -a /opt/graphite/conf/wsgi.py<<EOF
[uwsgi]
processes = 2
socket = localhost:8080
gid = apache
uid = apache
virtualenv = /opt/graphite
chdir = /opt/graphite/conf
module = wsgi:application
EOF
tee -a /etc/uwsgi/apps-available/graphite.ini<<EOF
import sys
sys.path.append('/opt/graphite/webapp')
from graphite.wsgi import application
EOF
cp /opt/graphite/conf/graphite.wsgi.example /opt/graphite/webapp/graphite/graphite.wsgi
tee -a /etc/httpd/conf.d/graphite-vhost.conf<<EOF
LoadModule wsgi_module modules/mod_wsgi.so

WSGISocketPrefix /var/run/wsgi

<VirtualHost *:8080>

    ServerName graphite
    DocumentRoot "/opt/graphite/webapp"
    ErrorLog /opt/graphite/storage/log/webapp/error.log
    CustomLog /opt/graphite/storage/log/webapp/access.log common

    WSGIDaemonProcess graphite-web processes=5 threads=5 display-name='%{GROUP}' inactivity-timeout=120
    WSGIProcessGroup graphite-web
    WSGIApplicationGroup %{GLOBAL}
    WSGIImportScript /opt/graphite/webapp/graphite/graphite.wsgi process-group=graphite-web application-group=%{GLOBAL}

    WSGIScriptAlias / /opt/graphite/webapp/graphite/graphite.wsgi

    Alias /static/ /opt/graphite/static/

    <Directory /opt/graphite/static/>
            <IfVersion < 2.4>
                    Order deny,allow
                    Allow from all
            </IfVersion>
            <IfVersion >= 2.4>
                    Require all granted
            </IfVersion>
    </Directory>

    <Directory /opt/graphite/webapp/>
            <IfVersion < 2.4>
                    Order deny,allow
                    Allow from all
            </IfVersion>
            <IfVersion >= 2.4>
                    Require all granted
            </IfVersion>
    </Directory>
    <Directory /opt/graphite/conf/>
            <IfVersion < 2.4>
                    Order deny,allow
                    Allow from all
            </IfVersion>
            <IfVersion >= 2.4>
                    Require all granted
            </IfVersion>
    </Directory>
</VirtualHost>
EOF
tee -a /etc/httpd/conf.d/ports.conf<<EOF
Listen 8080

<IfModule ssl_module>
        Listen 443
</IfModule>

<IfModule mod_gnutls.c>
        Listen 443
</IfModule>
EOF

ln -s /etc/uwsgi/apps-available/graphite.ini /etc/uwsgi/apps-enabled
chown apache -R /opt/graphite/storage/log/
semanage fcontext -a -t httpd_sys_rw_content_t "/opt/graphite/storage/log(/.*)?"
restorecon -Rv /opt/graphite/storage/log
PYTHONPATH=/opt/graphite/webapp django-admin.py collectstatic --noinput --settings=graphite.settings
chown apache /opt/graphite/static -R
cp /opt/graphite/webapp/graphite/local_settings.py.example /opt/graphite/webapp/graphite/local_settings.py
cd /opt/graphite/static
PYTHONPATH=/opt/graphite/webapp django-admin.py migrate --settings=graphite.settings --run-syncdb
systemctl restart httpd
cp /opt/graphite/conf/carbon.conf.example /opt/graphite/conf/carbon.conf
cp /opt/graphite/conf/storage-schemas.conf.example /opt/graphite/conf/storage-schemas.conf
tee /opt/graphite/conf/storage-schemas.conf<<EOF
[carbon]
pattern = ^carbon\.
retentions = 60:90d

[default]
pattern = .*
retentions = 5m:365d
EOF
tee -a /etc/systemd/system/carbon-cache.service<<EOF
[Unit]
Description=Graphite Carbon Cache Instance
After=network.target
[Service]
Type=forking
StandardOutput=syslog
StandardError=syslog
ExecStart=/opt/graphite/bin/carbon-cache.py --config=/opt/graphite/conf/carbon.conf --pidfile=/var/run/carbon-cache.pid start
#ExecStart=/opt/graphite/bin/carbon-cache.py --config=/opt/graphite/conf/carbon.conf --pidfile=/var/run/carbon-cache-%i.pid --instance=%i start
ExecReload=/bin/kill -USR1 $MAINPID
PIDFile=/var/run/carbon-cache.pid
[Install]
WantedBy=multi-user.target
EOF
systemctl enable carbon-cache
systemctl start carbon-cache
touch /opt/graphite/storage/graphite.db
chown apache:root -R /opt/graphite/storage/
apt-get install -y grafana
systemctl daemon-reload
systemctl start grafana-server
systemctl enable grafana-server.service
service httpd restart
mkdir -p /etc/grafana/infomaniak
curl https://docs.infomaniak.cloud/documentation/09.others/monitoring/monitoring_grafana_template.json >> /etc/grafana/infomaniak/infomaniak-public-cloud.json
tee -a /etc/grafana/provisioning/dashboards/infomaniak-dashboard.yml<<EOF
            apiVersion: 1

            providers:
              # <string> an unique provider name. Required
              - name: 'Infomaniak Public Cloud'
                # <int> Org id. Default to 1
                orgId: 1
                # <string> name of the dashboard folder.
                folder: ''
                # <string> folder UID. will be automatically generated if not specified
                folderUid: ''
                # <string> provider type. Default to 'file'
                type: file
                # <bool> disable dashboard deletion
                disableDeletion: false
                # <int> how often Grafana will scan for changed dashboards
                updateIntervalSeconds: 10
                # <bool> allow updating provisioned dashboards from the UI
                allowUiUpdates: true
                options:
                  # <string, required> path to dashboard files on disk. Required when using the 'file' type
                  path: /etc/grafana/infomaniak/infomaniak-public-cloud.json
                  # <bool> use folder names from filesystem to create folders in Grafana
                  foldersFromFilesStructure: false
EOF
tee -a /etc/grafana/provisioning/datasources/infomaniak-datasource.yml<<EOF
            # config file version
            apiVersion: 1

            # list of datasources to insert/update depending
            # what's available in the database
            datasources:
              # <string, required> name of the datasource. Required
              - name: Graphite
                # <string, required> datasource type. Required
                type: graphite
                # <string, required> access mode. proxy or direct (Server or Browser in the UI). Required
                access: proxy
                # <int> org id. will default to orgId 1 if not specified
                orgId: 1
                # <string> custom UID which can be used to reference this datasource in other parts of the configuration, if not specified will be generated automatically
                #uid:
                # <string> url
                url: http://localhost:8080
                # <string> Deprecated, use secureJsonData.password
                password:
                # <string> database user, if used
                user:
                # <string> database name, if used
                database:
                # <bool> enable/disable basic auth
                basicAuth:
                # <string> basic auth username
                basicAuthUser:
                # <string> Deprecated, use secureJsonData.basicAuthPassword
                basicAuthPassword:
                # <bool> enable/disable with credentials headers
                withCredentials:
                # <bool> mark as default datasource. Max one per org
                isDefault: true
                # <map> fields that will be converted to json and stored in jsonData
                jsonData:
                  graphiteVersion: '1.1'
                  tlsAuth: false
                  tlsAuthWithCACert: false
                  # <string> database password, if used
                  password:
                  # <string> basic auth password
                  basicAuthPassword:
                version: 1
                # <bool> allow users to edit datasources from the UI.
                editable: true
EOF
sed -i 's/;default_home_dashboard_path =/default_home_dashboard_path = \/etc\/grafana\/infomaniak\/infomaniak-public-cloud.json/g' /etc/grafana/grafana.ini
systemctl restart grafana-server