FROM docker.io/cloudflare/sandbox:0.7.0

# Install Node.js 22, Python 3.13, media tools, dev tools, rclone
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
    xz-utils ca-certificates rclone \
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
    && npm --version \
    && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/*

# Install Python packages (AI, audio, web, media, cloud, dev tools)
RUN pip install --no-cache-dir \
    openai anthropic \
    huggingface_hub transformers datasets \
    replicate modal \
    pydub librosa soundfile \
    httpx requests beautifulsoup4 lxml \
    websockets aiohttp playwright \
    yt-dlp Pillow pytesseract \
    sendgrid \
    jupyter papermill nbconvert ipykernel \
    awscli \
    python-dotenv psutil rich pyyaml markdown gitpython \
    && rm -rf /root/.cache/pip

# Install Playwright browsers for web automation
RUN playwright install chromium && playwright install-deps chromium \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install pnpm globally
RUN npm install -g pnpm

# Install OpenClaw — latest version
RUN npm install -g openclaw@2026.2.9 \
    && openclaw --version

# Create OpenClaw directories
RUN mkdir -p /root/.openclaw \
    && mkdir -p /root/clawd \
    && mkdir -p /root/clawd/skills

# Copy startup script
# Build cache bust: 2026-02-12-v2-brave-key
COPY start-openclaw.sh /usr/local/bin/start-openclaw.sh
RUN chmod +x /usr/local/bin/start-openclaw.sh

# Copy custom skills
COPY skills/ /root/clawd/skills/

# Set working directory
WORKDIR /root/clawd

# Expose the gateway port
EXPOSE 18789
