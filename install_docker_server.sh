#!/bin/bash

# Define your timezone
timezone=GMT-7

# Define game version
version=1.7.3

# Target game zip to be download and extracted
DIR_WORK=/
DIR_GAME_LOCATION=$DIR_WORK/home # VERY IMPORTANT! this location can be different depends on your gameServer.zip structure.
gameFolder="pw"
gameDownloadUrl="https://drive.usercontent.google.com/download?id=1UebfhrwJIWfP5cZvdra1tNWVZb8Is9PE&export=download&authuser=0&confirm=t&uuid=10bc2449-8417-4b1d-8157-347fd1803c4f&at=AN_67v2QMLcZgDJuqkGLolMqHBg9:1728696167922"

# Define database configuration
dbHost=localhost
dbUser=admin
dbPassword=admin
dbName=pw
sqlScript=pwa.sql

# Define website configuration
pwAdminUsername="admin"
pwAdminRawPw="admin"
pwAdminEmail="admin@gmail.com"

currentSQLDate=$(date +'%F %T');
logfile="/setup.log"

# Define bash functions
function log(){
    local message=$1
    echo "$message" | tee -a "$logfile"
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
    apt install -y sudo
    apt install -y dialog apt-utils > /dev/null 2>&1
    apt install -y mc nano wget curl sed bash grep dpkg net-tools ufw > /dev/null 2>&1
    # Are these necessary
    # apt install -y libstdc++5:i386 gcc-multilib zlib1g:i386 zlib1g libxml2:i386 libstdc++6:i386 > /dev/null 2>&1
    apt install -y p7zip-full > /dev/null 2>&1

    # TODO: hình như cần mở firewall:
    #sudo ufw allow 29000/tcp
    #sudo ufw status hoặc iptables -A INPUT -p tcp --dport 29000 -j ACCEPT
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

    # TODO: nên cài tomcat vào opt/tomcat. Thay vì đang để chung 1 đống với game như hiện tại.
    # Tomcat 7.0.108. 
    # wget https://archive.apache.org/dist/tomcat/tomcat-7/v7.0.108/bin/apache-tomcat-7.0.108.tar.gz -P /tmp
    # sudo tar xf /tmp/apache-tomcat-7.0.108.tar.gz -C /opt/tomcat

    # java version "1.7.0_80". apt-get install openjdk-8-jdk
    # apt-get install openjdk-8-jdk

    # Override info in file /home/server: DB connection; [pwadmin] web tool location; and other info.
    sed -i "/^# Last Updated:/c\# Last Updated: $(date +'%Y/%m/%d')" "$DIR_GAME_LOCATION/server"
    sed -i "/^# Require:/c\# Require: Perfect World server v$version" "$DIR_GAME_LOCATION/server"
    sed -i "/^ServerDir=/c\ServerDir=$DIR_GAME_LOCATION" "$DIR_GAME_LOCATION/server"
    sed -i "/^USR=/c\USR=$dbUser" "$DIR_GAME_LOCATION/server"
    sed -i "/^PASSWD=/c\PASSWD=$dbPassword" "$DIR_GAME_LOCATION/server"
    sed -i "/^DB=/c\DB=$dbName" "$DIR_GAME_LOCATION/server"
    sed -i "/^pwAdmin_dir=/c\pwAdmin_dir=$DIR_GAME_LOCATION/pwadmin/bin" "$DIR_GAME_LOCATION/server"
    #sed -i "/^DIR_TOMCAT_BIN=/c\DIR_TOMCAT_BIN=$DIR_GAME_LOCATION/pwadmin/bin" "$DIR_GAME_LOCATION/server"


    # Override info in file /home/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp: DB connection; game location; MD5 of iweb password.
    pwAdminEncodedPw="$(printf "$pwAdminRawPw" | md5sum | sed 's/ .*$//')"
    sed -i "/String db_host = /c\String db_host = \"$dbHost\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String db_user = /c\String db_user = \"$dbUser\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String db_password = /c\String db_password = \"$dbPassword\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String db_database = /c\String db_database = \"$dbName\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String iweb_password = /c\String iweb_password = \"$pwAdminEncodedPw\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String iweb_password = /c\String iweb_password = \"$pwAdminEncodedPw\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"
    sed -i "/String pw_server_path = /c\String pw_server_path = \"$DIR_GAME_LOCATION/\";" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/WEB-INF/.pwadminconf.jsp"

    # Override info in file /home/pwadmin/webapps/pwadmin/addons/Top Players - Manual Refresh/index.jsp: DB connection.
    sed -i "/connection = DriverManager.getConnection(/c\connection = DriverManager.getConnection(\"jdbc:mysql://$dbHost:3306/$dbName?useUnicode=true&characterEncoding=utf8\", \"$dbUser\", \"$db_password\");" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/addons/Top Players - Manual Refresh/index.jsp"

    # Grant permission 777 to the whole game location.
    chmod 777 $DIR_GAME_LOCATION

}

function translateIwebMapNamesIntoVietnamese() {

    sed -i '1i <%@page contentType="text/html; charset=UTF-8" %>' "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp" #to display UTF-8

    sed -i "s/City of Abominations/Minh Thú Thành/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Secret Passage/Anh Hùng Trủng/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Firecrag Grotto/Hỏa Nham Động Huyệt/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Den of Rabid Wolves/Cuồng Lang Sào Huyệt/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Cave of the Vicious/Xà Hạt Động/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Hall of Deception/Thanh Y Trủng/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Gate of Delirium/U Minh Cư/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Secret Frostcover Grounds/Lí Sương Bí Cảnh/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Valley of Disaster/Thiên Kiếp Cốc/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Forest Ruins/Tùng Lâm Di Tích/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Cave of Sadistic Glee/Quỷ Vực Huyễn Cảnh/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Wraithgate/Oán Linh Chi Môn/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Hallucinatory Trench/Bí Bảo Quật/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Eden/Tiên Huyễn Thiên/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Brimstone Pit/Ma Huyễn Thiên/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Temple of the Dragon/Long Cung/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Nightscream Island/Dạ Khốc Đảo/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Snake Isle/Vạn Xà Đảo/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Lothranis/Tiên giới/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Momaganon/Ma giới/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Seat of Torment/Thiên Giới Luyện Ngục/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Abaddon/Ma Vực Đào Nguyên/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Warsong City/Chiến Ca Chi Thành/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Palace of Nirvana/Luân Hồi Điện/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Lunar Glade/Thần Nguyệt Cốc/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Valley of Reciprocity/Thần Vô Cốc/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Frostcover City/Phúc Sương Thành/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Twilight Temple/Hoàng Hôn Thánh Điện/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Cube of Fate/Vận Mệnh Ma Phương/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Chrono City/Thiên Lệ Chi Thành/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Perfect Chapel/Khung cảnh Hôn Lễ/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Guild Base/Phụ bản Bang Phái/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Morai/Bồng Lai Huyễn Cảnh/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Phoenix Valley/Phượng Minh Cốc/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Endless Universe/Vô Định Trụ/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Blighted Chamer/Thần Độc Chi Gian/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Endless Universe/Vô ĐỊnh Trụ-mô thức cấp cao/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Wargod Gulch/Chiến Thần Cốc/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Five Emperors/Ngũ Đế Chi Đô/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Nation War 2/Quốc Chiến-Cô Đảo Đoạt Kì/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Nation Wa TOWER/Quốc Chiến-Thủy Tinh Tranh Đoạt/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Nation War CRYSTAL/Quốc Chiến-Đoạn Kiều Đối Trì/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Sunset Valley/Lạc Nhật Cốc/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Shutter Palace/Bất Xá Đường/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Dragon Hidden Den/Long Ẩn Quật/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Realm of Reflection/Linh Đàn Huyễn Cảnh/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/startpoint/Linh Độ Đinh Châu/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Origination/Khung Thế Giới/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Primal World/Nhân Giới/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Flowsilver Palace/Lưu Ngân Cung/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Undercurrent Hall/Phục Ba Đường/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Mortal Realm/Mô thức Câu chuyện Nhân Giới/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/LightSail Cave/Bồng Minh Động/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Cube of Fate (2)/Vận Mệnh Ma Phương (2)/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/dragon counqest/Thiện Long Cốc/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/heavenfall temple/Tru Thiên Phù Đồ Tháp 1/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/heavenfall temple/Tru Thiên Phù Đồ Tháp 2/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/heavenfall temple/Tru Thiên Phù Đồ Tháp 3/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/heavenfall temple/Tru Thiên Phù Đồ Tháp 4/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Uncharted Paradise/Huyễn Hải Kì Đàm/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Thurs Fights Cross/Thurs Fights Cross/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Western Steppes/Đại Lục Hoàn Mĩ - Tây Lục/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Homestead, Beyond the Clouds/Lăng Vân Giới 1/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Homestead, Beyond the Clouds/Lăng Vân Giới 2/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Homestead, Beyond the Clouds/Lăng Vân Giới 3/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Homestead, Beyond the Clouds/Lăng Vân Giới 4/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Grape Valley, Grape Valley/Grape Valley/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Nemesis Gaunntlet, Museum/Linh Lung Cục/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Dawnlight Halls, Palace of the Dawn (DR 1)/Thự Quang Điện (DR 1)/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Mirage Lake, Mirage Lake/Huyễn Cảnh Thận Hồ/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Rosesand Ruins, Desert Ruins/Côi Mạc Tàn Viên/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Nightmare Woods, Forest Ruins/Yểm Lâm Phế Khư/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Advisors Sanctum, Palace of the Dawn (DR 2)/Thự Quang Điện (DR 2)/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Wonderland, Adventure Kingdom (Park)/Kì Lạc Mạo Hiểm Vương Quốc/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/The Indestructible City/Mô thức câu chuyện Tây Lục/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Phoenix Sanctum, Hall of Fame/Phoenix Sanctum, Hall of Fame/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Town of Arrivals, Battlefield - Dusk Outpost/Ước chiến Liên server - Long Chiến Chi Dã/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Icebound Underworld, Ice Hell (LA)/Băng Vọng Địa Ngục/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Doosan Station, Arena of the Gods/Doosan Station, Arena of the Gods/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Alt TT Revisited, Twilight Palace/Alt TT Revisited, Twilight Palace/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Spring Pass, Peach Abode (Mentoring)/Spring Pass, Peach Abode (Mentoring)/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Abode of Dreams/Abode of Dreams/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/White Wolf Pass/White Wolf Pass/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Imperial Battle/Imperial Battle/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Northern Lands/Northern Lands/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Altar of the Virgin/Altar of the Virgin/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Imperial Battle/Imperial Battle/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Northern Lands/Northern Lands/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Full Moon Pavilion/Full Moon Pavilion/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Abode of Changes/Abode of Changes/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/quicksand maze/quicksand maze/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/quicksand maze/quicksand maze/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Territory War T-3 PvP/Đấu trường T-3 PvP/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Territory War T-3 PvE/Đấu trường T-3 PvE/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Territory War T-2 PvP/Đấu trường T-2 PvP/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Territory War T-2 PvE/Đấu trường T-2 PvE/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Territory War T-1 PvP/Đấu trường T-1 PvP/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Territory War T-1 PvE/Đấu trường T-1 PvE/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Etherblade Arena/Đấu trường Kiếm Tiên Thành/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Lost Arena/Đấu trường Vạn Hóa Thành/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Plume Arena/Đấu trường Tích Vũ Thành/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Archosaur Arenas/Đấu trường Tổ Long Thành/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Quicksand Maze (Sandstorm Mirage)/Huyễn Sa Thận Cảnh/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Quicksand Maze (Mirage of the wandering sands)/Mê Sa Huyễn Cảnh/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"
    sed -i "s/Tomb of Whispers/Tomb of Whispers/g" "$DIR_GAME_LOCATION/pwadmin/webapps/pwadmin/serverctrl.jsp"

    # Có nhiều map mình không tìm được tên tiếng Việt. Ai biết, xin chỉ giùm nhé.
}

function setupWebTools() {

    setupRegisterPhp
    translateIwebMapNamesIntoVietnamese
    setupIwebJava

    # Other tools
}

function prepareStartAndStopScript(){

    # TODO: file /home/server hình như không work.

    # download start/stop script
    wget -O /start https://raw.githubusercontent.com/hoangnguyent/pwWebTools/refs/heads/master/start
    wget -O /stop https://raw.githubusercontent.com/hoangnguyent/pwWebTools/refs/heads/master/stop

    # Override path in 'start' file
    sed -i "/^#PW_PATH=/root#PW_PATH=/root/home" "/start"

}

function setupGameServer(){

    # Update file /etc/hosts, firewall
    

    # Override config in /home/authd/authd.conf
    sed -i 's#mtrace				=	/home/authd/mtrace.authd#mtrace				=	'"$DIR_GAME_LOCATION"'/home/authd/mtrace.authd#g' "$DIR_GAME_LOCATION/authd/authd.conf"

    # Override config in /home/gamed/gs.conf
    sed -i 's#Root				= /root/pwserver/gamed/config#Root				=	'"$DIR_GAME_LOCATION"'/gamed/config#g' "$DIR_GAME_LOCATION/gamed/gs.conf"

    # Override config in /home/gamedbd/gamesys.conf
    sed -i 's#homedir			= /home/gamedbd/dbhome#homedir			=	'"$DIR_GAME_LOCATION"'/gamedbd/dbhome#g' "$DIR_GAME_LOCATION/gamedbd/gamesys.conf"
    sed -i 's#backupdir		=	/home/gamedbd/backup#backupdir		=	'"$DIR_GAME_LOCATION"'/gamedbd/backup#g' "$DIR_GAME_LOCATION/gamedbd/gamesys.conf"
    sed -i 's#homedir			=	/home/gamedbd/dbhomewdb#homedir			=	'"$DIR_GAME_LOCATION"'/home/gamedbd/dbhomewdb#g' "$DIR_GAME_LOCATION/gamedbd/gamesys.conf"

    # Override config in /home/uniquenamed/gamesys.conf
    sed -i 's#homedir			=	/root/pwserver/uniquenamed/uname#homedir			=	'"$DIR_GAME_LOCATION"'/uniquenamed/uname#g' "$DIR_GAME_LOCATION/uniquenamed/gamesys.conf"
    sed -i 's#backupdir		=	/root/pwserver/uniquenamed/uname#backupdir		=	'"$DIR_GAME_LOCATION"'/uniquenamed/uname#g' "$DIR_GAME_LOCATION/uniquenamed/gamesys.conf"
    sed -i 's#backupdir		=	/root/pwserver/uniquenamed/unamewdbbackup#backupdir		=	backupdir		=	'"$DIR_GAME_LOCATION"'/uniquenamed/unamewdbbackup#g' "$DIR_GAME_LOCATION/uniquenamed/gamesys.conf"

    # Override config in home/logservice/logservice.conf
    sed -i 's#fd_err			=	/home/logs/world2.err#fd_err			=	'"$DIR_GAME_LOCATION"'/logs/world2.err#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"
    sed -i 's#fd_log			=	/home/logs/world2.log#fd_log			=	'"$DIR_GAME_LOCATION"'/logs/world2.log#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"
    sed -i 's#fd_formatlog	=	/home/logs/world2.formatlog#fd_formatlog	=	'"$DIR_GAME_LOCATION"'/logs/world2.formatlog#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"
    sed -i 's#fd_trace		=	/home/logs/world2.trace#fd_trace		=	'"$DIR_GAME_LOCATION"'/logs/world2.trace#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"
    sed -i 's#fd_chat			=	/home/logs/world2.chat#fd_chat			=	'"$DIR_GAME_LOCATION"'/logs/world2.chat#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"
    sed -i 's#fd_cash			=	/home/logs/world2.cash#fd_cash			=	'"$DIR_GAME_LOCATION"'/logs/world2.cash#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"
    sed -i 's#fd_statinfom	=	/home/logs/statinfom#fd_statinfom	=	'"$DIR_GAME_LOCATION"'/logs/statinfom#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"
    sed -i 's#fd_statinfoh	=	/home/logs/statinfoh#fd_statinfoh	=	'"$DIR_GAME_LOCATION"'/logs/statinfoh#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"
    sed -i 's#fd_statinfod	=	/home/logs/statinfod#fd_statinfod	=	'"$DIR_GAME_LOCATION"'/logs/statinfod#g' "$DIR_GAME_LOCATION/logservice/logservice.conf"

    # Override /home/chmod.sh
    echo -e 'echo "wirte the chmod 777 to '"$DIR_GAME_LOCATION"'/*"
sleep 3
chmod 777 -R '"$DIR_GAME_LOCATION"'/*
echo "Done.."' > "$DIR_GAME_LOCATION/chmod.sh"

    # Find table.xml in the working folder, and then copy it to /etc
    find $DIR_WORK -type f -name "table.xml" -exec cp -f {} "/etc" \;

    # Override config in table.xml
    sed -i "/^<connection name=\"auth0\" poolsize=\"3\" url=\"jdbc:mysql/c\<connection name=\"auth0\" poolsize=\"3\" url=\"jdbc:mysql://$dbHost:3306/$dbName?useUnicode=true&amp;characterEncoding=ascii&amp;jdbcCompliantTruncation=false\" username=\"$dbUser\" password=\"$dbPassword\"/>" "/etc/table.xml"

    # TODO: hãy kiểm tra trong bản 141 các file/folder sau, có gì?
    cp -R "$DIR_GAME_LOCATION"/update/etc/* /etc/
    cp -R "$DIR_GAME_LOCATION"/update/lib/*.* /lib/
    #cp -R $DIR_GAME_LOCATION/update/lib64/*.* /lib64/
    cp -R "$DIR_GAME_LOCATION"/update/opt/* /opt/

    chmod 777 "$DIR_WORK"/etc/authd.conf
    chmod 777 "$DIR_WORK"/etc/crontab
    chmod 777 "$DIR_WORK"/etc/gmopgen.xml
    chmod 777 "$DIR_WORK"/etc/GMserver.conf
    chmod 777 "$DIR_WORK"/etc/hosts
    chmod 777 "$DIR_WORK"/etc/iweb.conf
    chmod 777 "$DIR_WORK"/etc/motd.tail
    chmod 777 "$DIR_WORK"/etc/table_thevisad.xml

    # Sync files into folder /gamed/config. This should be done manually.
    # elements.data
    # gshop.data
    # gshop1.data
    # gshop2.data
    # gshopsev.data
    # gshopsev1.data
    # gshopsev2.data
    # tasks.data

    # TODO: load default map gs01, is61, is69
}

function cleanUp(){
    echo
}

function main(){
    log "Script START."
    log "Each step requires several minutes so be patient..."
    trap finallyExit EXIT

    log "Step 1: Install the required ubuntu packages and i386 libs."
    installSeverPackages

    log "Step 2: Install the development related packages (apache2, mariaDB, java)."
    installDevPackages
    switchTimezone

    log "Step 3: Download Perfect World Server."
    #downloadGameServer

    log "Step 4: Extract the Perfect World Server."
    #extractGameServer

    log "Step 5: Setup the database."
    setupDb
    enableToConnectDbFromOutsideContainer

    log "Step 6: Setup the web tools."
    setupWebTools

    log "Step 7: Setup the Perfect World Server."
    setupGameServer
    prepareStartAndStopScript

    log "Step 8: Clean up."
    cleanUp

    log "#######################################################################################"
    log "The Perfect World ${version} game server has been completed. Run [./start] to start it."
    log "#######################################################################################"
}

# Execute
main