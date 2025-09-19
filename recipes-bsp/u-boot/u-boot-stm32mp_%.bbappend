FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += "${@bb.utils.contains('MACHINE_FEATURES', '00395 00365', 'file://0001-Add-fdtfile-definition-for-cargt-00395-00365.patch', '', d)} \
            "