FROM node:22-alpine
WORKDIR /app 
COPY app/package*.json ./
RUN npm ci --omit=dev
COPY app/ ./
USER node
ENV PORT=3000
EXPOSE 3000
CMD ["node", "does-not-exist.js"]