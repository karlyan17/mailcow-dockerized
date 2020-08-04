DOCKER_ORG:=mailcow
DOCKER_IMAGE:=postfix

build: package
	docker build -t $(DOCKER_ORG)/$(DOCKER_IMAGE) .

.PHONY: package
