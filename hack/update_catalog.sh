#!/usr/bin/env bash

declare CONFIGS_DIR
declare CERT_MANAGER_OPERATOR_IMAGE
declare CERT_MANAGER_OPERATOR_BUNDLE_IMAGE
declare CERT_MANAGER_IMAGE
declare CERT_MANAGER_ACMESOLVER_IMAGE

CATALOG_MANIFEST_FILE_NAME="catalog.yaml"


# TODO: [future] de-dup this function, as this is the same logic from render_templates.sh->update_csv_manifest() 
update_catalog_manifest()
{
	CATALOG_MANIFEST_FILE="${CONFIGS_DIR}/${CATALOG_MANIFEST_FILE_NAME}"
	if [[ ! -f "${CATALOG_MANIFEST_FILE}" ]]; then
		echo "[$(date)] -- ERROR -- catalog manifest file \"${CATALOG_MANIFEST_FILE}\" does not exist"
		exit 1
	fi

	## replace cert-manager operand related images
	sed -i "s#registry.redhat.io/cert-manager/jetstack-cert-manager-rhel9.*#${CERT_MANAGER_IMAGE}#g" "${CATALOG_MANIFEST_FILE}"
	sed -i "s#registry.redhat.io/cert-manager/jetstack-cert-manager-acmesolver-rhel9.*#${CERT_MANAGER_ACMESOLVER_IMAGE}#g" "${CATALOG_MANIFEST_FILE}"

	## replace cert-manager-operator image
	sed -i "s#registry.redhat.io/cert-manager/cert-manager-operator-rhel9.*#${CERT_MANAGER_OPERATOR_IMAGE}#g" "${CATALOG_MANIFEST_FILE}"

	## replace cert-manager-operator-bundle image
	sed -i "s#registry.redhat.io/cert-manager/cert-manager-operator-bundle.*#${CERT_MANAGER_OPERATOR_BUNDLE_IMAGE}#g" "${CATALOG_MANIFEST_FILE}"
}

usage()
{
	echo -e "usage:\n\t$(basename "${BASH_SOURCE[0]}")" \
		'"<CATALOG_CONFIG_DIR>"' \
		'"<CERT_MANAGER_OPERATOR_IMAGE>"' \
		'"<CERT_MANAGER_OPERATOR_BUNDLE_IMAGE>"' \
		'"<CERT_MANAGER_IMAGE>"' \
		'"<CERT_MANAGER_ACMESOLVER_IMAGE>"'
	exit 1
}

##############################################
###############  MAIN  #######################
##############################################

if [[ $# -ne 6 ]]; then
  usage
fi

CONFIGS_DIR=$1
CERT_MANAGER_OPERATOR_IMAGE=$2
CERT_MANAGER_OPERATOR_BUNDLE_IMAGE=$3
CERT_MANAGER_IMAGE=$4
CERT_MANAGER_ACMESOLVER_IMAGE=$5

echo "[$(date)] -- INFO  -- $*"

if [[ ! -d ${CONFIGS_DIR} ]]; then
  echo "[$(date)] -- ERROR -- manifests directory \"${MANIFESTS_DIR}\" does not exist"
	exit 1
fi

update_catalog_manifest

exit 0
