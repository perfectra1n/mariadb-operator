##@ OLM

ifneq ($(origin CHANNELS), undefined)
BUNDLE_CHANNELS := --channels=$(CHANNELS)
endif

ifneq ($(origin DEFAULT_CHANNEL), undefined)
BUNDLE_DEFAULT_CHANNEL := --default-channel=$(DEFAULT_CHANNEL)
endif
BUNDLE_METADATA_OPTS ?= $(BUNDLE_CHANNELS) $(BUNDLE_DEFAULT_CHANNEL)

BUNDLE_GEN_FLAGS ?= -q --overwrite=false --version $(VERSION) $(BUNDLE_METADATA_OPTS)
USE_IMAGE_DIGESTS ?= true
ifeq ($(USE_IMAGE_DIGESTS), true)
	BUNDLE_GEN_FLAGS += --use-image-digests
endif

ifneq ($(origin CATALOG_BASE_IMG), undefined)
FROM_INDEX_OPT := --from-index $(CATALOG_BASE_IMG)
endif

BUNDLE_IMG ?= mariadb/mariadb-operator-enterprise-bundle:v$(VERSION)
BUNDLE_IMGS ?= $(BUNDLE_IMG)
CATALOG_IMG ?= mariadb/mariadb-operator-enterprise-catalog:v$(VERSION)

REDHAT_PROJECT_ID ?= ""
REDHAT_API_KEY ?= ""

.PHONY: scorecard-sa
scorecard-sa: ## Create scorecard ServiceAccount.
	$(KUBECTL) apply -f ./hack/manifests/scorecard-serviceaccount.yaml

BUNDLE_VALIDATE_FLAGS ?= --select-optional suite=operatorframework
# BUNDLE_VALIDATE_FLAGS ?= --select-optional suite=operatorframework --select-optional name=multiarch
.PHONY: bundle-validate
bundle-validate: operator-sdk ## Validate content and format of the operator bundle.
	$(OPERATOR_SDK) bundle validate ./bundle $(BUNDLE_VALIDATE_FLAGS)

BUNBLDE_SCORECARD_FLAGS ?= --service-account=scorecard --namespace=default --wait-time=3m
.PHONY: bundle-scorecard
bundle-scorecard: operator-sdk cluster-ctx scorecard-sa ## Statically validate your operator bundle using Scorecard.
	$(OPERATOR_SDK) scorecard ./bundle $(BUNBLDE_SCORECARD_FLAGS)

.PHONY: bundle
bundle: operator-sdk yq kustomize manifests ## Generate bundle manifests and metadata, then validate generated files.
	$(OPERATOR_SDK) generate kustomize manifests -q
	cd config/manager && $(KUSTOMIZE) edit set image controller=$(IMG_ENT)
	$(YQ) e -i '.spec.template.spec.containers[0].env[0].value = "$(RELATED_IMAGE_MARIADB_ENT)"' config/manager/manager.yaml
	$(YQ) e -i '.spec.template.spec.containers[0].env[1].value = "$(RELATED_IMAGE_MAXSCALE_ENT)"' config/manager/manager.yaml
	$(YQ) e -i '.spec.template.spec.containers[0].env[2].value = "$(RELATED_IMAGE_EXPORTER_ENT)"' config/manager/manager.yaml
	$(YQ) e -i '.spec.template.spec.containers[0].env[3].value = "$(RELATED_IMAGE_EXPORTER_MAXSCALE_ENT)"' config/manager/manager.yaml
	$(YQ) e -i '.spec.template.spec.containers[0].env[4].value = "$(IMG_ENT)"' config/manager/manager.yaml
	$(YQ) e -i '.spec.template.spec.containers[0].env[5].value = "$(MARIADB_GALERA_INIT_IMAGE_ENT)"' config/manager/manager.yaml
	$(YQ) e -i '.spec.template.spec.containers[0].env[6].value = "$(MARIADB_GALERA_AGENT_IMAGE_ENT)"' config/manager/manager.yaml
	$(YQ) e -i '.spec.template.spec.containers[0].env[7].value = "$(MARIADB_GALERA_LIB_PATH_ENT)"' config/manager/manager.yaml
	$(KUSTOMIZE) build config/manifests | $(OPERATOR_SDK) generate bundle $(BUNDLE_GEN_FLAGS)
	$(YQ) e -i '.metadata.annotations.containerImage = (.spec.relatedImages[] | select(.name == "mariadb-operator-enterprise").image)' bundle/manifests/mariadb-operator-enterprise.clusterserviceversion.yaml
	$(MAKE) bundle-validate

.PHONY: bundle-build
bundle-build: ## Build the bundle image.
	docker build -f Dockerfile.bundle -t $(BUNDLE_IMG) .

.PHONY: bundle-push
bundle-push: ## Push the bundle image.
	$(MAKE) docker-push IMG=$(BUNDLE_IMG)

.PHONY: catalog-build
catalog-build: opm ## Build a catalog image.
	$(OPM) index add --container-tool docker --mode semver --tag $(CATALOG_IMG) --bundles $(BUNDLE_IMGS) $(FROM_INDEX_OPT)

.PHONY: catalog-push
catalog-push: ## Push a catalog image.
	$(MAKE) docker-push IMG=$(CATALOG_IMG)

.PHONY: catalog-deploy
catalog-deploy: openshift-registry ## Deploy catalog to a OpenShift cluster.
	cd hack/manifests/catalog && $(KUSTOMIZE) edit set image catalog=$(CATALOG_IMG)
	$(KUSTOMIZE) build hack/manifests/catalog	| $(KUBECTL) apply -f -

.PHONY: catalog-undeploy
catalog-undeploy: ## Undeploy catalog from a OpenShift cluster.
	$(KUSTOMIZE) build hack/manifests/catalog	| $(KUBECTL) delete --ignore-not-found=$(ignore-not-found) -f -

.PHONY: openshift-deploy
openshift-deploy: docker-build-ent docker-push-ent bundle bundle-build bundle-push catalog-build catalog-push catalog-deploy ## Build, push and deploy images needed to test in Openshift.

.PHONY: preflight-image
preflight-image: preflight ## Run preflight tests on the operator image.
	$(PREFLIGHT) check container $(IMG_ENT) --docker-config $(DOCKER_CONFIG)

.PHONY: preflight-image-submit
preflight-image-submit: preflight ## Run preflight tests on the operator image and submit the results to Red Hat.
	$(PREFLIGHT) check container $(IMG_ENT)\
		--submit \
		--pyxis-api-token=$(REDHAT_API_KEY) \
		--certification-project-id=$(REDHAT_PROJECT_ID)\
		--docker-config $(DOCKER_CONFIG) 

.PHONY: preflight-bundle
preflight-bundle: preflight ## Run preflight tests on the bundle image and submit .
	PFLT_INDEXIMAGE=$(CATALOG_IMG) $(PREFLIGHT) check operator $(BUNDLE_IMG) --docker-config $(DOCKER_CONFIG)

.PHONY: licenses
licenses: go-licenses ## Generate licenses folder.
	$(GO_LICENSES) save ./... --save_path=licenses/go-licenses --force

CERTIFIED_REPO ?= "https://github.com/mariadb-operator/certified-operators"
CERTIFIED_BRANCH ?= cert-test
BUNDLE_PATH ?= "operators/mariadb-operator/${VERSION}"
.PHONY: cert-test
cert-test: openshift-registry ## Run certification tests in OpenShift.
	CERTIFIED_REPO=$(CERTIFIED_REPO) CERTIFIED_BRANCH=$(CERTIFIED_BRANCH) BUNDLE_PATH=$(BUNDLE_PATH) ./hack/certification_test.sh 