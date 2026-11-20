## DESCRIPTION

Show the network interfaces and routes.

- `ip` or `ip addr`: each interface with its state, MTU, hardware
  address, bytes received and sent, and its IPv4 address.
- `ip link` (or `ip l`): the same without addresses.
- `ip route` (or `ip r`): the routing table, including the default
  route (the router packets go through).

Changing interfaces with `ip` is not supported: Ethernet is configured
by DHCP when the cable is plugged in, and Wi-Fi with `wifi`.

## SEE ALSO

ifconfig(1), dhclient(1), wifi(1), ping(1)
