#!/opt/wz_mini/bin/bash
### BEGIN INIT INFO
# Provides:
# Short-Description: OpenRouter AI Camera
# Description:       Capture JPEG frames or short video clips at a configurable
#                    interval and analyze them with the OpenRouter vision API.
#                    Results are written to /opt/wz_mini/www/ai/ (served by
#                    httpd) and optionally pushed to Home Assistant via the HA
#                    REST API.
#
# Supports two capture modes (OPENROUTER_MODE):
#   image  — capture a single JPEG via 'cmd jpeg 0 -n' and send as image_url
#   video  — record a short MP4 clip via ffmpeg and send as video_url
#
# OpenRouter API references:
#   https://openrouter.ai/docs/guides/overview/multimodal/image-understanding
#   https://openrouter.ai/docs/guides/overview/multimodal/videos
### END INIT INFO

. /opt/wz_mini/wz_mini.conf
. /opt/wz_mini/etc/rc.common

AI_LOG=/opt/wz_mini/log/ai_camera
AI_DIR=/opt/wz_mini/www/ai
AI_SNAPSHOT="$AI_DIR/snapshot.jpg"
AI_CLIP="/tmp/ai_clip.mp4"
AI_RESULT="$AI_DIR/latest.json"

case "$1" in
start)

echo "#####$(basename "$0")#####"

if [[ "$AI_CAMERA_ENABLED" != "true" ]]; then
echo "AI camera disabled"
exit 0
fi

if [[ -z "$OPENROUTER_API_KEY" ]]; then
echo "OPENROUTER_API_KEY is not set — AI camera disabled"
exit 1
fi

# Apply defaults for optional config keys
: "${OPENROUTER_MODEL:=google/gemini-flash-1.5-8b}"
: "${OPENROUTER_PROMPT:=Describe what you see in this image.}"
: "${OPENROUTER_INTERVAL:=30}"
: "${OPENROUTER_MODE:=image}"
: "${OPENROUTER_VIDEO_SECONDS:=5}"

mkdir -p "$AI_DIR"
rotate_log "$AI_LOG"

# Wait for network and iCamera before starting the loop
wait_for_wlan_ip "$(basename "$0")"
wait_for_icamera

(
while true; do

if [[ "$OPENROUTER_MODE" == "video" ]]; then
# ---- VIDEO MODE ----
# Record a short clip from the hi-res V4L2 loopback device.
# The clip is base64-encoded and sent as a video_url payload.
# Per the OpenRouter docs the text prompt must come first in
# the content array.
rm -f "$AI_CLIP"
/opt/wz_mini/bin/ffmpeg -loglevel error \
-f v4l2 -i /dev/video1 \
-t "$OPENROUTER_VIDEO_SECONDS" \
-c:v libx264 -preset ultrafast -movflags +faststart \
-y "$AI_CLIP" 2>/dev/null

if [ ! -s "$AI_CLIP" ]; then
echo "$(date): Failed to capture video clip" >> "$AI_LOG.log"
sleep "$OPENROUTER_INTERVAL"
continue
fi

# Save a thumbnail for the web UI (first frame)
/opt/wz_mini/bin/ffmpeg -loglevel error \
-i "$AI_CLIP" -vframes 1 -y "$AI_SNAPSHOT" 2>/dev/null

clip_b64=$(busybox base64 < "$AI_CLIP" | tr -d '\n')

# Text first, then video — per OpenRouter docs
payload=$(printf \
'{"model":"%s","messages":[{"role":"user","content":[{"type":"text","text":"%s"},{"type":"video_url","video_url":{"url":"data:video/mp4;base64,%s"}}]}]}' \
"$OPENROUTER_MODEL" \
"$OPENROUTER_PROMPT" \
"$clip_b64")

else
# ---- IMAGE MODE (default) ----
# Capture a single JPEG frame via the cmd utility.
# Text first, then image — per OpenRouter docs.
/opt/wz_mini/bin/cmd jpeg 0 -n > "$AI_SNAPSHOT" 2>/dev/null

if [ ! -s "$AI_SNAPSHOT" ]; then
echo "$(date): Failed to capture frame" >> "$AI_LOG.log"
sleep "$OPENROUTER_INTERVAL"
continue
fi

img_b64=$(busybox base64 < "$AI_SNAPSHOT" | tr -d '\n')

# Text first, then image — per OpenRouter docs
payload=$(printf \
'{"model":"%s","messages":[{"role":"user","content":[{"type":"text","text":"%s"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,%s"}}]}]}' \
"$OPENROUTER_MODEL" \
"$OPENROUTER_PROMPT" \
"$img_b64")
fi

# POST to OpenRouter
response=$(/opt/wz_mini/bin/curl -s \
--cacert /opt/wz_mini/etc/ssl/ca-bundle.crt \
-H "Authorization: Bearer $OPENROUTER_API_KEY" \
-H "Content-Type: application/json" \
-X POST "https://openrouter.ai/api/v1/chat/completions" \
-d "$payload")

timestamp=$(date)
echo "$timestamp: $response" >> "$AI_LOG.log"

# Write result file for the web UI and HA REST sensor polling.
# The full OpenRouter response JSON is embedded under "response".
printf '{"timestamp":"%s","model":"%s","mode":"%s","response":%s}\n' \
"$timestamp" \
"$OPENROUTER_MODEL" \
"$OPENROUTER_MODE" \
"$response" > "$AI_RESULT"

# Optionally push to Home Assistant via REST API
if [[ "$HA_ENABLED" == "true" ]] && [[ -n "$HA_URL" ]] && [[ -n "$HA_TOKEN" ]]; then

# Extract the content text; truncate to 255 chars (HA state limit).
# NOTE: This regex extraction is best-effort; content containing
# escaped quotes may be truncated. Install jq for robust parsing.
ai_text=$(echo "$response" \
| grep -o '"content":"[^"]*"' | head -1 \
| sed 's/^"content":"//; s/"$//' \
| cut -c1-255)

# Escape backslashes, then double-quotes for JSON safety
ai_text_safe=$(echo "$ai_text" | sed 's/\\/\\\\/g; s/"/\\"/g')

ha_payload=$(printf \
'{"state":"%s","attributes":{"timestamp":"%s","model":"%s","mode":"%s","friendly_name":"AI Camera"}}' \
"$ai_text_safe" \
"$timestamp" \
"$OPENROUTER_MODEL" \
"$OPENROUTER_MODE")

/opt/wz_mini/bin/curl -s \
--cacert /opt/wz_mini/etc/ssl/ca-bundle.crt \
-H "Authorization: Bearer $HA_TOKEN" \
-H "Content-Type: application/json" \
-X POST "$HA_URL/api/states/$HA_ENTITY_ID" \
-d "$ha_payload" > /dev/null 2>&1
fi

sleep "$OPENROUTER_INTERVAL"

done
) &
;;
*)
echo "Usage: $0 {start}"
exit 1
;;
esac
