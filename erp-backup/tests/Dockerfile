# Test harness for erp-backup-kit.sh: a Linux userland with the tools an Umbrel box has, driving real
# ERPNext containers through the host's docker socket. Not used on the boxes themselves.
FROM docker:27.3.1-cli
RUN apk add --no-cache bash coreutils findutils rsync python3 openssh-client util-linux age tar gzip \
        curl grep sed gawk procps iproute2 diffutils
COPY systemctl-stub.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl
WORKDIR /t
