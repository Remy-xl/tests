#!/bin/bash
#
# Copyright (c) 2019 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#
# This script runs the Sonobuoy e2e Conformance tests.
# Run this script once your K8s cluster is running.
# WARNING: it is prefered to use containerd as the 
# runtime interface instead of cri-o as we have seen
# errors with cri-o that still need to be debugged.

set -o errexit
set -o nounset
set -o pipefail

export KUBECONFIG=$HOME/.kube/config
SCRIPT_PATH=$(dirname "$(readlink -f "$0")")
source "${SCRIPT_PATH}/../../../lib/common.bash"

RUNTIME="${RUNTIME:-kata-runtime}"
CRI_RUNTIME="${CRI_RUNTIME:-crio}"

# Overall Sonobuoy timeout in minutes.
WAIT_TIME=${WAIT_TIME:-180}

SONOBUOY_KATA_YAML="${SCRIPT_PATH}/sonobuoy_kata.yaml"

create_kata_webhook() {
	pushd "${SCRIPT_PATH}/../../../kata-webhook" >> /dev/null
	# Create certificates for the kata webhook
	./create-certs.sh

	# Apply kata-webhook deployment
	kubectl apply -f deploy/
	popd
}

run_sonobuoy() {
	# Run Sonobuoy e2e tests
	info "Starting sonobuoy execution."
	info "When using kata as k8s runtime, the tests take around 2 hours to finish."

	local skipped_tests_file="${SCRIPT_PATH}/skipped_tests_e2e.yaml"
	local skipped_tests=$("${GOPATH}/bin/yq" read "${skipped_tests_file}" "${CRI_RUNTIME}")

	# Default skipped tests for Conformance testing:
	_skip_options=("Alpha|\[(Disruptive|Feature:[^\]]+|Flaky)\]|")
	mapfile -t _skipped_tests <<< "${skipped_tests}"
	for entry in "${_skipped_tests[@]}"
	do
		_skip_options+=("${entry#- }|")
	done

	skip_options=$(IFS= ; echo "${_skip_options[*]}")
	skip_options="${skip_options%|}"

	sonobuoy run --e2e-skip="$skip_options" --wait="$WAIT_TIME"

	# Retrieve results
	e2e_result_dir="$(mktemp -d /tmp/kata_e2e_results.XXXXX)"
	sonobuoy retrieve "$e2e_result_dir" || \
		die "Couldn't retrieve sonobuoy results, please check status using: sonobuoy status"
	pushd "$e2e_result_dir" >> /dev/null

	# Uncompress results
	ls | grep tar.gz | xargs tar -xvf
	e2e_result_log="${e2e_result_dir}/plugins/e2e/results/e2e.log"
	info "Results of the e2e tests can be found on: $e2e_result_log"

	# If on CI, display the e2e log on the console.
	[ "$CI" == true ] && cat "$e2e_result_log"

	# Check for Success message on the logs.
	grep -aq " 0 Failed" "$e2e_result_log"
	grep -aq "SUCCESS" "$e2e_result_log" && \
		info " k8s e2e conformance using Kata runtime finished successfully"
	popd
}

cleanup() {
	# Remove sonobuoy execution pods
	sonobuoy delete
	info "Results directory $e2e_result_dir will not be deleted"
}

main() {
	sonobuoy_repo="github.com/heptio/sonobuoy"
	go get -u "$sonobuoy_repo"

	if [ "$RUNTIME" == "kata-runtime" ]; then
		create_kata_webhook
	fi
	run_sonobuoy
	cleanup
}

main
