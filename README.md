# Raspberry Pi USB Pet Camera

A small, **local-only** camera system for Raspberry Pi OS Lite (64-bit) and a USB UVC webcam (tested conceptually with an Anker PowerConf C300). Features:

- Live MJPEG video in a web dashboard
- Rolling **30- and 60-second replay** (temporary files in RAM)
- Motion-triggered MP4 recordings with a recent-events list
- Automatic startup with systemd and daily event cleanup
- **No cloud account, remote-access service, or router port forwarding required**

> **Security:** The webcam stream (`127.0.0.1:8080`) and dashboard (`127.0.0.1:8090`) bind to the Pi's loopback interface by default. Use SSH port forwarding to view it. Optional LAN access using Nginx is shown below; Basic Auth over plain HTTP is **not encrypted** and is suitable only for trusted home networks. No remote internet access is configured by this project.

## How it works

```text
USB UVC webcam
      |
      v
uStreamer 127.0.0.1:8080  (only process opening the webcam)
      |         |           |
      |         |           +--> Flask/Waitress dashboard 127.0.0.1:8090
      |         +--------------> Motion --> saved events (MP4)
      +------------------------> FFmpeg --> rotating 2-second segments in /run/petcam/replay
```

## Requirements

- Raspberry Pi 4 (or similar), Raspberry Pi OS Lite 64-bit
- UVC USB webcam with MJPEG at 1280×720 / 15 FPS (or adjust the generated capture service)
- Working SSH and local network connectivity
- `sudo` permissions and enough disk space for motion clips
- Motion **4.x** configuration (newer major versions may require config changes)

**Important for an existing camera setup:** This repository installs `petcam-*` services and does not migrate or disable existing custom webcam services. Do not run it on a Pi already hosting a working camera stack without reviewing service names, ports, directories, and capture conflicts. Stop competing camera applications before installing.

## Install on a fresh Pi

1. Connect the webcam and check its capture device and supported formats:

   ```bash
   sudo apt update && sudo apt install -y v4l-utils
   v4l2-ctl --list-devices
   v4l2-ctl -d /dev/video0 --list-formats-ext
   ```

2. Clone this repository to the Pi, or copy `install.sh` and `dashboard.py` into the same directory.
3. Make sure no other app is accessing the camera or using ports `8080` or `8090`.
4. Run as your **normal Linux account**, not root:

   ```bash
   bash install.sh
   ```

   Optional capture-device and motion-detection settings for installation:

   ```bash
   CAMERA_DEVICE=/dev/video2 MOTION_THRESHOLD=500 MOTION_MIN_FRAMES=5 MOTION_EVENT_GAP=30 bash install.sh
   ```

5. Check services:

   ```bash
   systemctl status petcam-capture petcam-motion petcam-buffer petcam-dashboard --no-pager
   curl -I http://127.0.0.1:8090/
   ls -lh /run/petcam/replay/
   ls -lh ~/petcam-data/events/
   ```

6. From another computer, create an SSH tunnel (replace placeholders with **your own** account and local Pi address):

   ```bash
   ssh -N -L 8090:127.0.0.1:8090 <PI_USERNAME>@<PI_LAN_ADDRESS>
   ```

   Open **http://127.0.0.1:8090** in the browser on that same computer.

## Optional: password-protected access on a trusted LAN

This is **not needed** for SSH-tunnel access. To access the dashboard from other local devices without a tunnel, install Nginx on the Pi:

```bash
sudo apt install -y nginx apache2-utils
sudo htpasswd -c /etc/nginx/.petcam-users camerauser
sudo nano /etc/nginx/sites-available/petcam
```

Paste the following Nginx site configuration:

```nginx
server {
    listen 8091;
    server_name _;

    auth_basic "Pet Camera";
    auth_basic_user_file /etc/nginx/.petcam-users;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_set_header Host $host;
    }
}
```

Enable the site and reload:

```bash
sudo ln -s /etc/nginx/sites-available/petcam /etc/nginx/sites-enabled/petcam
sudo nginx -t && sudo systemctl reload nginx
```

Visit `http://<PI_LAN_ADDRESS>:8091` from a device on the same trusted local network. Choose a unique, strong password. **HTTP Basic Auth does not encrypt credentials or video**; do not use public or guest Wi-Fi, port-forward 8091, or expose it to the internet. For encrypted remote access, add an independently reviewed VPN/HTTPS solution later; none is included here. The Nginx `listen 8091` directive binds on available network interfaces, so consider a host firewall or a LAN-IP-specific listen directive if your network is not fully trusted.

## Motion configuration

The installer creates `/etc/petcam-motion.conf` with these initial values:

```ini
threshold 500
minimum_motion_frames 5
event_gap 30
```

At 10 FPS, five consecutive positive frames represent about 0.5 seconds, **not** a strict two-second movement requirement. `event_gap 30` groups activity until 30 seconds of inactivity; it is **not** a guaranteed 30-second cooldown between clip starts. Tune to suit your enclosure and lighting. A stricter duration filter would require separate event logic.

Apply edits with:

```bash
sudo nano /etc/petcam-motion.conf
sudo systemctl restart petcam-motion
```

## Storage and limits

- Motion clips: `~/petcam-data/events/` (on the Pi's normal storage by default)
- Replay ring: `/run/petcam/replay/` (volatile RAM-backed files, about 70 seconds total)
- Cleanup: `/etc/cron.daily/petcam-clean` removes older MP4 event files (roughly 48+ hours; not a disk-space quota)
- Live video: 1280×720 MJPEG / 15 FPS by default
- Replay: 640×360 H.264 / 10 FPS, with a few seconds of lag behind live video
- **No audio, clip download button, external-drive setup, AI animal detection, or phone notifications in this version**

Motion clips written continuously can wear out microSD storage. A USB SSD and a disk-space cap are recommended if recording volume is high.

## Troubleshooting

```bash
# Check camera modes
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --list-formats-ext

# Check if the webcam is held open
sudo fuser -v /dev/video0

# Check logs
journalctl -u petcam-capture -u petcam-motion -u petcam-buffer -u petcam-dashboard -n 100 --no-pager

# Check binding of dashboard and webcam
sudo ss -ltnp | grep -E ':8080|:8090|:8091'

# Stop the stack
sudo systemctl stop petcam-dashboard petcam-buffer petcam-motion petcam-capture
```

This is a small hobby project, not audited security software. Keep OS packages current and avoid publishing recordings, logs, access tokens, or private configuration files in the Git repository.
