FROM node:20-alpine

WORKDIR /app

# Non-root user — mirrors the pattern used in the project's other containers
RUN addgroup -g 1001 -S appgroup && \
    adduser -S appuser -u 1001 -G appgroup

# Install deps before copying source so layer is cached on code-only changes
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src/ ./src/

# Ensure the non-root user owns the workdir
RUN chown -R appuser:appgroup /app

USER appuser

EXPOSE 3457

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -q -O- http://localhost:3457/health || exit 1

CMD ["node", "src/index.js"]
