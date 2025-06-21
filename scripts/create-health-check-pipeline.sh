#!/bin/bash
set -euo pipefail

# Script to create/update the agent health check pipeline in Buildkite

PIPELINE_SLUG="agent-vm-health-check"
PIPELINE_NAME="Agent VM Health Check"
SCHEDULE_CRON="*/5 * * * *"  # Every 5 minutes

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Create pipeline configuration
create_pipeline_config() {
    cat << 'EOF'
{
  "name": "Agent VM Health Check",
  "description": "Periodic health check for agent VM image availability",
  "repository": "https://github.com/build-archetype/client-oven-sh-bun.git",
  "branch_configuration": "feat/self-hosted-mac-ci-with-tart",
  "cancel_running_builds_on_new_build": true,
  "skip_intermediate_builds": true,
  "provider_settings": {
    "trigger_mode": "none"
  },
  "steps": [
    {
      "type": "script",
      "name": "🩺 Agent VM Health Check",
      "command": [
        "echo 'Running VM health check on agent...'",
        "./scripts/agent-vm-health-check.sh check"
      ],
      "agents": {
        "queue": "darwin"
      },
      "timeout_in_minutes": 5,
      "retry": {
        "automatic": false
      },
      "parallelism": 10
    },
    {
      "type": "script", 
      "name": "📊 Health Check Summary",
      "command": [
        "echo '=== HEALTH CHECK SUMMARY ==='",
        "echo 'All agents have completed health checks'", 
        "echo 'Check individual agent meta-data in Buildkite UI'",
        "echo ''",
        "echo 'To view agent status manually:'",
        "echo './scripts/agent-vm-health-check.sh status'"
      ],
      "agents": {
        "queue": "darwin"
      },
      "depends_on": [
        {
          "step": "🩺 Agent VM Health Check"
        }
      ]
    }
  ]
}
EOF
}

# Create schedule configuration  
create_schedule_config() {
    cat << EOF
{
  "cronline": "$SCHEDULE_CRON",
  "label": "Every 5 minutes",
  "message": "Automatic agent VM health check",
  "env": {
    "HEALTH_CHECK_AUTOMATED": "true"
  },
  "branch": "feat/self-hosted-mac-ci-with-tart"
}
EOF
}

log "=== AGENT VM HEALTH CHECK PIPELINE SETUP ==="

echo "This script helps you set up the agent health check pipeline."
echo ""
echo "📋 What this creates:"
echo "  • Pipeline: '$PIPELINE_NAME'"
echo "  • Schedule: Every 5 minutes ($SCHEDULE_CRON)"
echo "  • Targets: All darwin queue agents"
echo "  • Action: Updates agent vm-ready-macos-X tags"
echo ""

# Show the configurations
log "Pipeline Configuration:"
create_pipeline_config | jq .

log "Schedule Configuration:"  
create_schedule_config | jq .

echo ""
echo "🛠️  Setup Instructions:"
echo ""
echo "1. Create the pipeline in Buildkite:"
echo "   - Go to your Buildkite organization"
echo "   - Click 'New Pipeline'"
echo "   - Use the pipeline configuration above"
echo ""
echo "2. Add the schedule:"
echo "   - Go to pipeline Settings > Schedules"
echo "   - Click 'New Schedule'"
echo "   - Use the schedule configuration above"
echo ""
echo "3. Alternative - API Setup:"
echo "   If you have Buildkite API access:"
echo "   export BUILDKITE_API_TOKEN='your-token'"
echo "   export BUILDKITE_ORG='your-org'"
echo "   $0 --create-api"
echo ""

# API creation option
if [ "${1:-}" = "--create-api" ]; then
    if [ -z "${BUILDKITE_API_TOKEN:-}" ] || [ -z "${BUILDKITE_ORG:-}" ]; then
        echo "❌ Error: BUILDKITE_API_TOKEN and BUILDKITE_ORG must be set for API creation"
        exit 1
    fi
    
    log "Creating pipeline via API..."
    
    # Create pipeline
    create_pipeline_config > /tmp/pipeline.json
    curl -X POST \
        -H "Authorization: Bearer $BUILDKITE_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d @/tmp/pipeline.json \
        "https://api.buildkite.com/v2/organizations/$BUILDKITE_ORG/pipelines"
    
    log "Pipeline created. Now creating schedule..."
    
    # Create schedule  
    create_schedule_config > /tmp/schedule.json
    curl -X POST \
        -H "Authorization: Bearer $BUILDKITE_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d @/tmp/schedule.json \
        "https://api.buildkite.com/v2/organizations/$BUILDKITE_ORG/pipelines/$PIPELINE_SLUG/schedules"
    
    log "✅ Health check pipeline and schedule created!"
    
    # Cleanup
    rm -f /tmp/pipeline.json /tmp/schedule.json
fi

log "=== SETUP COMPLETE ==="
echo ""
echo "🎯 Once deployed, this pipeline will:"
echo "  • Run every 5 minutes automatically"
echo "  • Check VM availability on all agents" 
echo "  • Update agent meta-data tags"
echo "  • Provide visibility into agent health"
echo ""
echo "🔍 Monitor via:"
echo "  • Buildkite pipeline view"
echo "  • Agent meta-data in Buildkite UI"
echo "  • Manual check: ./scripts/agent-vm-health-check.sh status" 