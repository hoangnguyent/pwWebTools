#!/bin/bash
# ------------------ Config -------------------------
#define your timezone
timezone=GMT-7

# define game version
version=1.7.3

# target game zip to be download and extracted
DIR_WORK=/root
DIR_GAME_LOCATION=$DIR_WORK/home # Depend on your gameServer.zip, this location can be different.
gameFolder="pw"
gameDownloadUrl="https://drive.usercontent.google.com/download?id=1UebfhrwJIWfP5cZvdra1tNWVZb8Is9PE&export=download&authuser=0&confirm=t&uuid=10bc2449-8417-4b1d-8157-347fd1803c4f&at=AN_67v2QMLcZgDJuqkGLolMqHBg9:1728696167922"

# define database configuration
dbHost=localhost
dbUser=admin
dbPassword=admin
dbName=pw
sqlScript=pwa.sql

# define website configuration
pwAdminUsername="pwadmin"
pwAdminRawPw="pwadmin"
pwAdminEmail="pwadmin@gmail.com"

currentSQLDate=$(date +'%F %T');

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

    dpkg --add-architecture i386
    apt update
    apt install -y dialog apt-utils > /dev/null 2>&1
    apt install -y mc nano wget curl sed bash grep dpkg net-tools cron > /dev/null 2>&1
    # Does these necessary
    # apt install -y libstdc++5:i386 gcc-multilib zlib1g:i386 zlib1g libxml2:i386 libstdc++6:i386 > /dev/null 2>&1
    apt install -y p7zip-full > /dev/null 2>&1
}

function installDevPackages(){

    apt install -y apache2 > /dev/null 2>&1
    apt install -y default-jre > /dev/null 2>&1
    apt install -y mariadb-server > /dev/null 2>&1
}

function downloadGameServer(){

    chmod 777 -R $DIR_WORK
    wget -c $gameDownloadUrl -O $DIR_WORK/${gameFolder}.7z
}

function extractGameServer(){

    7z x -aoa $DIR_WORK/${gameFolder}.7z -sccutf-8 -scsutf-8 -o$DIR_WORK
    chmod 777 -R $DIR_WORK
    rm -f $DIR_WORK/${gameFolder}.7z
}

function setupGameServer(){

    # Edit file /etc/hosts to map addresses
    echo "127.0.0.1	gm_server
127.0.0.1	PW-Server
127.0.0.1	aumanager
127.0.0.1	manager
127.0.0.1	link1
127.0.0.1	game1
127.0.0.1	game2
127.0.0.1	delivery
127.0.0.1	database
127.0.0.1	backup
127.0.0.1	auth
127.0.0.1	audb
127.0.0.1	gmserver
127.0.0.1	LOCAL0
127.0.0.1	LogServer
127.0.0.1	AUDATA" > /etc/hosts

    # Find recursively the table.xml working folder, and copy it to /etc
    find $DIR_WORK -type f -name "table.xml" -exec cp -f {} "/etc" \;

    # Override config in table.xml
    sed -i "/^<connection name=\"auth0\" poolsize=\"3\" url=\"jdbc:mysql/c\<connection name=\"auth0\" poolsize=\"3\" url=\"jdbc:mysql://$dbHost:3306/$dbName?useUnicode=true&amp;characterEncoding=ascii&amp;jdbcCompliantTruncation=false\" username=\"$dbUser\" password=\"$dbPassword\"/>" "/etc/table.xml"

    cp -R "$DIR_GAME_LOCATION"/update/etc/* /etc/
    cp -R "$DIR_GAME_LOCATION"/update/lib/*.* /lib/
    #cp -R $DIR_GAME_LOCATION/update/lib64/*.* /lib64/
    cp -R "$DIR_GAME_LOCATION"/update/opt/* /opt/

    chmod 777 "$DIR_WORK"/etc/authd.conf
    #chmod 777 "$DIR_WORK"/etc/crontab
    chmod 777 "$DIR_WORK"/etc/gmopgen.xml
    chmod 777 "$DIR_WORK"/etc/GMserver.conf
    chmod 777 "$DIR_WORK"/etc/hosts
    chmod 777 "$DIR_WORK"/etc/iweb.conf
    chmod 777 "$DIR_WORK"/etc/motd.tail
    chmod 777 "$DIR_WORK"/etc/table_thevisad.xml

}

function setupDb() {

    wget -c https://raw.githubusercontent.com/hoangnguyent/pwWebTools/refs/heads/master/pwa.sql -O "$DIR_WORK/$sqlScript"

    service mariadb start

    # Grant DB permission.
    mariadb -u"root" -p"123456" <<EOF
DROP USER IF EXISTS '$dbUser'@'$dbHost';
CREATE USER '$dbUser'@'$dbHost' IDENTIFIED BY '$dbPassword';
GRANT ALL PRIVILEGES ON *.* TO '$dbUser'@'$dbHost';
DROP USER IF EXISTS '$dbUser'@'%';
CREATE USER '$dbUser'@'%' IDENTIFIED BY '$dbPassword';
GRANT ALL PRIVILEGES ON *.* TO '$dbUser'@'%';
FLUSH PRIVILEGES;
EOF

    service mariadb restart

    mariadb -u"$dbUser" -p"$dbPassword" <<EOF
DROP DATABASE IF EXISTS $dbName;
CREATE DATABASE $dbName CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
EOF

    mariadb -u"$dbUser" -p"$dbPassword" pw < "$DIR_WORK/$sqlScript"
    rm "$DIR_WORK/$sqlScript"

    pwAdminEncodedPw="$(printf "$pwAdminRawPw" | md5sum | sed 's/ .*$//')"

    mariadb -u"$dbUser" -p"$dbPassword" pw <<EOF
CALL adduser("$pwAdminUsername", "$pwAdminEncodedPw", "0", "0", "super admin", "0.0.0.0", "$pwAdminEmail", "0", "0", "0", "0", "0", "0", "0", "$currentSQLDate", " ", "$pwAdminEncodedPw");
EOF

    lastInsertedUserId=$(mariadb -u"$dbUser" -p"$dbPassword" pw -se "SELECT ID from users WHERE name=\"$pwAdminUsername\"");
    echo "last inserted id: $lastInsertedUserId";
    if [[ "$lastInsertedUserId" =~ ^[0-9]+$ ]]; then
        mariadb -u"$dbUser" -p"$dbPassword" pw <<EOF
CALL addGM("$lastInsertedUserId", "1");
INSERT INTO usecashnow (userid, zoneid, sn, aid, point, cash, status, creatime) VALUES ("$lastInsertedUserId", "1", "0", "1", "0", "100000", "1", "$currentSQLDate") ON DUPLICATE KEY UPDATE cash = cash + 100000;
EOF
    fi

    # Create additional tables
    mariadb -u"$dbUser" -p"$dbPassword" pw <<EOF
CREATE TABLE IF NOT EXISTS point(uid int, zoneid VARCHAR(255), PRIMARY KEY(uid) );
CREATE TABLE IF NOT EXISTS online(uid int, zoneid VARCHAR(255), PRIMARY KEY(uid) );
EOF

}

function enableToConnectDbFromOutsideContainer(){

    # Allow all IP addresses outside the container.
    echo -e "[mysqld]
log_error = /var/log/mysql/error.log
bind-address = 0.0.0.0" >> /etc/mysql/my.cnf
}

function setupRegisterPhp(){

    websitePath=/var/www/html

    # Install PHP packages
    DEBIAN_FRONTEND=noninteractive apt install -y libapache2-mod-php
    apt install -y php php-mysql php-curl mcrypt

    # Donwload register.php
    wget -c https://raw.githubusercontent.com/hoangnguyent/pwWebTools/refs/heads/master/register.php -O "$websitePath/register.php"
    chmod 777 -R "$websitePath"

    # Override config in the register.php
    sed -i "/^\$config = \[\];/c\$config = ['host' => '$dbHost', 'user' => '$dbUser', 'pass' => '$dbPassword', 'name' => '$dbName', 'gold' => '1000000000',];" "$websitePath/register.php"

    service apache2 restart
}

function setupIwebJava(){

    # Override info in file /home/server: DB connection; [pwadmin] web tool location; and other info.
    sed -i "/^# Last Updated:/c\# Last Updated: $(date +'%Y/%m/%d')" "$DIR_GAME_LOCATION/server"
    sed -i "/^# Require:/c\# Require: Perfect World server v$version" "$DIR_GAME_LOCATION/server"
    sed -i "/^ServerDir=/c\ServerDir=$DIR_GAME_LOCATION" "$DIR_GAME_LOCATION/server"
    sed -i "/^USR=/c\USR=$dbUser" "$DIR_GAME_LOCATION/server"
    sed -i "/^PASSWD=/c\PASSWD=$dbPassword" "$DIR_GAME_LOCATION/server"
    sed -i "/^DB=/c\DB=$dbName" "$DIR_GAME_LOCATION/server"
    sed -i "/^pwAdmin_dir=/c\pwAdmin_dir=$DIR_GAME_LOCATION/pwadmin/bin" "$DIR_GAME_LOCATION/server"


    # Override info in file /home/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp: DB connection; game location; MD5 of iweb password.
    pwAdminEncodedPw="$(printf "$pwAdminRawPw" | md5sum | sed 's/ .*$//')"
    sed -i "/String db_host = /c\String db_host = \"$dbHost\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String db_user = /c\String db_user = \"$dbUser\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String db_password = /c\String db_password = \"$dbPassword\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String db_database = /c\String db_database = \"$dbName\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String iweb_password = /c\String iweb_password = \"$pwAdminEncodedPw\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String iweb_password = /c\String iweb_password = \"$pwAdminEncodedPw\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String pw_server_path = /c\String pw_server_path = \"$DIR_GAME_LOCATION/\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"

    # Grant permission 777 to the whole game location.
    chmod 777 $DIR_GAME_LOCATION

    # Start iweb with an instance name must be 'pwAdmin'. This name is hard code in file "/home/server"
    $DIR_GAME_LOCATION/server pwAdmin start
}

function setupWebTools() {

    setupRegisterPhp
    setupIwebJava

    # Other tools
}

function generateStartAndStopScript(){
    echo -e "service mariadb start" >> /start
    echo -e "service apache2 start" >> /start
    echo -e "$DIR_GAME_LOCATION/server pwAdmin start" >> /start

    echo -e "$DIR_GAME_LOCATION/server pwAdmin stop" >> /stop
    echo -e "service apache2 stop" >> /stop
    echo -e "service mariadb stop" >> /stop

}

function main(){
    log "Script START."
    log "Each step requires several minutes so be patient..."
    trap finallyExit EXIT

    log "Step 1: Install the required ubuntu packages and i386 libs."
    #installSeverPackages

    log "Step 2: Install the development related packages (apache2, mariaDB, java)."
    #installDevPackages
    #switchTimezone

    log "Step 3: Download Perfect World Server."
    #downloadGameServer

    log "Step 4: Extract the Perfect World Server."
    #extractGameServer

    log "Step 5: Setup the Perfect World Server."
    #setupGameServer

    log "Step 6: Setup the database."
    #setupDb
    #enableToConnectDbFromOutsideContainer

    log "Step 7: Setup the web tools."
    setupWebTools

    log "Step 8: Generate start and stop script."
    generateStartAndStopScript

    log "#######################################################################################"
    log "The Perfect World ${version} game server has been completed. Run [./start] to start it."
    log "#######################################################################################"
}

# Execute
main