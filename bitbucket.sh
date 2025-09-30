#!/bin/bash
# This script triggers the review API, parses the JSON response,
# formats a comment for Bitbucket, and posts it to the pull request.

# 1. TRIGGER THE EXTERNAL REVIEW API
echo "Triggering code review for commit $BITBUCKET_COMMIT..."
API_PAYLOAD=$(jq -n --arg repo_url "$BITBUCKET_GIT_HTTP_ORIGIN" --arg commit_hash "$BITBUCKET_COMMIT" --arg base_branch "$BITBUCKET_PR_DESTINATION_BRANCH" --arg source_branch "$BITBUCKET_BRANCH" '{repo_url: $repo_url, commit_hash: $commit_hash, base_branch: $base_branch, source_branch: $source_branch}')

API_RESPONSE_BODY=$(curl -s -X POST "$REVIEW_API_URL" --header "Content-Type: application/json" --header "X-API-Key: $REVIEW_API_KEY" --data "$API_PAYLOAD")

# 2. DEBUG LOGGING
echo "--- Raw API Response Received ---"; echo "$API_RESPONSE_BODY"; echo "---------------------------------"

# 3. PARSE RESPONSE AND BUILD THE FORMATTED COMMENT IN A FILE
COMMENT_FILE="comment.md"
> "$COMMENT_FILE"

if ! echo "$API_RESPONSE_BODY" | jq -e . > /dev/null 2>&1; then
  echo -e "🚨 **Automated Code Review Failed** 🚨\n\nCould not get a valid JSON response from the review service." > "$COMMENT_FILE"
else
  TOTAL_ISSUES=$(echo "$API_RESPONSE_BODY" | jq -r '.summary.total_issues // 0')
  TOTAL_PRAISES=$(echo "$API_RESPONSE_BODY" | jq -r '.summary.total_praises // 0')

  if [ "$TOTAL_ISSUES" -eq 0 ] && [ "$TOTAL_PRAISES" -eq 0 ]; then
    echo -e "✅ **Automated Code Review Complete** ✅\n\nNo issues or praises were found." > "$COMMENT_FILE"
  else
    # Add header
    echo "🤖 **Automated Code Review Results**" >> "$COMMENT_FILE"
    echo "" >> "$COMMENT_FILE"

    # --- Praises Section ---
    if [ "$TOTAL_PRAISES" -gt 0 ]; then
      echo "### ✨ Praises ($TOTAL_PRAISES)" >> "$COMMENT_FILE"
      echo "" >> "$COMMENT_FILE"
      echo "$API_RESPONSE_BODY" | jq -r '.review.praises[] | @json' | while IFS= read -r praise_json; do
        file_path=$(echo "$praise_json" | jq -r '.file_path')
        line_number=$(echo "$praise_json" | jq -r '.line_number')
        message=$(echo "$praise_json" | jq -r '.message')
        category=$(echo "$praise_json" | jq -r '.category')

        file_link="[$file_path:$line_number]($BITBUCKET_GIT_HTTP_ORIGIN/src/$BITBUCKET_COMMIT/$file_path#lines-$line_number)"
        formatted_category=$(echo "$category" | sed -e 's/_/ /g' -e 's/\b\(.\)/\u\1/g')

        echo "- ✅ **$formatted_category** in $file_link" >> "$COMMENT_FILE"
        echo "  - $message" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
      done
    fi

    # --- Issues Section ---
    if [ "$TOTAL_ISSUES" -gt 0 ]; then
      HIGH_ISSUES=$(echo "$API_RESPONSE_BODY" | jq -r '.summary.high // 0')
      MEDIUM_ISSUES=$(echo "$API_RESPONSE_BODY" | jq -r '.summary.medium // 0')
      LOW_ISSUES=$(echo "$API_RESPONSE_BODY" | jq -r '.summary.low // 0')
      CRITICAL_ISSUES=$(echo "$API_RESPONSE_BODY" | jq -r '.summary.critical // 0')

      echo "### ⚠️ Issues Found ($TOTAL_ISSUES)" >> "$COMMENT_FILE"
      echo "" >> "$COMMENT_FILE"

      echo "| Severity | Count |" >> "$COMMENT_FILE"
      echo "| :--- | :---: |" >> "$COMMENT_FILE"
      if [ "$CRITICAL_ISSUES" -gt 0 ]; then
        echo "| 🟣 Critical | $CRITICAL_ISSUES |" >> "$COMMENT_FILE"
      fi
      if [ "$HIGH_ISSUES" -gt 0 ]; then
        echo "| 🔴 High | $HIGH_ISSUES |" >> "$COMMENT_FILE"
      fi
      if [ "$MEDIUM_ISSUES" -gt 0 ]; then
        echo "| 🟠 Medium | $MEDIUM_ISSUES |" >> "$COMMENT_FILE"
      fi
      if [ "$LOW_ISSUES" -gt 0 ]; then
        echo "| 🟡 Low | $LOW_ISSUES |" >> "$COMMENT_FILE"
      fi
      echo "" >> "$COMMENT_FILE"

      # Process each issue
      echo "$API_RESPONSE_BODY" | jq -r '.review.issues[] | @json' | while IFS= read -r issue_json; do
        file_path=$(echo "$issue_json" | jq -r '.file_path')
        line_number=$(echo "$issue_json" | jq -r '.line_number')
        message=$(echo "$issue_json" | jq -r '.message')
        severity=$(echo "$issue_json" | jq -r '.severity')
        category=$(echo "$issue_json" | jq -r '.category')
        suggested_fix=$(echo "$issue_json" | jq -r '.suggested_fix // ""')

        emoji="⚪️"
        case "$severity" in
          "critical") emoji="🟣" ;;
          "high") emoji="🔴" ;;
          "medium") emoji="🟠" ;;
          "low") emoji="🟡" ;;
        esac

        category_emoji="📝" # Default emoji
        case "$category" in
          "bug") category_emoji="🐞" ;;
          "security") category_emoji="🛡️" ;;
          "best_practice") category_emoji="✨" ;;
          "dependency") category_emoji="📦" ;;
          "performance") category_emoji="🚀" ;;
          "rbac") category_emoji="🔑" ;;
          "syntax") category_emoji="📝" ;;
        esac

        file_link="[$file_path:$line_number]($BITBUCKET_GIT_HTTP_ORIGIN/src/$BITBUCKET_COMMIT/$file_path#lines-$line_number)"
        formatted_category=$(echo "$category" | sed -e 's/_/ /g' -e 's/\b\(.\)/\u\1/g')

        echo "- $emoji **$severity** in $file_link ($category_emoji $formatted_category)" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
        echo "$message" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"

        if [ -n "$suggested_fix" ] && [ "$suggested_fix" != "null" ] && [ "$suggested_fix" != "" ]; then
          sanitized_fix=$(echo "$suggested_fix" | sed -E 's/^```[a-zA-Z]*n?//g' | sed 's/```$//g')

          echo "**💡 Suggested Fix:**" >> "$COMMENT_FILE"
          echo '```' >> "$COMMENT_FILE"
          echo "$sanitized_fix" >> "$COMMENT_FILE"
          echo '```' >> "$COMMENT_FILE"
        fi
        echo "" >> "$COMMENT_FILE"
      done
    fi
  fi
fi

# 4. POST THE FORMATTED COMMENT FROM THE FILE
echo "--- Final Comment Content ---"
cat "$COMMENT_FILE"
echo "---------------------------"

JSON_PAYLOAD=$(jq -n --rawfile content "$COMMENT_FILE" '{content: {raw: $content}}')

POST_RESPONSE=$(curl -s -X POST "https://api.bitbucket.org/2.0/repositories/$BITBUCKET_WORKSPACE/$BITBUCKET_REPO_SLUG/pullrequests/$BITBUCKET_PR_ID/comments" --header "Authorization: Bearer $BOT_PASSWORD" --header "Content-Type: application/json" --data "$JSON_PAYLOAD" -w "\n%{http_code}")

HTTP_STATUS=$(echo "$POST_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$POST_RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  echo "Successfully posted comment to pull request."
else
  echo "Error posting comment to pull request. HTTP Status: $HTTP_STATUS"
  echo "Response (filtered for sensitive info): $(echo "$RESPONSE_BODY" | sed 's/Bearer [^ ]*/Bearer [REDACTED]/g')"
  exit 1
fi
