#!/usr/bin/env bash
set -euo pipefail
if [[ $(id -u) -eq 0 ]]; then echo 'Run this as your normal Pi user, not root. sudo will prompt when required.'; exit 1; fi
U=$(id -un)
CAMERA_DEVICE=${CAMERA_DEVICE:-/dev/video0}
MOTION_THRESHOLD=${MOTION_THRESHOLD:-500}
MOTION_MIN_FRAMES=${MOTION_MIN_FRAMES:-5}
MOTION_EVENT_GAP=${MOTION_EVENT_GAP:-30}
HOME_DIR=$(getent passwd "$U" | cut -d: -f6)
ROOT=$(cd -- "$(dirname -- "$0")" && pwd)
if [[ ! -f "$ROOT/dashboard.py" ]]; then echo 'dashboard.py missing'; exit 1; fi
if [[ ! -e "$CAMERA_DEVICE" ]]; then echo "$CAMERA_DEVICE is missing. Check v4l2-ctl --list-devices."; exit 1; fi
sudo apt-get update
sudo apt-get install -y ustreamer v4l-utils motion ffmpeg python3-flask python3-waitress
# Do not disable the distro motion.service automatically. Stop it explicitly if it is already running.
# Stop other webcam capture services manually before installation.
# This installer does not modify unrelated systemd units.
sudo install -d -o "$U" -g "$U" "$HOME_DIR/petcam-data/events" "$HOME_DIR/petcam-app"
sudo install -m 644 "$ROOT/dashboard.py" "$HOME_DIR/petcam-app/dashboard.py"
sudo chown "$U:$U" "$HOME_DIR/petcam-app/dashboard.py"
sudo tee /etc/systemd/system/petcam-capture.service >/dev/null <<EOF
[Unit]
Description=Pet camera single USB capture via uStreamer
After=network.target
[Service]
Type=simple
User=$U
SupplementaryGroups=video
ExecStart=/usr/bin/ustreamer --device=$CAMERA_DEVICE --host=127.0.0.1 --port=8080 --resolution=1280x720 --format=MJPEG --desired-fps=15
Restart=always
RestartSec=5
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/petcam-motion.conf >/dev/null <<EOF
# Motion 4.x, fed by localhost µStreamer (not direct webcam access)
daemon off
netcam_url http://127.0.0.1:8080/stream
width 640
height 360
framerate 10
threshold $MOTION_THRESHOLD
minimum_motion_frames $MOTION_MIN_FRAMES
noise_tune on
despeckle_filter EedDl
lightswitch_percent 20
event_gap $MOTION_EVENT_GAP
pre_capture 3
post_capture 10
picture_output off
movie_output on
movie_codec mp4
movie_quality 55
movie_max_time 90
movie_filename %Y%m%d-%H%M%S
target_dir $HOME_DIR/petcam-data/events
stream_port 0
webcontrol_port 0
EOF
sudo tee /etc/systemd/system/petcam-motion.service >/dev/null <<EOF
[Unit]
Description=Pet camera motion detection and event clips
After=petcam-capture.service
Requires=petcam-capture.service
[Service]
Type=simple
User=$U
ExecStart=/usr/bin/motion -n -c /etc/petcam-motion.conf
Restart=always
RestartSec=6
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/systemd/system/petcam-buffer.service >/dev/null <<EOF
[Unit]
Description=Pet camera rolling replay segment buffer
After=petcam-capture.service
Requires=petcam-capture.service
[Service]
Type=simple
User=$U
RuntimeDirectory=petcam
RuntimeDirectoryMode=0700
ExecStartPre=/usr/bin/mkdir -p /run/petcam/replay
ExecStart=/usr/bin/ffmpeg -hide_banner -loglevel warning -nostdin -i http://127.0.0.1:8080/stream -vf fps=10,scale=640:360 -an -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p -b:v 800k -maxrate 1200k -bufsize 1600k -g 20 -keyint_min 20 -sc_threshold 0 -f segment -segment_time 2 -segment_wrap 35 -reset_timestamps 1 -segment_format mp4 /run/petcam/replay/seg%%03d.mp4
Restart=always
RestartSec=6
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
# systemd uses %% to encode literal percent in ExecStart; correct to one % in the ffmpeg argument by systemd itself.
sudo tee /etc/systemd/system/petcam-dashboard.service >/dev/null <<EOF
[Unit]
Description=Local pet camera replay and events dashboard
After=petcam-capture.service petcam-buffer.service
Requires=petcam-capture.service
[Service]
Type=simple
User=$U
Environment=PETCAM_EVENTS=$HOME_DIR/petcam-data/events
WorkingDirectory=$HOME_DIR/petcam-app
ExecStart=/usr/bin/python3 $HOME_DIR/petcam-app/dashboard.py
Restart=always
RestartSec=5
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
EOF
sudo tee /etc/cron.daily/petcam-clean >/dev/null <<EOF
#!/bin/sh
find '$HOME_DIR/petcam-data/events' -type f -name '*.mp4' -mtime +1 -delete
EOF
sudo chmod 755 /etc/cron.daily/petcam-clean
sudo systemctl daemon-reload
sudo systemctl enable --now petcam-capture.service
sleep 3
sudo systemctl enable --now petcam-motion.service petcam-buffer.service petcam-dashboard.service
printf '\nServices:\n'
systemctl --no-pager --full status petcam-capture petcam-motion petcam-buffer petcam-dashboard | grep -E '●|Active:' || true
printf '\nLOCAL DASHBOARD CHECK: curl -I http://127.0.0.1:8090/\n'
printf 'For local testing, use SSH port forwarding to localhost:8090 (see README).\n'
printf 'Then visit http://127.0.0.1:8090 in your browser.\n'
printf 'If you previously started ustreamer in another terminal, STOP that instance before using this kit.\n'
