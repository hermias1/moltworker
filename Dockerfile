FROM docker.io/cloudflare/sandbox:0.7.0

# Install Node.js 22 (required by clawdbot) and rsync (for R2 backup sync)
# The base image has Node 20, we need to replace it with Node 22
# Using direct binary download for reliability
ENV NODE_VERSION=22.13.1
RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
         amd64) NODE_ARCH="x64" ;; \
         arm64) NODE_ARCH="arm64" ;; \
         *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
       esac \
    && apt-get update && apt-get install -y software-properties-common \
    && add-apt-repository -y ppa:deadsnakes/ppa \
    && apt-get update && apt-get install -y \
    xz-utils ca-certificates rsync \
    python3.13 python3.13-venv python3.13-dev \
    ffmpeg sox libsox-fmt-all \
    gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly \
    git vim nano htop strace \
    curl wget jq unzip zip lsof \
    gh \
    build-essential libffi-dev libssl-dev \
    imagemagick poppler-utils tesseract-ocr \
    && update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.13 1 \
    && update-alternatives --install /usr/bin/python python /usr/bin/python3.13 1 \
    && curl -sS https://bootstrap.pypa.io/get-pip.py | python3.13 \
    && curl -fsSLk https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

# Install Python packages (AI, audio, web, media, cloud, dev tools)
RUN pip install --no-cache-dir \
    nvidia-riva-client openai anthropic \
    huggingface_hub transformers datasets \
    replicate modal \
    pydub librosa soundfile \
    httpx requests beautifulsoup4 lxml \
    websockets aiohttp playwright \
    yt-dlp Pillow pytesseract \
    sendgrid \
    jupyter papermill nbconvert ipykernel \
    awscli \
    python-dotenv psutil rich pyyaml markdown gitpython

# Install Playwright browsers for web automation
RUN playwright install chromium && playwright install-deps chromium

# Install Node.js global packages (pnpm, wrangler for Cloudflare deploys)
RUN npm install -g pnpm wrangler vercel

# Install moltbot (CLI is still named clawdbot until upstream renames)
# Pin to specific version for reproducible builds
RUN npm install -g clawdbot@2026.1.24-3 \
    && clawdbot --version \
    && find /usr/local/lib/node_modules/clawdbot -name "*.sh" -exec chmod +x {} \;

# Create moltbot directories (paths still use clawdbot until upstream renames)
# Templates are stored in /root/.clawdbot-templates for initialization
RUN mkdir -p /root/.clawdbot \
    && mkdir -p /root/.clawdbot-templates \
    && mkdir -p /root/clawd \
    && mkdir -p /root/clawd/skills

# Copy startup script
# Build cache bust: 2026-01-28-v26-browser-skill
COPY start-moltbot.sh /usr/local/bin/start-moltbot.sh
RUN chmod +x /usr/local/bin/start-moltbot.sh

# Copy default configuration template
COPY moltbot.json.template /root/.clawdbot-templates/moltbot.json.template

# Copy custom skills
COPY skills/ /root/clawd/skills/

# Set working directory
WORKDIR /root/clawd

# Expose the gateway port
EXPOSE 18789
