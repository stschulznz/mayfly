// I2P entry only. The system policy still applies (extensions blocked, DNS over
// HTTPS off, telemetry off, WebRTC address limits, developer tools off). These
// are user preferences: the router refuses clearnet requests whatever they say.
// ---- proxy: everything to the router's HTTP proxy, nothing direct ----
user_pref("network.proxy.type", 1);
user_pref("network.proxy.http", "127.0.0.1");
user_pref("network.proxy.http_port", 4444);
user_pref("network.proxy.ssl", "127.0.0.1");
user_pref("network.proxy.ssl_port", 4444);
user_pref("network.proxy.ftp", "");
user_pref("network.proxy.ftp_port", 0);
user_pref("network.proxy.socks", "");
user_pref("network.proxy.socks_port", 0);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.share_proxy_settings", false);
user_pref("network.proxy.no_proxies_on", "");
user_pref("network.proxy.allow_hijacking_localhost", true);
user_pref("network.proxy.failover_direct", false);
user_pref("network.proxy.allow_bypass", false);
user_pref("network.proxy.autoconfig_url", "");
user_pref("network.proxy.enable_wpad_over_dhcp", false);
user_pref("network.dns.disablePrefetch", true);
// ---- HTTPS-Only would block http://*.i2p; eepsites are mostly plain HTTP ----
user_pref("dom.security.https_only_mode", false);
user_pref("dom.security.https_first", false);
user_pref("dom.security.https_first_pbm", false);
user_pref("dom.security.https_first_schemeless", false);
// ---- WebRTC fully off ----
user_pref("media.peerconnection.enabled", false);
user_pref("media.peerconnection.ice.proxy_only", true);
// ---- the URL bar never turns typed words into searches or local lookups ----
user_pref("keyword.enabled", false);
user_pref("browser.fixup.domainsuffixwhitelist.i2p", true);
user_pref("browser.urlbar.dnsResolveSingleWordsAfterSearch", 0);
// ---- content posture ----
user_pref("javascript.enabled", false);
user_pref("privacy.resistFingerprinting", true);
user_pref("privacy.resistFingerprinting.letterboxing", true);
user_pref("network.http.referer.XOriginPolicy", 2);
user_pref("browser.startup.homepage", "about:blank");
user_pref("browser.startup.page", 0);
