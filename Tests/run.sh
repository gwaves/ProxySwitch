#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
swiftc -swift-version 5 \
  ProxySwitch/Models/ProxyProfile.swift \
  ProxySwitch/Services/ProxyTrafficMonitor.swift \
  ProxySwitch/Services/ProxyHealthChecker.swift \
  Tests/main.swift -o "$output/monitoring-tests"
"$output/monitoring-tests"
swiftc -swift-version 5 \
  ProxySwitch/Models/ProxyProfile.swift ProxySwitch/Models/AppState.swift \
  ProxySwitch/Services/ProxyTrafficMonitor.swift \
  ProxySwitch/Services/ProxyHealthChecker.swift \
  Tests/AppState/main.swift -o "$output/state-tests"
"$output/state-tests"
