<!-- SPDX-License-Identifier: Apache-2.0 -->
# Signet

[![ci](https://github.com/chanuk-park/Signet/actions/workflows/ci.yml/badge.svg)](https://github.com/chanuk-park/Signet/actions/workflows/ci.yml)
[![license](https://github.com/chanuk-park/Signet/actions/workflows/license.yml/badge.svg)](https://github.com/chanuk-park/Signet/actions/workflows/license.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Go](https://img.shields.io/badge/Go-1.24+-00ADD8.svg)](https://go.dev/)
[![SPIFFE](https://img.shields.io/badge/SPIFFE-SPIRE-4F46E5.svg)](https://spiffe.io/)
[![DTLS](https://img.shields.io/badge/DTLS-1.2-2E7D32.svg)](https://github.com/pion/dtls)
[![5G](https://img.shields.io/badge/5G-N4_PFCP-E4572E.svg)](https://www.3gpp.org/)

SPIFFE/SPIRE **mutually-authenticated DTLS for the 5G N4 interface** (PFCP between SMF and UPF), without modifying the network function.

> A signet ring sealed a letter and proved who sent it. Signet does the same for N4: every PFCP packet travels sealed in DTLS, under a SPIFFE identity the far end verifies.

Both ends present an X509-SVID issued by SPIRE and authorize each other by SPIFFE ID. The network function keeps its image, configuration and command line, and the PFCP payload is never rewritten: a sidecar in the NF's network namespace takes the NF's own N4 traffic into a DTLS session and delivers it on the far side.

```
        SMF pod                                            UPF pod
 ┌───────────────────────┐                        ┌───────────────────────┐
 │  SMF (unmodified)     │                        │  UPF (unmodified)     │
 │      │ PFCP 8805      │                        │      ▲ PFCP 8805      │
 │      ▼                │                        │      │                │
 │  ┌─────────┐ capture  │                        │  ┌─────────┐ deliver  │
 │  │ signet  │◄─────────┤                        │  │ signet  ├─────────►│
 │  └────┬────┘          │                        │  └────▲────┘          │
 └───────┼───────────────┘                        └───────┼───────────────┘
         │        DTLS 8806, X509-SVID mutual auth        │
         └───────────────────────────────────────────────►┘
```

## Highlights

- **No NF change.** No image, configuration or command change in the SMF or UPF; the sidecar shares the NF's network namespace.
- **PFCP left intact.** PFCP carries IP addresses inside its payload (F-SEID, Node ID), so Signet never re-originates it under other addresses: cores that correlate sessions on the outer address keep matching.
- **SPIFFE identity only.** The credential is always an SVID from SPIRE, never a PSK or a static certificate. The peer is verified against SPIRE's trust bundle and authorized by its exact SPIFFE ID.
- **Rotation without restart.** SVIDs and bundles are streamed and the current one is served at each handshake.
- **Fails closed.** A packet the tunnel cannot carry is dropped, never sent in plaintext; a session whose peer went away is detected (nothing received for 20 s while sending) and re-established.

## How it works

Two datapaths, selected with `-mode`:

| | **socket** (default) | **nfqueue** |
|---|---|---|
| capture | iptables `REDIRECT` of the NF's PFCP into the sidecar's socket | `NFQUEUE` rule on egress PFCP, both directions |
| carried as | each datagram in a DTLS record | the whole IP packet as one DTLS record |
| delivery | transparently to the local NF | written to a TUN device, original L3 header intact |
| needs | iptables `nat` and `raw` | iptables `mangle`, `libnetfilter_queue`, `/dev/net/tun` |

`nfqueue` is only needed to share an interception path with another capture-based gate. [docs/design.md](docs/design.md) explains capture, encapsulation and reinjection and why each choice was made.

## Identity

Two deployment shapes, differing only in how the sidecar itself is attested:

| | **in-pod** (default) | **host + delegated** |
|---|---|---|
| where it runs | a container in the NF's pod | a systemd unit on the node |
| network namespace | shared with the NF | entered with `nsenter` |
| SPIRE selectors | `k8s:ns` + `k8s:sa` + `k8s:container-name` | `unix:path` + `unix:sha256` |
| SPIRE API | Workload API | Delegated Identity API |
| pod spec | a container is added (NF pods restart) | untouched, no restart |

**in-pod is the stronger binding**: the identity is tied to that namespace, service account and container, so a process elsewhere on the node cannot obtain it by running a copy of the NF binary. Use `host + delegated` when the pod spec must not change at all.

## Quick start

The sidecar runs as a **container in the SMF and UPF pods**, and SPIRE runs in the cluster.

```sh
# 1. build and make the image available to every node that runs an NF
docker build -t ghcr.io/chanuk-park/signet:latest .

# 2. SPIRE in-cluster: server (StatefulSet) + agent (DaemonSet) + one identity per NF
#    edit deploy/k8s/spire/13-registrar-config.yaml for your namespace/service accounts
kubectl apply -f deploy/k8s/spire/

# 3. add the sidecar to the network functions -- UPF first (it listens), then SMF (it dials)
#    edit the two patches for your addresses and trust domain
kubectl -n core patch deploy oai-upf --patch-file deploy/k8s/sidecar/upf-patch.yaml
kubectl -n core patch deploy oai-smf --patch-file deploy/k8s/sidecar/smf-patch.yaml

# 4. check it
kubectl -n core logs deploy/oai-smf -c signet | grep SIGNET-STATE
./deploy/signet-verify.sh          # 11 checks, exit 0 only if all pass
```

[deploy/k8s/README.md](deploy/k8s/README.md) is the full guide. If the pod spec must not change at all, use the host variant in [deploy/README.md](deploy/README.md).

## Scope

- **Does:** confidentiality and integrity for N4, with both ends cryptographically identified by SPIRE and authorized by SPIFFE ID; automatic rotation; no NF modification.
- **Does not:** distinguish *which instance* of an identity is speaking. Anything SPIRE issues the identity to can use the tunnel: with `k8s` selectors that means anything in that pod, with `unix` selectors anything running that binary on that node. Admission tied to a specific execution rather than to an identity is a different control.

## Requirements

- Linux with `libnetfilter_queue` and `/dev/net/tun`, and `CAP_NET_ADMIN` for the sidecar
- A SPIRE deployment (`deploy/spire-bootstrap.sh` can stand one up)
- Kubernetes and `kubectl` for the deploy scripts
- DTLS 1.2 via `pion/dtls` v3

## Documentation

| Document | Contents |
| --- | --- |
| [deploy/k8s/README.md](deploy/k8s/README.md) | Kubernetes deployment: in-cluster SPIRE and the sidecar in the SMF and UPF pods |
| [deploy/README.md](deploy/README.md) | Host variant driven by shell scripts, for when the pod spec must not change |
| [docs/design.md](docs/design.md) | Capture, encapsulation, reinjection, and the reasons behind each |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Failure modes that are easy to hit and how to recognise them |

## Repository layout

```
Signet/
├── cmd/signet/       the sidecar: identity, DTLS session, socket and NFQUEUE datapaths, TUN
├── deploy/
│   ├── k8s/          in-cluster SPIRE and the SMF/UPF sidecar patches
│   └── *.sh          host variant: SPIRE bootstrap, deploy, inject, verify
└── docs/             design notes and troubleshooting
```

## Development

```bash
make build          # signet binary (needs libnetfilter-queue-dev)
make test           # unit tests
make gofmt vet      # formatting and vet, as in CI
make golangci-lint  # linters (.golangci.yml)
make gosec          # security scan
make image          # container image ghcr.io/chanuk-park/signet
```

## License

Apache-2.0. See [LICENSE](LICENSE).
