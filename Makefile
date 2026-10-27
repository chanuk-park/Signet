# SPDX-License-Identifier: Apache-2.0

IMAGE  ?= ghcr.io/chanuk-park/signet
TAG    ?= latest
# docker without sudo when the user can reach the daemon (CI), sudo otherwise.
DOCKER ?= $(shell docker info >/dev/null 2>&1 && echo docker || echo sudo docker)
GOLANGCI := $(shell command -v golangci-lint 2>/dev/null || echo $(shell go env GOPATH)/bin/golangci-lint)
GOSEC    := $(shell command -v gosec 2>/dev/null || echo $(shell go env GOPATH)/bin/gosec)

.PHONY: build test vet fmt gofmt golangci-lint gosec image build-image clean

## build: the signet binary (cgo; needs libnetfilter-queue-dev)
build:
	CGO_ENABLED=1 go build -trimpath -o signet ./cmd/signet

test:
	go test ./... -count=1

vet:
	go vet ./...

fmt:
	gofmt -l -w .

## gofmt: CI check -- fails if any Go file is not gofmt-clean.
gofmt:
	@out=$$(gofmt -l $$(git ls-files '*.go')); \
	if [ -n "$$out" ]; then echo "not gofmt-clean:"; echo "$$out"; exit 1; fi

## golangci-lint: run the linter (config in .golangci.yml).
golangci-lint:
	$(GOLANGCI) run ./...

## gosec: security scan. G103: the TUN ioctl needs unsafe.Pointer on the ifreq
## buffer. G115: the workload PID handed to the delegated API is an int32 by
## protocol. G204: iptables is run with argument lists built from flags, never
## through a shell.
GOSEC_EXCLUDE := G103,G115,G204
gosec:
	$(GOSEC) -exclude-generated -exclude=$(GOSEC_EXCLUDE) ./...

## image: the sidecar container image
image:
	$(DOCKER) build -t $(IMAGE):$(TAG) .

## build-image: CI alias for image.
build-image: image

clean:
	rm -f signet
