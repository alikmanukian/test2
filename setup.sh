#!/bin/bash

SHARED_FOLDER="shared"
APP_FOLDER="${SHARED_FOLDER}/data/app"
APP_ENV_FILE="${APP_FOLDER}/.env"
PULL=${1:-"pull"}
BUILD_TYPE="$2"
#git@github.com:alikmanukian/test2.git

# Determine OS and set sed in-place extension accordingly
sed_extension=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS requires an empty string as an argument for in-place edits without backup
    sed_extension="''"
fi

# ---------------------------------------------------
# Helper functions
# ---------------------------------------------------
trim() {
    echo $(echo "$1" | sed "s/^\\(['\"]\\)\\(.*\\)\\1$/\\2/")
}

# fetch env value from container:
# example: echo $(envInContainer "encryption-nginx" "DB_PASSWORD" "/var/www/html/.env")
envInContainer() {
    local CONTAINER=$1
    local VALUE=$2
    local env_file_path=$3
    echo $(trim $(docker exec "$CONTAINER" grep "$VALUE" "$env_file_path" | cut -d '=' -f2))
}

# fetch env value from encryption container
# example: echo $(envInEncryption "DB_PASSWORD")
envInEncryption() {
    local VALUE=$1
    echo $(envInContainer "encryption-nginx" "$VALUE" "/var/www/html/.env")
}

# promt user for input
# example with default value: echo $(prompt "Enter Application URL (Ex: https://google.com)" "https://google.com")
# example when value is required: echo $(prompt "Enter Application URL (Ex: https://google.com)")
prompt() {
    read -p "$1 → " USER_INPUT
    if [ -z "$USER_INPUT" ] && [ -z "$2" ]; then
        echo $(prompt "$1")
    else
        echo ${USER_INPUT:-$2}
    fi
}

# prompt for boolean value
# example: echo $(prompt_boolean "Do you want to use 2 factor authentication ([Y]/n)" "y")
prompt_boolean() {
    local string=$(prompt "$1" "$2")
    local value=$(echo "$string" | tr '[:upper:]' '[:lower:]') # get lowercase value

    if [ "$value" == "y" ] || [ "$value" == "yes" ]; then
        echo "true"
    else
        echo "false"
    fi
}

# prompt for multiple values
# example: echo $(variants "Choose database connection" "mysql|pgsql|sqlite" "mysql")
variants() {
    local string=$(prompt "$1 [$2]" "$3")
    local allowed_values="$2"
    # Convert the list of allowed values into an array
    IFS='|' read -r -a allowed_array <<< "$allowed_values"
    # Flag to indicate if the string is found in the allowed values
    local found=0
    # Iterate through the array to check if the string is an allowed value
    for value in "${allowed_array[@]}"; do
        if [[ "$string" == "$value" ]]; then
            found=1
            break
        fi
    done

    if [[ $found -eq 0 ]]; then
        string=$(variants "$1" "$2" "$3")
    fi

    echo "$string"
}

# prompt for email with validation
validEmail() {
    local value=$(prompt "$1")

    # Regular expression for email validation
    local email_regex="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"

    if [[ ! $value =~ $email_regex ]]; then
        value=$(validEmail "$1")
    fi

    echo "$value"
}

validUrl() {
    local value=$(prompt "$1" "$2")

    # Regular expression for email validation
    local url_regex="^(http|https):\/\/[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(\/.*)?$"

    if [ $value != "http://localhost" ] && [ $value != "https://localhost" ] && [[ ! $value =~ $url_regex ]]; then
        value=$(validUrl "$1" "$2")
    fi

    echo "$value"
}

# generate app key
generateAppKey() {
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 32)
    echo base64:$(echo -n "$random_string" | base64)
}

# Function to update or add environment variable values in a .env file
# Usage: update_env_var VAR_NAME NEW_VALUE FILE_PATH
# Example usage:
# update_env_var "APP_RF_FULL_URL" "https://new-url.com" ".env"
# update_env_var "APP_KEY" "newkeyvalue" ".env"
update_env_var() {
    local var_name="$1"
    local new_value="$2"
    local file_path="$3"

    # Wrap the new value in double quotes and escape inner double quotes
    local final_value="\"$(echo "$new_value" | sed 's/"/\\"/g')\""

    # Use awk to robustly search and replace or append the variable
    awk -v var="$var_name" -v val="$final_value" -F "=" 'BEGIN{OFS=FS} $1 == var {$2=val; found=1} {print} END{if(!found) print var"="val}' "$file_path" > tmp.$$ && mv tmp.$$ "$file_path"
}

# Check if a command exists
command_exists() {
	command -v "$@" > /dev/null 2>&1
}

# ---------------------------------------------------
# Actions
# ---------------------------------------------------
ensure_docker_installed() {
    if ! command_exists docker; then
        echo "Installing Docker ..."
        curl -fsSL https://get.docker.com | sudo sh -
        sudo gpasswd -a $(whoami) docker && sudo reboot
        exit 0
    fi
}

ensure_docker_compose_installed() {
    if ! command_exists docker-compose; then
        echo "Installing Docker Compose ..."
        sudo curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
    fi
}

ask_for_resetting_env_file() {
    if [ -f .env ]; then
        DELETE_ENV=$(prompt_boolean "You already have .env file. Do you want to reset it ([Y]/n)?" "y")
        if [ "$DELETE_ENV" == "true" ]; then
            rm .env

            # ask for deleting existing database
            if [ -f "$SHARED_FOLDER/data/mysql/mysql" ]; then
                KEEP_EXISTING_DB=$(prompt_boolean "You already have installed local db. Do you want to keep it ([Y]/n)?" "y")

                if [ "$KEEP_EXISTING_DB" == "false" ]; then
                    sudo rm -rf "$SHARED_FOLDER/data/mysql"
                fi
            fi
        fi
    fi
}

prepare_env_file() {
    if [ ! -f .env ]; then
        echo "Please provide the following details to setup the project:"

        APP_KEY=$(generateAppKey)
        echo "APP_KEY=$APP_KEY"
        APP_URL=$(validUrl "Application URL (Ex: https://google.com)")
        REPO_PULL_TOKEN=$(prompt "API token to pull encryption repository")
        REPO_AUTO_UPDATE=$(prompt_boolean "Do you want to update encryption project manually ([Y]/n)?" "y")
        if [ "$REPO_AUTO_UPDATE" == "true" ]; then
            REPO_AUTO_UPDATE="false"
        else
            REPO_AUTO_UPDATE="true"
        fi
        SUPERUSER_EMAIL=$(validEmail "Superuser email")
        OTP_ENABLED=$(prompt_boolean "Do you want to use 2 factor authentication ([Y]/n)?" "y")
        APP_RF_FULL_URL=$(validUrl "Enter Referral factory API URL (Ex: https://referral-factory.com). Skip this if you are a developer in \"Referral Factory\"." "https://referral-factory.com")
        DISABLE_NGINX_PROXY=$(prompt_boolean "Do you want to disable the NGINX proxying for Kubernetes environments (y/[N])?" "n")
        USE_EXTERNAL_DB=$(prompt_boolean "Do you want to use external database (y/[N])?" "n")

        if [ "$USE_EXTERNAL_DB" == "true" ]; then
            DB_CONNECTION=$(variants "Choose database connection" "mysql|pgsql|sqlite")

            if [ "$DB_CONNECTION" != "sqlite" ]; then
                DB_DATABASE=$(prompt "Enter database name")
                DB_HOST=$(prompt "Enter database host")
                DB_PORT=$(prompt "Enter database port")
                DB_USERNAME=$(prompt "Enter database user name")
            fi
        fi

        DB_PASSWORD=$(prompt "Choose database password")

        # write .env file
        echo "APP_URL=$APP_URL" >> .env
        echo "APP_KEY=$APP_KEY" >> .env
        echo "REPO_PULL_TOKEN=$REPO_PULL_TOKEN" >> .env
        echo "REPO_AUTO_UPDATE=$REPO_AUTO_UPDATE" >> .env
        echo "SUPERUSER_EMAIL=$SUPERUSER_EMAIL" >> .env
        echo "OTP_ENABLED=$OTP_ENABLED" >> .env
        echo "DISABLE_NGINX_PROXY=$DISABLE_NGINX_PROXY" >> .env
        echo "APP_RF_FULL_URL=$APP_RF_FULL_URL" >> .env
        echo "DB_PASSWORD=$DB_PASSWORD" >> .env

        if [ "$USE_EXTERNAL_DB" == "true" ]; then
            echo "USE_EXTERNAL_DB=$USE_EXTERNAL_DB" >> .env
            echo "DB_CONNECTION=$DB_CONNECTION" >> .env
            echo "DB_DATABASE=$DB_DATABASE" >> .env
            if [ "$DB_CONNECTION" != "sqlite" ]; then
                echo "DB_HOST=$DB_HOST" >> .env
                echo "DB_PORT=$DB_PORT" >> .env
                echo "DB_USERNAME=$DB_USERNAME" >> .env
            fi
        fi
    fi

    source .env
}

setup_encryption_app() {
    # prepare shared folder
    mkdir -p $SHARED_FOLDER/data/{mysql,redis,app}

    # prepare project
    if [ -n "$REPO_PULL_TOKEN" ]; then

        if [ ! -z "$(find "$APP_FOLDER" -maxdepth 0 -type d -empty)" ]; then
            set -e # exit from script on error on pull

            echo "Cloning project..."
            # clone project if shared/app is empty
            git clone "https://x-token-auth:$REPO_PULL_TOKEN@bitbucket.org/referral-factory/encryption.git" "$APP_FOLDER/."

            set +e # disable exit on error
        fi

        # copy .env file for app
        cp $APP_FOLDER/.env.example $APP_ENV_FILE

        # replace values in .env file
        update_env_var "APP_RF_FULL_URL" "$APP_RF_FULL_URL" $APP_ENV_FILE
        update_env_var "REPO_AUTO_UPDATE" "$REPO_AUTO_UPDATE" $APP_ENV_FILE
        update_env_var "OTP_ENABLED" "$OTP_ENABLED" $APP_ENV_FILE
        update_env_var "APP_URL" "$APP_URL" $APP_ENV_FILE
        update_env_var "APP_KEY" "$APP_KEY" $APP_ENV_FILE
        update_env_var "DB_PASSWORD" "$DB_PASSWORD" $APP_ENV_FILE
        if [ "$USE_EXTERNAL_DB" == "true" ]; then
            update_env_var "DB_CONNECTION" "$DB_CONNECTION" $APP_ENV_FILE
            update_env_var "DB_DATABASE" "$DB_DATABASE" $APP_ENV_FILE
            if [ "$DB_CONNECTION" != "sqlite" ]; then
                update_env_var "DB_HOST" "$DB_HOST" $APP_ENV_FILE
                update_env_var "DB_PORT" "$DB_PORT" $APP_ENV_FILE
                update_env_var "DB_USERNAME" "$DB_USERNAME" $APP_ENV_FILE
            fi
        fi
        update_env_var "MAIL_FROM_ADDRESS" "$SUPERUSER_EMAIL" $APP_ENV_FILE
    fi
}

setup_containers() {
    set -e

    # 6. build pull service images
    if [ "$PULL" == "pull" ]; then
        docker-compose pull
    else
        docker-compose build $BUILD_TYPE
    fi

    # replace nginx server_name
    # DOMAIN=$(echo "$APP_URL" | sed -e 's/^http:\/\///' -e 's/^https:\/\///' -e 's/^\/\///')

    # run new containers
    docker-compose down
    if [ "$USE_EXTERNAL_DB" == "true" ]; then
        docker-compose up -d nginx php-fpm laravel-horizon redis
    else
        docker-compose up -d nginx php-fpm laravel-horizon redis mysql
    fi

    echo "Wait for 20 seconds to start the containers..."
    sleep 20

    # migrate, build and update app
    docker-compose exec php-fpm composer install
    docker-compose exec php-fpm php artisan app:update
}

download_additional_files() {
    curl -o docker-compose.yml https://raw.githubusercontent.com/alikmanukian/test2/main/docker-compose.yml
    mkdir -p shared/nginx/sites
    curl -o shared/nginx/sites/default.conf https://raw.githubusercontent.com/alikmanukian/test2/main/shared/nginx/sites/default.conf
    mkdir -p shared/supervisord.d
    curl -o shared/supervisord.d/laravel-worker.conf https://raw.githubusercontent.com/alikmanukian/test2/main/supervisord.d/laravel-worker.conf
}

# ---------------------------------------------------------
# Main script starts here
# ---------------------------------------------------------

ensure_docker_installed
ensure_docker_compose_installed
ask_for_resetting_env_file
prepare_env_file
download_additional_files
setup_encryption_app
setup_containers
