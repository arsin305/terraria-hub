FROM node:18-alpine
RUN apk add --no-cache docker-cli python3 make g++
WORKDIR /app
COPY package.json .
RUN npm install
COPY app.js .
COPY public/ public/
EXPOSE 3001
CMD ["node", "app.js"]
