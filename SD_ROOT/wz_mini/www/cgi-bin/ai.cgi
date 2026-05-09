#!/bin/sh
# Serve the latest AI camera result as JSON.
# Used by the ai.html web UI and by Home Assistant as a REST sensor source.
#
# Query string:
#   (none)    — return latest.json  (full result including conversation)
#   alert=1   — return alert.json   (alert written by the agent's alert tool)
#
# Home Assistant REST sensor example (configuration.yaml):
#   sensor:
#     - platform: rest
#       name: "AI Camera"
#       resource: "http://CAMERA_IP/cgi-bin/ai.cgi"
#       value_template: >
#         {{ value_json.response.choices[0].message.content
#            if value_json.response and value_json.response.choices
#            else 'No result' }}
#       json_attributes_path: "$"
#       json_attributes:
#         - timestamp
#         - model

AI_RESULT="/opt/wz_mini/www/ai/latest.json"
AI_ALERT="/opt/wz_mini/www/ai/alert.json"

echo "HTTP/1.1 200"
echo "Content-Type: application/json"
echo "Cache-Control: no-store, no-cache"
echo ""

if [ "$QUERY_STRING" = "alert=1" ]; then
	if [ -f "$AI_ALERT" ]; then
		cat "$AI_ALERT"
	else
		printf '{}\n'
	fi
else
	if [ -f "$AI_RESULT" ]; then
		cat "$AI_RESULT"
	else
		printf '{"timestamp":"","model":"","response":null}\n'
	fi
fi
