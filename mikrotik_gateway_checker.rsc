# MikroTik Script: Check IP availability via all gateways and tunnel interfaces
# Usage: Set target IP in the :global variable or pass as parameter

:global TargetIP "8.8.8.8"
:global TimeoutTime "3s"
:global PingCount 3

# Function to check ping via specific gateway/interface
:proc CheckPing {
    :local ip $1
    :local gateway $2
    :local interface $3
    
    :local result "FAIL"
    :local sent 0
    :local received 0
    
    if ($gateway != "") do={
        /ping address=$ip gateway=$gateway count=$PingCount timeout=$TimeoutTime do={
            :set received [/ ping address=$ip gateway=$gateway count=$PingCount timeout=$TimeoutTime as-value]->"received"
            :set sent [/ ping address=$ip gateway=$gateway count=$PingCount timeout=$TimeoutTime as-value]->"sent"
        }
        delay 1s
        if ($received > 0) do={ :set result "OK" }
    } else={
        /ping address=$ip interface=$interface count=$PingCount timeout=$TimeoutTime do={
            :set received [/ ping address=$ip interface=$interface count=$PingCount timeout=$TimeoutTime as-value]->"received"
            :set sent [/ ping address=$ip interface=$interface count=$PingCount timeout=$TimeoutTime as-value]->"sent"
        }
        delay 1s
        if ($received > 0) do={ :set result "OK" }
    }
    
    :return "$result (sent=$sent, received=$received)"
}

:put "=========================================="
:put "MikroTik Gateway & Tunnel IP Checker"
:put "Target IP: $TargetIP"
:put "Timeout: $TimeoutTime, Count: $PingCount"
:put "=========================================="

# Collect all active gateways from routing table
:local gateways [:toarray]
:local i 0
:foreach r in=[/ip route find where active=yes and gateway!="" and distance<255] do={
    :local gw [/ip route get $r gateway]
    :local dst [/ip route get $r dst-address]
    
    # Avoid duplicates
    :local found 0
    :foreach g in=$gateways do={
        if ($g = $gw) do={ :set found 1 }
    }
    if ($found = 0) do={
        :set ($gateways->$i) $gw
        :set i ($i + 1)
    }
}

# Collect tunnel interfaces
:local tunnels [:toarray]
:local j 0
:foreach t in=[/interface find where type~"tunnel|gre|ipip|eoip|l2tp|pptp|pppoe|vlan|vxlan|bonding"] do={
    :local tname [/interface get $t name]
    :local trunning [/interface get $t running]
    if ($trunning = true) do={
        :set ($tunnels->$j) $tname
        :set j ($j + 1)
    }
}

:put ""
:put "Found $($gateways->len) unique gateways:"
:foreach gw in=$gateways do={
    :put "  Gateway: $gw"
    :local status [CheckPing $TargetIP $gw ""]
    :put "    Status: $status"
}

:put ""
:put "Found $($tunnels->len) tunnel interfaces:"
:foreach tun in=$tunnels do={
    :put "  Tunnel: $tun"
    :local status [CheckPing $TargetIP "" $tun]
    :put "    Status: $status"
}

:put ""
:put "=========================================="
:put "Check completed."
:put "=========================================="
