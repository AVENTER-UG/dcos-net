# DC/OS Networking Run Book Automation

This is a codified version of `dcos-net` part of the networking runbook.

## Usage

It should be run under root. If possible the tool pulls `mesosphere/net-toolbox` Docker image that contains certain utilities that it uses to capture diagnostics data. If it fails to do so, it is expected that tools like `ipset` are avaialbe on the host.

After executing `./runbook.sh`, there should be a directory named like `data-<ip-address>` containing diagnostics data.
