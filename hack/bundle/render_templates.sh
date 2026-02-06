#!/usr/bin/env bash

set -o nounset
set -o pipefail
set -o errexit

[[ "${DEBUG:-}" == "true" ]] && set -x

readonly CSV_FILE_NAME="cert-manager-operator.clusterserviceversion.yaml"
readonly ANNOTATIONS_FILE_NAME="annotations.yaml"

log_info()  { echo "[$(date)] -- INFO  -- $*"; }
log_error() { echo "[$(date)] -- ERROR -- $*" >&2; }

update_csv_manifest() {
	local csv_file="${MANIFESTS_DIR}/${CSV_FILE_NAME}"
	if [[ ! -f "${csv_file}" ]]; then
		log_error "operator csv file \"${csv_file}\" does not exist"
		exit 1
	fi

	## replace operator and operand images in the CSV manifest.
	sed -i \
	  -e "s#openshift.io/cert-manager-operator.*#${CERT_MANAGER_OPERATOR_IMAGE}#g" \
		-e "s#quay.io/jetstack/cert-manager-webhook.*#${CERT_MANAGER_WEBHOOK_IMAGE}#g" \
		-e "s#quay.io/jetstack/cert-manager-controller.*#${CERT_MANAGER_CONTROLLER_IMAGE}#g" \
		-e "s#quay.io/jetstack/cert-manager-cainjector.*#${CERT_MANAGER_CA_INJECTOR_IMAGE}#g" \
		-e "s#quay.io/jetstack/cert-manager-acmesolver.*#${CERT_MANAGER_ACMESOLVER_IMAGE}#g" \
		-e "s#quay.io/jetstack/cert-manager-istio-csr.*#${CERT_MANAGER_ISTIOCSR_IMAGE}#g" \
		-e "s#quay.io/jetstack/trust-manager.*#${TRUST_MANAGER_IMAGE}#g" \
		"${csv_file}"

	## update annotations in CSV manifest.
	yq e -i ".metadata.annotations.createdAt=\"$(date -u +'%Y-%m-%dT%H:%M:%S')\"" "${csv_file}"
}

update_annotations_metadata() {
	local annotation_file="${METADATA_DIR}/${ANNOTATIONS_FILE_NAME}"
	if [[ ! -f "${annotation_file}" ]]; then
		log_error "annotations metadata file \"${annotation_file}\" does not exist"
		exit 1
	fi

	# update annotations.
	yq e -i '.annotations."operators.operatorframework.io.bundle.package.v1"="openshift-cert-manager-operator"' "${annotation_file}"
}

usage() {
	echo -e "usage:\n\t$(basename "${BASH_SOURCE[0]}")" \
		'"<MANIFESTS_DIR>"' \
		'"<METADATA_DIR>"' \
		'"<IMAGES_DIGEST_CONF_FILE>"'
	exit 1
}

##############################################
###############  MAIN  #######################
##############################################

if [[ $# -ne 3 ]]; then
	usage
fi

declare -r MANIFESTS_DIR=$1
declare -r METADATA_DIR=$2
declare -r IMAGES_DIGEST_CONF_FILE=$3

log_info "$*"

[[ -d "${MANIFESTS_DIR}" ]] || { log_error "manifests directory \"${MANIFESTS_DIR}\" does not exist"; exit 1; }
[[ -d "${METADATA_DIR}" ]] || { log_error "metadata directory \"${METADATA_DIR}\" does not exist"; exit 1; }
[[ -f "${IMAGES_DIGEST_CONF_FILE}" ]] || { log_error "image digests conf file \"${IMAGES_DIGEST_CONF_FILE}\" does not exist"; exit 1; }

# shellcheck source=/dev/null
source "${IMAGES_DIGEST_CONF_FILE}"

required_images=(
	CERT_MANAGER_OPERATOR_IMAGE
	CERT_MANAGER_WEBHOOK_IMAGE
	CERT_MANAGER_CA_INJECTOR_IMAGE
	CERT_MANAGER_CONTROLLER_IMAGE
	CERT_MANAGER_ACMESOLVER_IMAGE
	CERT_MANAGER_ISTIOCSR_IMAGE
	TRUST_MANAGER_IMAGE
)

for img_var in "${required_images[@]}"; do
	if [[ -z "${!img_var:-}" ]]; then
		log_error "required image variable ${img_var} is not set"
		exit 1
	fi
done

update_csv_manifest
update_annotations_metadata

exit 0
