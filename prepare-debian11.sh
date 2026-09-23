#!/bin/bash
# Native (non-Docker) installer for the OpenRoaming Hybrid Connector.
#
# Installs and wires up, directly on the host:
#   - FreeRADIUS 3.2 (NetworkRADIUS/InkBridge apt repo)
#   - radsecproxy (built from source, version pinned below)
#   - PostgreSQL (installed locally, or skipped if pointed at a remote/DBaaS host)
#
# Usage:
#   $ curl -fsSL https://raw.githubusercontent.com/wireless-broadband-alliance/wba-openroaming-connector/main/prepare-debian11.sh -o prepare-debian11.sh
#   $ chmod +x prepare-debian11.sh
#   $ ./prepare-debian11.sh

set -euo pipefail

REPO_URL="https://github.com/wireless-broadband-alliance/wba-openroaming-connector.git"
CERTS_PATH="/root/wba-openroaming-connector/certs"
PROJECT_PATH="/root/wba-openroaming-connector"

RADSECPROXY_VERSION="1.11.4"
RADSECPROXY_URL="https://github.com/radsecproxy/radsecproxy/releases/download/${RADSECPROXY_VERSION}/radsecproxy-${RADSECPROXY_VERSION}.tar.gz"

# Override if NetworkRADIUS/InkBridge change their repo layout for your
# distro/release - verify against https://networkradius.com/packages/3.2/
# before relying on this in production.
NR_KEY_URL="${NR_KEY_URL:-https://packages.networkradius.com/pgp/packages@networkradius.com}"
NR_REPO_BASE="${NR_REPO_BASE:-https://packages.networkradius.com/freeradius-3.2}"

if [ "$EUID" -ne 0 ]; then
    echo "You must run this script as root, you can either sudo the script directly or become root with a command such as 'sudo su'"
    exit 1
fi

if [[ ! -f "$CERTS_PATH/wba/key.pem" ]]; then
    echo "Please upload your certificate private key to $CERTS_PATH/wba/key.pem"
    exit 1
fi
if [[ ! -f "$CERTS_PATH/wba/client.pem" ]]; then
    echo "Please upload your OpenRoaming certificate to $CERTS_PATH/wba/client.pem"
    exit 1
fi
if [[ ! -f "$CERTS_PATH/freeradius/cert.pem" ]]; then
    echo "Please upload your FreeRadius (LetsEncrypt) certificate to $CERTS_PATH/freeradius/cert.pem"
    exit 1
fi
if [[ ! -f "$CERTS_PATH/freeradius/chain.pem" ]]; then
    echo "Please upload your FreeRadius (LetsEncrypt) chain to $CERTS_PATH/freeradius/chain.pem"
    exit 1
fi
if [[ ! -f "$CERTS_PATH/freeradius/fullchain.pem" ]]; then
    echo "Please upload your FreeRadius (LetsEncrypt) fullchain to $CERTS_PATH/freeradius/fullchain.pem"
    exit 1
fi
if [[ ! -f "$CERTS_PATH/freeradius/privkey.pem" ]]; then
    echo "Please upload your FreeRadius (LetsEncrypt) private key to $CERTS_PATH/freeradius/privkey.pem"
    exit 1
fi

# Prompt for user input
read -p "Enter REALM name: " realm_name
read -p "Enter the client CIDR (default: 0.0.0.0/0): " client_cidr
client_cidr=${client_cidr:-0.0.0.0/0}
read -p "Enter the client secret (default: radsec): " client_secret
client_secret=${client_secret:-radsec}

read -p "PostgreSQL host (leave blank to install PostgreSQL locally on this node): " db_host
read -p "Enter database name (default: radius): " db_name
db_name=${db_name:-radius}
read -p "Enter database user (default: admin): " db_user
db_user=${db_user:-admin}
read -p "Enter database password (default: admin): " db_password
db_password=${db_password:-admin}

# ---------------------------------------------------------------------------
# 1. Base dependencies
# ---------------------------------------------------------------------------
apt-get update -y
apt-get install -y curl wget nano git gnupg build-essential libssl-dev nettle-dev pkg-config

# ---------------------------------------------------------------------------
# 2. FreeRADIUS 3.2 via NetworkRADIUS/InkBridge apt repo
# ---------------------------------------------------------------------------
. /etc/os-release
install -d -o root -g root -m 0755 /etc/apt/keyrings
curl -fsSL "$NR_KEY_URL" -o /etc/apt/keyrings/packages.networkradius.com.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/packages.networkradius.com.asc] ${NR_REPO_BASE}/${ID} ${VERSION_CODENAME} main" \
    > /etc/apt/sources.list.d/networkradius.list

if ! apt-get update -y; then
    echo "Failed to fetch the NetworkRADIUS/InkBridge apt repo for ${ID}/${VERSION_CODENAME}."
    echo "Check the current repo path at https://networkradius.com/packages/3.2/ and re-run with NR_REPO_BASE set accordingly."
    exit 1
fi
apt-get install -y freeradius freeradius-utils freeradius-postgresql

FR_ETC=/etc/freeradius/3.0
if [ ! -d "$FR_ETC" ]; then
    FR_ETC=/etc/freeradius
fi

# ---------------------------------------------------------------------------
# 3. PostgreSQL (local install, unless a remote/DBaaS host was given)
# ---------------------------------------------------------------------------
if [ -z "$db_host" ]; then
    apt-get install -y postgresql postgresql-client
    systemctl enable --now postgresql
    db_host="localhost"

    sudo -u postgres psql <<SQL
CREATE DATABASE ${db_name};
CREATE USER ${db_user} WITH ENCRYPTED PASSWORD '${db_password}';
GRANT ALL PRIVILEGES ON DATABASE ${db_name} TO ${db_user};
SQL
    sudo -u postgres psql -d "$db_name" -c "GRANT ALL ON SCHEMA public TO ${db_user};"

    # Allow the FreeRADIUS SQL module (which connects over TCP, not the
    # Unix socket) to authenticate with a password on loopback.
    PG_HBA="$(sudo -u postgres psql -tAc 'SHOW hba_file;')"
    if ! grep -q "^host\s\+${db_name}\s\+${db_user}\s\+127.0.0.1/32" "$PG_HBA"; then
        echo "host    ${db_name}    ${db_user}    127.0.0.1/32    scram-sha-256" >> "$PG_HBA"
        systemctl reload postgresql
    fi
else
    apt-get install -y postgresql-client
fi

# ---------------------------------------------------------------------------
# 4. Fetch project files (configs, certs, schema) if not already present
# ---------------------------------------------------------------------------
if [ ! -d "$PROJECT_PATH" ]; then
    mkdir -p "$(dirname "$PROJECT_PATH")"
    git clone "$REPO_URL" "$PROJECT_PATH"
fi

# ---------------------------------------------------------------------------
# 5. Apply the FreeRADIUS SQL schema
# ---------------------------------------------------------------------------
SCHEMA_FILE="${PROJECT_PATH}/configs/postgresql/schema/freeradius.sql"
if [ "$db_host" = "localhost" ]; then
    SCHEMA_APPLY_OK=1
    sudo -u postgres psql -d "$db_name" -f "$SCHEMA_FILE" || SCHEMA_APPLY_OK=0
else
    SCHEMA_APPLY_OK=1
    PGPASSWORD="$db_password" psql "host=${db_host} port=5432 dbname=${db_name} user=${db_user} sslmode=require" -f "$SCHEMA_FILE" || SCHEMA_APPLY_OK=0
fi
if [ "$SCHEMA_APPLY_OK" -eq 0 ]; then
    echo "Could not apply the schema automatically against ${db_host}."
    echo "Apply it manually: psql \"host=${db_host} port=5432 dbname=${db_name} user=${db_user} sslmode=require\" -f ${SCHEMA_FILE}"
fi

# ---------------------------------------------------------------------------
# 6. Build and install radsecproxy from source
# ---------------------------------------------------------------------------
id -u radsecproxy &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin radsecproxy

BUILD_DIR="$(mktemp -d)"
curl -fsSL "$RADSECPROXY_URL" -o "${BUILD_DIR}/radsecproxy.tar.gz"
tar xf "${BUILD_DIR}/radsecproxy.tar.gz" --strip-components=1 -C "$BUILD_DIR"
(
    cd "$BUILD_DIR"
    ./configure --prefix=/usr/local --sysconfdir=/etc
    make
    make install
)
rm -rf "$BUILD_DIR"

mkdir -p /etc/radsecproxy/certs/chain
rm -f /etc/radsecproxy/certs/key.pem /etc/radsecproxy/certs/client.pem /etc/radsecproxy/certs/chain.pem
cp "$CERTS_PATH/wba/key.pem" /etc/radsecproxy/certs/key.pem
cp "$CERTS_PATH/wba/client.pem" /etc/radsecproxy/certs/client.pem
cp "${PROJECT_PATH}/configs/radsecproxy/certs/chain/"*.pem /etc/radsecproxy/certs/chain/
cat /etc/radsecproxy/certs/client.pem /etc/radsecproxy/certs/chain/WBA_Issuing_CA.pem /etc/radsecproxy/certs/chain/WBA_Cisco_Policy_CA.pem \
    /etc/radsecproxy/certs/chain/WBA_Issuing7_CA.pem /etc/radsecproxy/certs/chain/WBA_Policy7_CA.pem \
    > /etc/radsecproxy/certs/chain.pem

sed -e "s/-RNAME-/${realm_name//./\\.}/g" \
    -e "s|-RCLIENT-|${client_cidr}|g" \
    -e "s/-RSECRET-/${client_secret}/g" \
    "${PROJECT_PATH}/configs/radsecproxy/radsecproxy.conf" > /etc/radsecproxy.conf

install -m 0755 "${PROJECT_PATH}/configs/radsecproxy/naptr-openroaming.sh" /etc/radsecproxy/naptr-openroaming.sh

chown -R radsecproxy:radsecproxy /etc/radsecproxy /etc/radsecproxy.conf
chmod 600 /etc/radsecproxy/certs/key.pem
chmod 644 /etc/radsecproxy/certs/client.pem /etc/radsecproxy/certs/chain.pem

install -m 0644 "${PROJECT_PATH}/systemd/radsecproxy.service" /etc/systemd/system/radsecproxy.service
systemctl daemon-reload
systemctl enable --now radsecproxy

# ---------------------------------------------------------------------------
# 7. FreeRADIUS configuration
# ---------------------------------------------------------------------------
install -m 0644 "${PROJECT_PATH}/configs/freeradius/site-config/tls" "${FR_ETC}/sites-available/tls"
ln -sf ../sites-available/tls "${FR_ETC}/sites-enabled/tls"

mkdir -p "${FR_ETC}/certs"
cp "$CERTS_PATH/freeradius/"*.pem "${FR_ETC}/certs/"

sed "s/-RNAME-/${realm_name//./\\.}/g" "${PROJECT_PATH}/configs/freeradius/proxy.conf" > "${FR_ETC}/proxy.conf"
install -m 0644 "${PROJECT_PATH}/configs/freeradius/clients.conf" "${FR_ETC}/clients.conf"

sed -e "s/-RSQLUSER-/${db_user}/g" \
    -e "s/-RSQLPASS-/${db_password}/g" \
    -e "s/-RSQLHOST-/${db_host}/g" \
    "${PROJECT_PATH}/configs/freeradius/mods-available/sql" > "${FR_ETC}/mods-available/sql"
install -m 0644 "${PROJECT_PATH}/configs/freeradius/mods-available/eap" "${FR_ETC}/mods-available/eap"
ln -sf ../mods-available/sql "${FR_ETC}/mods-enabled/sql"
ln -sf ../mods-available/eap "${FR_ETC}/mods-enabled/eap"

chown -R freerad:freerad "${FR_ETC}/certs" "${FR_ETC}/sites-available/tls" "${FR_ETC}/mods-available/sql" "${FR_ETC}/mods-available/eap"
chmod 600 "${FR_ETC}/certs/"*.pem
chmod 600 "${FR_ETC}/sites-available/tls" "${FR_ETC}/mods-available/sql"

systemctl enable --now freeradius
systemctl restart freeradius

echo "Reminder: Make sure UDP/TCP ports 11812, 11813 (local NAS/AP clients) and 2083 (RadSec federation) are open on your firewall (on your cloud provider if applicable), refer to the documentation for more details"
echo "Verify with: systemctl status radsecproxy freeradius postgresql"
