SHELL := $(shell which bash) # ensure bash is used
export BASH_ENV=hack/scripts/common

# populate vars
$(shell source hack/scripts/version; env | grep -E '_VERSION|_IMAGE|REGISTRY_PREFIX' >.env)
include .env

BINS := refunc loader sidecar

GOOS := $(shell eval $$(go env); echo $${GOOS})
ARCH := $(shell eval $$(go env); echo $${GOARCH})

LD_FLAGS := -X github.com/refunc/refunc/pkg/version.Version=$(REFUNC_VERSION) \
-X github.com/refunc/refunc/pkg/version.LoaderVersion=$(LOADER_VERSION) \
-X github.com/refunc/refunc/pkg/version.SidecarVersion=$(SIDECAR_VERSION)

clean:
	rm -rf bin/*

ifneq ($(GOOS),linux)
images: clean dockerbuild
	export GOOS=linux; make $@
else
images: $(addsuffix -image, $(BINS))
endif

bins: $(BINS)

bin/$(GOOS):
	mkdir -p $@

$(BINS): % : bin/$(GOOS) bin/$(GOOS)/%
	@log_info "Build: $@"

bin/$(GOOS)/%:
	@echo GOOS=$(GOOS)
	CGO_ENABLED=0 go build \
	-tags netgo -installsuffix netgo \
	-ldflags "-s -w $(LD_FLAGS)" \
	-a \
	-o $@ \
	./cmd/$*/

ifneq ($(GOOS),linux)
%-image:
	export GOOS=linux; make $@
else
%-image: % package/Dockerfile
	@rm package/$* 2>/dev/null || true && cp bin/linux/$* package/
	@cd package \
	&& docker build \
	--build-arg https_proxy="$${HTTPS_RPOXY}" \
	--build-arg http_proxy="$${HTTP_RPOXY}" \
	--build-arg BIN_TARGET=$* \
	-t $(TARGET_IMAGE) .
	@log_info "Image: $(TARGET_IMAGE)"
endif

bin/$(GOOS)/refunc: $(shell find pkg -type f -name '*.go') $(shell find cmd -type f -name '*.go')
refunc-image: TARGET_IMAGE=$(REFUNC_IMAGE)

bin/$(GOOS)/loader: cmd/loader/*.go pkg/runtime/lambda/loader/*.go
loader-image: TARGET_IMAGE=$(LOADER_IMAGE)

bin/$(GOOS)/sidecar: cmd/sidecar/*.go $(shell find pkg/sidecar -type f -name '*.go') $(shell find pkg/transport -type f -name '*.go')
sidecar-image: TARGET_IMAGE=$(SIDECAR_IMAGE)

bin/$(GOOS)/credsyncer: pkg/apis/refunc/v1beta3/*.go pkg/credsyncer/*.go cmd/credsyncer/*.go
credsyncer-image: TARGET_IMAGE=$(CREDSYNCER_IMAGE)

push: images
	@log_info "start pushing images"; \
	docker push $(LOADER_IMAGE) && \
	docker push $(SIDECAR_IMAGE) && \
	docker push $(REFUNC_IMAGE); \
	log_info "tag refunc to latest"; \
	docker tag $(REFUNC_IMAGE) $(REGISTRY_PREFIX)refunc:latest && \
	docker push $(REGISTRY_PREFIX)refunc:latest

build-container:
	docker build -t refunc:build -f Dockerfile.build .

dockerbuild: build-container
	@log_info "make bins in docker"
	@docker run --rm -it -v $(shell pwd):/github.com/refunc/refunc refunc:build make bins
