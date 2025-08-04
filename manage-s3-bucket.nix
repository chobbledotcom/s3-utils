#!/usr/bin/env nix-shell
#!nix-shell -i bash -p bash awscli2 jq

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables from .env file
if [ -f "$SCRIPT_DIR/.env" ]; then
    # Export variables from .env file
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
else
    echo "Error: .env file not found in $SCRIPT_DIR"
    echo "Please create a .env file with the following variables:"
    echo "  S3_ENDPOINT=https://your-endpoint.com"
    echo "  S3_BUCKET=your-bucket-name"
    echo "  S3_REGION=your-region"
    echo "  S3_ACCESS_KEY=your-access-key"
    exit 1
fi

# Validate required environment variables
if [ -z "$S3_ENDPOINT" ] || [ -z "$S3_BUCKET" ] || [ -z "$S3_REGION" ] || [ -z "$S3_ACCESS_KEY" ]; then
    echo "Error: Missing required environment variables in .env file"
    echo "Please ensure all of the following are set:"
    echo "  S3_ENDPOINT, S3_BUCKET, S3_REGION, S3_ACCESS_KEY"
    exit 1
fi

# S3 Configuration from environment
ENDPOINT="$S3_ENDPOINT"
BUCKET="$S3_BUCKET"
REGION="$S3_REGION"
ACCESS_KEY="$S3_ACCESS_KEY"

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Check for --deleted flag
if [[ "$1" == "--deleted" ]]; then
    LIST_DELETED=true
else
    LIST_DELETED=false
fi

echo -e "${YELLOW}Hetzner S3 Bucket Management Script${NC}"
echo -e "${YELLOW}=====================================${NC}"
echo ""

# Check if secret key is already set in environment
if [ -n "$S3_SECRET_KEY" ]; then
    SECRET_KEY="$S3_SECRET_KEY"
    echo -e "${GREEN}Using secret key from .env file${NC}"
else
    # Prompt for secret key
    echo -n "Enter your S3 secret key: "
    read -s SECRET_KEY
    echo ""
fi

# Export AWS credentials
export AWS_ACCESS_KEY_ID="$ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="$SECRET_KEY"

echo -e "\n${GREEN}Checking bucket configuration...${NC}"

# Function to check if bucket exists and is accessible
check_bucket() {
    if aws s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$REGION" 2>/dev/null; then
        echo -e "${GREEN}✓ Bucket '$BUCKET' is accessible${NC}"
        return 0
    else
        echo -e "${RED}✗ Cannot access bucket '$BUCKET'. Please check your credentials.${NC}"
        return 1
    fi
}

# Function to show current bucket settings
show_bucket_info() {
    echo -e "\n${YELLOW}Current Bucket Settings:${NC}"
    echo -e "${YELLOW}------------------------${NC}"
    
    # Get bucket location
    echo -e "\n${GREEN}Location:${NC}"
    aws s3api get-bucket-location --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$REGION" 2>/dev/null || echo "Could not retrieve location"
    
    # Get bucket versioning status
    echo -e "\n${GREEN}Versioning Status:${NC}"
    VERSIONING=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$REGION" 2>/dev/null)
    if [ -z "$VERSIONING" ] || [ "$VERSIONING" = "{}" ]; then
        echo "Versioning: Disabled"
    else
        echo "$VERSIONING" | jq -r '"Versioning: " + (.Status // "Disabled")'
        echo "$VERSIONING" | jq -r 'if .MFADelete then "MFA Delete: " + .MFADelete else "" end' | grep -v '^$'
    fi
    
    # Get lifecycle configuration
    echo -e "\n${GREEN}Lifecycle Rules:${NC}"
    LIFECYCLE=$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$REGION" 2>&1)
    if echo "$LIFECYCLE" | grep -q "NoSuchLifecycleConfiguration"; then
        echo "No lifecycle rules configured"
    else
        echo "$LIFECYCLE" | jq -r '.Rules[] | "- Rule ID: " + .ID + " (Status: " + .Status + ")"' 2>/dev/null || echo "Could not parse lifecycle rules"
    fi
}

# Function to enable versioning (required for deleted object retention)
enable_versioning() {
    echo -e "\n${YELLOW}Enabling versioning on bucket...${NC}"
    if aws s3api put-bucket-versioning \
        --bucket "$BUCKET" \
        --versioning-configuration Status=Enabled \
        --endpoint-url "$ENDPOINT" \
        --region "$REGION"; then
        echo -e "${GREEN}✓ Versioning enabled successfully${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to enable versioning${NC}"
        return 1
    fi
}

# Function to set up lifecycle rule for deleted objects
setup_lifecycle_rule() {
    echo -e "\n${YELLOW}Setting up lifecycle rule for 60-day retention of deleted objects...${NC}"
    
    # First, check if there are existing lifecycle rules
    echo -e "${YELLOW}Checking for existing lifecycle rules...${NC}"
    EXISTING_RULES=$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$REGION" 2>&1)
    
    if echo "$EXISTING_RULES" | grep -q "NoSuchLifecycleConfiguration"; then
        echo -e "${GREEN}No existing lifecycle rules found. Creating new configuration...${NC}"
        # Create new lifecycle configuration
        cat > /tmp/lifecycle-config.json << 'EOF'
{
    "Rules": [
        {
            "ID": "DeletedObjectsRetention60Days",
            "Status": "Enabled",
            "Filter": {},
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 60
            },
            "AbortIncompleteMultipartUpload": {
                "DaysAfterInitiation": 7
            }
        }
    ]
}
EOF
    else
        echo -e "${YELLOW}Found existing lifecycle rules. Merging with new rule...${NC}"
        # Parse existing rules and add our new rule
        echo "$EXISTING_RULES" | jq '.Rules += [{
            "ID": "DeletedObjectsRetention60Days",
            "Status": "Enabled",
            "Filter": {},
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 60
            },
            "AbortIncompleteMultipartUpload": {
                "DaysAfterInitiation": 7
            }
        }] | {Rules: (.Rules | map(select(.ID != "DeletedObjectsRetention60Days")) + [.Rules[] | select(.ID == "DeletedObjectsRetention60Days")] | unique_by(.ID))}' > /tmp/lifecycle-config.json
        
        # Show what will be applied
        echo -e "${YELLOW}New lifecycle configuration:${NC}"
        cat /tmp/lifecycle-config.json | jq .
    fi

    # Apply lifecycle configuration
    if aws s3api put-bucket-lifecycle-configuration \
        --bucket "$BUCKET" \
        --lifecycle-configuration file:///tmp/lifecycle-config.json \
        --endpoint-url "$ENDPOINT" \
        --region "$REGION" 2>&1; then
        echo -e "${GREEN}✓ Lifecycle rule created successfully${NC}"
        echo -e "${GREEN}  - Deleted objects will be retained for 60 days${NC}"
        echo -e "${GREEN}  - Incomplete multipart uploads will be cleaned up after 7 days${NC}"
        rm -f /tmp/lifecycle-config.json
        return 0
    else
        echo -e "${RED}✗ Failed to create lifecycle rule${NC}"
        echo -e "${RED}Error details:${NC}"
        aws s3api put-bucket-lifecycle-configuration \
            --bucket "$BUCKET" \
            --lifecycle-configuration file:///tmp/lifecycle-config.json \
            --endpoint-url "$ENDPOINT" \
            --region "$REGION" 2>&1
        
        # Try a simpler configuration
        echo -e "\n${YELLOW}Trying simpler configuration...${NC}"
        cat > /tmp/lifecycle-config-simple.json << 'EOF'
{
    "Rules": [
        {
            "ID": "DeletedObjectsRetention60Days",
            "Status": "Enabled",
            "Filter": {"Prefix": ""},
            "NoncurrentVersionExpiration": {
                "NoncurrentDays": 60
            }
        }
    ]
}
EOF
        
        if aws s3api put-bucket-lifecycle-configuration \
            --bucket "$BUCKET" \
            --lifecycle-configuration file:///tmp/lifecycle-config-simple.json \
            --endpoint-url "$ENDPOINT" \
            --region "$REGION"; then
            echo -e "${GREEN}✓ Lifecycle rule created successfully with simplified configuration${NC}"
            rm -f /tmp/lifecycle-config-simple.json
            return 0
        else
            echo -e "${RED}✗ Still failed with simplified configuration${NC}"
            rm -f /tmp/lifecycle-config-simple.json
            return 1
        fi
        
        rm -f /tmp/lifecycle-config.json
        return 1
    fi
}

# Function to list deleted files (noncurrent versions)
list_deleted_files() {
    echo -e "\n${YELLOW}Listing deleted files (noncurrent versions)...${NC}"
    echo -e "${YELLOW}================================================${NC}\n"
    
    # Get all object versions
    VERSIONS=$(aws s3api list-object-versions \
        --bucket "$BUCKET" \
        --endpoint-url "$ENDPOINT" \
        --region "$REGION" 2>/dev/null)
    
    if [ -z "$VERSIONS" ] || [ "$VERSIONS" = "{}" ]; then
        echo -e "${YELLOW}No versions found in bucket.${NC}"
        return
    fi
    
    # Check if there are any delete markers or noncurrent versions
    DELETE_MARKERS=$(echo "$VERSIONS" | jq -r '.DeleteMarkers // []')
    NONCURRENT=$(echo "$VERSIONS" | jq -r '.Versions // [] | map(select(.IsLatest == false))')
    
    if [ "$DELETE_MARKERS" = "[]" ] && [ "$NONCURRENT" = "[]" ]; then
        echo -e "${GREEN}No deleted files found.${NC}"
        echo -e "${GREEN}All objects in the bucket are current versions.${NC}"
        return
    fi
    
    # Display delete markers
    if [ "$DELETE_MARKERS" != "[]" ]; then
        echo -e "${RED}Files with delete markers (deleted but recoverable):${NC}"
        echo -e "${RED}----------------------------------------------------${NC}"
        echo "$VERSIONS" | jq -r '.DeleteMarkers[] | 
            "  File: " + .Key + 
            "\n  Deleted on: " + .LastModified + 
            "\n  Version ID: " + .VersionId + 
            "\n  Delete Marker ID: " + .VersionId + 
            "\n"'
    fi
    
    # Display noncurrent versions
    if [ "$NONCURRENT" != "[]" ]; then
        echo -e "${YELLOW}Noncurrent versions (old versions of modified files):${NC}"
        echo -e "${YELLOW}----------------------------------------------------${NC}"
        echo "$VERSIONS" | jq -r '.Versions[] | select(.IsLatest == false) | 
            "  File: " + .Key + 
            "\n  Modified: " + .LastModified + 
            "\n  Size: " + (.Size | tostring) + " bytes" +
            "\n  Version ID: " + .VersionId + 
            "\n  Storage Class: " + .StorageClass + 
            "\n"'
    fi
    
    # Count total deleted/noncurrent objects
    TOTAL_DELETE_MARKERS=$(echo "$VERSIONS" | jq -r '.DeleteMarkers // [] | length')
    TOTAL_NONCURRENT=$(echo "$VERSIONS" | jq -r '.Versions // [] | map(select(.IsLatest == false)) | length')
    TOTAL=$((TOTAL_DELETE_MARKERS + TOTAL_NONCURRENT))
    
    echo -e "${YELLOW}Summary:${NC}"
    echo -e "  Total deleted files (delete markers): $TOTAL_DELETE_MARKERS"
    echo -e "  Total noncurrent versions: $TOTAL_NONCURRENT"
    echo -e "  ${GREEN}Total recoverable objects: $TOTAL${NC}"
    
    if [ "$TOTAL" -gt 0 ]; then
        echo -e "\n${YELLOW}Note:${NC} These files will be automatically removed after 60 days according to your lifecycle policy."
        echo -e "${YELLOW}To restore a deleted file, use:${NC}"
        echo -e "  aws s3api delete-object --bucket $BUCKET --key <filename> --version-id <delete-marker-id> --endpoint-url $ENDPOINT"
    fi
}

# Main execution
if check_bucket; then
    if [ "$LIST_DELETED" = true ]; then
        list_deleted_files
    else
    show_bucket_info
    
    echo -e "\n${YELLOW}Do you want to set up 60-day retention for deleted objects? (y/n)${NC}"
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        # Check if versioning is enabled
        VERSIONING_STATUS=$(aws s3api get-bucket-versioning --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$REGION" 2>/dev/null | jq -r '.Status // "Disabled"')
        
        if [ "$VERSIONING_STATUS" != "Enabled" ]; then
            echo -e "\n${YELLOW}Note: Versioning must be enabled to retain deleted objects.${NC}"
            echo -e "${YELLOW}Do you want to enable versioning? (y/n)${NC}"
            read -r enable_vers
            
            if [[ "$enable_vers" =~ ^[Yy]$ ]]; then
                if enable_versioning; then
                    setup_lifecycle_rule
                else
                    echo -e "${RED}Cannot proceed without versioning enabled.${NC}"
                fi
            else
                echo -e "${RED}Cannot set up deleted object retention without versioning.${NC}"
            fi
        else
            setup_lifecycle_rule
        fi
        
        # Show updated settings
        echo -e "\n${YELLOW}Updated bucket settings:${NC}"
        show_bucket_info
    fi
    fi
else
    exit 1
fi
