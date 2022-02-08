# Set environment variables
export CLUSTER_NAME?=kind-kiosk
export CILIUM_VERSION?=1.11.1
export KIOSK_VERSION?=0.2.11
#export KIOSK_VERSION?=0.2.9
export TRIVY_IMAGE_CHECK=1
export NAMESPACE=patrik-majer

# kind image list
# image: kindest/node:v1.20.2@sha256:15d3b5c4f521a84896ed1ead1b14e4774d02202d5c65ab68f30eeaf310a3b1a7
# image: kindest/node:v1.21.2@sha256:9d07ff05e4afefbba983fac311807b3c17a5f36e7061f6cb7e2ba756255b2be4
# image: kindest/node:v1.22.4@sha256:ca3587e6e545a96c07bf82e2c46503d9ef86fc704f44c17577fca7bcabf5f978
# image: kindest/node:v1.23.3@sha256:0df8215895129c0d3221cda19847d1296c4f29ec93487339149333bd9d899e5a
export KIND_NODE_IMAGE="kindest/node:v1.21.2@sha256:9d07ff05e4afefbba983fac311807b3c17a5f36e7061f6cb7e2ba756255b2be4"

.PHONY: kind-all
#kind-all: kind-create kx-kind cilium-install deploy-cert-manager kiosk-install install-nginx-ingress deploy-prometheus-stack
kind-all: kind-create kx-kind cilium-prepare-images cilium-install deploy-cert-manager kiosk-install

.PHONY: kind-create
kind-create:
ifeq ($(TRIVY_IMAGE_CHECK), 1)
	trivy image --severity=HIGH --exit-code=0 "$(KIND_NODE_IMAGE)"
endif
	kind --version
	kind create cluster --name "$(CLUSTER_NAME)" \
 		--config="kind/kind-config.yaml" \
 		--image="$(KIND_NODE_IMAGE)"
	# fix prometheus-operator's CRDs
	kubectl apply -f https://raw.githubusercontent.com/prometheus-community/helm-charts/main/charts/kube-prometheus-stack/crds/crd-servicemonitors.yaml
# for testing PSP
#	kubectl apply -f https://github.com/appscodelabs/tasty-kube/raw/master/psp/privileged-psp.yaml
#	kubectl apply -f https://github.com/appscodelabs/tasty-kube/raw/master/psp/baseline-psp.yaml
#	kubectl apply -f https://github.com/appscodelabs/tasty-kube/raw/master/psp/restricted-psp.yaml
#	kubectl apply -f https://github.com/appscodelabs/tasty-kube/raw/master/kind/psp/cluster-roles.yaml
#	kubectl apply -f https://github.com/appscodelabs/tasty-kube/raw/master/kind/psp/role-bindings.yaml
# for more control planes, but no workers
# kubectl taint nodes --all node-role.kubernetes.io/master- || true

.PHONY: kind-delete
kind-delete:
	kind delete cluster --name $(CLUSTER_NAME)

.PHONY: kx-kind
kx-kind:
	kind export kubeconfig --name $(CLUSTER_NAME)


#.PHONY: workload-purge
#workload-purge:
#	helm un one20 -n $(NAMESPACE)
##	devspace purge --all
#	kubectl -n $(NAMESPACE) delete pvc --all

.PHONY: cilium-prepare-images
cilium-prepare-images:
	# pull image locally
	docker pull quay.io/cilium/cilium:v$(CILIUM_VERSION)
	docker pull quay.io/cilium/hubble-ui:v0.8.5
	docker pull quay.io/cilium/hubble-ui-backend:v0.8.5
	docker pull quay.io/cilium/hubble-relay:v$(CILIUM_VERSION)
ifeq ($(TRIVY_IMAGE_CHECK), 1)
	trivy image --severity=HIGH --exit-code=1 quay.io/cilium/cilium:v$(CILIUM_VERSION)
	trivy image --severity=HIGH --exit-code=1 quay.io/cilium/hubble-ui:v0.8.5
	trivy image --severity=HIGH --exit-code=1 quay.io/cilium/hubble-ui-backend:v0.8.5
	trivy image --severity=HIGH --exit-code=1 quay.io/cilium/hubble-relay:v$(CILIUM_VERSION)
endif
	# Load the image onto the cluster
	kind load docker-image --name $(CLUSTER_NAME) quay.io/cilium/cilium:v$(CILIUM_VERSION)
	kind load docker-image --name $(CLUSTER_NAME) quay.io/cilium/hubble-ui:v0.8.5
	kind load docker-image --name $(CLUSTER_NAME) quay.io/cilium/hubble-ui-backend:v0.8.5
	kind load docker-image --name $(CLUSTER_NAME) quay.io/cilium/hubble-relay:v$(CILIUM_VERSION)

.PHONY: cilium-install
cilium-install:
	# Add the Cilium repo
	helm repo add cilium https://helm.cilium.io/
	# install/upgrade the chart
	helm upgrade --install cilium cilium/cilium --version $(CILIUM_VERSION) \
	   -f kind/kind-values-cilium.yaml \
	   -f kind/kind-values-cilium-hubble.yaml \
	   -f kind/kind-values-cilium-service-monitors.yaml \
	   --namespace kube-system \
	   --wait

.PHONY: nginx-ingress-deploy
nginx-ingress-deploy:
	docker pull k8s.gcr.io/ingress-nginx/controller:v1.1.1
	kind load docker-image --name $(CLUSTER_NAME) k8s.gcr.io/ingress-nginx/controller:v1.1.1
	helm repo add --force-update ingress-nginx https://kubernetes.github.io/ingress-nginx
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
	  --namespace ingress-nginx \
	  --create-namespace \
	-f kind/kind-values-ingress-nginx.yaml

#	kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml
#	kubectl delete validatingwebhookconfigurations.admissionregistration.k8s.io ingress-nginx-admission

.PHONY: deploy-cert-manager
deploy-cert-manager:
	kind/cert-manager_install.sh

.PHONY: deploy-prometheus-stack
deploy-prometheus-stack:
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm upgrade --install \
	prometheus-stack \
	prometheus-community/kube-prometheus-stack \
	--namespace monitoring \
    --create-namespace \
    --set kubeStateMetrics.enabled=false \
    --set nodeExporter.enabled=false \
    --set alertmanager.enabled=false,kubeApiServer.enabled=false \
    --set kubelet.enabled=false \
    --set kubeControllerManager.enabled=false,coredns.enabled=false \
    --set prometheus.enabled=false \
    --set grafana.enabled=false \
    --set prometheusOperator.admissionWebhooks.enabled=false \
    --set prometheusOperator.tls.enabled=false

.PHONY: kiosk-install
kiosk-install:
	kubectl create namespace kiosk || true
	helm upgrade --install \
	kiosk \
	--version $(KIOSK_VERSION) \
	--namespace kiosk --atomic \
	--repo https://charts.devspace.sh/ \
	kiosk

.PHONY: chart-upgrade-old
chart-upgrade-old:
	EMAIL="Patrik.Majer1@ataccama.com"; \
	CHARTNAME=$$(echo $$EMAIL |sed 's/[@|_|.]/-/g' | tr '[:upper:]' '[:lower:]'); \
	helm upgrade --install \
	-n kube-system \
	--set=email=$$EMAIL \
	--set=account.shareWith[0]=Pavel.First@ataccama.com \
	--set=account.shareWith[1]=Jan.Second@ataccama.com \
	--set=indexedSpace.count=3 \
	"od-account-$${CHARTNAME}" \
	./ondemand-user-account

.PHONY: chart-upgrade-new
chart-upgrade-new:
	EMAIL="Patrik.Majer1@ataccama.com"; \
	CHARTNAME=$$(echo $$EMAIL |sed 's/[@|_|.]/-/g' | tr '[:upper:]' '[:lower:]'); \
	helm upgrade --install \
	-n kube-system \
	--set=email=$$EMAIL \
	--set=indexedSpace.count=2 \
	--set=certificate.dnsDomain="aks.ondemand.ataccama.dev" \
	"od-account-$${CHARTNAME}" \
	./ondemand-user-account

#.PHONY: k8s-apply
#k8s-apply:
#	kubectl get ns cilium-linkerd 1>/dev/null 2>/dev/null || kubectl create ns cilium-linkerd
#	kubectl apply -k k8s/podinfo -n cilium-linkerd
#	kubectl apply -f k8s/client
#	kubectl apply -f k8s/networkpolicy
#
#.PHONY: check-status
#check-status:
#	linkerd top deployment/podinfo --namespace cilium-linkerd
#	linkerd tap deployment/client --namespace cilium-linkerd
#	kubectl exec deploy/client -n cilium-linkerd -c client -- curl -s podinfo:9898

