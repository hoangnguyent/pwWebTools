#!/bin/bash
# ------------------ Config -------------------------
webSiteType='PHP'; # 'PHP' | 'java' | 'nodejs'
currentSQLDate=$(date +'%F %T');

#define your timezone
timezone=GMT-7

# define game version
version=1.7.3

# target game zip to be download and extracted
gameFolder="pw"
gameDownloadUrl="https://drive.usercontent.google.com/download?id=1UebfhrwJIWfP5cZvdra1tNWVZb8Is9PE&export=download&authuser=0&confirm=t&uuid=10bc2449-8417-4b1d-8157-347fd1803c4f&at=AN_67v2QMLcZgDJuqkGLolMqHBg9:1728696167922"


# define database configuration
dbHost=localhost
dbUser=admin
dbPassword=admin
dbName=pw
sqlScript=pwa.sql
serverRoot=/root

# define website configuration
pwAdminUsername="pwadmin"
pwAdminRawPw="pwadmin"
pwAdminRawSalt="${pwAdminUsername}${pwAdminRawPw}"
pwAdminEmail="pwadmin@gmail.com"

# define bash functions
function log(){
    local message=$1
    echo "$message" | tee -a "/install.log"
    # example of use: log "This is a log message"
}

function finallyExit(){
    log "Script END."
}

function switchTimezone(){
    ln -sf /usr/share/zoneinfo/Etc/$timezone /etc/localtime
}

function installSeverPackages(){
    log "\nStep 1: Install the required ubuntu packages and i386 libs."

    dpkg --add-architecture i386
    apt update
    apt install -y dialog apt-utils > /dev/null 2>&1
    apt install -y mc nano wget curl sed bash grep dpkg net-tools cron > /dev/null 2>&1
    apt install -y libstdc++5:i386 gcc-multilib zlib1g:i386 zlib1g libxml2:i386 libstdc++6:i386 > /dev/null 2>&1
    apt install -y p7zip-full > /dev/null 2>&1
}

function installDevPackages(){
    log "\nStep 2: Install the development related packages (apache2, mariaDB, java)."

    apt install -y apache2 > /dev/null 2>&1
    apt install -y default-jre > /dev/null 2>&1
    apt install -y mariadb-server > /dev/null 2>&1
}

function downloadGameServer(){
    log "\nStep 3: Download Perfect World Server."
    
    chmod 777 -R $serverRoot
    wget -c $gameDownloadUrl -O $serverRoot/${gameFolder}.7z
}

function extractGameServer(){
    log "\nStep 4: Extract the Perfect World Server."
    7z x -aoa $serverRoot/${gameFolder}.7z -sccutf-8 -scsutf-8 -o$serverRoot
    chmod 777 -R $serverRoot
    rm -f $serverRoot/${gameFolder}.7z
}

function setupGameServer(){
    log "\nStep 5: Setup the Perfect World Server."
    sed -r -e "s|PerfectWorldDBName|$dbName|g" -e "s|PerfectWorldDBUsername|$dbUser|g" -e "s|PerfectWorldDBPassword|$dbPassword|g" $serverRoot/authd/build/table.xml > $serverRoot/authd/build/table.new
    mv "$serverRoot/authd/build/table.new" "$serverRoot/authd/build/table.xml"

    cp -R $serverRoot/update/etc/* /etc/
    cp -R $serverRoot/update/lib/*.* /lib/
    #cp -R $serverRoot/update/lib64/*.* /lib64/
    cp -R $serverRoot/update/opt/* /opt/

    chmod 777 /etc/authd.conf
    chmod 777 /etc/crontab
    chmod 777 /etc/gmopgen.xml
    chmod 777 /etc/GMserver.conf
    chmod 777 /etc/hosts
    chmod 777 /etc/iweb.conf
    chmod 777 /etc/motd.tail
    chmod 777 /etc/table_thevisad.xml
}

function setupDb() {
    log "\nStep 6: Setup the database."

    # Find recursively the SQL file by name and copy it to the $serverRoot
    wget -c https://raw.githubusercontent.com/hoangnguyent/pwWebTools/refs/heads/master/pwa.sql -O "$serverRoot/$sqlScript"

    service mariadb start

    # Grant DB permission.
    mariadb -u"root" -p"123456" <<EOF
DROP USER IF EXISTS '$dbUser'@'$dbHost';
CREATE USER '$dbUser'@'$dbHost' IDENTIFIED BY '$dbPassword';
GRANT ALL PRIVILEGES ON *.* TO '$dbUser'@'$dbHost';
DROP USER IF EXISTS '$dbUser'@'%';
CREATE USER '$dbUser'@'%' IDENTIFIED BY '$dbPassword';
GRANT ALL PRIVILEGES ON *.* TO '$dbUser'@'%;
FLUSH PRIVILEGES;
EOF

    service mariadb restart

    mariadb -u"$dbUser" -p"$dbPassword" <<EOF
DROP DATABASE IF EXISTS $dbName;
CREATE DATABASE $dbName CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
EOF

    mariadb -u"$dbUser" -p"$dbPassword" pw < $serverRoot/$sqlScript
    #rm ./$sqlScript

    pwAdminRawSalt="${pwAdminUsername}${pwAdminRawPw}"
    pwAdminPw="$(printf "$pwAdminRawSalt" | md5sum | sed 's/ .*$//')"
    pwAdminPw=0x"$pwAdminPw"

    mariadb -u"$dbUser" -p"$dbPassword" pw <<EOF
call adduser("$pwAdminUsername", $pwAdminPw, "0", "0", "", "0.0.0.0", "$pwAdminEmail", "0", "0", "0", "0", "0", "0", "0", "$currentSQLDate", " ", $pwAdminPw);
EOF

    lastInsertedUserId=$(mariadb -u"$dbUser" -p"$dbPassword" pw -se "SELECT ID from users WHERE name=\"$pwAdminUsername\"");
    echo "last inserted id: $lastInsertedUserId";
    if [[ "$lastInsertedUserId" =~ ^[0-9]+$ ]]; then
        mariadb -u"$dbUser" -p"$dbPassword" pw <<EOF
call addGM("$lastInsertedUserId", "1");
INSERT INTO usecashnow (userid, zoneid, sn, aid, point, cash, status, creatime) VALUES ("$lastInsertedUserId", "1", "0", "1", "0", "100000", "1", "$currentSQLDate") ON DUPLICATE KEY UPDATE cash = cash + 100000;
EOF
    fi

    # Create additional tables
    mariadb -u"$dbUser" -p"$dbPassword" pw <<EOF
create table if not exists point(uid int, zoneid varchar(255), primary key(uid) );
create table if not exists online(uid int, zoneid varchar(255), primary key(uid) );
EOF

}

function enableToConnectDbFromOutsideContainer(){

    # Allow all IP addres outside the contaner.
    echo "\n[mysqld]\nlog_error = /var/log/mysql/error.log\nbind-address = 0.0.0.0" | cat >> /etc/mysql/my.cnf

}

function setupWebTools() {
    log "\nStep 7: Setup the web tools."

    service apache2 start
    if [[ $webSiteType == "PHP" ]]; then

        websitePath=/var/www/html

        # Install PHP packages
        DEBIAN_FRONTEND=noninteractive apt install -y libapache2-mod-php
        apt install -y php php-mysql php-curl mcrypt

        # Install register.php
        wget -c https://raw.githubusercontent.com/hoangnguyent/pwWebTools/refs/heads/master/register.php -O "$websitePath/register.php"

        chmod 777 -R "$websitePath"

        sed -i '/\$config = \[\];/c\$config = [
            "host" => "$dbHost",
            "user" => "$pwAdminUsername",
            "pass" => "$pwAdminRawPw",
            "name" => "$dbName",
            "gold" => "1000000000",
            ];' "$websitePath/register.php"
        
        # Other tools

        service apache2 restart
    fi
}

function main(){
    log "Script START."
    log "Each step requires several minutes so be patient..."
    trap finallyExit EXIT

    #installSeverPackages
    #installDevPackages
    #switchTimezone
    #downloadGameServer
    #extractGameServer
    #setupGameServer
    #setupDb
    #enableToConnectDbFromOutsideContainer
    setupWebTools
    
    log "####################################################################################################"
    log "The Perfect World ${version} game server has been completed. Run $serverRoot/startip.sh to start it."
    log "####################################################################################################"
}

# Execute
main