#!/bin/bash
# This script triggers the review API, parses the JSON response,
# formats a comment for Azure DevOps, and posts it to the pull request.

# Strip user from BUILD_REPOSITORY_URI if it exists
BUILD_REPOSITORY_URI=$(echo "$BUILD_REPOSITORY_URI" | sed 's/https:\/\/.*@/https:\/\//')

# Strip refs/heads/ from branch names
SYSTEM_PULLREQUEST_TARGETBRANCH=$(echo "$SYSTEM_PULLREQUEST_TARGETBRANCH" | sed 's/refs\/heads\///')
SYSTEM_PULLREQUEST_SOURCEBRANCH=$(echo "$SYSTEM_PULLREQUEST_SOURCEBRANCH" | sed 's/refs\/heads\///')


# Azure DevOps Environment Variables
# SYSTEM_PULLREQUEST_SOURCECOMMITID - The commit hash
# BUILD_REPOSITORY_URI - The full repo URL
# SYSTEM_PULLREQUEST_PULLREQUESTID - The PR ID
# SYSTEM_TEAMFOUNDATIONCOLLECTIONURI - The org URL (e.g., https://dev.azure.com/myorg/)
# SYSTEM_TEAMPROJECT - The project name
# BUILD_REPOSITORY_ID - The repository ID
# ADO_PERSONAL_ACCESS_TOKEN - The access token (from env)

# 1. TRIGGER THE EXTERNAL REVIEW API
echo "Triggering code review for commit $SYSTEM_PULLREQUEST_SOURCECOMMITID..."
API_PAYLOAD=$(jq -n \
  --arg repo_url "$BUILD_REPOSITORY_URI" \
  --arg commit_hash "$SYSTEM_PULLREQUEST_SOURCECOMMITID" \
  --arg base_branch "$SYSTEM_PULLREQUEST_TARGETBRANCH" \
  --arg source_branch "$SYSTEM_PULLREQUEST_SOURCEBRANCH" \
  --arg ticket_system "ado" \
  '{repo_url: $repo_url, commit_hash: $commit_hash, base_branch: $base_branch, source_branch: $source_branch, ticket_system: $ticket_system}')

API_RESPONSE_BODY=$(curl -s -X POST "$REVIEW_API_URL" \
  --header "Content-Type: application/json" \
  --header "X-API-Key: $REVIEW_API_KEY" \
  --data "$API_PAYLOAD")

# 2. DEBUG LOGGING
echo "--- Raw API Response Received ---"; echo "$API_RESPONSE_BODY"; echo "---------------------------------"

# 3. PARSE RESPONSE AND POST INLINE COMMENTS FOR ISSUES
ADO_API_URL="${SYSTEM_TEAMFOUNDATIONCOLLECTIONURI}${SYSTEM_TEAMPROJECT}/_apis/git/repositories/${BUILD_REPOSITORY_ID}/pullRequests/${SYSTEM_PULLREQUEST_PULLREQUESTID}/threads?api-version=6.0"

# Use an associative array to store locations of existing comments
declare -A existing_comment_locations

# Function to post a comment thread
post_thread() {
  local payload="$1"
  local post_response
  local http_status
  local response_body

  post_response=$(curl -s -X POST "$ADO_API_URL" \
    -H "Authorization: Bearer $ADO_PERSONAL_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    --data "$payload" -w "\n%{http_code}")

  http_status=$(echo "$post_response" | tail -n1)
  response_body=$(echo "$post_response" | sed '$d')

  if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
    echo "Successfully posted an inline comment."
  else
    echo "Error posting an inline comment. HTTP Status: $http_status"
    echo "Response: $response_body"
  fi
}

# Function to get existing threads and populate a lookup map to avoid duplicate comments
populate_existing_comments_map() {
  echo "Fetching existing comment threads to prevent duplicates..."
  local existing_threads_response
  existing_threads_response=$(curl -s -X GET "$ADO_API_URL" \
    -H "Authorization: Bearer $ADO_PERSONAL_ACCESS_TOKEN" \
    -H "Content-Type: application/json")

  if ! echo "$existing_threads_response" | jq -e . > /dev/null 2>&1; then
    echo "Warning: Could not fetch or parse existing threads. Duplicate checking will be skipped."
    return
  fi

  echo "$existing_threads_response" | jq -r '.value[] | select(.threadContext != null) | @json' | while IFS= read -r thread_json; do
    local file_path
    local line_number
    local location_key

    file_path=$(echo "$thread_json" | jq -r '.threadContext.filePath')
    line_number=$(echo "$thread_json" | jq -r '.threadContext.rightFileStart.line')

    if [ -n "$file_path" ] && [ "$file_path" != "null" ] && [ -n "$line_number" ] && [ "$line_number" != "null" ]; then
      location_key="${file_path}:${line_number}"
      existing_comment_locations["$location_key"]=1
    fi
  done
  echo "Found comments at ${#existing_comment_locations[@]} unique locations."
}


if echo "$API_RESPONSE_BODY" | jq -e . > /dev/null 2>&1; then
  TOTAL_ISSUES=$(echo "$API_RESPONSE_BODY" | jq -r '.summary.total_issues // 0')
  if [ "$TOTAL_ISSUES" -gt 0 ]; then
    # First, fetch all existing comments to enable duplicate checking
    populate_existing_comments_map

    echo "Posting inline comments for issues..."
    echo "$API_RESPONSE_BODY" | jq -r '.review.issues[] | @json' | while IFS= read -r issue_json; do
      file_path=$(echo "$issue_json" | jq -r '.file_path')
      line_number=$(echo "$issue_json" | jq -r '.line_number')

      if [ -n "$file_path" ] && [ "$file_path" != "null" ] && [ -n "$line_number" ] && [ "$line_number" != "null" ]; then
        # Create a location key for the new potential comment to check for duplicates
        new_comment_location_key="/${file_path}:${line_number}"

        if [[ -v existing_comment_locations["$new_comment_location_key"] ]]; then
          echo "Skipping comment on ${file_path}:${line_number} as a comment already exists there."
          continue
        fi

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

        formatted_category=$(echo "$category" | sed -e 's/_/ /g' -e 's/\b\(.\)/\u\1/g')

        inline_comment_content=$(printf "%s" "$emoji **$severity ($category_emoji $formatted_category):**\n\n$message")
        if [ -n "$suggested_fix" ] && [ "$suggested_fix" != "null" ] && [ "$suggested_fix" != "" ]; then
          sanitized_fix=$(echo "$suggested_fix" | sed -E 's/^```[a-zA-Z]*n?//g' | sed 's/```$//g')
          suggestion=$(printf "\n\n**💡 Suggested Fix:**\n\`\`\`\n%s\n\`\`\`" "$sanitized_fix")
          inline_comment_content+="$suggestion"
        fi

        inline_payload=$(jq -n \
          --arg content "$inline_comment_content" \
          --arg file_path "/$file_path" \
          --argjson line_number "$line_number" \
          '{
            "comments": [{"parentCommentId": 0, "content": $content, "commentType": 1}],
            "status": 1,
            "threadContext": {
              "filePath": $file_path,
              "rightFileStart": {"line": $line_number, "offset": 1},
              "rightFileEnd": {"line": $line_number, "offset": 2}
            }
          }')

        post_thread "$inline_payload"
      fi
    done
  fi
fi


# 4. PARSE RESPONSE AND BUILD THE FORMATTED SUMMARY COMMENT IN A FILE
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

        # ADO link format is different
        file_link="[$file_path:$line_number]($BUILD_REPOSITORY_URI?path=/$file_path&version=GC$SYSTEM_PULLREQUEST_SOURCECOMMITID&line=$line_number)"
        formatted_category=$(echo "$category" | sed -e 's/_/ /g' -e 's/\b\(.\)/\u\1/g')

        echo "- ✅ **$formatted_category** in $file_link" >> "$COMMENT_FILE"
        echo "  - $message" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
      done
    fi

    # --- Issues Section ---
    if [ "$TOTAL_ISSUES" -gt 0 ]; then
      # ... (This section is identical to the bitbucket script)
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

      # Process each issue for the human-readable summary
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

        file_link="[$file_path:$line_number]($BUILD_REPOSITORY_URI?path=/$file_path&version=GC$SYSTEM_PULLREQUEST_SOURCECOMMITID&line=$line_number)"
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

      # --- AI-Assisted Fix Section (Individual Blocks) ---
      echo "" >> "$COMMENT_FILE"
      echo "---" >> "$COMMENT_FILE"
      echo "<br>" >> "$COMMENT_FILE"
      echo "" >> "$COMMENT_FILE"
      echo "**🤖 For AI-Assisted Fix (Copy the relevant block below)**" >> "$COMMENT_FILE"
      echo "" >> "$COMMENT_FILE"

      echo "$API_RESPONSE_BODY" | jq -r '.review.issues[] | @json' | while IFS= read -r issue_json; do
        file_path=$(echo "$issue_json" | jq -r '.file_path')
        line_number=$(echo "$issue_json" | jq -r '.line_number')
        message=$(echo "$issue_json" | jq -r '.message')
        severity=$(echo "$issue_json" | jq -r '.severity')
        category=$(echo "$issue_json" | jq -r '.category')
        suggested_fix=$(echo "$issue_json" | jq -r '.suggested_fix // ""')

        echo "---" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
        echo "**Issue in \`$file_path:$line_number\`**" >> "$COMMENT_FILE"
        echo '```yaml' >> "$COMMENT_FILE"
        echo "- file: $file_path" >> "$COMMENT_FILE"
        echo "  line: $line_number" >> "$COMMENT_FILE"
        echo "  severity: $severity" >> "$COMMENT_FILE"
        echo "  category: $category" >> "$COMMENT_FILE"
        echo "  message: |" >> "$COMMENT_FILE"
        echo "    $message" >> "$COMMENT_FILE"
        if [ -n "$suggested_fix" ] && [ "$suggested_fix" != "null" ] && [ "$suggested_fix" != "" ]; then
          sanitized_fix=$(echo "$suggested_fix" | sed -E 's/^```[a-zA-Z]*n?//g' | sed 's/```$//g')
          echo "  suggested_fix: |" >> "$COMMENT_FILE"
          # Use sed to indent the suggested fix block
          echo "$sanitized_fix" | sed 's/^/    /' >> "$COMMENT_FILE"
        fi
        echo '```' >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
      done
    fi
  fi
fi

# 5. POST THE FORMATTED SUMMARY COMMENT TO AZURE DEVOPS
echo "--- Final Summary Comment Content ---"
cat "$COMMENT_FILE"
echo "---------------------------"

# Azure DevOps API requires a specific JSON structure for creating a PR thread
JSON_PAYLOAD=$(jq -n --rawfile content "$COMMENT_FILE" \
  '{
    "comments": [
      {
        "parentCommentId": 0,
        "content": $content,
        "commentType": 1
      }
    ],
    "status": 1
  }')

POST_RESPONSE=$(curl -s -X POST "$ADO_API_URL" \
  -H "Authorization: Bearer $ADO_PERSONAL_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$JSON_PAYLOAD" -w "\n%{http_code}")

HTTP_STATUS=$(echo "$POST_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$POST_RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  echo "Successfully posted summary comment to pull request."
else
  echo "Error posting summary comment to pull request. HTTP Status: $HTTP_STATUS"
  echo "Response: $RESPONSE_BODY"
  exit 1
fi
