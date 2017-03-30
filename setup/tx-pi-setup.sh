#!/bin/bash

# preparaion
# copy 2017-03-02-raspbian-jessie-lite.img to sd card
# set interfaces for eth0
# touch /boot/ssh
# -> boot pi
# raspi-config
#    hostname tx-pi
#    enable ssh
#    expand filesystem
#    disable wait for network

# TODO
# - adjust font size
# - add screen calibration tool
# - adjust timezone
# - fix web upload
# - fix wlan/eth
#   - don't wait for eth0
#   - start wpa_supplicant (through interfaces entry)
#   - control regular dhcpcd
#   - check dhcp settings in network app
# much much more ...

# to be run on plain jessie-lite
echo "Setting up TX-PI on jessie lite ..."

GITBASE="https://raw.githubusercontent.com/ftCommunity/ftcommunity-TXT/master/"
GITROOT=$GITBASE"board/fischertechnik/TXT/rootfs"
SVNBASE="https://github.com/ftCommunity/ftcommunity-TXT.git/trunk/"
SVNROOT=$SVNBASE"board/fischertechnik/TXT/rootfs"
TSVNBASE="https://github.com/harbaum/TouchUI.git/trunk/"

# Things you may do:
# set a root password
# enable root ssh login
# apt-get install emacs-nox

if [ "$HOSTNAME" != tx-pi ]; then
    echo "Make sure your R-Pi has been setup completely and is named tx-pi"
    exit -1
fi

# ----------------------- package installation ---------------------

apt-get update

# X11
apt-get -y install --no-install-recommends xserver-xorg xinit xserver-xorg-video-fbdev xserver-xorg-legacy
# python and pyqt
apt-get -y install --no-install-recommends python3-pyqt4 python3 python3-pip
# misc tools
apt-get -y install i2c-tools lighttpd git subversion ntpdate

# some additionl python stuff
pip3 install semantic_version
pip3 install websockets

# ---------------------- display setup ----------------------
# check if waveshare driver is installed
if [ ! -f /boot/overlays/waveshare32b-overlay.dtb ]; then
    echo "============================================================"
    echo "============== SCREEN DRIVER INSTALLATION =================="
    echo "============================================================"
    echo "= YOU NEED TO RESTART THIS SCRIPT ONCE THE PI HAS REBOOTED ="
    echo "============================================================"
    cd
    wget -N http://www.waveshare.com/w/upload/7/74/LCD-show-170309.tar.gz
    tar xvfz LCD-show-170309.tar.gz
    cd LCD-show
    ./LCD32-show
    # the pi will reboot
fi

# ----------------------- user setup ---------------------
# create ftc user
groupadd ftc
useradd -g ftc -m ftc
usermod -a -G video ftc
usermod -a -G tty ftc

echo "ftc:ftc" | chpasswd

# special ftc permissions
cd /etc/sudoers.d
wget -N $GITROOT/etc/sudoers.d/shutdown
chmod 0440 /etc/sudoers.d/shutdown
wget -N $GITROOT/etc/sudoers.d/bluetooth
chmod 0440 /etc/sudoers.d/bluetooth
cat <<EOF > /etc/sudoers.d/wifi
## Permissions for ftc access to programs required
## for wifi setup
ftc     ALL = NOPASSWD: /sbin/wpa_cli
EOF
chmod 0440 /etc/sudoers.d/wifi

# ----------------------- display setup ---------------------

# disable fbturbo/enable ordinary fbdev
rm -f /usr/share/X11/xorg.conf.d/99-fbturbo.conf
cat <<EOF > /usr/share/X11/xorg.conf.d/99-fbdev.conf
Section "Device"
        Identifier      "FBDEV"
        Driver          "fbdev"
        Option          "fbdev" "/dev/fb1"

        Option          "SwapbuffersWait" "true"
EndSection
EOF

# X server/launcher start
cat <<EOF > /etc/systemd/system/launcher.service
[Unit]
Description=Start Launcher

[Service]
ExecStart=/bin/su ftc -c "PYTHONPATH=/opt/ftc startx /opt/ftc/launcher.py"
ExecStop=/usr/bin/killall xinit

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# systemctl start launcher
systemctl enable launcher

# allow any user to start xs
sed -i 's,^\(allowed_users=\).*,\1'\anybody',' /etc/X11/Xwrapper.config

# rotate display
sed -i 's,^\(dtoverlay=waveshare32b.rotate=\).*,\1'\0',' /boot/config.txt

# rotate touchscreen 
cat <<EOF > /usr/share/X11/xorg.conf.d/99-calibration.conf
Section "InputClass"
Identifier "calibration"
MatchProduct "ADS7846 Touchscreen"
Option "Calibration" "200 3900 200 3900"
Option "SwapAxes" "0"
EndSection
EOF

# hide cursor and disable screensaver
cat <<EOF > /etc/X11/xinit/xserverrc
#!/bin/sh
exec /usr/bin/X -s 0 dpms -nocursor -nolisten tcp "\$@"
EOF

# allow user to modify locale and network settings
touch /etc/locale
chmod 666 /etc/locale
cat <<EOF > /etc/network/interfaces
# /etc/network/interfaces
# generated by network.py

auto lo
auto wlan0
auto eth0

iface eth0 inet dhcp
iface wlan0 inet dhcp
        wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
iface lo inet loopback
EOF
chmod 666 /etc/network/interfaces

# get /opt/ftc
echo "Populating /opt/ftc ..."
cd /opt
rm -rf ftc
svn export $SVNROOT"/opt/ftc"
cd /opt/ftc
# just fetch a copy of ftrobopy to make some programs happy
wget -N https://raw.githubusercontent.com/ftrobopy/ftrobopy/master/ftrobopy.py

# remove usedless ftgui
rm -rf /opt/ftc/apps/system/ftgui

# add power tool from touchui
cd /opt/ftc/apps/system
svn export $TSVNBASE"/touchui/apps/system/power"

# adjust lighttpd config
sed -i 's,^\(server.document-root *=\).*,\1'\ \"/var/www\"',' /etc/lighttpd/lighttpd.conf
sed -i 's,^\(server.username *=\).*,\1'\ \"ftc\"',' /etc/lighttpd/lighttpd.conf
sed -i 's,^\(server.groupname *=\).*,\1'\ \"ftc\"',' /etc/lighttpd/lighttpd.conf

# enable ssi
if ! grep -q mod_ssi /etc/lighttpd/lighttpd.conf; then
cat <<EOF >> /etc/lighttpd/lighttpd.conf

server.modules += ( "mod_ssi" )
ssi.extension = ( ".html" )
EOF
fi

# enable cgi
if ! grep -q mod_cgi /etc/lighttpd/lighttpd.conf; then
cat <<EOF >> /etc/lighttpd/lighttpd.conf
server.modules += ( "mod_cgi" )

\$HTTP["url"] =~ "^/cgi-bin/" {
       cgi.assign = ( "" => "" )
}

cgi.assign      = (
       ".py"  => "/usr/bin/python3"
)
EOF
fi
    
# fetch www pages
echo "Populating /var/www ..."
cd /var
rm -rf www
svn export $SVNROOT"/var/www"

# adjust file ownership for changed www user name
chown -R ftc:ftc /var/www/*
chown -R ftc:ftc /var/log/lighttpd
chown -R ftc:ftc /var/run/lighttpd

#mkdir /opt/ftc/apps/user
#chown -R ftc:ftc /opt/ftc/apps/user

mkdir /home/ftc/apps
chown -R ftc:ftc /home/ftc/apps

/etc/init.d/lighttpd restart

echo "rebooting ..."

sync
reboot
