#!/opt/wz_mini/bin/bash
### BEGIN INIT INFO
# Provides:
# Short-Description: OpenRouter AI Camera
# Description:       Capture JPEG frames at a configurable interval and analyze
#                    them with the OpenRouter vision API.  Results are written
#                    to /opt/wz_mini/www/ai/ (served by httpd) and optionally
#                    pushed to Home Assistant via the HA REST API.
### END INIT INFO

. /opt/wz_mini/wz_mini.conf
. /opt/wz_mini/etc/rc.common

AI_LOG=/opt/wz_mini/log/ai_camera
AI_DIR=/opt/wz_mini/www/ai
AI_SNAPSHOT="$AI_DIR/snapshot.jpg"
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

		mkdir -p "$AI_DIR"
		rotate_log "$AI_LOG"

		# Wait for network and iCamera before starting the loop
		wait_for_wlan_ip "$(basename "$0")"
		wait_for_icamera

		(
		while true; do

			# Capture a JPEG frame from channel 0 (high-res) using cmd
			/opt/wz_mini/bin/cmd jpeg 0 -n > "$AI_SNAPSHOT" 2>/dev/null

			if [ ! -s "$AI_SNAPSHOT" ]; then
				echo "$(date): Failed to capture frame" >> "$AI_LOG.log"
				sleep "$OPENROUTER_INTERVAL"
				continue
			fi

			# Base64-encode the image with no line breaks
			img_b64=$(busybox base64 < "$AI_SNAPSHOT" | tr -d '\n')

			# Build the OpenRouter JSON payload
			payload=$(printf '{"model":"%s","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"data:image/jpeg;base64,%s"}},{"type":"text","text":"%s"}]}]}' \
				"$OPENROUTER_MODEL" \
				"$img_b64" \
				"$OPENROUTER_PROMPT")

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
			printf '{"timestamp":"%s","model":"%s","response":%s}\n' \
				"$timestamp" \
				"$OPENROUTER_MODEL" \
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
					'{"state":"%s","attributes":{"timestamp":"%s","model":"%s","friendly_name":"AI Camera"}}' \
					"$ai_text_safe" \
					"$timestamp" \
					"$OPENROUTER_MODEL")

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
