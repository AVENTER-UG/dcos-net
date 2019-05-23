#!/bin/bash

set -uo pipefail

usage() {
  echo "usage: $SCRIPT"
  echo
  echo "a networking helper for troubleshooting and collecting diagnostics data"
}

SCRIPT="$0"
NARGS="$#"

if [ "$NARGS" -ne 0 ]; then
  echo "error: extra arguments"
  echo
  usage
  exit 1
fi


if [ -z "${DCOS_VERSION+x}" ]; then
  exec /opt/mesosphere/bin/dcos-shell "$SCRIPT"
fi

IP="$(/opt/mesosphere/bin/detect_ip)"
DATA_DIR="data-$IP"
SERVICE_AUTH_TOKEN=$(sed 's/^SERVICE_AUTH_TOKEN=//' /run/dcos/etc/dcos-net_auth.env)

minor-version() {
  echo "$DCOS_VERSION" | cut -d. -f2 | cut -d- -f1
}

MINOR_VERSION="$(minor-version)"

running-on-master() {
  if systemctl status dcos-mesos-master &> /dev/null; then
    echo yes
  else
    echo no
  fi
}

RUNNING_ON_MASTER="$(running-on-master)"

USE_NET_TOOLBOX=${USE_NET_TOOLBOX:-true}
if [ "$USE_NET_TOOLBOX" == "true" ]; then
  if ! docker pull mesosphere/net-toolbox; then
    USE_NET_TOOLBOX="false"
    echo "*WARNING* could not download mesosphere/net-toolbox docker image"
    echo "*WARNING* the ipvsadm command must be installed before collection"
    echo "*WARNING* will succeed."
  fi
fi

wrap-curl() {
  curl --insecure --silent "$@"
}

wrap-ipvsadm() {
  if [ "${USE_NET_TOOLBOX}" == "false" ]; then
    if type ipvsadm &> /dev/null; then
      ipvsadm "$@"
    else
      echo "ipvsadm is not available"
    fi
  else
    docker run \
           --rm \
           --net=host \
           --privileged \
           mesosphere/net-toolbox:latest ipvsadm "$@"
  fi
}

wrap-net-eval() {
  if [ "$MINOR_VERSION" -lt "11" ]; then
    /opt/mesosphere/active/navstar/navstar/bin/navstar-env eval "$@"
  else
    /opt/mesosphere/bin/dcos-net-env eval "$@"
  fi
}

dcos-version() {
  echo "======================================================================"
  (
    echo "DC/OS $DCOS_VERSION";
    if [ ! -z "${DCOS_VARIANT+x}" ]; then
      echo "Variant: $DCOS_VARIANT";
    fi
    echo "Image commit: $DCOS_IMAGE_COMMIT"
  ) | tee "$DATA_DIR/dcos-version.txt"
  echo
}

os-data() {
  echo "======================================================================"
  echo "Capturing OS release and version..."

  for f in /etc/*-release; do
    cp "$f" "$DATA_DIR/$(basename $f).txt"
  done
  uname -a > "$DATA_DIR/uname.txt"

  echo "Captured OS release and version."
  echo
}

logs() {
  echo "======================================================================"
  echo "Capturing logs using journald..."

  if [ "$RUNNING_ON_MASTER" == "yes" ]; then
    echo "Capturing dcos-mesos-master logs..."
    journalctl -u dcos-mesos-master.service > "$DATA_DIR/dcos-mesos-master-logs.txt"
    echo "Capturing dcos-mesos-dns logs..."
    journalctl -u dcos-mesos-dns.service > "$DATA_DIR/dcos-mesos-dns-logs.txt"
  else
    echo "Capturing dcos-mesos-slave logs..."
    journalctl -u dcos-mesos-slave.service > "$DATA_DIR/dcos-mesos-slave-logs.txt"
  fi

  if [ "$MINOR_VERSION" -lt "11" ]; then
    echo "Capturing dcos-navstar logs..."
    journalctl -u dcos-navstar.service > "$DATA_DIR/dcos-navstar-logs.txt"
    echo "Capturing dcos-spartan logs..."
    journalctl -u dcos-spartan.service > "$DATA_DIR/dcos-spartan-logs.txt"
  else
    echo "Capturing dcos-net logs..."
    journalctl -u dcos-net.service > "$DATA_DIR/dcos-net-logs.txt"
  fi

  echo "Captured logs using journald."
  echo
}

dcos-configs() {
  echo "======================================================================"
  echo "Capturing DC/OS configuration files..."

  echo "Capturing DC/OS user config..."
  cp /opt/mesosphere/etc/user.config.yaml "$DATA_DIR/dcos-user.config.yaml"

  echo "Captured DC/OS configuration files."
  echo
}

mesos-master-state() {
  ADDR="master.mesos"
  if [ "$RUNNING_ON_MASTER" == "yes" ]; then
    ADDR="$IP"
  fi
  wrap-curl "https://$ADDR:5050/state" | jq .
}

mesos-agent-state() {
  if [ "$MINOR_VERSION" -lt "11" ]; then
    wrap-net-eval 'mesos_state_client:poll(mesos_state:ip(), 5051).'
  elif [ "$MINOR_VERSION" -lt "12" ]; then
    wrap-net-eval 'false = dcos_dns:is_master(), dcos_net_mesos:poll("/state").'
  else
    wrap-curl \
      -H 'Content-Type: application/json' \
      -H "Authorization: token=$SERVICE_AUTH_TOKEN" \
      -d '{"type": "GET_STATE"}' \
      "https://$IP:5051/api/v1" | jq .
  fi
}

mesos-state() {
  echo "======================================================================"
  echo "Capturing the Mesos state..."

  echo "Capturing the Mesos master state..."
  mesos-master-state > "$DATA_DIR/mesos-master-state.json"

  if [ "$RUNNING_ON_MASTER" == "no" ]; then
    echo "Capturing the Mesos agent state..."
    mesos-agent-state > "$DATA_DIR/mesos-agent-state.json"
  fi

  echo "Captured the Mesos state."
  echo
}

l4lb-data() {
  echo "======================================================================"
  echo "Capturing L4LB data..."

  echo "Capturing vips..."
  wrap-curl 'http://localhost:62080/v1/vips' | jq . > "$DATA_DIR/l4lb-vips.json"

  echo "Capturing ipvs state..."
  wrap-ipvsadm -L -n > "$DATA_DIR/ipvsadm.txt"

  echo "Capturing ipvs timeouts..."
  wrap-ipvsadm -L --timeout > "$DATA_DIR/ipvsadm-timeout.txt"

  echo "Capturing ipvs connection state..."
  cp /proc/net/ip_vs_conn "$DATA_DIR/ip-vs-conn.txt"

  echo "Capturing kernel state..."
  (sysctl net.ipv4.vs; sysctl net.ipv4.ip_local_port_range) > "$DATA_DIR/sysctl.txt"

  echo "Capturing iptables configuration..."
  iptables-save > "$DATA_DIR/iptables-save.txt"
  ip6tables-save > "$DATA_DIR/ip6tables-save.txt"

  echo "Capturing ipset configuration..."
  ipset list > "$DATA_DIR/ipset.txt"

  echo "Capturing netfilter conntrack table..."
  cp /proc/net/nf_conntrack "$DATA_DIR/nf-conntrack.txt"

  echo "Capturing minuteman routing table..."
  ip route show table local dev minuteman scope host > "$DATA_DIR/minuteman-routes.txt"

  echo "Capturing lashup membership..."
  wrap-net-eval 'lashup_gm:gm().' > "$DATA_DIR/lashup-membership.txt"

  echo "Captured L4LB data"
  echo
}

overlay-data() {
  echo "======================================================================"
  echo "Capturing overlay data..."

  echo "Capturing network configuration..."
  ifconfig -a > "$DATA_DIR/ifconfig.txt"
  ip link > "$DATA_DIR/ip-link.txt"
  ip addr > "$DATA_DIR/ip-addr.txt"
  ip route > "$DATA_DIR/ip-route.txt"

  echo "Capturing lashup overlay state..."
  wrap-net-eval \
    '[{Key, lashup_kv:value(Key)} || Key = [navstar, overlay, _Subnet] <- mnesia:dirty_all_keys(kv2)].' \
    > "$DATA_DIR/lashup-overlays.txt"

  echo "Capturing Mesos overlay information..."
  if [ "$RUNNING_ON_MASTER" == "yes" ];then
    wrap-curl \
      "https://$IP:5050/overlay-master/state" > "$DATA_DIR/overlay-master-state.json" | jq .
  else
    wrap-curl \
      "https://$IP:5051/overlay-agent/overlay" > "$DATA_DIR/overlay-agent-state.json" | jq .
  fi

  echo "Captured overlay data"
  echo
}

dns-data() {
  echo "======================================================================"
  echo "Capturing DNS data..."

  echo "Copying resolv.conf ..."
  cat /etc/resolv.conf > "$DATA_DIR/resolv.conf"

  echo "Resovling ready.spartan ..."
  dig ready.spartan > "$DATA_DIR/dig-ready.spartan.txt"
  echo "Resovling ready.spartan through 198.51.100.1 ..."
  dig ready.spartan @198.51.100.1 > "$DATA_DIR/dig-ready.spartan-at-198.51.100.1.txt"
  echo "Resovling leader.mesos through 198.51.100.1 ..."
  dig leader.mesos @198.51.100.1 > "$DATA_DIR/dig-leader.mesos-at-198.51.100.1.txt"
  echo "Resovling dcos.io through 198.51.100.1 ..."
  dig dcos.io @198.51.100.1 > "$DATA_DIR/dig-dcos.io-at-198.51.100.1.txt"

  echo "Resolving dcos.io through upstream servers..."
  (
    source /opt/mesosphere/etc/dns_config;
    for server in $(echo $RESOLVERS | tr ',' '\n'); do
      echo "===    Upstream DNS server: $server ===";
      dig dcos.io @$server;
    done
  ) > "$DATA_DIR/dig-dcos.io-at-upstream-servers.txt"

  echo "Copying Mesos DNS configuration..."
  cat /opt/mesosphere/etc/mesos-dns.json | jq . > "$DATA_DIR/mesos-dns-config.json"
  echo "Fetching Mesos DNS records..."
  if [ "$RUNNING_ON_MASTER" == "yes" ]; then
    wrap-curl http://localhost:8123/v1/enumerate | jq . > "$DATA_DIR/mesos-dns-records.json"
  fi

  echo "Fetching dcos-dns records..."
  wrap-curl http://localhost:62080/v1/records | jq . > "$DATA_DIR/dcos-dns-records.json"

  echo "Captured DNS data"
  echo
}

# dig <yourapp>.<yourframework>.mesos @127.0.0.1 -p 61053

mkdir "$DATA_DIR"

dcos-version
os-data
logs
dcos-configs
mesos-state
l4lb-data
overlay-data
dns-data

chmod 644 "$DATA_DIR"/*
tar czf "$DATA_DIR.tar.gz" "$DATA_DIR"
rm -Rf "$DATA_DIR"
