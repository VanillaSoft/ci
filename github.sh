#!/usr/bin/env bash
# Requires bash 4.0+ for associative arrays
set -euo pipefail
# This script triggers the review API, parses the JSON response,
# formats a comment for GitHub, and posts it to the pull request.

# GitHub Actions Environment Variables
# GITHUB_SHA - The commit hash
# GITHUB_REPOSITORY - The repository (owner/repo)
# GITHUB_SERVER_URL - The GitHub server URL (e.g., https://github.com)
# GITHUB_EVENT_PATH - Path to the event JSON file
# GITHUB_TOKEN - GitHub token for API access (from secrets)

# Comment Formatting Configuration
# These can be set as environment variables in the workflow to customize comment formatting
INCLUDE_AI_ASSIST_INLINE="${INCLUDE_AI_ASSIST_INLINE:-true}"  # Include AI-assist YAML block in inline comments
INCLUDE_AI_ASSIST_SUMMARY="${INCLUDE_AI_ASSIST_SUMMARY:-false}"  # Include AI-assist YAML block in summary comment
MAX_LINE_WIDTH="${MAX_LINE_WIDTH:-100}"  # Maximum character width for code blocks before wrapping

# Function to wrap long lines in code blocks
wrap_code_block() {
  local content="$1"
  local max_width="$2"

  printf "%s\n" "$content" | fold -s -w "$max_width"
}

# Extract PR number and branch information from the GitHub event
PR_NUMBER=$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")
BASE_BRANCH=$(jq -r '.pull_request.base.ref' "$GITHUB_EVENT_PATH")
SOURCE_BRANCH=$(jq -r '.pull_request.head.ref' "$GITHUB_EVENT_PATH")
# Use the actual HEAD commit from the PR, not the merge commit
COMMIT_HASH=$(jq -r '.pull_request.head.sha' "$GITHUB_EVENT_PATH")
REPO_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}.git"

# 1. TRIGGER THE EXTERNAL REVIEW API
echo "Triggering code review for commit $COMMIT_HASH..."
API_PAYLOAD=$(jq -n \
  --arg repo_url "$REPO_URL" \
  --arg commit_hash "$COMMIT_HASH" \
  --arg base_branch "$BASE_BRANCH" \
  --arg source_branch "$SOURCE_BRANCH" \
  --arg ticket_system "github" \
  --arg vcs_token "$GITHUB_TOKEN" \
  '{repo_url: $repo_url, commit_hash: $commit_hash, base_branch: $base_branch, source_branch: $source_branch, ticket_system: $ticket_system, vcs_token: $vcs_token}')

API_RESPONSE_BODY=$(curl -s -X POST "$REVIEW_API_URL" \
  --header "Content-Type: application/json" \
  --header "X-API-Key: $REVIEW_API_KEY" \
  --data "$API_PAYLOAD")

# 2. DEBUG LOGGING
echo "--- Raw API Response Received ---"; echo "$API_RESPONSE_BODY"; echo "---------------------------------"

# 3. PARSE RESPONSE AND POST INLINE COMMENTS FOR ISSUES
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}"

# Use an associative array to store locations of existing comments
declare -A existing_comment_locations

# Function to post a review comment
post_review_comment() {
  local file_path="$1"
  local line_number="$2"
  local comment_body="$3"
  local post_response
  local http_status
  local response_body

  local comment_payload
  comment_payload=$(jq -n \
    --arg body "$comment_body" \
    --arg commit_id "$COMMIT_HASH" \
    --arg path "$file_path" \
    --argjson line "$line_number" \
    '{
      body: $body,
      commit_id: $commit_id,
      path: $path,
      line: $line
    }')

  post_response=$(curl -s -X POST "${GITHUB_API_URL}/comments" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    -H "Content-Type: application/json" \
    --data "$comment_payload" -w "\n%{http_code}")

  http_status=$(echo "$post_response" | tail -n1)
  response_body=$(echo "$post_response" | sed '$d')

  if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
    echo "Successfully posted an inline comment on ${file_path}:${line_number}."
  else
    echo "Error posting an inline comment. HTTP Status: $http_status"
    echo "Response: $response_body"
  fi
}

# Function to fetch all pages of comments using pagination
fetch_all_comments() {
  local url="$1"
  local all_comments="[]"
  local page_url="$url?per_page=100"

  while [ -n "$page_url" ]; do
    local response
    local headers_file
    headers_file=$(mktemp)

    # Fetch page with headers to get Link header for pagination
    response=$(curl -s -X GET "$page_url" \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      -D "$headers_file")

    if ! echo "$response" | jq -e . > /dev/null 2>&1; then
      rm -f "$headers_file"
      echo "[]"
      return
    fi

    # Merge this page with all_comments
    all_comments=$(jq -s '.[0] + .[1]' <(echo "$all_comments") <(echo "$response"))

    # Extract next page URL from Link header
    page_url=$(grep -i "^link:" "$headers_file" | sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p')

    rm -f "$headers_file"
  done

  echo "$all_comments"
}

# Function to delete old bot summary comments
delete_old_summary_comments() {
  echo "Deleting old bot summary comments..."
  local existing_comments_response
  local issue_comments_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments"

  existing_comments_response=$(fetch_all_comments "$issue_comments_url")

  if ! echo "$existing_comments_response" | jq -e . > /dev/null 2>&1; then
    echo "Warning: Could not fetch existing comments to delete old summaries."
    return
  fi

  # Find and delete comments that contain our signature
  echo "$existing_comments_response" | jq -r '.[] | select(.body | contains("Automated Code Review Results")) | .id' | while IFS= read -r comment_id; do
    echo "Deleting old summary comment (ID: $comment_id)..."

    local delete_response
    delete_response=$(curl -s -X DELETE "https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/comments/${comment_id}" \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      -w "\n%{http_code}")

    local http_status
    http_status=$(echo "$delete_response" | tail -n1)

    if [ "$http_status" -ge 200 ] && [ "$http_status" -lt 300 ]; then
      echo "Successfully deleted comment $comment_id"
    else
      echo "Warning: Could not delete comment $comment_id (HTTP $http_status)"
    fi
  done
}

# Function to get existing review comments and populate a lookup map to avoid duplicate comments
populate_existing_comments_map() {
  echo "Fetching existing review comments to prevent duplicates..."
  echo "[DEBUG] GITHUB_API_URL=${GITHUB_API_URL}"
  echo "[DEBUG] Fetching from: ${GITHUB_API_URL}/comments"

  local existing_comments_response
  existing_comments_response=$(fetch_all_comments "${GITHUB_API_URL}/comments")

  echo "[DEBUG] fetch_all_comments returned, exit code: $?"
  echo "[DEBUG] Response length: ${#existing_comments_response}"
  echo "[DEBUG] Response content: $existing_comments_response"

  if ! echo "$existing_comments_response" | jq -e . > /dev/null 2>&1; then
    echo "Warning: Could not fetch or parse existing comments. Duplicate checking will be skipped."
    echo "[DEBUG] jq validation failed"
    return
  fi

  echo "[DEBUG] jq validation passed"

  # Extract file path and line number from existing comments
  local comment_count=0
  echo "[DEBUG] Starting to process comments array..."

  while IFS= read -r comment_json; do
    local file_path
    local line_number
    local location_key

    file_path=$(echo "$comment_json" | jq -r '.path // empty')
    line_number=$(echo "$comment_json" | jq -r '.line // empty')

    echo "[DEBUG] Checking comment - path: '$file_path', line: '$line_number'"

    if [ -n "$file_path" ] && [ "$file_path" != "null" ] && [ -n "$line_number" ] && [ "$line_number" != "null" ]; then
      location_key="${file_path}:${line_number}"
      existing_comment_locations["$location_key"]=1
      ((comment_count++))
      echo "[DEBUG] Added comment location: $location_key"
    else
      echo "[DEBUG] Skipping comment - path or line is null/empty"
    fi
  done < <(echo "$existing_comments_response" | jq -c '.[]' || true)

  echo "[DEBUG] Finished processing comments"
  echo "Found comments at ${comment_count} unique locations."
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
        new_comment_location_key="${file_path}:${line_number}"

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

        inline_comment_content=$(printf "%s **%s (%s %s):**\n\n%s" "$emoji" "$severity" "$category_emoji" "$formatted_category" "$message")

        # Sanitize and wrap suggested_fix once if it exists (for reuse in both blocks)
        if [ -n "$suggested_fix" ] && [ "$suggested_fix" != "null" ] && [ "$suggested_fix" != "" ]; then
          sanitized_fix=$(echo "$suggested_fix" | sed -E 's/^```[a-zA-Z]*//' | sed 's/```$//g')
          wrapped_fix=$(wrap_code_block "$sanitized_fix" "$MAX_LINE_WIDTH")

          # Add human-readable suggested fix block
          suggestion=$(printf "\n\n---\n\n**💡 Suggested Fix:**\n\n\`\`\`\n%s\n\`\`\`" "$wrapped_fix")
          inline_comment_content+="$suggestion"
        fi

        # Add AI-assist YAML block to inline comment (if enabled)
        if [ "$INCLUDE_AI_ASSIST_INLINE" = "true" ]; then
          ai_assist_block=$(printf "\n\n---\n\n**🤖 AI-Assisted Fix (copy this):**\n\`\`\`yaml\n- file: %s\n  line: %s\n  severity: %s\n  category: %s\n  message: |\n%s" "$file_path" "$line_number" "$severity" "$category" "$(printf "%s\n" "$message" | sed 's/^/    /')")
          if [ -n "$suggested_fix" ] && [ "$suggested_fix" != "null" ] && [ "$suggested_fix" != "" ]; then
            # Use unwrapped sanitized_fix to preserve code integrity in YAML
            ai_assist_block+=$(printf "\n  suggested_fix: |\n%s" "$(printf "%s\n" "$sanitized_fix" | sed 's/^/    /')")
          fi
          ai_assist_block+=$(printf "\n\`\`\`")
          inline_comment_content+="$ai_assist_block"
        fi

        post_review_comment "$file_path" "$line_number" "$inline_comment_content"
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

        # GitHub link format
        file_link="[$file_path:$line_number](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/blob/${COMMIT_HASH}/${file_path}#L${line_number})"
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

        # GitHub link format
        file_link="[$file_path:$line_number](${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/blob/${COMMIT_HASH}/${file_path}#L${line_number})"
        formatted_category=$(echo "$category" | sed -e 's/_/ /g' -e 's/\b\(.\)/\u\1/g')

        echo "- $emoji **$severity** in $file_link ($category_emoji $formatted_category)" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
        printf "%s\n" "$message" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"

        # Sanitize and wrap suggested_fix once if it exists (for reuse in both blocks)
        if [ -n "$suggested_fix" ] && [ "$suggested_fix" != "null" ] && [ "$suggested_fix" != "" ]; then
          sanitized_fix=$(echo "$suggested_fix" | sed -E 's/^```[a-zA-Z]*//' | sed 's/```$//g')
          wrapped_fix=$(wrap_code_block "$sanitized_fix" "$MAX_LINE_WIDTH")

          # Add human-readable suggested fix block
          echo "**💡 Suggested Fix:**" >> "$COMMENT_FILE"
          echo '```' >> "$COMMENT_FILE"
          printf "%s\n" "$wrapped_fix" >> "$COMMENT_FILE"
          echo '```' >> "$COMMENT_FILE"
        fi

        # Add AI-assist YAML block to summary comment (if enabled)
        if [ "$INCLUDE_AI_ASSIST_SUMMARY" = "true" ]; then
          echo "" >> "$COMMENT_FILE"
          echo "**🤖 AI-Assisted Fix (copy this):**" >> "$COMMENT_FILE"
          echo '```yaml' >> "$COMMENT_FILE"
          echo "- file: $file_path" >> "$COMMENT_FILE"
          echo "  line: $line_number" >> "$COMMENT_FILE"
          echo "  severity: $severity" >> "$COMMENT_FILE"
          echo "  category: $category" >> "$COMMENT_FILE"
          echo "  message: |" >> "$COMMENT_FILE"
          printf "%s\n" "$message" | sed 's/^/    /' >> "$COMMENT_FILE"
          if [ -n "$suggested_fix" ] && [ "$suggested_fix" != "null" ] && [ "$suggested_fix" != "" ]; then
            # Use unwrapped sanitized_fix to preserve code integrity in YAML
            echo "  suggested_fix: |" >> "$COMMENT_FILE"
            printf "%s\n" "$sanitized_fix" | sed 's/^/    /' >> "$COMMENT_FILE"
          fi
          echo '```' >> "$COMMENT_FILE"
        fi

        echo "" >> "$COMMENT_FILE"
      done
    fi
  fi
fi

# 5. DELETE OLD SUMMARY COMMENTS AND POST NEW ONE TO GITHUB

# First, delete old summary comments to reduce clutter
delete_old_summary_comments

echo "--- Final Summary Comment Content ---"
cat "$COMMENT_FILE"
echo "---------------------------"

# GitHub API requires the body in the comment payload
# Use issue comments endpoint for summary (not review comments endpoint)
COMMENT_BODY=$(cat "$COMMENT_FILE")
JSON_PAYLOAD=$(jq -n --arg body "$COMMENT_BODY" '{body: $body}')

ISSUE_COMMENTS_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments"
POST_RESPONSE=$(curl -s -X POST "$ISSUE_COMMENTS_URL" \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
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

# 6. POST COMMIT STATUS TO BLOCK/UNBLOCK MERGE BASED ON CRITICAL ISSUES
echo "Posting commit status..."

# Determine status based on critical issues only
CRITICAL_ISSUES=$(echo "$API_RESPONSE_BODY" | jq -r '.summary.critical // 0')

if [ "$CRITICAL_ISSUES" -gt 0 ]; then
  COMMIT_STATUS="failure"
  STATUS_DESCRIPTION="Found $CRITICAL_ISSUES critical severity issues that must be addressed"
else
  COMMIT_STATUS="success"
  STATUS_DESCRIPTION="No critical severity issues found"
fi

# GitHub Commit Status API
# Use the actual commit hash, not the temporary merge commit
COMMIT_STATUS_URL="https://api.github.com/repos/${GITHUB_REPOSITORY}/statuses/${COMMIT_HASH}"

STATUS_PAYLOAD=$(jq -n \
  --arg state "$COMMIT_STATUS" \
  --arg description "$STATUS_DESCRIPTION" \
  --arg context "Code Review" \
  '{
    state: $state,
    description: $description,
    context: $context
  }')

STATUS_RESPONSE=$(curl -s -X POST "$COMMIT_STATUS_URL" \
  -H "Authorization: token $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github.v3+json" \
  -H "Content-Type: application/json" \
  --data "$STATUS_PAYLOAD" -w "\n%{http_code}")

STATUS_HTTP_CODE=$(echo "$STATUS_RESPONSE" | tail -n1)
STATUS_BODY=$(echo "$STATUS_RESPONSE" | sed '$d')

if [ "$STATUS_HTTP_CODE" -ge 200 ] && [ "$STATUS_HTTP_CODE" -lt 300 ]; then
  echo "Successfully posted commit status: $COMMIT_STATUS"
else
  echo "Warning: Could not post commit status. HTTP Status: $STATUS_HTTP_CODE"
  echo "Response: $STATUS_BODY"
fi
