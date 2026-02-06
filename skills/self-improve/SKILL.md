# Self-Improve Skill

Tu as la capacite de t'auto-ameliorer en modifiant ton propre code source.

## Architecture

Tu tournes dans un container Cloudflare avec cette stack :
- **Worker**: `moltworker` sur `molt.colombani.ai`
- **Container**: `moltworker-sandbox` (4 vCPU, 12 Go RAM)
- **Repo GitHub**: `https://github.com/music-music/moltworker-fork`
- **Config**: `/root/.clawdbot/clawdbot.json`

## Fichiers importants

| Fichier | Role |
|---------|------|
| `Dockerfile` | Definit les outils installes dans le container |
| `start-moltbot.sh` | Script de demarrage, configure clawdbot.json |
| `src/gateway/env.ts` | Variables d'env passees au container |
| `src/types.ts` | Types TypeScript des variables d'env |
| `skills/` | Dossier des skills (dont celui-ci) |

## Comment t'ameliorer

### 1. Cloner le repo
```bash
cd /root/clawd
gh repo clone music-music/moltworker-fork
cd moltworker-fork
```

### 2. Modifier ce dont tu as besoin
- **Nouveau package Python** → Modifier `Dockerfile` ligne ~35
- **Nouveau package Node** → Modifier `Dockerfile` ligne ~60
- **Nouvelle variable d'env** → Modifier `src/types.ts` et `src/gateway/env.ts`
- **Nouveau skill** → Creer un dossier dans `skills/`
- **Config clawdbot** → Modifier `start-moltbot.sh`

### 3. Commit et push
```bash
git add .
git commit -m "Description du changement"
git push origin main
```

### 4. Notifier l'utilisateur
Apres le push, dis a l'utilisateur :
> "J'ai push les modifications sur GitHub. Pour les appliquer, va sur https://molt.colombani.ai et clique sur **Restart Gateway** dans Overview. Ou dis-moi de le faire si tu m'as donne le CLOUDFLARE_API_TOKEN."

## Outils disponibles

### CLI
- `gh` - GitHub CLI (authentifie via GH_TOKEN)
- `git` - Git
- `wrangler` - Cloudflare Workers CLI
- `vercel` - Vercel CLI
- `aws` - AWS CLI
- `huggingface-cli` - Hugging Face CLI

### Python
- `huggingface_hub`, `transformers`, `datasets` - ML/AI
- `anthropic`, `openai`, `replicate`, `modal` - APIs AI
- `jupyter`, `papermill`, `nbconvert` - Notebooks
- `playwright` - Automation web
- `gitpython` - Git en Python

### Secrets disponibles (env vars)
- `GITHUB_TOKEN` / `GH_TOKEN` - Push sur GitHub
- `NVIDIA_API_KEY` - NVIDIA NIM (LLM + Whisper)
- `ELEVENLABS_API_KEY` - TTS
- `TELEGRAM_BOT_TOKEN` - Telegram
- `HF_TOKEN` - Hugging Face (si configure)
- `CLOUDFLARE_API_TOKEN` - Deploy direct (si configure)

## Exemples d'ameliorations

### Ajouter un package Python
```dockerfile
# Dans Dockerfile, ajouter a la liste pip install:
    scipy numpy pandas \
```

### Ajouter un nouveau skill
```bash
mkdir -p skills/mon-nouveau-skill
cat > skills/mon-nouveau-skill/SKILL.md << 'EOF'
# Mon Nouveau Skill
Description de ce que fait ce skill...
EOF
```

### Ajouter une nouvelle variable d'env
1. `src/types.ts` : ajouter le type
2. `src/gateway/env.ts` : passer la variable au container
3. `start-moltbot.sh` : utiliser la variable dans la config

## Regles

1. **Toujours tester localement** si possible avant de push
2. **Faire des commits atomiques** avec des messages clairs
3. **Ne jamais supprimer de fonctionnalites existantes** sans demander
4. **Prevenir l'utilisateur** avant tout push
5. **Documenter les changements** dans le commit message
