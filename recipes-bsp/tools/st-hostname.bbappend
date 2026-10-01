FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}/files:"

# Insert a separator between the MACHINE-derived base hostname and the MAC
# address st-hostname.sh appends - upstream joins them with no separator at
# all, which is genuinely hard to read whenever MACHINE ends in a digit
# right next to the MAC's own leading digit (see st-hostname.sh's own
# comment for the concrete example). Full-file override since the change
# touches several lines of the same short script.
