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
        
        # ADO link format is different
        safe_file_path=$(echo "$file_path" | sed 's/ /%20/g')
        file_link="[$file_path:$line_number]($BUILD_REPOSITORY_URI?path=/$safe_file_path&version=GC$SYSTEM_PULLREQUEST_SOURCECOMMITID&line=$line_number)"
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
        
        safe_file_path=$(echo "$file_path" | sed 's/ /%20/g')
        file_link="[$file_path:$line_number]($BUILD_REPOSITORY_URI?path=/$safe_file_path&version=GC$SYSTEM_PULLREQUEST_SOURCECOMMITID&line=$line_number)"
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

# 4. POST THE FORMATTED COMMENT TO AZURE DEVOPS
echo "--- Final Comment Content ---"
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

ADO_API_URL="${SYSTEM_TEAMFOUNDATIONCOLLECTIONURI}${SYSTEM_TEAMPROJECT}/_apis/git/repositories/${BUILD_REPOSITORY_ID}/pullRequests/${SYSTEM_PULLREQUEST_PULLREQUESTID}/threads?api-version=6.0"

POST_RESPONSE=$(curl -s -X POST "$ADO_API_URL" \
  -H "Authorization: Bearer $ADO_PERSONAL_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$JSON_PAYLOAD" -w "\n%{http_code}")

HTTP_STATUS=$(echo "$POST_RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$POST_RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  echo "Successfully posted comment to pull request."
else
  echo "Error posting comment to pull request. HTTP Status: $HTTP_STATUS"
  echo "Response: $RESPONSE_BODY"
  exit 1
fi
