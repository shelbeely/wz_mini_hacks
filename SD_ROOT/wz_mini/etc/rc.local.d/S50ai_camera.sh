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
# Supports three capture modes (OPENROUTER_MODE):
#   image  — capture a single JPEG via 'cmd jpeg 0 -n' and send as image_url
#   video  — record a short MP4 clip via ffmpeg and send as video_url
#   agent  — multi-turn conversation loop; the AI may call tools and request
#             follow-up frames before producing a final result
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
AI_ALERT="$AI_DIR/alert.json"

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
: "${OPENROUTER_MAX_TURNS:=4}"
: "${OPENROUTER_SYSTEM_PROMPT:=You are an AI security camera assistant. Analyze the image carefully and decide if any action is needed. To use a tool, output exactly one line in this format: TOOL_CALL:<name>:<argument>. Available tools: alert (write a local alert with a message), ha_trigger (POST to a Home Assistant webhook with a message), notify (POST to a push-notification webhook with a message), capture_again (take a fresh frame for the next turn), record (start a background video clip; argument is duration in seconds). Only call a tool when necessary.}"
: "${OPENROUTER_AGENT_TOOLS:=alert ha_trigger notify capture_again}"
: "${AI_RECORD_DIR:=/tmp/ai_recordings}"
: "${HA_WEBHOOK_URL:=}"
: "${NOTIFY_WEBHOOK_URL:=}"

mkdir -p "$AI_DIR"
rotate_log "$AI_LOG"

# Wait for network and iCamera before starting the loop
wait_for_wlan_ip "$(basename "$0")"
wait_for_icamera

# ---------------------------------------------------------------------------
# Helper functions used by agent mode.
# ---------------------------------------------------------------------------

# json_escape: escape a string for safe embedding as a JSON string value.
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | tr '\r' ' ' | tr '\t' ' '
}

# extract_content: pull the first assistant "content" value from an OpenRouter
# response.  JSON-escape sequences (e.g. \n) are kept as-is so the result can
# be re-embedded in JSON without double-escaping.
extract_content() {
    printf '%s' "$1" | grep -o '"content":"[^"]*"' | head -1 | \
        sed 's/^"content":"//; s/"$//'
}

# append_msg: append a plain {role, content} entry to a comma-separated
# messages list string and print the result.
# Usage: messages=$(append_msg "$messages" "role" "content_string")
append_msg() {
    local content
    content=$(json_escape "$3")
    printf '%s,{"role":"%s","content":"%s"}' "$1" "$2" "$content"
}

# append_user_image: append a user turn containing text + a JPEG image.
# Usage: messages=$(append_user_image "$messages" "text" "base64_jpeg")
append_user_image() {
    local txt
    txt=$(json_escape "$2")
    printf '%s,{"role":"user","content":[{"type":"text","text":"%s"},{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,%s"}}]}' \
        "$1" "$txt" "$3"
}

# or_call: POST the messages list to OpenRouter and return the raw response.
# Usage: response=$(or_call "$messages")
or_call() {
    local payload
    payload=$(printf '{"model":"%s","messages":[%s]}' "$OPENROUTER_MODEL" "$1")
    /opt/wz_mini/bin/curl -s \
        --cacert /opt/wz_mini/etc/ssl/ca-bundle.crt \
        -H "Authorization: Bearer $OPENROUTER_API_KEY" \
        -H "Content-Type: application/json" \
        -X POST "https://openrouter.ai/api/v1/chat/completions" \
        -d "$payload"
}

# run_tool: execute a whitelisted agent tool.  Prints a one-line result string.
# Usage: result=$(run_tool "name" "arg")
run_tool() {
    local name="$1"
    local arg="$2"
    case " $OPENROUTER_AGENT_TOOLS " in
        *" $name "*) ;;
        *) echo "Tool not enabled: $name"; return ;;
    esac
    case "$name" in
        alert)
            local safe_arg
            safe_arg=$(json_escape "$arg")
            printf '{"timestamp":"%s","message":"%s"}\n' "$(date)" "$safe_arg" > "$AI_ALERT"
            if [[ "$HA_ENABLED" == "true" ]] && [[ -n "$HA_URL" ]] && [[ -n "$HA_TOKEN" ]]; then
                local ha_payload
                ha_payload=$(printf \
                    '{"state":"ALERT","attributes":{"message":"%s","timestamp":"%s","friendly_name":"AI Camera"}}' \
                    "$safe_arg" "$(date)")
                /opt/wz_mini/bin/curl -s \
                    --cacert /opt/wz_mini/etc/ssl/ca-bundle.crt \
                    -H "Authorization: Bearer $HA_TOKEN" \
                    -H "Content-Type: application/json" \
                    -X POST "$HA_URL/api/states/$HA_ENTITY_ID" \
                    -d "$ha_payload" > /dev/null 2>&1
            fi
            echo "Alert saved: $arg"
            ;;
        ha_trigger)
            if [[ -n "$HA_WEBHOOK_URL" ]]; then
                local safe_arg
                safe_arg=$(json_escape "$arg")
                /opt/wz_mini/bin/curl -s \
                    --cacert /opt/wz_mini/etc/ssl/ca-bundle.crt \
                    -H "Content-Type: application/json" \
                    -X POST "$HA_WEBHOOK_URL" \
                    -d "{\"message\":\"$safe_arg\"}" > /dev/null 2>&1
                echo "HA webhook triggered: $arg"
            else
                echo "HA_WEBHOOK_URL not set"
            fi
            ;;
        notify)
            if [[ -n "$NOTIFY_WEBHOOK_URL" ]]; then
                local safe_arg
                safe_arg=$(json_escape "$arg")
                /opt/wz_mini/bin/curl -s \
                    --cacert /opt/wz_mini/etc/ssl/ca-bundle.crt \
                    -H "Content-Type: application/json" \
                    -X POST "$NOTIFY_WEBHOOK_URL" \
                    -d "{\"message\":\"$safe_arg\"}" > /dev/null 2>&1
                echo "Notification sent: $arg"
            else
                echo "NOTIFY_WEBHOOK_URL not set"
            fi
            ;;
        capture_again)
            /opt/wz_mini/bin/cmd jpeg 0 -n > "$AI_SNAPSHOT" 2>/dev/null
            if [ -s "$AI_SNAPSHOT" ]; then
                echo "New frame captured"
            else
                echo "Frame capture failed"
            fi
            ;;
        record)
            local dur="${arg:-10}"
            mkdir -p "$AI_RECORD_DIR"
            local clip="$AI_RECORD_DIR/clip_$(date +%Y%m%d_%H%M%S).mp4"
            /opt/wz_mini/bin/ffmpeg -loglevel error \
                -f v4l2 -i /dev/video1 \
                -t "$dur" \
                -c:v libx264 -preset ultrafast -movflags +faststart \
                -y "$clip" 2>/dev/null &
            echo "Recording started: ${dur}s"
            ;;
        *)
            echo "Unknown tool: $name"
            ;;
    esac
}

(
while true; do

if [[ "$OPENROUTER_MODE" == "agent" ]]; then
# ---- AGENT MODE ----
# Capture a JPEG then run a multi-turn conversation with OpenRouter.
# The AI signals tool calls with a line: TOOL_CALL:<name>:<argument>
/opt/wz_mini/bin/cmd jpeg 0 -n > "$AI_SNAPSHOT" 2>/dev/null

if [ ! -s "$AI_SNAPSHOT" ]; then
echo "$(date): Failed to capture frame" >> "$AI_LOG.log"
sleep "$OPENROUTER_INTERVAL"
continue
fi

img_b64=$(busybox base64 < "$AI_SNAPSHOT" | tr -d '\n')

# Build the initial messages list: system prompt + first user turn with image.
sys_esc=$(json_escape "$OPENROUTER_SYSTEM_PROMPT")
messages=$(printf '{"role":"system","content":"%s"}' "$sys_esc")
messages=$(append_user_image "$messages" "$OPENROUTER_PROMPT" "$img_b64")

# conv_entries accumulates {role,content} objects for the result JSON.
conv_entries=""
turn=0
last_response=""

while [ "$turn" -lt "$OPENROUTER_MAX_TURNS" ]; do
response=$(or_call "$messages")
last_response="$response"
echo "$(date) [agent turn $turn]: $response" >> "$AI_LOG.log"

asst_text=$(extract_content "$response")

# Append assistant turn to messages and conversation log.
messages=$(append_msg "$messages" "assistant" "$asst_text")
safe_asst=$(json_escape "$asst_text")
[ -n "$conv_entries" ] && conv_entries="${conv_entries},"
conv_entries="${conv_entries}{\"role\":\"assistant\",\"content\":\"$safe_asst\"}"

# Detect a tool call (convert JSON \n sequences to real newlines first).
tool_line=$(printf '%s' "$asst_text" | sed 's/\\n/\n/g' | grep -m1 '^TOOL_CALL:')
[ -z "$tool_line" ] && break

tool_name=$(printf '%s' "$tool_line" | cut -d: -f2)
tool_arg=$(printf '%s' "$tool_line" | cut -d: -f3-)

tool_result=$(run_tool "$tool_name" "$tool_arg")

safe_result=$(json_escape "[$tool_name] $tool_result")
conv_entries="${conv_entries},{\"role\":\"tool_result\",\"content\":\"$safe_result\"}"

# Feed result back; attach a new frame if capture_again succeeded.
if [ "$tool_name" = "capture_again" ] && [ -s "$AI_SNAPSHOT" ]; then
img_b64=$(busybox base64 < "$AI_SNAPSHOT" | tr -d '\n')
messages=$(append_user_image "$messages" "Tool result: $tool_result" "$img_b64")
else
messages=$(append_msg "$messages" "user" "Tool result: $tool_result")
fi

turn=$((turn + 1))
done

timestamp=$(date)
printf '{"timestamp":"%s","model":"%s","mode":"agent","conversation":[%s],"response":%s}\n' \
"$timestamp" \
"$OPENROUTER_MODEL" \
"$conv_entries" \
"$last_response" > "$AI_RESULT"

# Push final assistant summary to HA.
if [[ "$HA_ENABLED" == "true" ]] && [[ -n "$HA_URL" ]] && [[ -n "$HA_TOKEN" ]]; then
ai_text=$(extract_content "$last_response" | cut -c1-255)
ai_text_safe=$(json_escape "$ai_text")
ha_payload=$(printf \
'{"state":"%s","attributes":{"timestamp":"%s","model":"%s","mode":"agent","friendly_name":"AI Camera"}}' \
"$ai_text_safe" "$timestamp" "$OPENROUTER_MODEL")
/opt/wz_mini/bin/curl -s \
--cacert /opt/wz_mini/etc/ssl/ca-bundle.crt \
-H "Authorization: Bearer $HA_TOKEN" \
-H "Content-Type: application/json" \
-X POST "$HA_URL/api/states/$HA_ENTITY_ID" \
-d "$ha_payload" > /dev/null 2>&1
fi

sleep "$OPENROUTER_INTERVAL"
continue
fi

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
ai_text=$(echo "$response" | grep -o '"content":"[^"]*"' | head -1 | sed 's/^"content":"//; s/"$//' | cut -c1-255)

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
