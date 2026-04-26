:global powerRestoredFired
:if ([:typeof $powerRestoredFired] = "nothing") do={ :set powerRestoredFired "no" }

:local wifiInterface "wlan1"
:local powerThreshold 4
:local webhookUrl "https://examples.com/telegram-send/?name=electric&status=up&auth=1234567890"

:local wasDisabled [/interface/wireless/get $wifiInterface disabled]

:if ($wasDisabled = true) do={
    :log info "Enabling $wifiInterface for scan"
    /interface/wireless/set $wifiInterface disabled=no
    :delay 5
}

:local currentCount 0
:do {
    :local scanResult [/interface/wireless/scan $wifiInterface duration=5 as-value]
    :set currentCount [:len $scanResult]
    :log info "WiFi scan: found $currentCount networks"
} on-error={
    :log error "Scan failed on $wifiInterface"
}

:if ($wasDisabled = true) do={
    /interface/wireless/set $wifiInterface disabled=yes
}

:if ($currentCount >= $powerThreshold) do={
    :if ($powerRestoredFired = "no") do={
        :log warning "Power likely restored - $currentCount networks, firing webhook"
        :do {
            /tool/fetch url=$webhookUrl http-method=post \
                http-data="{\"event\":\"power_restored\",\"networks\":$currentCount}" \
                http-header-field="Content-Type: application/json" \
                output=none
            :set powerRestoredFired "yes"
        } on-error={ :log error "Webhook fetch failed" }
    }
} else={
    :if ($powerRestoredFired = "yes") do={
        :log info "Count dropped to $currentCount - resetting latch"
        :set powerRestoredFired "no"
    }
}
