#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config/workspace/skills from R2 via rclone (if configured)
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts a background sync loop (rclone, watches for file changes)
# 5. Starts the gateway
# cache-bust: 2026-02-12-v5-models-merge

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# RCLONE SETUP
# ============================================================

r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}

R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"

setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}

RCLONE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket"

# ============================================================
# RESTORE FROM R2
# ============================================================

if r2_configured; then
    setup_rclone

    echo "Checking R2 for existing backup..."
    # Check if R2 has an openclaw config backup
    if rclone ls "r2:${R2_BUCKET}/openclaw/openclaw.json" $RCLONE_FLAGS 2>/dev/null | grep -q openclaw.json; then
        echo "Restoring config from R2..."
        rclone copy "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: config restore failed with exit code $?"
        echo "Config restored"
    elif rclone ls "r2:${R2_BUCKET}/clawdbot/clawdbot.json" $RCLONE_FLAGS 2>/dev/null | grep -q clawdbot.json; then
        echo "Restoring from legacy R2 backup..."
        rclone copy "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: legacy config restore failed with exit code $?"
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Legacy config restored and migrated"
    else
        echo "No backup found in R2, starting fresh"
    fi

    # Restore workspace
    REMOTE_WS_COUNT=$(rclone ls "r2:${R2_BUCKET}/workspace/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_WS_COUNT" -gt 0 ]; then
        echo "Restoring workspace from R2 ($REMOTE_WS_COUNT files)..."
        mkdir -p "$WORKSPACE_DIR"
        rclone copy "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: workspace restore failed with exit code $?"
        echo "Workspace restored"
    fi

    # Restore skills
    REMOTE_SK_COUNT=$(rclone ls "r2:${R2_BUCKET}/skills/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_SK_COUNT" -gt 0 ]; then
        echo "Restoring skills from R2 ($REMOTE_SK_COUNT files)..."
        mkdir -p "$SKILLS_DIR"
        rclone copy "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: skills restore failed with exit code $?"
        echo "Skills restored"
    fi
else
    echo "R2 not configured, starting fresh"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    # NVIDIA NIM: skip onboard (validates against api.openai.com, fails with nvapi- keys)
    if [ -n "$NVIDIA_API_KEY" ]; then
        echo "NVIDIA NIM detected, creating base config (skipping onboard)..."
        echo '{"gateway":{"port":18789,"mode":"local"}}' > "$CONFIG_FILE"
        echo "Base config created"
    else
        echo "No existing config found, running openclaw onboard..."

        AUTH_ARGS=""
        if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
            AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
                --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
                --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
                --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
        elif [ -n "$ANTHROPIC_API_KEY" ]; then
            AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
        elif [ -n "$OPENAI_API_KEY" ]; then
            AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
        fi

        openclaw onboard --non-interactive --accept-risk \
            --mode local \
            $AUTH_ARGS \
            --gateway-port 18789 \
            --gateway-bind lan \
            --skip-channels \
            --skip-skills \
            --skip-health

        echo "Onboard completed"
    fi
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// NVIDIA NIM (OPENAI_BASE_URL pointing to nvidia.com)
// Skipped if CF_AI_GATEWAY_MODEL is set (AI Gateway takes precedence)
if (!process.env.CF_AI_GATEWAY_MODEL && process.env.OPENAI_BASE_URL && process.env.OPENAI_BASE_URL.includes('nvidia.com')) {
    const baseUrl = process.env.OPENAI_BASE_URL.replace(/\/+$/, '');
    const apiKey = process.env.OPENAI_API_KEY || '';
    config.models = config.models || {};
    config.models.mode = 'merge';
    config.models.providers = config.models.providers || {};
    config.models.providers.nvidia = {
        baseUrl: baseUrl,
        apiKey: apiKey,
        api: 'openai-completions',
        models: [
            { id: 'deepseek-ai/deepseek-v3.2', name: 'DeepSeek V3.2 (685B)', reasoning: false,
              input: ['text'], contextWindow: 128000, maxTokens: 8192 },
            { id: 'moonshotai/kimi-k2.5', name: 'Kimi K2.5 (1T MoE)', reasoning: false,
              input: ['text'], contextWindow: 256000, maxTokens: 32768 },
            { id: 'nvidia/nemotron-3-nano-30b-a3b', name: 'Nemotron Nano 30B (1M ctx)', reasoning: false,
              input: ['text'], contextWindow: 1000000, maxTokens: 32768 },
            { id: 'z-ai/glm4.7', name: 'GLM 4.7 (tool calling)', reasoning: false,
              input: ['text'], contextWindow: 131072, maxTokens: 16384 },
            { id: 'qwen/qwen3-next-80b-a3b-instruct', name: 'Qwen3 Next 80B', reasoning: false,
              input: ['text'], contextWindow: 262144, maxTokens: 16384 },
            { id: 'deepseek-ai/deepseek-v3.1-terminus', name: 'DeepSeek V3.1 Terminus (tool calling)', reasoning: false,
              input: ['text'], contextWindow: 128000, maxTokens: 8192 },
        ],
    };
    // Default to DeepSeek V3.2 — best overall quality
    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    config.agents.defaults.model = { primary: 'nvidia/deepseek-ai/deepseek-v3.2' };
    // Model allowlist (required for custom providers)
    config.agents.defaults.models = config.agents.defaults.models || {};
    config.agents.defaults.models['nvidia/deepseek-ai/deepseek-v3.2'] = {};
    config.agents.defaults.models['nvidia/moonshotai/kimi-k2.5'] = {};
    config.agents.defaults.models['nvidia/nvidia/nemotron-3-nano-30b-a3b'] = {};
    config.agents.defaults.models['nvidia/z-ai/glm4.7'] = {};
    config.agents.defaults.models['nvidia/qwen/qwen3-next-80b-a3b-instruct'] = {};
    config.agents.defaults.models['nvidia/deepseek-ai/deepseek-v3.1-terminus'] = {};

    // Disable compaction — NVIDIA NIM hangs on summarization calls (openclaw#5980)
    delete config.agents.defaults.compaction;

    console.log('NVIDIA NIM provider configured with', 6, 'models via', baseUrl);
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

// ElevenLabs TTS
if (process.env.ELEVENLABS_API_KEY) {
    config.messages = config.messages || {};
    config.messages.tts = {
        auto: 'inbound',
        provider: 'elevenlabs',
        elevenlabs: {
            apiKey: process.env.ELEVENLABS_API_KEY,
            voiceId: 'pMsXgVXv3BLzUgSXRplE',
            modelId: 'eleven_multilingual_v2',
            voiceSettings: { stability: 0.5, similarityBoost: 0.75, style: 0.0, useSpeakerBoost: true, speed: 1.0 },
        },
    };
    console.log('ElevenLabs TTS configured');
}

// Clean up keys not recognized by OpenClaw v2026.2.9 (may exist in R2 backup)
if (config.agents && config.agents.defaults) {
    delete config.agents.defaults.mcp;
}
if (config.tools && config.tools.web && config.tools.web.fetch) {
    delete config.tools.web.fetch.readability;
}

// Tool profile: full (enable all built-in tools)
config.tools = config.tools || {};
config.tools.profile = 'full';

// Web fetch (no API key needed)
config.tools.web = config.tools.web || {};
config.tools.web.fetch = { enabled: true, maxChars: 50000 };

// Web search (Brave)
if (process.env.BRAVE_API_KEY) {
    config.tools.web.search = {
        enabled: true,
        provider: 'brave',
        apiKey: process.env.BRAVE_API_KEY,
        maxResults: 5,
    };
    console.log('Brave web search enabled');
}

console.log('Tools configured: profile=full, web fetch/search');

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# BACKGROUND SYNC LOOP
# ============================================================
if r2_configured; then
    echo "Starting background R2 sync loop..."
    (
        MARKER=/tmp/.last-sync-marker
        LOGFILE=/tmp/r2-sync.log
        touch "$MARKER"

        while true; do
            sleep 30

            CHANGED=/tmp/.changed-files
            {
                find "$CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
                find "$WORKSPACE_DIR" -newer "$MARKER" \
                    -not -path '*/node_modules/*' \
                    -not -path '*/.git/*' \
                    -type f -printf '%P\n' 2>/dev/null
            } > "$CHANGED"

            COUNT=$(wc -l < "$CHANGED" 2>/dev/null || echo 0)

            if [ "$COUNT" -gt 0 ]; then
                echo "[sync] Uploading changes ($COUNT files) at $(date)" >> "$LOGFILE"
                rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
                    $RCLONE_FLAGS --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' 2>> "$LOGFILE"
                if [ -d "$WORKSPACE_DIR" ]; then
                    rclone sync "$WORKSPACE_DIR/" "r2:${R2_BUCKET}/workspace/" \
                        $RCLONE_FLAGS --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' 2>> "$LOGFILE"
                fi
                if [ -d "$SKILLS_DIR" ]; then
                    rclone sync "$SKILLS_DIR/" "r2:${R2_BUCKET}/skills/" \
                        $RCLONE_FLAGS 2>> "$LOGFILE"
                fi
                date -Iseconds > "$LAST_SYNC_FILE"
                touch "$MARKER"
                echo "[sync] Complete at $(date)" >> "$LOGFILE"
            fi
        done
    ) &
    echo "Background sync loop started (PID: $!)"
fi

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
fi
