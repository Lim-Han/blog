# Stage 1: Build Environment
FROM klakegg/hugo:ext-alpine AS builder
WORKDIR /app
# 소스코드와 서브모듈(Theme) 복사
COPY . . 
# 정적 아티팩트 빌드 (public 폴더 생성)
RUN hugo --minify

# Stage 2: Runtime Environment (Production)
FROM nginx:alpine
# SRE 관점: 불필요한 OS 패키지가 없는 Alpine 리눅스를 사용하여 공격 표면(Attack Surface) 최소화
COPY ./nginx.conf /etc/nginx/nginx.conf
# Builder 스테이지에서 생성된 순수 HTML/CSS 결과물만 Nginx 서빙 폴더로 복사
COPY --from=builder /app/public /usr/share/nginx/html

EXPOSE 80