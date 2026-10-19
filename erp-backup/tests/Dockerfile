# Test harness for erp-backup-kit.sh: a Linux userland with the tools an Umbrel box has, driving real
# ERPNext containers through the host's docker socket. Not used on the boxes themselves.
# rrsync is upstream rsync's support/rrsync at v3.2.7 - the version Debian 12 (and so the Umbrels) ship - pinned by
# checksum, so pushes in the tests go through the real write-only jail (fake-ssh.sh stands in for ssh).
FROM docker:27.3.1-cli
RUN apk add --no-cache bash coreutils findutils rsync python3 openssh-client util-linux age tar gzip \
        curl grep sed gawk procps iproute2 diffutils
RUN curl -fsSL -o /usr/bin/rrsync https://raw.githubusercontent.com/RsyncProject/rsync/v3.2.7/support/rrsync \
 && echo "cb46c1bf89c25e1193eb16e9201405bc0e39d2c2d03bff42d3cee86ef15e3050  /usr/bin/rrsync" | sha256sum -c - && chmod +x /usr/bin/rrsync
COPY systemctl-stub.sh /usr/local/bin/systemctl
COPY fake-ssh.sh /usr/local/bin/fake-ssh
RUN chmod +x /usr/local/bin/systemctl /usr/local/bin/fake-ssh
WORKDIR /t
