FROM node:20-alpine

WORKDIR /app
COPY package.json server.js dashboard.html ./

USER node
EXPOSE 9000
CMD ["node", "server.js"]
