
+-----------------------------+
|        FortiGate 90G        |
|  AS 64512                   |
|  LAN: 10.0.20.1/24          |
|  BGP ↔ Calico Node (64513)  |
|  Route: 192.168.0.0/16 → 10.0.20.197 |
+-----------------------------+
             │
             │ BGP Peering
             │
+-----------------------------+
|     K3s / Calico Node       |
|  Host IP: 10.0.20.197       |
|  AS 64513                   |
|  Pod CIDR: 192.168.0.0/16   |
|  Calico (no SNAT, no tunnel)|
|  MetalLB: 10.0.20.150-179   |
|  Traefik LB: 10.0.20.150    |
+-----------------------------+
             │
     ┌──────────────────────┐
     │    Calico Pod CIDR   │
     │   192.168.236.0/26   │
     │  (Pods, Services)    │
     └──────────────────────┘





1.1 Pick Calico’s ASN & set global BGP config
```
# Set Calico's global ASN (only once)
cat <<'YAML' | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: BGPConfiguration
metadata:
  name: default
spec:
  asNumber: 64513
  # optional but nice to be explicit
  logSeverityScreen: Info
YAML
```

Note: You currently have ipipMode: Always on the default pool. That’s OK; BGP will still advertise routes.
If your nodes and pods are on the same L2 and you prefer no encapsulation, you can switch to:
```
kubectl patch ippool default-ipv4-ippool --type merge -p '{"spec":{"ipipMode":"Never","vxlanMode":"Never"}}'
```



1.2 Create a BGPPeer to the FortiGate
```
cat <<'YAML' | kubectl apply -f -
apiVersion: crd.projectcalico.org/v1
kind: BGPPeer
metadata:
  name: fgt-lan
spec:
  peerIP: 10.0.20.1         # FortiGate IP on the LAN
  asNumber: 64512           # FortiGate ASN
  # Optional: restrict which nodes peer (here: all)
  # nodeSelector: all()
YAML
```


2.2 Configure BGP on FortiGate
```
config router bgp
    set as 64512
    set router-id 10.0.20.1
    # Optional: keep routes only if peering is up
    set keepalive-timer 10
    set holdtime 30

    config neighbor
        edit 10.0.20.197
            set remote-as 64513
            set update-source "lan"           # replace with your LAN interface name
            set next-hop-self enable
            set soft-reconfiguration enable
        next
    end

    # Accept the Calico pod-CIDR(s) (learned from the neighbor)
    # You generally don't need to "network" them; they are learned via eBGP.
    # If you want to *originate* something from FGT, use `config network` here.
end
```


# Look for: Neighbor 10.0.20.197 State = Established
```
FortiGate-90G # get router info bgp summary

VRF 0 BGP router identifier 10.0.20.1, local AS number 64512
BGP table version is 1
1 BGP AS-PATH entries
0 BGP community entries

Neighbor    V         AS MsgRcvd MsgSent   TblVer  InQ OutQ Up/Down  State/PfxRcd
10.0.20.197 4      64513       4       2        0    0    0 00:00:06        1

Total number of neighbors 1
```

# Check received prefixes; you should see 192.168.0.0/16 (or per-block routes)
```
FortiGate-90G # get router info bgp neighbors 10.0.20.197
VRF 0 neighbor table:
BGP neighbor is 10.0.20.197, remote AS 64513, local AS 64512, external link
  BGP version 4, remote router ID 10.0.20.101
  BGP state = Established, up for 00:01:31
  Last read 00:00:02, hold time is 30, keepalive interval is 10 seconds
  Configured hold time is 30, keepalive interval is 10 seconds
  Neighbor capabilities:
    Route refresh: advertised and received (new)
    Address family IPv4 Unicast: advertised and received
    Address family VPNv4 Unicast: advertised
    Address family IPv6 Unicast: advertised
    Address family VPNv6 Unicast: advertised
    Address family L2VPN EVPN: advertised
  Received 14 messages, 0 notifications, 0 in queue
  Sent 12 messages, 0 notifications, 0 in queue
  Route refresh request: received 0, sent 0
  NLRI treated as withdraw: 0
  Minimum time between advertisement runs is 30 seconds

 For address family: IPv4 Unicast
  BGP table version 1, neighbor version 0
  Index 1, Offset 0, Mask 0x2
    Graceful restart: received
    Additional Path:
      Send-mode: received
      Receive-mode: received
  Inbound soft reconfiguration allowed
  NEXT_HOP is always this router
  Community attribute sent to this neighbor (both)
  1 accepted prefixes, 1 prefixes in rib
  0 announced prefixes

 For address family: VPNv4 Unicast
  BGP table version 1, neighbor version 0
  Index 1, Offset 0, Mask 0x2
  Community attribute sent to this neighbor (both)
  0 accepted prefixes, 0 prefixes in rib
  0 announced prefixes

 For address family: IPv6 Unicast
  BGP table version 1, neighbor version 0
  Index 1, Offset 0, Mask 0x2
  Community attribute sent to this neighbor (both)
  0 accepted prefixes, 0 prefixes in rib
  0 announced prefixes

 For address family: VPNv6 Unicast
  BGP table version 1, neighbor version 0
  Index 1, Offset 0, Mask 0x2
  Community attribute sent to this neighbor (both)
  0 accepted prefixes, 0 prefixes in rib
  0 announced prefixes

 For address family: L2VPN EVPN
  BGP table version 1, neighbor version 0
  Index 1, Offset 0, Mask 0x2
  Community attribute sent to this neighbor (both)
  0 accepted prefixes, 0 prefixes in rib
  0 announced prefixes

 Connections established 1; dropped 0
 Graceful-restart Status:
  Remote restart-time is 120 sec
  Re-established, restarting side

Local host: 10.0.20.1, Local port: 9624
Foreign host: 10.0.20.197, Foreign port: 179
Egress interface: 31
Nexthop: 10.0.20.1
Nexthop interface: VLAN-200
Nexthop global: ::
Nexthop local: ::
BGP connection: non shared network

```

# Should show 192.168.0.0/16 learned via BGP next-hop 10.0.20.197
```
get router route
```

If you want to allow the exact /16 and any more-specifics (/17–/32), create two rules:
```
config router prefix-list
    edit "ALLOW-PODS"
        config rule
            edit 1
                set prefix 192.168.0.0 255.255.0.0
            next
            edit 2
                set prefix 192.168.0.0 255.255.0.0
                set ge 17
                set le 32
            next
        end
    next
end
```

Route-map and apply to neighbor
```
config router route-map
    edit "RM-IN-PODS"
        config rule
            edit 1
                set match-ip-address "ALLOW-PODS"
                set action permit
            next
        end
    next
end

config router bgp
    set as 64512
    set router-id 10.0.20.1
    config neighbor
        edit 10.0.20.197
            set remote-as 64513
            set update-source "VLAN-200"
            set route-map-in "RM-IN-PODS"
            set next-hop-self enable
        next
    end
end
```





