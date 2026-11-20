## DESCRIPTION

Connect to Wi-Fi networks and manage the saved ones. Lepton connects to
the saved networks by itself whenever a Wi-Fi adapter is present.
Looking and scanning are for everyone; connecting and forgetting take
`sudo`.

## COMMANDS

- `wifi`, `wifi status`: the adapter, the network you are connected to
  and your address, and the saved networks.
- `scan [IFACE]`: the networks in range, with their signal, security
  and band.
- `connect SSID [PASSPHRASE]`: save the network and connect to it. You
  are asked for the passphrase if you leave it out (Enter for an open
  network); a saved network needs none.
- `forget [SSID]`: forget a saved network (all of them with no SSID).
- `setup`: choose a network from a list and connect, interactively.

## EXAMPLES

    wifi scan
    sudo wifi connect "Home Network"
    sudo wifi forget "Cafe"

## SEE ALSO

ip(1), dhclient(1), ping(1), https://trylepton.app/docs/networking.html
