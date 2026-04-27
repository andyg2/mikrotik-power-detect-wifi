:global powerRestoredFired
:if ([:typeof $powerRestoredFired] = "nothing") do={ :set powerRestoredFired "no" }

:local wifiInterface "wlan1"
:local signalCutoff -65
:local fireThreshold 3
:local resetThreshold 0
:local webhookUrl "https://examples.com/telegram-send/?name=electric&status=up&auth=1234567890"

:local wasDisabled [/interface/wireless/get $wifiInterface disabled]

:if ($wasDisabled = true) do={
    :log info "Enabling $wifiInterface for scan"
    /interface/wireless/set $wifiInterface disabled=no
    :delay 5
}

:local scanOk false
:local weakCount 0
:local totalCount 0
:do {
    :local scanResult [/interface/wireless/scan $wifiInterface duration=10 as-value]
    :set totalCount [:len $scanResult]
    :foreach entry in=$scanResult do={
        :local sig ($entry->"signal-strength")
        :if ([:typeof $sig] != "nothing") do={
            :if ($sig <= $signalCutoff) do={ :set weakCount ($weakCount + 1) }
        }
    }
    :set scanOk true
    :log info "WiFi scan: $totalCount total, $weakCount weak (<=$signalCutoff dBm)"
} on-error={
    :log error "Scan failed on $wifiInterface"
}

:if ($wasDisabled = true) do={
    /interface/wireless/set $wifiInterface disabled=yes
}

:if ($scanOk) do={
    :if ($weakCount >= $fireThreshold) do={
        :if ($powerRestoredFired = "no") do={
            :log warning "Power likely restored - $weakCount weak APs, firing webhook"
            :do {
                /tool/fetch url=$webhookUrl http-method=post \
                    http-data="{\"event\":\"power_restored\",\"weak\":$weakCount,\"total\":$totalCount}" \
                    http-header-field="Content-Type: application/json" \
                    output=none
                :set powerRestoredFired "yes"
            } on-error={ :log error "Webhook fetch failed" }
        }
    } else={
        :if ($weakCount <= $resetThreshold) do={
            :if ($powerRestoredFired = "yes") do={
                :log info "Weak count $weakCount <= $resetThreshold - resetting latch"
                :set powerRestoredFired "no"
            }
        }
    }
}
