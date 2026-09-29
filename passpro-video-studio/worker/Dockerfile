# PassPro Video Studio — FFmpeg render worker (Railway).
# Build context: passpro-video-studio/   (railway.json points here)
# Holds ONLY Supabase service credentials. Refuses to start with AI keys.
FROM node:22-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg fonts-dejavu-core \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json ./
COPY src/core ./src/core
COPY src/worker ./src/worker

ENV NODE_ENV=production
USER node
CMD ["node", "src/worker/main.ts"]
