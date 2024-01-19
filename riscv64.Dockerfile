FROM --platform=linux/riscv64 ghcr.io/go-riscv/distroless/static-unstable@sha256:5bff20496c00bdee4a69765eaac97728a16b07f35b053536038ac9d805074908

ADD etcd /usr/local/bin/
ADD etcdctl /usr/local/bin/
ADD etcdutl /usr/local/bin/

WORKDIR /var/etcd/
WORKDIR /var/lib/etcd/

EXPOSE 2379 2380

# Define default command.
CMD ["/usr/local/bin/etcd"]
