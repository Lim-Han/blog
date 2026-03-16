# Stage 1: Build Environment (로컬과 동일한 0.146.0 버전 강제 프로비저닝)
FROM debian:bookworm-slim AS builder
WORKDIR /app

# 필수 패키지 설치 및 Hugo Extended 바이너리 다운로드 (의존성 지연 원천 차단)
RUN apt-get update && apt-get install -y wget ca-certificates && \
    wget https://github.com/gohugoio/hugo/releases/download/v0.146.0/hugo_extended_0.146.0_linux-amd64.tar.gz && \
    tar -zxvf hugo_extended_0.146.0_linux-amd64.tar.gz && \
    mv hugo /usr/local/bin/hugo && \
    chmod +x /usr/local/bin/hugo

# 소스코드 및 서브모듈 복사 후 정적 빌드
COPY . .
RUN hugo --minify

# Stage 2: Runtime Environment (Production - 변경 없음)
FROM nginx:alpine
COPY ./nginx.conf /etc/nginx/nginx.conf
COPY --from=builder /app/public /usr/share/nginx/html
EXPOSE 80
