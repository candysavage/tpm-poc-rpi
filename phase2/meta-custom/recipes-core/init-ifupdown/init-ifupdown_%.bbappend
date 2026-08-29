FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# Shadows poky/meta/recipes-core/init-ifupdown's stock interfaces file —
# same filename, found first via the prepended search path above, no
# SRC_URI change needed. See files/interfaces for what changed and why
# (eth0: static, not dhcp — this is a direct point-to-point link, not a
# router uplink, and no DHCP server exists on it).
