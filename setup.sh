#!/bin/bash

args=("$@")

SERVICES="Wildduck, Zone-MTA, Haraka, Wildduck Webmail"

echo "Setting up $SERVICES"

if [ "$#" -gt "0" ]
  then
    # foo/bar -> bar
    MAILDOMAIN=${args[0]}
    HOSTNAME=${args[1]:-$MAILDOMAIN}
    FULL_SETUP=${args[2]:-false}

    if [ "$HOSTNAME" = "full" ]; then
        FULL_SETUP=$HOSTNAME
        HOSTNAME=$MAILDOMAIN
    fi

    echo -e "DOMAINNAME: $MAILDOMAIN, HOSTNAME: $HOSTNAME, FULL_SETUP: $FULL_SETUP"
  else
    echo -e "You specified ZERO arguments, I will ask you for arguments directly \n"

    read -p "Specify the DOMAIN of your server: " MAILDOMAIN
    read -p "Perfect! The email domain is: $MAILDOMAIN. Do you wish to also specify the hostname? [y/N] " yn

    case $yn in
        [Yy]* ) read -p "Hostname of the machine: " HOSTNAME;;
        [Nn]* ) echo "No hostname provided. Will use domain as hostname"; HOSTNAME=$MAILDOMAIN;;
        * ) echo "No hostname provided. Will use domain as hostname"; HOSTNAME=$MAILDOMAIN;;
    esac

    echo -e "DOMAINNAME: $MAILDOMAIN, HOSTNAME: $HOSTNAME"
fi

if [ ! -e ./config-generated ]; then 
    echo "Copying default configuration into ./config-generated/config-generated"
    mkdir config-generated
    cp -r ./default-config ./config-generated/config-generated
fi

# Docker compose
echo "Copying default docker-compose to ./config-generated"
cp ./docker-compose.yml ./config-generated/docker-compose.yml

# Traefik
echo "Copying Traefik config and replacing default configuration"
cp -r ./dynamic_conf ./config-generated
sed -i "s|\./config/|./config-generated/|g" ./config-generated/docker-compose.yml
sed -i "s|api.HOSTNAME|api.$HOSTNAME|g" ./config-generated/docker-compose.yml
sed -i "s|HOSTNAME|$HOSTNAME|g" ./config-generated/docker-compose.yml

# API exposure configuration
EXPOSE_API=false
read -p "Do you wish to expose the API externally via Traefik (api.$HOSTNAME)? (y/N) " yn

    case $yn in
        [Yy]* ) EXPOSE_API=true;;
        [Nn]* ) EXPOSE_API=false;;
        * ) EXPOSE_API=false;;
    esac

if ! $EXPOSE_API; then
    echo "Removing external API exposure - API will only be accessible internally"
    # Remove all wildduck-api Traefik labels
    sed -i "/traefik.http.routers.wildduck-api/d" ./config-generated/docker-compose.yml
    sed -i "/traefik.http.services.wildduck-api/d" ./config-generated/docker-compose.yml
else
    echo "API will be exposed externally at https://api.$HOSTNAME"
fi

# Certs for traefik
USE_SELF_SIGNED_CERTS=false
read -p "Do you wish to set up self-signed certs for development? (Y/n) " yn

    case $yn in
        [Yy]* ) USE_SELF_SIGNED_CERTS=true;;
        [Nn]* ) USE_SELF_SIGNED_CERTS=false;;
        * ) USE_SELF_SIGNED_CERTS=true;;
    esac

if $USE_SELF_SIGNED_CERTS; then
    echo "Generating self-signed TLS Certs"
    mkdir -p ./config-generated/certs

    openssl genrsa -out ./config-generated/certs/rootCA.key 4096
    openssl req -x509 -new -nodes -key ./config-generated/certs/rootCA.key -sha256 -days 3650 -out ./config-generated/certs/rootCA.pem -subj "/C=US/ST=State/L=City/O=Your Organization/CN=Your CA"
    openssl genrsa -out ./config-generated/certs/$HOSTNAME.key 2048
    openssl req -new -key ./config-generated/certs/$HOSTNAME.key -out ./config-generated/certs/$HOSTNAME.csr -subj "/C=US/ST=State/L=City/O=Your Organization/CN=$HOSTNAME"
    cat > ./config-generated/certs/$HOSTNAME.ext << EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names

[alt_names]
DNS.1 = $HOSTNAME
DNS.2 = *.$HOSTNAME
EOF
    openssl x509 -req -in ./config-generated/certs/$HOSTNAME.csr -CA ./config-generated/certs/rootCA.pem -CAkey ./config-generated/certs/rootCA.key -CAcreateserial -out ./config-generated/certs/$HOSTNAME.crt -days 825 -sha256 -extfile ./config-generated/certs/$HOSTNAME.ext
    mv ./config-generated/certs/$HOSTNAME.crt ./config-generated/certs/$HOSTNAME.pem
    mv ./config-generated/certs/$HOSTNAME.key ./config-generated/certs/$HOSTNAME-key.pem
fi

# Haraka certs settings
# Replace the key line
sed -i "s|./certs/HOSTNAME-key.pem|./certs/$HOSTNAME-key.pem|g" ./config-generated/docker-compose.yml

# Replace the cert line
sed -i "s|./certs/HOSTNAME.pem|./certs/$HOSTNAME.pem|g" ./config-generated/docker-compose.yml

if ! $USE_SELF_SIGNED_CERTS; then
    # use let's encrypt
    sed -i "s|# - \"--certificatesresolvers.letsencrypt.acme.email=ACME_EMAIL\"|- \"--certificatesresolvers.letsencrypt.acme.email=domainadmin@$MAILDOMAIN\"|g" ./config-generated/docker-compose.yml
    sed -i "s|# - \"--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json\"|- \"--certificatesresolvers.letsencrypt.acme.storage=/data/acme.json\"|g" ./config-generated/docker-compose.yml
    sed -i "s|# - \"--certificatesresolvers.letsencrypt.acme.tlschallenge=true\"|- \"--certificatesresolvers.letsencrypt.acme.tlschallenge=true\"|g" ./config-generated/docker-compose.yml

    # Uncomment the traefik.tcp.routers.zonemta.tls.certresolver line
    sed -i "s|# traefik.tcp.routers.zonemta.tls.certresolver: letsencrypt|traefik.tcp.routers.zonemta.tls.certresolver: letsencrypt|g" ./config-generated/docker-compose.yml

    # Uncomment the traefik.tcp.routers.wildduck-pop3s.tls.certresolver line
    sed -i "s|# traefik.tcp.routers.wildduck-pop3s.tls.certresolver: letsencrypt|traefik.tcp.routers.wildduck-pop3s.tls.certresolver: letsencrypt|g" ./config-generated/docker-compose.yml

    # Uncomment the traefik.tcp.routers.wildduck-imaps.tls.certresolver line
    sed -i "s|# traefik.tcp.routers.wildduck-imaps.tls.certresolver: letsencrypt|traefik.tcp.routers.wildduck-imaps.tls.certresolver: letsencrypt|g" ./config-generated/docker-compose.yml

    # Uncomment the traefik.http.routers.wildduck-webmail.tls.certresolver line
    sed -i "s|# traefik.http.routers.wildduck-webmail.tls.certresolver: letsencrypt|traefik.http.routers.wildduck-webmail.tls.certresolver: letsencrypt|g" ./config-generated/docker-compose.yml

    # Uncomment the traefik.http.routers.wildduck-api.tls.certresolver line (only if API is exposed)
    if $EXPOSE_API; then
        sed -i "s|# traefik.http.routers.wildduck-api.tls.certresolver: letsencrypt|traefik.http.routers.wildduck-api.tls.certresolver: letsencrypt|g" ./config-generated/docker-compose.yml
    fi

    # Delete the traefik.tcp.routers.zonemta.tls: true line
    sed -i "/traefik.tcp.routers.zonemta.tls: true/d" ./config-generated/docker-compose.yml

    # Delete the traefik.tcp.routers.wildduck-pop3s.tls: true line
    sed -i "/traefik.tcp.routers.wildduck-pop3s.tls: true/d" ./config-generated/docker-compose.yml

    # Delete the traefik.tcp.routers.wildduck-imaps.tls: true line
    sed -i "/traefik.tcp.routers.wildduck-imaps.tls: true/d" ./config-generated/docker-compose.yml

    # Delete the traefik.http.routers.wildduck-webmail.tls: true line
    sed -i "/traefik.http.routers.wildduck-webmail.tls: true/d" ./config-generated/docker-compose.yml

    # Delete the traefik.http.routers.wildduck-api.tls: true line (only if API is exposed)
    if $EXPOSE_API; then
        sed -i "/traefik.http.routers.wildduck-api.tls: true/d" ./config-generated/docker-compose.yml
    fi

    sed -i "/- \.\/dynamic_conf:\/etc\/traefik\/dynamic_conf:ro/d" ./config-generated/docker-compose.yml

    # Delete the providers.file=true line
    sed -i '/- "--providers.file=true"/d' ./config-generated/docker-compose.yml

    # Delete the providers.file.directory line
    sed -i '/- "--providers.file.directory=\/etc\/traefik\/dynamic_conf"/d' ./config-generated/docker-compose.yml

    # Delete the providers.file.watch line
    sed -i '/- "--providers.file.watch=true"/d' ./config-generated/docker-compose.yml

    # Delete the serversTransport.insecureSkipVerify line
    sed -i '/- "--serversTransport.insecureSkipVerify=true"/d' ./config-generated/docker-compose.yml

    # Delete the serversTransport.rootCAs line
    sed -i '/- "--serversTransport.rootCAs=\/etc\/traefik\/certs\/rootCA.pem"/d' ./config-generated/docker-compose.yml

    # Delete the log.level=DEBUG line
    sed -i '/- "--log.level=DEBUG"/d' ./config-generated/docker-compose.yml

    # Delete the certs line
    sed -i '/- \.\/certs:\/etc\/traefik\/certs.*# Mount your certs directory/d' ./config-generated/docker-compose.yml
fi

echo "Replacing domains in $SERVICES configuration"

# Zone-MTA
sed -i "s/name=\"example.com\"/name=\"$HOSTNAME\"/" ./config-generated/config-generated/zone-mta/pools.toml
sed -i "s/hostname=\"email.example.com\"/hostname=\"$HOSTNAME\"/" ./config-generated/config-generated/zone-mta/plugins/wildduck.toml
sed -i "s/rewriteDomain=\"email.example.com\"/rewriteDomain=\"$MAILDOMAIN\"/" ./config-generated/config-generated/zone-mta/plugins/wildduck.toml

# Load .env file if it exists
if [ -f .env ]; then
    echo "Loading environment variables from .env file"
    set -a
    source .env
    set +a
fi

# Configure nextMTA from environment variables if set
DEFAULT_TOML="./config-generated/config-generated/zone-mta/zones/default.toml"
if [ -n "$NEXTMTA_HOST" ] && [ -n "$NEXTMTA_PORT" ] && [ -n "$NEXTMTA_USER" ] && [ -n "$NEXTMTA_PASS" ]; then
    echo "Configuring nextMTA from environment variables"
    # Uncomment and set host (match commented line with any value)
    sed -i "s|^#host = .*|host = \"$NEXTMTA_HOST\"|" "$DEFAULT_TOML"
    # Uncomment and set port (match commented line with any number)
    sed -i "s|^#port = .*|port = $NEXTMTA_PORT|" "$DEFAULT_TOML"
    # Uncomment the [default.auth] section header
    sed -i "s|^#\[default.auth\]|[default.auth]|" "$DEFAULT_TOML"
    # Uncomment and set user (match commented line with any value)
    sed -i "s|^#user = .*|user = \"$NEXTMTA_USER\"|" "$DEFAULT_TOML"
    # Uncomment and set pass (match commented line with any value)
    sed -i "s|^#pass = .*|pass = \"$NEXTMTA_PASS\"|" "$DEFAULT_TOML"
else
    echo "NextMTA configuration not found in .env file, skipping nextMTA setup"
fi

# Configure external MongoDB from environment variables if set
if [ -n "$MONGO_URL" ]; then
    echo "Configuring external MongoDB from environment variables"
    
    # Escape special characters in MONGO_URL for sed
    MONGO_URL_ESCAPED=$(echo "$MONGO_URL" | sed 's/[[\.*^$()+?{|]/\\&/g')
    
    # Update Wildduck dbs.toml
    WILDDUCK_DBS="./config-generated/config-generated/wildduck/dbs.toml"
    sed -i "s|mongo = \"mongodb://mongo:27017/wildduck\"|mongo = \"$MONGO_URL_ESCAPED\"|" "$WILDDUCK_DBS"
    
    # Update Zone-MTA dbs-production.toml
    ZONEMTA_DBS_PROD="./config-generated/config-generated/zone-mta/dbs-production.toml"
    sed -i "s|mongo = \"mongodb://mongo:27017/wildduck\"|mongo = \"$MONGO_URL_ESCAPED\"|" "$ZONEMTA_DBS_PROD"
    
    # Update Zone-MTA dbs-development.toml (extract database name from URL if needed)
    ZONEMTA_DBS_DEV="./config-generated/config-generated/zone-mta/dbs-development.toml"
    # Extract database name from MONGO_URL (default to wildduck if not specified)
    MONGO_DB_NAME=$(echo "$MONGO_URL" | sed -n 's|.*/\([^?]*\).*|\1|p')
    if [ -z "$MONGO_DB_NAME" ]; then
        MONGO_DB_NAME="wildduck"
    fi
    # Replace the database name in the connection string for development
    MONGO_URL_DEV=$(echo "$MONGO_URL" | sed "s|/[^/]*$|/$MONGO_DB_NAME|")
    MONGO_URL_DEV_ESCAPED=$(echo "$MONGO_URL_DEV" | sed 's/[[\.*^$()+?{|]/\\&/g')
    sed -i "s|mongo = \"mongodb://mongo:27017/zone-mta\"|mongo = \"$MONGO_URL_DEV_ESCAPED\"|" "$ZONEMTA_DBS_DEV"
    
    # Update Haraka wildduck.yaml
    HARAKA_WILDDUCK="./config-generated/config-generated/haraka/wildduck.yaml"
    sed -i "s|url: \"mongodb://mongo:27017/wildduck\"|url: \"$MONGO_URL_ESCAPED\"|" "$HARAKA_WILDDUCK"
    
    echo "External MongoDB configured: $MONGO_URL"
    
    # Remove mongo from depends_on in docker-compose.yml if using external MongoDB
    DOCKER_COMPOSE="./config-generated/docker-compose.yml"
    echo "Removing mongo service dependencies from docker-compose.yml"
    
    # Remove mongo from depends_on lists (keep redis)
    # Handle different indentation levels
    sed -i '/depends_on:/,/^  [a-z]/ { /^[[:space:]]*- mongo$/s/^/#/; }' "$DOCKER_COMPOSE"
    
    # Comment out the mongo service definition
    # Find the mongo service block and comment it out
    awk '
    /^  mongo:/ { in_mongo=1 }
    in_mongo && /^  [a-z]/ && !/^  mongo/ { in_mongo=0 }
    in_mongo { print "#" $0; next }
    { print }
    ' "$DOCKER_COMPOSE" > "$DOCKER_COMPOSE.tmp" && mv "$DOCKER_COMPOSE.tmp" "$DOCKER_COMPOSE"
    
    # Comment out mongo volume
    sed -i 's/^  mongo:$/#  mongo:  # Removed: using external MongoDB/' "$DOCKER_COMPOSE"
    
    echo "MongoDB service and dependencies removed from docker-compose.yml"
    echo "Note: Please review docker-compose.yml and ensure mongo dependencies are properly removed"
else
    echo "MONGO_URL not set in .env file, using default MongoDB container"
fi

# Wildduck
sed -i "s/hostname=\"email.example.com\"/hostname=\"$HOSTNAME\"/" ./config-generated/config-generated/wildduck/imap.toml
sed -i "s/hostname=\"email.example.com\"/hostname=\"$HOSTNAME\"/" ./config-generated/config-generated/wildduck/pop3.toml
sed -i "s/hostname=\"email.example.com\"/hostname=\"$HOSTNAME\"/" ./config-generated/config-generated/wildduck/default.toml
sed -i "s/rpId=\"email.example.com\"/rpId=\"$HOSTNAME\"/" ./config-generated/config-generated/wildduck/default.toml
sed -i "s/emailDomain=\"email.example.com\"/emailDomain=\"$MAILDOMAIN\"/" ./config-generated/config-generated/wildduck/default.toml

echo "Generating secrets and placing them in $SERVICES configuration"

SRS_SECRET=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`
ZONEMTA_SECRET=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`
DKIM_SECRET=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`
HMAC_SECRET=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`

# Use ACCESS_TOKEN from .env if set, otherwise generate a random one
if [ -z "$ACCESS_TOKEN" ]; then
    ACCESS_TOKEN=`head /dev/urandom | tr -dc A-Za-z0-9 | head -c30`
    echo "Generated random ACCESS_TOKEN: $ACCESS_TOKEN"
else
    echo "Using ACCESS_TOKEN from environment"
fi

# Zone-MTA
sed -i "s/secret=\"super secret value\"/secret=\"$ZONEMTA_SECRET\"/" ./config-generated/config-generated/zone-mta/plugins/loop-breaker.toml
sed -i "s/secret=\"secret value\"/secret=\"$SRS_SECRET\"/" ./config-generated/config-generated/zone-mta/plugins/wildduck.toml
sed -i "s/secret=\"super secret key\"/secret=\"$DKIM_SECRET\"/" ./config-generated/config-generated/zone-mta/plugins/wildduck.toml

# Wildduck
sed -i "s/#loopSecret=\"secret value\"/loopSecret=\"$SRS_SECRET\"/" ./config-generated/config-generated/wildduck/sender.toml
sed -i "s/secret=\"super secret key\"/secret=\"$DKIM_SECRET\"/" ./config-generated/config-generated/wildduck/dkim.toml
sed -i "s/accessToken=\"somesecretvalue\"/accessToken=\"$ACCESS_TOKEN\"/" ./config-generated/config-generated/wildduck/api.toml
sed -i "s/secret=\"a secret cat\"/secret=\"$HMAC_SECRET\"/" ./config-generated/config-generated/wildduck/api.toml
sed -i "s/\"domainadmin@example.com\"/\"domainadmin@$MAILDOMAIN\"/" ./config-generated/config-generated/wildduck/acme.toml
sed -i "s/\"https:\/\/wildduck.email\"/\"https:\/\/$MAILDOMAIN\"/" ./config-generated/config-generated/wildduck/acme.toml

# Haraka
sed -i "s/#loopSecret: \"secret value\"/loopSecret: \"$SRS_SECRET\"/" ./config-generated/config-generated/haraka/wildduck.yaml
sed -i "s/secret: \"secret value\"/secret: \"$SRS_SECRET\"/" ./config-generated/config-generated/haraka/wildduck.yaml

# Webmail
sed -i "s|example\.com|$HOSTNAME|g" ./config-generated/config-generated/wildduck-webmail/default.toml
sed -i "s|accessToken=\"\"|accessToken=\"$ACCESS_TOKEN\"|g" ./config-generated/config-generated/wildduck-webmail/default.toml

# Haraka certs from Traefik
if ! $USE_SELF_SIGNED_CERTS; then
    echo "Getting certs for Haraka from Traefik"

    CURRENT_DIR=$(basename "$(pwd)")
    if [ -f "docker-compose.yml" ] && [ "$CURRENT_DIR" = "config-generated" ]; then
        docker compose up traefik -d 
    else
        cd ./config-generated/ 
        docker compose up traefik -d
        cd ../
    fi

    echo "Waiting for container to start..."
    sleep 2 # Just in case
    
    mkdir ./config-generated/certs/
    CERT_FILE="./config-generated/certs/$HOSTNAME.pem"
    KEY_FILE="./config-generated/certs/$HOSTNAME-key.pem"

    CONTAINER_ID=$(docker ps --filter "name=traefik" --format "{{.ID}}")
    docker cp $CONTAINER_ID:/data/acme.json ./acme.json

    # Extract the certificate
    CERT=$(jq -r --arg domain "$HOSTNAME" '.letsencrypt.Certificates[] | select(.domain.main == $domain) | .certificate' acme.json)
    
    # Extract the private key
    KEY=$(jq -r --arg domain "$HOSTNAME" '.letsencrypt.Certificates[] | select(.domain.main == $domain) | .key' acme.json)

    # Decode and save certificate
    echo "$CERT" | base64 -d > "$CERT_FILE"

    # Decode and save private key
    echo "$KEY" | base64 -d > "$KEY_FILE"

    docker stop $CONTAINER_ID

    # Create script to update certificates
    cat > update_certs.sh << 'EOF'
#!/bin/bash

# Import the HOSTNAME variable from the original script environment
HOSTNAME="$HOSTNAME"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACME_PATH="$SCRIPT_DIR/acme.json"
NEW_ACME_PATH="$SCRIPT_DIR/acme.json.new"
CERT_FILE="$SCRIPT_DIR/config-generated/certs/$HOSTNAME.pem"
KEY_FILE="$SCRIPT_DIR/config-generated/certs/$HOSTNAME-key.pem"

# Get container ID for Traefik
CONTAINER_ID=$(docker ps --filter "name=traefik" --format "{{.ID}}")

if [ -z "$CONTAINER_ID" ]; then
    echo "Traefik container not running. Starting it..."
    
    CURRENT_DIR=$(basename "$(pwd)")
    if [ -f "docker-compose.yml" ] && [ "$CURRENT_DIR" = "config-generated" ]; then
        docker compose up traefik -d 
    else
        cd ./config-generated/ 
        docker compose up traefik -d
        cd "$SCRIPT_DIR"
    fi
    
    echo "Waiting for container to start..."
    sleep 2
    CONTAINER_ID=$(docker ps --filter "name=traefik" --format "{{.ID}}")
    
    if [ -z "$CONTAINER_ID" ]; then
        echo "Failed to start Traefik container. Exiting."
        exit 1
    fi
fi

# Copy the acme.json file from Traefik container
docker cp $CONTAINER_ID:/data/acme.json $NEW_ACME_PATH

# Check if acme.json has changed
if [ -f "$ACME_PATH" ] && diff -q "$ACME_PATH" "$NEW_ACME_PATH" >/dev/null; then
    echo "No changes in certificates detected."
    rm "$NEW_ACME_PATH"
    exit 0
fi

# Replace the old acme.json with the new one
mv "$NEW_ACME_PATH" "$ACME_PATH"

echo "Certificate changes detected. Updating certificate files..."

# Extract the certificate
CERT=$(jq -r --arg domain "$HOSTNAME" '.letsencrypt.Certificates[] | select(.domain.main == $domain) | .certificate' $ACME_PATH)

# Extract the private key
KEY=$(jq -r --arg domain "$HOSTNAME" '.letsencrypt.Certificates[] | select(.domain.main == $domain) | .key' $ACME_PATH)

# Check if we actually got the certificate and key
if [ -z "$CERT" ] || [ "$CERT" == "null" ]; then
    echo "Error: Certificate for $HOSTNAME not found!"
    exit 1
fi

if [ -z "$KEY" ] || [ "$KEY" == "null" ]; then
    echo "Error: Key for $HOSTNAME not found!"
    exit 1
fi

# Create directory if it doesn't exist
mkdir -p "$(dirname "$CERT_FILE")"

# Decode and save certificate
echo "$CERT" | base64 -d > "$CERT_FILE"

# Decode and save private key
echo "$KEY" | base64 -d > "$KEY_FILE"

echo "Certificate and key updated successfully at $(date)"

# Don't stop the container if it was already running
EOF
    # Pass the HOSTNAME variable to the script during creation
    sed -i "s/HOSTNAME=\"\$HOSTNAME\"/HOSTNAME=\"$HOSTNAME\"/" update_certs.sh

    # Make the script executable
    chmod +x update_certs.sh

    # Add weekly cron job to check for certificate updates
    CRON_JOB="0 0 * * 0 $(pwd)/update_certs.sh >> $(pwd)/cert_update.log 2>&1"
    (crontab -l 2>/dev/null || echo "") | grep -v "update_certs.sh" | { cat; echo "$CRON_JOB"; } | crontab -

    echo "Weekly certificate update check scheduled for every Sunday at midnight"
    echo "The script will check if Traefik has renewed the certificate and update the files accordingly"
fi

echo "Done!"

if [ "$FULL_SETUP" != "full" ]; then 
    read -p "Do you wish to continue and set up the DNS? [Y/n] " yn

    case $yn in
        [Yy]* ) FULL_SETUP="full";;
        [Nn]* ) echo "$SERVICES setup finished! Exiting..."; exit;;
        * ) FULL_SETUP="full";;
    esac
fi

if [ "$FULL_SETUP" = "full" ]; then 
    source "./setup-scripts/dns_setup.sh"
fi
