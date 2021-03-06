#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Verifies that services and portals work.

set -o errexit
set -o nounset
set -o pipefail

KUBE_ROOT=$(dirname "${BASH_SOURCE}")/../..
source "${KUBE_ROOT}/cluster/kube-env.sh"
source "${KUBE_ROOT}/cluster/${KUBERNETES_PROVIDER}/util.sh"

function error() {
  echo "$@" >&2
  exit 1
}

function sort_args() {
  printf "%s\n" "$@" | sort -n | tr '\n\r' ' ' | sed 's/  */ /g'
}

svcs_to_clean=()
function do_teardown() {
  local svc
  for svc in "${svcs_to_clean[@]:+${svcs_to_clean[@]}}"; do
    stop_service "${svc}"
  done
}

# Args:
#   $1: service name
#   $2: service port
#   $3: service replica count
function start_service() {
  echo "Starting service '$1' on port $2 with $3 replicas"
  svcs_to_clean+=("$1")
  ${KUBECFG} -s "$2" -p 9376 run kubernetes/serve_hostname "$3" "$1"
}

# Args:
#   $1: service name
function stop_service() {
  echo "Stopping service '$1'"
  ${KUBECFG} stop "$1" || true
  ${KUBECFG} delete "/replicationControllers/$1" || true
  ${KUBECFG} delete "/services/$1" || true
}

# Args:
#   $1: service name
#   $2: expected pod count
function query_pods() {
  # This fails very occasionally, so retry a bit.
  pods_unsorted=()
  local i
  for i in $(seq 1 10); do
    pods_unsorted=($(${KUBECFG} \
        '-template={{range.Items}}{{.Name}} {{end}}' \
        -l name="$1" list pods))
    found="${#pods_unsorted[*]}"
    if [[ "${found}" == "$2" ]]; then
      break
    fi
    sleep 3
  done
  if [[ "${found}" != "$2" ]]; then
    error "Failed to query pods for $1: expected $2, found ${found}"
  fi

  # The "return" is a sorted list of pod IDs.
  sort_args "${pods_unsorted[@]}"
}

# Args:
#   $1: service name
#   $2: pod count
function wait_for_pods() {
  echo "Querying pods in $1"
  local pods_sorted=$(query_pods "$1" "$2")
  printf '\t%s\n' ${pods_sorted}

  # Container turn up on a clean cluster can take a while for the docker image
  # pulls.  Wait a generous amount of time.
  # TODO: Sometimes pods change underneath us, which makes the GET fail (404).
  # Maybe this test can be loosened and still be useful?
  pods_needed=$2
  local i
  for i in $(seq 1 30); do
    echo "Waiting for ${pods_needed} pods to become 'running'"
    pods_needed="$2"
    for id in ${pods_sorted}; do
      status=$(${KUBECFG} -template '{{.CurrentState.Status}}' get "pods/${id}")
      if [[ "${status}" == "Running" ]]; then
        pods_needed=$((pods_needed-1))
      fi
    done
    if [[ "${pods_needed}" == 0 ]]; then
      break
    fi
    sleep 3
  done
  if [[ "${pods_needed}" -gt 0 ]]; then
    error "Pods for $1 did not come up in time"
  fi
}

# Args:
#   $1: service name
#   $2: service IP
#   $3: service port
#   $4: pod count
#   $5: pod IDs
function wait_for_service_up() {
  local i
  for i in $(seq 1 20); do
    results=($(ssh-to-node "${test_node}" "
        set -e;
        for i in $(seq -s' ' 1 $4); do
          curl -s --connect-timeout 1 http://$2:$3;
        done | sort | uniq
        "))
    found_pods=$(sort_args "${results[@]:+${results[@]}}")
    if [[ "${found_pods}" == "$5" ]]; then
      break
    fi
    echo "Waiting for endpoints to propagate"
    sleep 3
  done
  if [[ "${found_pods}" != "$5" ]]; then
    error "Endpoints did not propagate in time"
  fi
}

# Args:
#   $1: service name
#   $2: service IP
#   $3: service port
function wait_for_service_down() {
  local i
  for i in $(seq 1 15); do
    $(ssh-to-node "${test_node}" "
        curl -s --connect-timeout 2 "http://$2:$3" >/dev/null 2>&1 && exit 1 || exit 0;
        ") && break
    echo "Waiting for $1 to go down"
    sleep 2
  done
}

# Args:
#   $1: service name
#   $2: service IP
#   $3: service port
#   $4: pod count
#   $5: pod IDs
function verify_from_container() {
  results=($(ssh-to-node "${test_node}" "
      set -e;
      sudo docker pull busybox >/dev/null;
      sudo docker run busybox sh -c '
          for i in $(seq -s' ' 1 $4); do
            wget -q -T 1 -O - http://$2:$3;
          done
      '")) \
      || error "testing $1 portal from container failed"
  found_pods=$(sort_args "${results[@]}")
  if [[ "${found_pods}" != "$5" ]]; then
    error -e "$1 portal failed from container, expected:\n
        $(printf '\t%s\n' $5)\n
        got:\n
        $(printf '\t%s\n' ${found_pods})
        "
  fi
}

trap "do_teardown" EXIT

# Get node IP addresses and pick one as our test point.
detect-minions
test_node="${MINION_NAMES[0]}"
master="${MASTER_NAME}"

# Launch some pods and services.
svc1_name="service1"
svc1_port=80
svc1_count=3
start_service "${svc1_name}" "${svc1_port}" "${svc1_count}"

svc2_name="service2"
svc2_port=80
svc2_count=3
start_service "${svc2_name}" "${svc2_port}" "${svc2_count}"

# Wait for the pods to become "running".
wait_for_pods "${svc1_name}" "${svc1_count}"
wait_for_pods "${svc2_name}" "${svc2_count}"

# Get the sorted lists of pods.
svc1_pods=$(query_pods "${svc1_name}" "${svc1_count}")
svc2_pods=$(query_pods "${svc2_name}" "${svc2_count}")

# Get the portal IPs.
svc1_ip=$(${KUBECFG} -template '{{.PortalIP}}' get "services/${svc1_name}")
test -n "${svc1_ip}" || error "Service1 IP is blank"
svc2_ip=$(${KUBECFG} -template '{{.PortalIP}}' get "services/${svc2_name}")
test -n "${svc2_ip}" || error "Service2 IP is blank"
if [[ "${svc1_ip}" == "${svc2_ip}" ]]; then
  error "Portal IPs conflict: ${svc1_ip}"
fi

#
# Test 1: Prove that the service portal is alive.
#
echo "Verifying the portals from the host"
wait_for_service_up "${svc1_name}" "${svc1_ip}" "${svc1_port}" \
    "${svc1_count}" "${svc1_pods}"
wait_for_service_up "${svc2_name}" "${svc2_ip}" "${svc2_port}" \
    "${svc2_count}" "${svc2_pods}"
echo "Verifying the portals from a container"
verify_from_container "${svc1_name}" "${svc1_ip}" "${svc1_port}" \
    "${svc1_count}" "${svc1_pods}"
verify_from_container "${svc2_name}" "${svc2_ip}" "${svc2_port}" \
    "${svc2_count}" "${svc2_pods}"

#
# Test 2: Bounce the proxy and make sure the portal comes back.
#
echo "Restarting kube-proxy"
restart-kube-proxy "${test_node}"
echo "Verifying the portals from the host"
wait_for_service_up "${svc1_name}" "${svc1_ip}" "${svc1_port}" \
    "${svc1_count}" "${svc1_pods}"
wait_for_service_up "${svc2_name}" "${svc2_ip}" "${svc2_port}" \
    "${svc2_count}" "${svc2_pods}"
echo "Verifying the portals from a container"
verify_from_container "${svc1_name}" "${svc1_ip}" "${svc1_port}" \
    "${svc1_count}" "${svc1_pods}"
verify_from_container "${svc2_name}" "${svc2_ip}" "${svc2_port}" \
    "${svc2_count}" "${svc2_pods}"

#
# Test 3: Stop one service and make sure it is gone.
#
stop_service "${svc1_name}"
wait_for_service_down "${svc1_name}" "${svc1_ip}" "${svc1_port}"

#
# Test 4: Bring up another service, make sure it re-uses Portal IPs.
#
svc3_name="service3"
svc3_port=80
svc3_count=3
start_service "${svc3_name}" "${svc3_port}" "${svc3_count}"

# Wait for the pods to become "running".
wait_for_pods "${svc3_name}" "${svc3_count}"

# Get the sorted lists of pods.
svc3_pods=$(query_pods "${svc3_name}" "${svc3_count}")

# Get the portal IP.
svc3_ip=$(${KUBECFG} -template '{{.PortalIP}}' get "services/${svc3_name}")
test -n "${svc3_ip}" || error "Service3 IP is blank"
if [[ "${svc3_ip}" != "${svc1_ip}" ]]; then
  error "Portal IPs not resued: ${svc3_ip} != ${svc1_ip}"
fi

echo "Verifying the portals from the host"
wait_for_service_up "${svc3_name}" "${svc3_ip}" "${svc3_port}" \
    "${svc3_count}" "${svc3_pods}"
echo "Verifying the portals from a container"
verify_from_container "${svc3_name}" "${svc3_ip}" "${svc3_port}" \
    "${svc3_count}" "${svc3_pods}"

#
# Test 5: Remove the iptables rules, make sure they come back.
#
echo "Manually removing iptables rules"
ssh-to-node "${test_node}" "sudo iptables -t nat -F KUBE-PROXY"
echo "Verifying the portals from the host"
wait_for_service_up "${svc3_name}" "${svc3_ip}" "${svc3_port}" \
    "${svc3_count}" "${svc3_pods}"
echo "Verifying the portals from a container"
verify_from_container "${svc3_name}" "${svc3_ip}" "${svc3_port}" \
    "${svc3_count}" "${svc3_pods}"

#
# Test 6: Restart the master, make sure portals come back.
#
echo "Restarting the master"
ssh-to-node "${master}" "sudo /etc/init.d/apiserver restart"
sleep 5
echo "Verifying the portals from the host"
wait_for_service_up "${svc3_name}" "${svc3_ip}" "${svc3_port}" \
    "${svc3_count}" "${svc3_pods}"
echo "Verifying the portals from a container"
verify_from_container "${svc3_name}" "${svc3_ip}" "${svc3_port}" \
    "${svc3_count}" "${svc3_pods}"

#
# Test 7: Bring up another service, make sure it does not re-use Portal IPs.
#
svc4_name="service4"
svc4_port=80
svc4_count=3
start_service "${svc4_name}" "${svc4_port}" "${svc4_count}"

# Wait for the pods to become "running".
wait_for_pods "${svc4_name}" "${svc4_count}"

# Get the sorted lists of pods.
svc4_pods=$(query_pods "${svc4_name}" "${svc4_count}")

# Get the portal IP.
svc4_ip=$(${KUBECFG} -template '{{.PortalIP}}' get "services/${svc4_name}")
test -n "${svc4_ip}" || error "Service4 IP is blank"
if [[ "${svc4_ip}" == "${svc2_ip}" || "${svc4_ip}" == "${svc3_ip}" ]]; then
  error "Portal IPs conflict: ${svc4_ip}"
fi

echo "Verifying the portals from the host"
wait_for_service_up "${svc4_name}" "${svc4_ip}" "${svc4_port}" \
    "${svc4_count}" "${svc4_pods}"
echo "Verifying the portals from a container"
verify_from_container "${svc4_name}" "${svc4_ip}" "${svc4_port}" \
    "${svc4_count}" "${svc4_pods}"

# TODO: test createExternalLoadBalancer

exit 0
